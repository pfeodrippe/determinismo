// SPDX-License-Identifier: MIT
//! `determinismo verify <explore options> --record <run.jsonl> --tape-dir <dir> [--sample <n>]
//! [--timeline <n>]... [--jobs <n>]`, or `determinismo verify --run <a run's directory>
//! [--sample <n>] [--timeline <n>]... [--jobs <n>]` (the explore options, record and tapes of a
//! run serve made, as its replays take them): replays a sample of a run's timelines (or the
//! ones named: a timeline under suspicion) from their tapes, each its own explore
//! (taking CPUs from the pool, beside whatever else runs on the host: a hunt, other runs), and
//! compares each history with the record's (its events hash). A timeline that does not replay
//! is a determinism bug of determinismo's, found under real load: its replay's first difference
//! is where to look (explore --trace: its .rdtsc log, then DETERMINISMO_ITRACE_AT).
//!
//! Exit status: 0 every sampled timeline replayed, 3 some did not, 2 usage.
const std = @import("std");
const assert = std.debug.assert;
const serve = @import("serve.zig");
const replays = @import("replays.zig");

const sample_default = 8;
const jobs_default = 2;
const timelines_max = 1 << 20;

const Timeline = struct {
    index: u32,
    events_hash: []const u8,
    /// Filled by the replay.
    replayed_hash: []const u8 = "",
    diverged: []const u8 = "",
    hazards: []const u8 = "",
    /// Its tape was recorded by another build of determinismo: parting may be the build's doing.
    other_build: bool = false,
    /// Where its events parted from the run's (replays.parting), when the run's are at hand.
    parted: []const u8 = "",
    status: u8 = 0,
    /// When nothing was replayed: how the replay ended (its last lines), so that a replay that
    /// could not start says why instead of passing for a divergence.
    ended: []const u8 = "",
    /// A divergence's report: the replay's last events before the checkpoint it failed (vm.zig's
    /// recent_print), to compare with the run's events there.
    recent: []const u8 = "",
};

/// The end of a replay's output kept when it replayed nothing.
const ended_size_max = 400;

const Work = struct {
    io: std.Io,
    self: []const u8,
    rest: []const []const u8,
    tape_directory: []const u8,
    /// The run's events (a run directory's `events`): each replay's are compared with them.
    events: ?[]const u8 = null,
    timelines: []Timeline,
    next: std.atomic.Value(usize) = .init(0),
};

pub fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    self: []const u8,
    arguments: []const [:0]const u8,
) !u8 {
    var record_path: ?[]const u8 = null;
    var tape_directory: ?[]const u8 = null;
    var run_directory: ?[]const u8 = null;
    var events_directory: ?[]const u8 = null;
    var sample: usize = sample_default;
    var jobs: usize = jobs_default;
    var named: std.ArrayList(u32) = .empty;
    var rest: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const flag = arguments[index];
        const value: ?[]const u8 = if (index + 1 < arguments.len) arguments[index + 1] else null;
        if (std.mem.eql(u8, flag, "--record") and value != null) {
            record_path = value;
            index += 1;
        } else if (std.mem.eql(u8, flag, "--tape-dir") and value != null) {
            tape_directory = value;
            index += 1;
        } else if (std.mem.eql(u8, flag, "--run") and value != null) {
            run_directory = value;
            index += 1;
        } else if (std.mem.eql(u8, flag, "--sample") and value != null) {
            sample = std.fmt.parseInt(usize, value.?, 10) catch return usage();
            index += 1;
        } else if (std.mem.eql(u8, flag, "--jobs") and value != null) {
            jobs = std.fmt.parseInt(usize, value.?, 10) catch return usage();
            index += 1;
        } else if (std.mem.eql(u8, flag, "--timeline") and value != null) {
            try named.append(arena, std.fmt.parseInt(u32, value.?, 10) catch return usage());
            index += 1;
        } else try rest.append(arena, flag);
    }
    if (run_directory) |directory| {
        var options: std.ArrayList([]const u8) = .empty;
        try run_arguments(arena, io, directory, &options);
        try options.appendSlice(arena, rest.items);
        rest = options;
        record_path = record_path orelse try std.fs.path.join(arena, &.{ directory, "record.jsonl" });
        tape_directory = tape_directory orelse try std.fs.path.join(arena, &.{ directory, "tapes" });
        events_directory = try std.fs.path.join(arena, &.{ directory, "events" });
    }
    const record = record_path orelse return usage();
    const tapes = tape_directory orelse return usage();
    if (sample == 0 or jobs == 0) return usage();
    const all = try record_timelines(arena, io, record, tapes);
    if (all.len == 0) {
        std.debug.print("[determinismo] verify: {s} has no timeline with a tape in {s}\n", .{ record, tapes });
        return 2;
    }
    // The timelines named, or the same sample each time for one record: a pseudo-random choice,
    // seeded by its size.
    var chosen = all;
    if (named.items.len > 0) {
        var kept: usize = 0;
        for (all) |timeline| {
            const wanted = std.mem.indexOfScalar(u32, named.items, timeline.index) != null;
            if (!wanted) continue;
            all[kept] = timeline;
            kept += 1;
        }
        if (kept < named.items.len) {
            std.debug.print("[determinismo] verify: {d} of the {d} timelines named have no tape in {s}\n", .{
                named.items.len - kept, named.items.len, tapes,
            });
            return 2;
        }
        chosen = all[0..kept];
    } else if (all.len > sample) {
        var random: std.Random.DefaultPrng = .init(all.len);
        random.random().shuffle(Timeline, all);
        chosen = all[0..sample];
        std.mem.sort(Timeline, chosen, {}, struct {
            fn less(_: void, a: Timeline, b: Timeline) bool {
                return a.index < b.index;
            }
        }.less);
    }
    std.debug.print("[determinismo] verify: replaying {d} of {d} timelines, {d} at a time\n", .{
        chosen.len, all.len, jobs,
    });
    var work: Work = .{
        .io = io,
        .self = self,
        .rest = rest.items,
        .tape_directory = tapes,
        .events = events_directory,
        .timelines = chosen,
    };
    const threads = try arena.alloc(std.Thread, @min(jobs, chosen.len));
    for (threads) |*thread| thread.* = try std.Thread.spawn(.{}, replay_worker, .{&work});
    for (threads) |thread| thread.join();
    var failed: u32 = 0;
    for (chosen) |timeline| {
        const same = timeline.status != 255 and timeline.diverged.len == 0 and
            std.mem.eql(u8, timeline.replayed_hash, timeline.events_hash);
        if (same) {
            std.debug.print("  PASS timeline {d} replays (events hash {s})\n", .{ timeline.index, timeline.events_hash });
            continue;
        }
        failed += 1;
        std.debug.print("  FAIL timeline {d} does not replay: recorded {s}, replayed {s}{s}{s}{s}{s}{s}{s}\n", .{
            timeline.index,
            timeline.events_hash,
            if (timeline.replayed_hash.len > 0) timeline.replayed_hash else "nothing",
            if (timeline.diverged.len > 0) "; " else "",
            timeline.diverged,
            if (timeline.hazards.len > 0) "; " else "",
            timeline.hazards,
            if (timeline.other_build) "; recorded by another build of determinismo" else "",
            timeline.parted,
        });
        if (timeline.ended.len > 0) std.debug.print("    {s}\n", .{timeline.ended});
        if (timeline.recent.len > 0) std.debug.print("{s}", .{timeline.recent});
    }
    std.debug.print("[determinismo] verify: {d} of {d} timelines replayed\n", .{ chosen.len - failed, chosen.len });
    return if (failed > 0) 3 else 0;
}

fn usage() u8 {
    std.debug.print("usage: determinismo verify <explore options> --record <run.jsonl> " ++
        "--tape-dir <dir> [--sample <n>] [--timeline <n>]... [--jobs <n>]\n" ++
        "       determinismo verify --run <run directory> [--sample <n>] [--timeline <n>]... " ++
        "[--jobs <n>]\n", .{});
    return 2;
}

/// A run's explore options, as serve's replays take them (serve.zig's run_replay): the machine
/// it booted, its system, its pin, its seed, scenario and profile. A replay missing one is
/// refused (other inputs) or is another system.
fn run_arguments(
    arena: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    options: *std.ArrayList([]const u8),
) !void {
    const cwd = std.Io.Dir.cwd();
    const machine_path = try std.fs.path.join(arena, &.{ directory, "machine.json" });
    const machine_json = try cwd.readFileAlloc(io, machine_path, arena, .limited(1 << 20));
    try options.appendSlice(arena, try std.json.parseFromSliceLeaky([]const []const u8, arena, machine_json, .{}));
    const request_path = try std.fs.path.join(arena, &.{ directory, "request.json" });
    const request_json = try cwd.readFileAlloc(io, request_path, arena, .limited(1 << 20));
    const request = try std.json.parseFromSliceLeaky(serve.RunRequest, arena, request_json, .{
        .ignore_unknown_fields = true,
    });
    try serve.system_arguments(arena, options, &request);
    const pin = try std.fs.path.join(arena, &.{ directory, "events", "system.pin.json" });
    if (cwd.access(io, pin, .{})) |_| try options.appendSlice(arena, &.{ "--system", pin }) else |_| {}
    try options.appendSlice(arena, &.{ "--seed", try std.fmt.allocPrint(arena, "{d}", .{request.seed orelse 0}) });
    if (request.scenario) |scenario| try options.appendSlice(arena, &.{ "--scenario", scenario });
    if (request.profile) |profile| try options.appendSlice(arena, &.{ "--profile", profile });
}

/// The record's timelines (index, events hash) whose tape is in `tapes`.
fn record_timelines(arena: std.mem.Allocator, io: std.Io, path: []const u8, tapes: []const u8) ![]Timeline {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    const Line = struct { branch: ?struct { index: u32, events_hash: []const u8 } = null };
    var out: std.ArrayList(Timeline) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "{\"branch\":")) continue;
        const parsed = std.json.parseFromSliceLeaky(Line, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        const branch = parsed.branch orelse continue;
        const tape = try tape_path(arena, tapes, branch.index);
        std.Io.Dir.cwd().access(io, tape, .{}) catch continue;
        if (out.items.len == timelines_max) return error.TooManyTimelines;
        try out.append(arena, .{ .index = branch.index, .events_hash = branch.events_hash });
    }
    return out.items;
}

fn tape_path(arena: std.mem.Allocator, tapes: []const u8, index: u32) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ tapes, index });
}

fn replay_worker(work: *Work) void {
    while (true) {
        const position = work.next.fetchAdd(1, .monotonic);
        if (position >= work.timelines.len) return;
        replay(work, &work.timelines[position]) catch |err| {
            work.timelines[position].status = 255;
            work.timelines[position].diverged = @errorName(err);
        };
    }
}

/// One replay, its own process: `explore <options> --tape <tape>`. Its strings live in the
/// page allocator (one arena per replay, kept: the results outlive the worker).
fn replay(work: *Work, timeline: *Timeline) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const arena = arena_state.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ work.self, "explore" });
    try argv.appendSlice(arena, work.rest);
    try argv.appendSlice(arena, &.{ "--tape", try tape_path(arena, work.tape_directory, timeline.index) });
    // Its events beside the tapes, compared with the run's if it parts (kept then, as evidence).
    const replay_events: ?[]const u8 = if (work.events != null)
        try std.fmt.allocPrint(arena, "{s}/verify-{d}-events", .{ work.tape_directory, timeline.index })
    else
        null;
    if (replay_events) |directory| try argv.appendSlice(arena, &.{ "--events-dir", directory });
    defer if (replay_events) |directory| {
        if (std.mem.eql(u8, timeline.replayed_hash, timeline.events_hash) and timeline.diverged.len == 0) {
            std.Io.Dir.cwd().deleteTree(work.io, directory) catch {};
        } else {
            timeline.parted = replays.parting(
                arena,
                work.io,
                std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ work.events.?, timeline.index }) catch "",
                std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ directory, timeline.index }) catch "",
            );
        }
    };
    const result = try std.process.run(arena, work.io, .{
        .argv = argv.items,
        .stdout_limit = .limited(64 << 20),
        .stderr_limit = .limited(64 << 20),
    });
    timeline.status = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };
    var recent: std.ArrayList(u8) = .empty;
    var in_recent = false;
    for ([_][]const u8{ result.stdout, result.stderr }) |output| {
        var lines = std.mem.tokenizeScalar(u8, output, '\n');
        while (lines.next()) |line| {
            // The divergence report: its header, then one "[determinismo]   <seq> ..." an event.
            if (std.mem.startsWith(u8, line, "[determinismo] its last ")) in_recent = true;
            if (in_recent) {
                const event = std.mem.startsWith(u8, line, "[determinismo]   ");
                if (event or std.mem.startsWith(u8, line, "[determinismo] its last ")) {
                    try recent.appendSlice(arena, "    ");
                    try recent.appendSlice(arena, line["[determinismo] ".len..]);
                    try recent.append(arena, '\n');
                    continue;
                }
                in_recent = false;
            }
            if (std.mem.startsWith(u8, line, "[branch ")) {
                const key = "events_hash=";
                const at = std.mem.indexOf(u8, line, key) orelse continue;
                const start = at + key.len;
                const end = std.mem.indexOfScalarPos(u8, line, start, ' ') orelse line.len;
                timeline.replayed_hash = line[start..end];
            } else if (std.mem.indexOf(u8, line, "replay diverged from its tape")) |at| {
                timeline.diverged = line[at..];
            } else if (std.mem.indexOf(u8, line, "its clock's hazards: ")) |at| {
                timeline.hazards = line[at + "its clock's hazards: ".len ..];
            } else if (std.mem.indexOf(u8, line, "recorded by another build of determinismo") != null) {
                timeline.other_build = true;
            }
        }
    }
    timeline.recent = recent.items;
    if (timeline.replayed_hash.len == 0) {
        const output = std.mem.trimEnd(u8, result.stderr, "\n");
        const tail = output[output.len -| ended_size_max..];
        timeline.ended = try std.fmt.allocPrint(arena, "exit {d}: {s}", .{ timeline.status, tail });
    }
}

test record_timelines {
    _ = record_timelines;
}
