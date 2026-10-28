// SPDX-License-Identifier: MIT
//! `determinismo causality`: how likely a bug was at each moment of a timeline where it
//! happened, as Antithesis's causality analysis (docs/ANTITHESIS.md).
//!
//!   determinismo causality <machine and system options> --seed <s> --branch <n>
//!       [--tape <branch n's tape>] --property '<message>' [--points <k>] [--futures <m>]
//!       [--refine <rounds>] [--snapshots <dir>] [--failure-ms <ms> --snapshot-ms <ms>]
//!       [--jobs <futures at once>] [--json]
//!
//! With its tape, branch n is the one explored (a tree's branch starts inside its ancestors:
//! the tape has its path); without, the n-th branch from the setup snapshot.
//!
//! First it finds when the property first failed in branch n (`--until`). Then one replay saves
//! the timeline to disk just after the setup snapshot and at k moments from there to that failure (`explore
//! --save-snapshots`: each the pages changed since the one before; a moment before a tree
//! branch's start is an ancestor's, saved by a replay of that one), and m futures fork from each
//! (`--from-snapshot`: no boot, no replay), the moments in parallel. Where the probability then
//! jumps between two moments, `--refine` rounds add moments in between: the jump narrowed down to
//! where the timeline made the bug likely. Look at the logs just before it (`determinismo query
//! ... --branch <n> --up-to-vtime <s>`). Each moment's probability comes with its 90% interval
//! (Wilson's). A coin-flip bug (two heads) reads 25%, then 50% after the first flip, then 100%
//! after the second.
//!
//! The snapshots stay in `--snapshots <dir>` (a later analysis of the same timeline starts from
//! them); without it, in a directory of its own, removed at the end.
//!
//! Which moments, and how many futures each, is the planner's (`--planner`): built in (k moments
//! evenly, then halfway inside each jump of `--jump-min` or more until it is `--gap-min-ms` wide),
//! or a plugin on the strategy plugins' transport (a command's standard input and output, or
//! `tcp://host:port`: plugins/clojure/strategies.clj serves planners, reloaded live), asked once
//! per round with everything so far (docs/PLUGINS.md, "Causality planners"):
//!   -> {"method":"plan","round":r,"branch":n,"property":p,"snapshot_ms":s,"failure_ms":f,
//!       "futures":m,"points_asked":k,"jump_min":j,"gap_min_ms":g,"moments_left":l,
//!       "run_url":u|null,"tape":t|null,"points":[{"vtime_ms","futures","failing",
//!       "probability","low","high"}]}
//!   <- {"moments":[{"vtime_ms":t,"futures":m}],"note":"why these"}   (none: done)
//! `run_url` (`--run-url`, serve passes it) is the run's HTTP API: a planner may query its events
//! (the faults the timeline went through, its logs) to decide.
//!
//! What counts as the bug in a future is the verdict: the property failing by default, or any
//! event condition (`--verdict '<condition>'`, query.zig's language: a fault followed by a log
//! line, another property, ...): the timeline's replay stops at its first match (the failure's
//! moment), and so does each future, which then counts.
const std = @import("std");
const cpus = @import("cpus.zig");
const assert = std.debug.assert;

const Strategy = @import("strategy.zig");

const points_max = 64;
/// Moments in all (`--moments-max`), at most.
const moments_limit = 256;
const futures_max = 256;

const Request = struct {
    branch: u32,
    property: []const u8,
    points: u32 = 8,
    futures: u32 = 16,
    /// Rounds after the first, at most (the built-in planner's: until the jumps are narrow).
    refine: u32 = 6,
    moments_max: u32 = 40,
    /// The built-in planner narrows a jump this large between two moments, until it is this
    /// wide.
    jump_min: f64 = 0.2,
    gap_min_ms: u64 = 20,
    /// A planner plugin's command, or `tcp://host:port`; null: the built-in one.
    planner: ?[]const u8 = null,
    /// An event condition that is the bug (`--verdict`); null: the property failing.
    verdict: ?[]const u8 = null,
    /// The run's HTTP API (serve's), told to planners.
    run_url: ?[]const u8 = null,
    /// When the property first failed and the setup snapshot's moment, if known (`--failure-ms`,
    /// `--snapshot-ms`: serve reads them in the run's events); else a replay finds them.
    failure_ms: ?u64 = null,
    snapshot_ms: ?u64 = null,
    /// Futures at once (`--jobs`): 0, one per CPU of the host's pool (an analysis someone
    /// waits for); fewer for one in the background, beside a hunt.
    jobs: u32 = 0,
    /// Only save the first round's moments to disk (`--save-only`): serve snapshots a failure
    /// as soon as it is found, and a later analysis forks its futures right away.
    save_only: bool = false,
    json: bool = false,
    /// Branch n's tape: the timeline replayed and branched from (a tree's branch).
    tape: ?[]const u8 = null,
    snapshots: ?[]const u8 = null,
    /// Everything else: machine and system options, the seed; passed to every explore.
    rest: []const []const u8,
};

/// A moment analyzed: futures from it, how many failed.
const Point = struct { vtime_ms: u64, futures: u32, failing: u32 };
/// A moment to analyze, and with how many futures.
const Moment = struct { vtime_ms: u64, futures: u32 };

const Analysis = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    self: []const u8,
    request: *const Request,
    directory: []const u8,
    points: std.ArrayList(Point) = .empty,
    out: *std.Io.Writer,
    out_mutex: std.Io.Mutex = .init,
    failure: Failure,
    planner: ?*Strategy = null,
    /// The faults the futures went through (after their moment), each with how many futures had
    /// it and how many of those failed: which faults make the failure more likely (as
    /// Antithesis's causality shows which events do). Under out_mutex.
    effects: std.StringArrayHashMapUnmanaged(Effect) = .empty,
    futures_total: u32 = 0,
    futures_failing: u32 = 0,
};

const Effect = struct { with: u32 = 0, with_failing: u32 = 0 };

/// A fault event's name, as the page names faults: its kind (a degradation's flavor too), its
/// node, and its peer ("partition kafka-2↔runner"); null for another line.
fn fault_label(arena: std.mem.Allocator, line: []const u8) !?[]const u8 {
    const Line = struct { details: struct {
        kind: []const u8 = "",
        node: []const u8 = "",
        peer: []const u8 = "",
        flavor: ?[]const u8 = null,
        /// A pod fault's pod (Kubernetes): it names the fault, not the node it runs in.
        pod: []const u8 = "",
    } };
    const parsed = std.json.parseFromSliceLeaky(Line, arena, line, .{ .ignore_unknown_fields = true }) catch return null;
    const fault = parsed.details;
    if (fault.kind.len == 0) return null;
    return try std.fmt.allocPrint(arena, "{s}{s}{s}{s}{s}{s}{s}", .{
        fault.kind,
        if (fault.flavor != null) " " else "",
        fault.flavor orelse "",
        if (fault.node.len > 0) " " else "",
        if (fault.pod.len > 0) fault.pod else fault.node,
        if (fault.peer.len > 0) "↔" else "",
        fault.peer,
    });
}

test fault_label {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const partition = "{\"event\":\"fault\",\"details\":{\"at_ns\":0,\"kind\":\"partition\",\"node\":\"kafka-2\",\"peer\":\"runner\",\"flavor\":null}}";
    try std.testing.expectEqualStrings("partition kafka-2↔runner", (try fault_label(arena, partition)).?);
    const degrade = "{\"event\":\"fault\",\"details\":{\"kind\":\"degrade\",\"node\":\"yb3\",\"peer\":\"yb1\",\"flavor\":\"delay_loss\"}}";
    try std.testing.expectEqualStrings("degrade delay_loss yb3↔yb1", (try fault_label(arena, degrade)).?);
    try std.testing.expectEqual(null, try fault_label(arena, "not json"));
    const pod = "{\"event\":\"fault\",\"details\":{\"kind\":\"pod_kill\",\"node\":\"kubernetes\",\"pod\":\"redis-7c9-x2k\"}}";
    try std.testing.expectEqualStrings("pod_kill redis-7c9-x2k", (try fault_label(arena, pod)).?);
}

/// The faults' effects so far, as one line (serve keeps the latest): each fault seen in at least
/// two futures, the strongest first (how much more often futures with it failed than without).
fn effects_print(analysis: *Analysis) !void {
    if (analysis.futures_total == 0) return;
    const Ranked = struct { name: []const u8, effect: Effect, lift: f64 };
    var ranked: std.ArrayList(Ranked) = .empty;
    const total: f64 = @floatFromInt(analysis.futures_total);
    const failing: f64 = @floatFromInt(analysis.futures_failing);
    for (analysis.effects.keys(), analysis.effects.values()) |name, effect| {
        if (effect.with < 2) continue;
        const with: f64 = @floatFromInt(effect.with);
        const with_failing: f64 = @floatFromInt(effect.with_failing);
        const without = total - with;
        const rate_without = if (without > 0) (failing - with_failing) / without else 0;
        try ranked.append(analysis.arena, .{ .name = name, .effect = effect, .lift = with_failing / with - rate_without });
    }
    std.mem.sort(Ranked, ranked.items, {}, struct {
        fn more(_: void, a: Ranked, b: Ranked) bool {
            return a.lift > b.lift;
        }
    }.more);
    const out = analysis.out;
    if (!analysis.request.json) {
        try out.print("faults, by how much more often futures with them failed ({d} futures, {d} failing):\n", .{
            analysis.futures_total, analysis.futures_failing,
        });
        for (ranked.items[0..@min(ranked.items.len, 12)]) |entry| {
            try out.print("  {d:>5.1}%  {s}  ({d} of {d} failed)\n", .{
                entry.lift * 100, entry.name, entry.effect.with_failing, entry.effect.with,
            });
        }
        try out.flush();
        return;
    }
    try out.print("{{\"faults\":[", .{});
    for (ranked.items[0..@min(ranked.items.len, 40)], 0..) |entry, at| {
        if (at > 0) try out.writeAll(",");
        try out.print("{{\"fault\":{f},\"with\":{d},\"with_failing\":{d}}}", .{
            std.json.fmt(entry.name, .{}), entry.effect.with, entry.effect.with_failing,
        });
    }
    try out.print("],\"futures\":{d},\"failing\":{d}}}\n", .{ analysis.futures_total, analysis.futures_failing });
    try out.flush();
}

pub fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    self: []const u8,
    environ: [:null]const ?[*:0]const u8,
    arguments: []const [:0]const u8,
) !u8 {
    const request = try arguments_parse(arena, arguments);
    // Known already (serve reads them in the run's events): no replay to find them, the first
    // of the two a long timeline costs before any future (minutes for YugabyteDB's).
    const known: ?Failure = if (request.failure_ms) |failure_ms| if (request.snapshot_ms) |snapshot_ms| .{
        .snapshot_ms = snapshot_ms,
        .failure_ms = failure_ms,
    } else null else null;
    const failure = known orelse try failure_find(arena, io, self, &request) orelse {
        std.debug.print("[determinismo] causality: '{s}' does not fail in branch {d}\n", .{
            request.property, request.branch,
        });
        return 1;
    };
    var buffer: [16 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;
    if (request.json) {
        try out.print("{f}\n", .{std.json.fmt(.{ .causality = .{
            .branch = request.branch,
            .property = request.property,
            .failure_ms = failure.failure_ms,
            .snapshot_ms = failure.snapshot_ms,
            .futures = request.futures,
            .planner = request.planner orelse "built-in",
            .verdict = request.verdict,
        } }, .{})});
    } else {
        try out.print("'{s}' in branch {d}: first failure at {d}ms (snapshot at {d}ms); " ++
            "{d} futures per moment\n", .{
            request.property, request.branch, failure.failure_ms, failure.snapshot_ms,
            request.futures,
        });
    }
    try out.flush();
    const cwd = std.Io.Dir.cwd();
    const temporary = request.snapshots == null;
    const directory = request.snapshots orelse
        try std.fmt.allocPrint(arena, "/tmp/determinismo-causality-{d}", .{std.os.linux.getpid()});
    try cwd.createDirPath(io, directory);
    defer if (temporary) cwd.deleteTree(io, directory) catch {};
    var analysis: Analysis = .{
        .arena = arena,
        .io = io,
        .self = self,
        .request = &request,
        .directory = directory,
        .out = out,
        .failure = failure,
    };
    if (request.planner) |command| {
        const planner = try arena.create(Strategy);
        planner.* = undefined;
        try planner.start(arena, command, environ);
        analysis.planner = planner;
        const hello = try planner.call_json("{\"method\":\"hello\",\"protocol\":1,\"kind\":\"causality\"}");
        const name = hello.get("name") orelse return error.BadPluginReply;
        if (name == .string) std.debug.print("[determinismo] causality planner: {s}\n", .{name.string});
    }
    defer if (analysis.planner) |planner| planner.stop();
    if (request.save_only) {
        const moments = try plan(&analysis, 0);
        try moments_analyze(&analysis, moments);
        try out.print("{{\"saved\":{d},\"snapshots\":{f}}}\n", .{ moments.len, std.json.fmt(directory, .{}) });
        try out.flush();
        return 0;
    }
    for (0..request.refine + 1) |round| {
        const moments = try plan(&analysis, @intCast(round));
        if (moments.len == 0) break;
        try moments_analyze(&analysis, moments);
    }
    if (!request.json) {
        const points = analysis.points.items;
        std.mem.sort(Point, points, {}, point_earlier);
        try out.print("by moment:\n", .{});
        for (points) |point| try point_text(out, point);
    }
    try out.flush();
    return 0;
}

fn point_earlier(_: void, a: Point, b: Point) bool {
    return a.vtime_ms < b.vtime_ms;
}

fn point_text(out: *std.Io.Writer, point: Point) !void {
    const interval = wilson(point.failing, point.futures);
    var bar: [40]u8 = @splat(' ');
    const filled: usize = @trunc(interval.probability * bar.len);
    @memset(bar[0..filled], '#');
    try out.print("  {d:>8}ms  {d:>5.1}%  |{s}|  ({d}/{d}, 90%: {d:.0}-{d:.0}%)\n", .{
        point.vtime_ms,     interval.probability * 100, &bar, point.failing, point.futures,
        interval.low * 100, interval.high * 100,
    });
}

const Interval = struct { probability: f64, low: f64, high: f64 };

/// The 90% interval of a probability seen `failing` times in `futures` (Wilson's score
/// interval: sound at 0 and 1, where the plain one collapses).
fn wilson(failing: u32, futures: u32) Interval {
    assert(futures > 0 and failing <= futures);
    const z = 1.6448536269514722;
    const n: f64 = @floatFromInt(futures);
    const p = @as(f64, @floatFromInt(failing)) / n;
    const denominator = 1 + z * z / n;
    const center = (p + z * z / (2 * n)) / denominator;
    const half = z * @sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denominator;
    return .{ .probability = p, .low = @max(0, center - half), .high = @min(1, center + half) };
}

test wilson {
    const none = wilson(0, 16);
    try std.testing.expectEqual(@as(f64, 0), none.low);
    try std.testing.expect(none.high > 0.1 and none.high < 0.2);
    const half = wilson(8, 16);
    try std.testing.expect(half.low < 0.5 and half.high > 0.5);
    try std.testing.expectApproxEqAbs(half.low, 1 - half.high, 1e-9);
}

/// Where a tree's moment is: the taped timeline running then (an ancestor's before the branch
/// started) and the branch it is, which names its snapshots.
const Place = struct { tape: ?[]const u8, branch: u32 };

fn moment_place(analysis: *Analysis, moment_ms: u64) !Place {
    const request = analysis.request;
    const tape = request.tape orelse return .{ .tape = null, .branch = request.branch };
    const path = try tape_at(analysis.arena, analysis.io, tape, moment_ms);
    const name = std.fs.path.basename(path);
    const prefix = "branch-";
    const suffix = ".jsonl";
    if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, suffix)) return error.TapeName;
    const digits = name[prefix.len .. name.len - suffix.len];
    return .{ .tape = path, .branch = try std.fmt.parseInt(u32, digits, 10) };
}

/// The moments of the analyzed timeline already saved in the snapshots directory
/// (`b<timeline>-<ms>.state`), in milliseconds.
fn saved_moments(analysis: *Analysis) ![]const u64 {
    var found: std.ArrayList(u64) = .empty;
    var directory = std.Io.Dir.cwd().openDir(analysis.io, analysis.directory, .{ .iterate = true }) catch return found.items;
    defer directory.close(analysis.io);
    const prefix = try std.fmt.allocPrint(analysis.arena, "b{d}-", .{analysis.request.branch});
    var entries = directory.iterate();
    while (try entries.next(analysis.io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix) or !std.mem.endsWith(u8, entry.name, ".state")) continue;
        const digits = entry.name[prefix.len .. entry.name.len - ".state".len];
        try found.append(analysis.arena, std.fmt.parseInt(u64, digits, 10) catch continue);
    }
    return found.items;
}

fn snapshot_name(analysis: *Analysis, place: Place, moment_ms: u64) ![]const u8 {
    return std.fmt.allocPrint(analysis.arena, "{s}/b{d}-{d}", .{ analysis.directory, place.branch, moment_ms });
}

/// Saves the moments not saved yet (a replay per timeline they are in, at once), then forks
/// each one's futures (some moments at a time: each explore takes its futures' CPUs).
fn moments_analyze(analysis: *Analysis, moments_all: []const Moment) !void {
    const arena = analysis.arena;
    var tapes: std.ArrayList(?[]const u8) = .empty;
    var groups: std.ArrayList(std.ArrayList(u64)) = .empty;
    var places: std.ArrayList(Place) = .empty;
    for (moments_all) |moment| {
        const ms = moment.vtime_ms;
        const place = try moment_place(analysis, ms);
        try places.append(arena, place);
        const state = try std.fmt.allocPrint(arena, "{s}.state", .{try snapshot_name(analysis, place, ms)});
        if (std.Io.Dir.cwd().access(analysis.io, state, .{})) |_| continue else |_| {}
        const group = for (tapes.items, 0..) |tape, index| {
            const same = if (tape == null or place.tape == null) tape == null and place.tape == null else std.mem.eql(u8, tape.?, place.tape.?);
            if (same) break index;
        } else none: {
            try tapes.append(arena, place.tape);
            try groups.append(arena, .empty);
            break :none tapes.items.len - 1;
        };
        try groups.items[group].append(arena, ms);
    }
    // The replays that save them.
    const Save = struct {
        analysis: *Analysis,
        tape: ?[]const u8,
        moments: []const u64,
        failed: bool = false,

        fn run(save: *@This()) void {
            save.go() catch |err| {
                std.debug.print("[determinismo] causality: saving failed: {s}\n", .{@errorName(err)});
                save.failed = true;
            };
        }

        fn go(save: *@This()) !void {
            var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer arena_state.deinit();
            const scratch = arena_state.allocator();
            const request = save.analysis.request;
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(scratch, &.{ save.analysis.self, "explore" });
            try argv.appendSlice(scratch, request.rest);
            if (save.tape) |tape| {
                try argv.appendSlice(scratch, &.{ "--tape", tape });
            } else try argv.appendSlice(scratch, &.{ "--branch", try std.fmt.allocPrint(scratch, "{d}", .{request.branch}) });
            var list: std.ArrayList(u8) = .empty;
            for (save.moments, 0..) |ms, index| {
                if (index > 0) try list.append(scratch, ',');
                try list.print(scratch, "{d}", .{ms});
            }
            try argv.appendSlice(scratch, &.{ "--save-snapshots", save.analysis.directory, "--save-at-ms", list.items });
            const result = try std.process.run(scratch, save.analysis.io, .{ .argv = argv.items });
            const saved = std.mem.count(u8, result.stderr, "saved snapshot ");
            if (saved != save.moments.len) std.debug.print("[determinismo] causality: {d} of {d} " ++
                "moments saved (the others are left out)\n{s}\n", .{
                saved, save.moments.len, result.stderr[result.stderr.len -| 4096..],
            });
        }
    };
    const saves = try arena.alloc(Save, groups.items.len);
    const save_threads = try arena.alloc(std.Thread, groups.items.len);
    for (saves, save_threads, tapes.items, groups.items) |*save, *thread, tape, group| {
        save.* = .{ .analysis = analysis, .tape = tape, .moments = group.items };
        thread.* = try std.Thread.spawn(.{}, Save.run, .{save});
    }
    for (save_threads) |thread| thread.join();
    for (saves) |save| if (save.failed) return error.NotSaved;
    if (analysis.request.save_only) return;
    // The moments on disk: one a replay could not save is left out, not the analysis.
    var kept_moments: std.ArrayList(Moment) = .empty;
    var kept_places: std.ArrayList(Place) = .empty;
    for (moments_all, places.items) |moment, place| {
        const state = try std.fmt.allocPrint(arena, "{s}.state", .{try snapshot_name(analysis, place, moment.vtime_ms)});
        std.Io.Dir.cwd().access(analysis.io, state, .{}) catch continue;
        try kept_moments.append(arena, moment);
        try kept_places.append(arena, place);
    }
    if (kept_moments.items.len == 0) return error.NotSaved;
    const moments = kept_moments.items;
    places = kept_places;
    // Their futures, in one queue over every moment: each CPU takes the next as it frees up (a
    // moment's futures waited for its slowest, and the next moment for them: one moment at a
    // time, half an hour for a YugabyteDB timeline's first points, srv3 2026-10-27). Each
    // moment's first future first, then each one's second...: a rough curve after the first
    // wave. Each future updates its moment's point at once.
    const Item = struct { moment: u32, future: u32 };
    var items: std.ArrayList(Item) = .empty;
    var most: u32 = 0;
    for (moments) |moment| most = @max(most, moment.futures);
    for (0..most) |future| for (moments, 0..) |moment, index| {
        if (future < moment.futures) try items.append(arena, .{ .moment = @intCast(index), .future = @intCast(future) });
    };
    const Futures = struct {
        analysis: *Analysis,
        names: []const []const u8,
        moments: []const Moment,
        items: []const Item,
        /// Per moment: its futures finished so far, the failing ones among them, and where its
        /// point is in the analysis's points.
        finished: []u32,
        failing: []u32,
        at: []?usize,
        next: std.atomic.Value(usize) = .init(0),
        failed: std.atomic.Value(bool) = .init(false),

        fn run(futures: *@This()) void {
            while (true) {
                const index = futures.next.fetchAdd(1, .monotonic);
                if (index >= futures.items.len) return;
                const item = futures.items[index];
                futures.one(item) catch |err| {
                    std.debug.print("[determinismo] causality: future {d} at {d}ms failed: {s}\n", .{
                        item.future, futures.moments[item.moment].vtime_ms, @errorName(err),
                    });
                    futures.failed.store(true, .monotonic);
                };
            }
        }

        fn one(futures: *@This(), item: Item) !void {
            var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer arena_state.deinit();
            const scratch = arena_state.allocator();
            const owner = futures.analysis;
            const request = owner.request;
            const io = owner.io;
            const moment = futures.moments[item.moment];
            const record = try std.fmt.allocPrint(scratch, "{s}/futures-{d}-{d}.jsonl", .{
                owner.directory, moment.vtime_ms, item.future,
            });
            defer std.Io.Dir.cwd().deleteFile(io, record) catch {};
            const faults = try std.fmt.allocPrint(scratch, "{s}/faults-{d}-{d}.jsonl", .{
                owner.directory, moment.vtime_ms, item.future,
            });
            defer std.Io.Dir.cwd().deleteFile(io, faults) catch {};
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(scratch, &.{ owner.self, "explore" });
            try argv.appendSlice(scratch, request.rest);
            try argv.appendSlice(scratch, &.{
                "--from-snapshot", futures.names[item.moment],
                "--branch",        try std.fmt.allocPrint(scratch, "{d}", .{item.future}),
                "--record",        record,
                "--faults-record", faults,
            });
            // A verdict: the future stops at its first match, which counts.
            if (request.verdict) |verdict| try argv.appendSlice(scratch, &.{ "--until", verdict });
            _ = try std.process.run(scratch, io, .{ .argv = argv.items });
            const source = try std.Io.Dir.cwd().readFileAlloc(io, record, scratch, .limited(1 << 24));
            const failing: u32 = if (request.verdict != null)
                @intCast(std.mem.count(u8, source, "\"outcome\":\"moment_reached\""))
            else
                try property_failing(scratch, source, request.property);
            // The faults it went through, each once.
            var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
            const fault_lines = std.Io.Dir.cwd().readFileAlloc(io, faults, scratch, .limited(16 << 20)) catch "";
            var fault_iterator = std.mem.tokenizeScalar(u8, fault_lines, '\n');
            while (fault_iterator.next()) |line| {
                if (try fault_label(scratch, line)) |label| try seen.put(scratch, label, {});
            }
            owner.out_mutex.lockUncancelable(io);
            defer owner.out_mutex.unlock(io);
            owner.futures_total += 1;
            owner.futures_failing += @intFromBool(failing > 0);
            for (seen.keys()) |label| {
                const entry = try owner.effects.getOrPut(owner.arena, label);
                if (!entry.found_existing) {
                    entry.key_ptr.* = try owner.arena.dupe(u8, label);
                    entry.value_ptr.* = .{};
                }
                entry.value_ptr.with += 1;
                entry.value_ptr.with_failing += @intFromBool(failing > 0);
            }
            futures.finished[item.moment] += 1;
            futures.failing[item.moment] += failing;
            const point: Point = .{
                .vtime_ms = moment.vtime_ms,
                .futures = futures.finished[item.moment],
                .failing = futures.failing[item.moment],
            };
            if (futures.at[item.moment]) |at| {
                owner.points.items[at] = point;
            } else {
                futures.at[item.moment] = owner.points.items.len;
                try owner.points.append(owner.arena, point);
            }
            try point_print(owner, point); // The moment's estimate so far (serve keeps the latest).
        }
    };
    const names = try arena.alloc([]const u8, moments.len);
    for (names, places.items, moments) |*name, place, moment| {
        name.* = try snapshot_name(analysis, place, moment.vtime_ms);
    }
    const finished = try arena.alloc(u32, moments.len);
    @memset(finished, 0);
    const failing = try arena.alloc(u32, moments.len);
    @memset(failing, 0);
    const at = try arena.alloc(?usize, moments.len);
    @memset(at, null);
    var futures: Futures = .{
        .analysis = analysis,
        .names = names,
        .moments = moments,
        .items = items.items,
        .finished = finished,
        .failing = failing,
        .at = at,
    };
    // One VM per future, one per CPU of the host's pool (cpus.zig), or as many as `--jobs`.
    const wanted = if (analysis.request.jobs > 0) analysis.request.jobs else cpus.usable_count();
    const at_once = std.math.clamp(wanted, 1, @max(1, items.items.len));
    const threads = try arena.alloc(std.Thread, at_once);
    for (threads) |*thread| thread.* = try std.Thread.spawn(.{}, Futures.run, .{&futures});
    for (threads) |thread| thread.join();
    try effects_print(analysis);
    if (futures.failed.load(.monotonic)) return error.FuturesFailed;
}

fn point_print(analysis: *Analysis, point: Point) !void {
    const out = analysis.out;
    if (analysis.request.json) {
        const interval = wilson(point.failing, point.futures);
        const format = "{{\"vtime_ms\":{d},\"futures\":{d},\"failing\":{d}," ++
            "\"probability\":{d:.3},\"low\":{d:.3},\"high\":{d:.3}}}\n";
        try out.print(format, .{
            point.vtime_ms, point.futures, point.failing, interval.probability, interval.low, interval.high,
        });
    } else try point_text(out, point);
    try out.flush();
}

/// The next round's moments: the planner's, without moments already analyzed or outside the
/// timeline (after the snapshot, up to the failure), within the moments left.
fn plan(analysis: *Analysis, round: u32) ![]const Moment {
    const asked = if (analysis.planner) |planner|
        try plan_plugin(analysis, planner, round)
    else
        try plan_built_in(analysis, round);
    const failure = analysis.failure;
    const left = analysis.request.moments_max -| @as(u32, @intCast(analysis.points.items.len));
    var moments: std.ArrayList(Moment) = .empty;
    for (asked) |moment| {
        if (moments.items.len == left) break;
        if (moment.vtime_ms <= failure.snapshot_ms or moment.vtime_ms > failure.failure_ms) continue;
        if (moment.futures == 0 or moment.futures > futures_max) continue;
        const known = for (analysis.points.items) |point| {
            if (point.vtime_ms == moment.vtime_ms) break true;
        } else for (moments.items) |other| {
            if (other.vtime_ms == moment.vtime_ms) break true;
        } else false;
        if (!known) try moments.append(analysis.arena, moment);
    }
    return moments.items;
}

/// The moment just after the setup snapshot (the bug's probability before the timeline did
/// anything: a jump from there is narrowed as any other), and k moments evenly to the failure
/// (the last one at it); then halfway inside the largest jumps so far (at most k a round):
/// between two neighbors whose probabilities differ by `jump_min` or more, until they are
/// `gap_min_ms` apart.
fn plan_built_in(analysis: *Analysis, round: u32) ![]const Moment {
    const request = analysis.request;
    const failure = analysis.failure;
    var moments: std.ArrayList(Moment) = .empty;
    if (round == 0) {
        try moments.append(analysis.arena, .{ .vtime_ms = failure.snapshot_ms + 1, .futures = request.futures });
        const span = failure.failure_ms - failure.snapshot_ms;
        // Evenly, each moment the nearest one saved already (the explorer's ladder of a failing
        // timeline, an earlier analysis's) within half a step: those need no replay to save.
        const saved = try saved_moments(analysis);
        const half_step = span / request.points / 2;
        for (0..request.points) |index| {
            const step = span * (index + 1) / request.points;
            const even = failure.snapshot_ms + @max(step, 1);
            var chosen = even;
            var distance: u64 = half_step + 1;
            for (saved) |ms| {
                if (ms <= failure.snapshot_ms + 1 or ms > failure.failure_ms) continue;
                const apart = if (ms > even) ms - even else even - ms;
                if (apart < distance) {
                    distance = apart;
                    chosen = ms;
                }
            }
            const repeated = for (moments.items) |moment| {
                if (moment.vtime_ms == chosen) break true;
            } else false;
            try moments.append(analysis.arena, .{ .vtime_ms = if (repeated) even else chosen, .futures = request.futures });
        }
        return moments.items;
    }
    const points = analysis.points.items;
    std.mem.sort(Point, points, {}, point_earlier);
    const Jump = struct { size: f64, moment_ms: u64 };
    var found: std.ArrayList(Jump) = .empty;
    if (points.len >= 2) for (points[0 .. points.len - 1], points[1..]) |a, b| {
        if (b.vtime_ms - a.vtime_ms < request.gap_min_ms) continue; // Narrow enough.
        const pa = @as(f64, @floatFromInt(a.failing)) / @as(f64, @floatFromInt(a.futures));
        const pb = @as(f64, @floatFromInt(b.failing)) / @as(f64, @floatFromInt(b.futures));
        if (@abs(pb - pa) < request.jump_min) continue;
        try found.append(analysis.arena, .{ .size = @abs(pb - pa), .moment_ms = a.vtime_ms + (b.vtime_ms - a.vtime_ms) / 2 });
    };
    const Order = struct {
        fn larger(_: void, x: Jump, y: Jump) bool {
            return x.size > y.size;
        }
    };
    std.mem.sort(Jump, found.items, {}, Order.larger);
    for (found.items[0..@min(found.items.len, request.points)]) |jump| {
        try moments.append(analysis.arena, .{ .vtime_ms = jump.moment_ms, .futures = request.futures });
    }
    return moments.items;
}

/// Asks the planner plugin (module comment: its request and reply).
fn plan_plugin(analysis: *Analysis, planner: *Strategy, round: u32) ![]const Moment {
    const request = analysis.request;
    const PointOut = struct { vtime_ms: u64, futures: u32, failing: u32, probability: f64, low: f64, high: f64 };
    const points = try analysis.arena.alloc(PointOut, analysis.points.items.len);
    for (analysis.points.items, points) |point, *out| {
        const interval = wilson(point.failing, point.futures);
        out.* = .{
            .vtime_ms = point.vtime_ms,
            .futures = point.futures,
            .failing = point.failing,
            .probability = interval.probability,
            .low = interval.low,
            .high = interval.high,
        };
    }
    const text = try std.fmt.allocPrint(analysis.arena, "{f}", .{std.json.fmt(.{
        .method = "plan",
        .round = round,
        .branch = request.branch,
        .property = request.property,
        .snapshot_ms = analysis.failure.snapshot_ms,
        .failure_ms = analysis.failure.failure_ms,
        .futures = request.futures,
        .points_asked = request.points,
        .jump_min = request.jump_min,
        .gap_min_ms = request.gap_min_ms,
        .moments_left = request.moments_max -| @as(u32, @intCast(points.len)),
        .run_url = request.run_url,
        .tape = request.tape,
        .points = points,
    }, .{})});
    const reply = try planner.call_json(text);
    if (reply.get("note")) |note| if (note == .string) {
        std.debug.print("[determinismo] causality planner, round {d}: {s}\n", .{ round, note.string });
    };
    const list = reply.get("moments") orelse return &.{};
    if (list != .array) return error.BadPluginReply;
    const moments = try analysis.arena.alloc(Moment, list.array.items.len);
    for (list.array.items, moments) |item, *moment| {
        if (item != .object) return error.BadPluginReply;
        const vtime = item.object.get("vtime_ms") orelse return error.BadPluginReply;
        if (vtime != .integer or vtime.integer < 0) return error.BadPluginReply;
        const futures: i64 = if (item.object.get("futures")) |value| switch (value) {
            .integer => |integer| integer,
            else => return error.BadPluginReply,
        } else request.futures;
        moment.* = .{ .vtime_ms = @intCast(vtime.integer), .futures = @intCast(std.math.clamp(futures, 0, futures_max)) };
    }
    return moments;
}

fn arguments_parse(arena: std.mem.Allocator, arguments: []const [:0]const u8) !Request {
    var request = Request{ .branch = 0, .property = "", .rest = &.{} };
    var branch: ?u32 = null;
    var rest: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const flag = arguments[index];
        const eql = std.mem.eql;
        if (eql(u8, flag, "--json")) {
            request.json = true;
            continue;
        }
        if (eql(u8, flag, "--save-only")) {
            request.save_only = true;
            continue;
        }
        const ours = eql(u8, flag, "--branch") or eql(u8, flag, "--property") or
            eql(u8, flag, "--points") or eql(u8, flag, "--futures") or eql(u8, flag, "--tape") or
            eql(u8, flag, "--refine") or eql(u8, flag, "--snapshots") or
            eql(u8, flag, "--planner") or eql(u8, flag, "--run-url") or
            eql(u8, flag, "--jump-min") or eql(u8, flag, "--gap-min-ms") or
            eql(u8, flag, "--moments-max") or eql(u8, flag, "--verdict") or
            eql(u8, flag, "--failure-ms") or eql(u8, flag, "--snapshot-ms") or eql(u8, flag, "--jobs");
        if (!ours) {
            try rest.append(arena, flag);
            continue;
        }
        index += 1;
        if (index == arguments.len) return error.Usage;
        const value = arguments[index];
        if (eql(u8, flag, "--branch")) {
            branch = try std.fmt.parseInt(u32, value, 10);
        } else if (eql(u8, flag, "--property")) {
            request.property = value;
        } else if (eql(u8, flag, "--tape")) {
            request.tape = value;
        } else if (eql(u8, flag, "--points")) {
            request.points = try std.fmt.parseInt(u32, value, 10);
        } else if (eql(u8, flag, "--refine")) {
            request.refine = try std.fmt.parseInt(u32, value, 10);
        } else if (eql(u8, flag, "--snapshots")) {
            request.snapshots = value;
        } else if (eql(u8, flag, "--planner")) {
            request.planner = value;
        } else if (eql(u8, flag, "--verdict")) {
            request.verdict = value;
        } else if (eql(u8, flag, "--run-url")) {
            request.run_url = value;
        } else if (eql(u8, flag, "--jump-min")) {
            request.jump_min = try std.fmt.parseFloat(f64, value);
        } else if (eql(u8, flag, "--gap-min-ms")) {
            request.gap_min_ms = try std.fmt.parseInt(u64, value, 10);
        } else if (eql(u8, flag, "--moments-max")) {
            request.moments_max = try std.fmt.parseInt(u32, value, 10);
        } else if (eql(u8, flag, "--failure-ms")) {
            request.failure_ms = try std.fmt.parseInt(u64, value, 10);
        } else if (eql(u8, flag, "--snapshot-ms")) {
            request.snapshot_ms = try std.fmt.parseInt(u64, value, 10);
        } else if (eql(u8, flag, "--jobs")) {
            request.jobs = try std.fmt.parseInt(u32, value, 10);
        } else {
            request.futures = try std.fmt.parseInt(u32, value, 10);
        }
    }
    request.branch = branch orelse return error.Usage;
    if (request.property.len == 0 and request.verdict == null) return error.Usage;
    if (request.points == 0 or request.points > points_max) return error.Usage;
    if (request.futures == 0 or request.futures > futures_max) return error.Usage;
    if (request.moments_max == 0 or request.moments_max > moments_limit) return error.Usage;
    if (!(request.jump_min > 0 and request.jump_min <= 1)) return error.Usage;
    request.rest = rest.items;
    return request;
}

const Failure = struct { snapshot_ms: u64, failure_ms: u64 };

/// Replays the branch until the property's first failure (`--until`).
fn failure_find(
    arena: std.mem.Allocator,
    io: std.Io,
    self: []const u8,
    request: *const Request,
) !?Failure {
    const until = request.verdict orelse try property_condition(arena, request.property);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ self, "explore" });
    try argv.appendSlice(arena, request.rest);
    if (request.tape) |path| {
        try argv.appendSlice(arena, &.{ "--tape", path, "--until", until });
    } else try argv.appendSlice(arena, &.{
        "--branch", try std.fmt.allocPrint(arena, "{d}", .{request.branch}), "--until", until,
    });
    const result = try std.process.run(arena, io, .{ .argv = argv.items });
    const snapshot_s = number_after(result.stderr, "snapshot at setup_complete: vtime=") orelse
        return error.NoSnapshot;
    // The last moment: a tree's branch replays along its path first (a moment per ancestor).
    const moment_ns = number_after_last(result.stderr, "at moment vtime=") orelse return null;
    return .{
        .snapshot_ms = @trunc(snapshot_s * 1000),
        .failure_ms = @trunc(moment_ns / std.time.ns_per_ms),
    };
}

/// A failing evaluation of the property (declarations, `hit` false, are not): an always kind
/// false, an unreachable reached.
fn property_condition(arena: std.mem.Allocator, property: []const u8) ![]const u8 {
    const message = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(property, .{})});
    return std.fmt.allocPrint(arena, "assert.message={s} assert.condition=false or " ++
        "assert.message={s} assert.type=unreachable assert.condition=true or " ++
        "antithesis_assert.message={s} antithesis_assert.hit=true antithesis_assert.condition=false or " ++
        "antithesis_assert.message={s} antithesis_assert.hit=true antithesis_assert.display_type=Unreachable", .{
        message, message, message, message,
    });
}

/// The tape of the timeline that was running at a moment: a tree's branch starts inside its
/// ancestors (its tape's chain: each ancestor and where the next branched from it), so a moment
/// before its start is an ancestor's, whose tape is beside it.
fn tape_at(arena: std.mem.Allocator, io: std.Io, tape: []const u8, moment_ms: u64) ![]const u8 {
    const Header = struct { chain: []const struct { branch: u32, vtime_ns: u64 } = &.{} };
    const text = try std.Io.Dir.cwd().readFileAlloc(io, tape, arena, .limited(1 << 24));
    const first = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    const header = try std.json.parseFromSliceLeaky(Header, arena, first, .{ .ignore_unknown_fields = true });
    for (header.chain) |segment| {
        if (moment_ms * std.time.ns_per_ms >= segment.vtime_ns) continue;
        const directory = std.fs.path.dirname(tape) orelse ".";
        return std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ directory, segment.branch });
    }
    return tape;
}

const Summary = struct {
    summary: struct {
        properties: []const struct { message: []const u8, branches_failing: u32 },
    },
};

fn property_failing(arena: std.mem.Allocator, record: []const u8, property: []const u8) !u32 {
    var lines = std.mem.tokenizeScalar(u8, record, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "{\"summary\":")) continue;
        const summary = try std.json.parseFromSliceLeaky(Summary, arena, line, .{
            .ignore_unknown_fields = true,
        });
        for (summary.summary.properties) |entry| {
            if (std.mem.eql(u8, entry.message, property)) return entry.branches_failing;
        }
        return 0; // Never evaluated in these futures: not failing.
    }
    return error.NoSummary;
}

/// The number right after `key` in `text` (as "1.017s" or "1053000000ns": digits and a dot).
fn number_after(text: []const u8, key: []const u8) ?f64 {
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    return number_at(text, at + key.len);
}

/// The number right after the last `key` in `text`.
fn number_after_last(text: []const u8, key: []const u8) ?f64 {
    const at = std.mem.lastIndexOf(u8, text, key) orelse return null;
    return number_at(text, at + key.len);
}

fn number_at(text: []const u8, start: usize) ?f64 {
    var end = start;
    while (end < text.len and (std.ascii.isDigit(text[end]) or text[end] == '.')) end += 1;
    return std.fmt.parseFloat(f64, text[start..end]) catch null;
}

test number_after {
    const output = "[determinismo] snapshot at setup_complete: vtime=1.017s branches=3\n" ++
        "[determinismo] at moment vtime=1053000000ns branches=4\n";
    try std.testing.expectEqual(@as(f64, 1.017), number_after(output, "setup_complete: vtime=").?);
    try std.testing.expectEqual(@as(f64, 1053000000), number_after(output, "at moment vtime=").?);
    const chain = output ++ "[determinismo] at moment vtime=2053000000ns branches=5\n";
    try std.testing.expectEqual(@as(f64, 2053000000), number_after_last(chain, "at moment vtime=").?);
}
