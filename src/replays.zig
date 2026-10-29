// SPDX-License-Identifier: MIT
//! Timelines replayed while a run explores (explore with --record and --tape-dir): a verifier
//! process reads the record as it grows and replays every `every`-th timeline from its tape,
//! each replay its own explore (a CPU of the pool, beside the run's workers: under the run's own
//! load), comparing its history (events hash) with the record's. The run ends with a property
//! of determinismo's, "timelines replay to their recorded history": a timeline that does not
//! is a determinism bug, found on a real workload as it ran (its replay's first difference is
//! where to look: explore --trace, its .rdtsc log, DETERMINISMO_ITRACE_AT).
//!
//! When the run's timelines are done, the explorer asks the verifier to finish (SIGUSR1): it
//! reads the record a last time and replays the sampled timelines still pending, side by side
//! on the CPUs the workers left (so that a short run is checked too, and a long one waits about
//! one timeline more), then exits.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const cpus = @import("cpus.zig");

/// At most this many replays in a run (each as long as its timeline).
pub const replays_max = 16;
/// The record is read this often; a timeline is replayed once it was there at the read before
/// (its tape closed).
const scan_interval_ns = 5 * std.time.ns_per_s;

pub const Verifier = struct {
    pid: linux.pid_t,
    results_path: []const u8,

    /// The verifier's process (a process group of its own, gone with the explorer).
    pub fn start(
        arena: std.mem.Allocator,
        io: std.Io,
        argv: []const [:0]const u8,
        record: []const u8,
        tapes: []const u8,
        every: u32,
        jobs: u32,
    ) !Verifier {
        assert(every > 0);
        const results_path = try std.fmt.allocPrint(arena, "{s}.replays", .{record});
        std.Io.Dir.cwd().deleteFile(io, results_path) catch {};
        const replayer: Replayer = .{
            .base = try program_kept(arena, io, try replay_argv(arena, argv), tapes),
            .tapes = tapes,
            .events = flag_value(argv, "--events-dir"),
        };
        const explorer = linux.getpid();
        const pid = linux.fork();
        if (linux.errno(pid) != .SUCCESS) return error.Fork;
        if (pid == 0) {
            _ = linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), @backingInt(linux.SIG.KILL), 0, 0, 0);
            if (linux.getppid() != explorer) linux.exit_group(0);
            _ = linux.setpgid(0, 0); // Its replays with it: stopped as one.
            // Forked while the explorer held its CPU for the setup: its replays (programs of
            // their own, which read their affinity afresh) get every CPU the run was given.
            cpus.unpin();
            const action: linux.Sigaction = .{
                .handler = .{ .handler = finish_requested },
                .mask = linux.sigemptyset(),
                .flags = 0,
            };
            _ = linux.sigaction(linux.SIG.USR1, &action, null);
            verify_loop(io, replayer, record, every, jobs, results_path);
            linux.exit_group(0);
        }
        return .{ .pid = @intCast(pid), .results_path = results_path };
    }

    /// Lets it replay the sampled timelines still pending (the run's are all recorded), waits
    /// for it, and reads what it found.
    pub fn finish(verifier: *const Verifier, arena: std.mem.Allocator, io: std.Io) !Results {
        _ = linux.kill(verifier.pid, .USR1);
        var status: i32 = 0;
        _ = linux.waitpid(verifier.pid, &status, 0);
        _ = linux.kill(-verifier.pid, .KILL); // Anything of its group left.
        const text = std.Io.Dir.cwd().readFileAlloc(io, verifier.results_path, arena, .limited(1 << 20)) catch "";
        return results_parse(arena, text);
    }
};

pub const Results = struct {
    replayed: u32 = 0,
    same: u32 = 0,
    first_different: ?u32 = null,
    /// The lines of the timelines that did not replay, for people.
    different: []const []const u8 = &.{},
};

/// Results lines: "<index> same <hash>" or "<index> different <recorded> <replayed> <why>".
fn results_parse(arena: std.mem.Allocator, text: []const u8) !Results {
    var results: Results = .{};
    var different: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const index = std.fmt.parseInt(u32, words.next() orelse continue, 10) catch continue;
        const verdict = words.next() orelse continue;
        // Not replayed: killed, or it could not run (its output kept beside the tapes).
        if (std.mem.eql(u8, verdict, "killed") or std.mem.eql(u8, verdict, "failed")) continue;
        results.replayed += 1;
        if (std.mem.eql(u8, verdict, "same")) {
            results.same += 1;
        } else {
            results.first_different = results.first_different orelse index;
            try different.append(arena, line);
        }
    }
    results.different = different.items;
    return results;
}

/// The explorer's own command line for one timeline's replay: what boots the system, without
/// what drives an exploration (its tape has the seeds and decisions).
fn replay_argv(arena: std.mem.Allocator, argv: []const [:0]const u8) ![]const []const u8 {
    const with_value = [_][]const u8{
        "--branches",      "--time-budget", "--jobs",           "--record",         "--tape-dir",
        "--events-dir",    "--branching",   "--generation",     "--pipeline",       "--horizon",
        "--strategy",      "--shard",       "--verify-replays", "--save-snapshots", "--save-at-ms",
        "--data",          "--branch",      "--tape",           "--at-vtime-ms",    "--until",
        "--run-directory", "--exec",        "--exec-script",    "--rewind-ms",      "--from-branch",
        "--from-vtime-ms", "--from-exec",   "--from-snapshot",  "--trace",          "--events",
        "--seed",
    };
    const alone = [_][]const u8{ "--resume", "--archive", "--no-archive", "--continue" };
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(arena, &.{ "/proc/self/exe", "explore" });
    assert(argv.len >= 2);
    var index: usize = 2;
    while (index < argv.len) : (index += 1) {
        const flag: []const u8 = argv[index];
        if (contains(&with_value, flag)) {
            index += 1;
            continue;
        }
        if (contains(&alone, flag)) continue;
        try out.append(arena, flag);
    }
    return out.items; // /proc/self/exe: the explorer's binary, the build that ran.
}

/// The test program as the run started it, copied beside the tapes, for the replays: a program
/// rebuilt meanwhile (another `zig build`) is other inputs, and its replays would not boot the
/// timelines' system.
fn program_kept(
    arena: std.mem.Allocator,
    io: std.Io,
    base: []const []const u8,
    tapes: []const u8,
) ![]const []const u8 {
    const flag = for (base, 0..) |word, index| {
        if (std.mem.eql(u8, word, "--program") and index + 1 < base.len) break index;
    } else return base;
    const kept = try std.fs.path.join(arena, &.{ tapes, "program" });
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, tapes);
    try cwd.copyFile(base[flag + 1], cwd, kept, io, .{});
    const out = try arena.dupe([]const u8, base);
    out[flag + 1] = kept;
    return out;
}

fn contains(list: []const []const u8, word: []const u8) bool {
    for (list) |each| if (std.mem.eql(u8, each, word)) return true;
    return false;
}

/// Set by SIGUSR1: the run's timelines are all recorded.
var finishing: std.atomic.Value(bool) = .init(false);

fn finish_requested(_: linux.SIG) callconv(.c) void {
    finishing.store(true, .release);
}

/// What a replay needs: the explorer's arguments for it, the run's tapes, and the run's events
/// (`--events-dir`), to place where a replay parts from them.
const Replayer = struct {
    base: []const []const u8,
    tapes: []const u8,
    events: ?[]const u8,
};

fn verify_loop(
    io: std.Io,
    replayer: Replayer,
    record: []const u8,
    every: u32,
    jobs: u32,
    results_path: []const u8,
) void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const arena = arena_state.allocator();
    var seen: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    var verified: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var replays: u32 = 0;
    while (replays < replays_max) {
        if (!finishing.load(.acquire)) sleep_ns(scan_interval_ns); // A signal ends the sleep.
        if (finishing.load(.acquire)) {
            const text = std.Io.Dir.cwd().readFileAlloc(io, record, arena, .unlimited) catch "";
            return finish_pending(arena, io, replayer, every, jobs, results_path, text, &verified, replays);
        }
        const text = std.Io.Dir.cwd().readFileAlloc(io, record, arena, .unlimited) catch continue;
        // Timelines recorded at the read before: their tapes are closed.
        var ready: std.ArrayList(struct { index: u32, hash: []const u8 }) = .empty;
        var it = seen.iterator();
        while (it.next()) |entry| {
            if (verified.contains(entry.key_ptr.*)) continue;
            ready.append(arena, .{ .index = entry.key_ptr.*, .hash = entry.value_ptr.* }) catch return;
        }
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "{\"branch\":")) continue;
            const Line = struct { branch: struct { index: u32, events_hash: []const u8 } };
            const parsed = std.json.parseFromSliceLeaky(Line, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
            if (parsed.branch.index % every != every - 1) continue; // Every `every`-th.
            seen.put(arena, parsed.branch.index, parsed.branch.events_hash) catch return;
        }
        std.mem.sort(@TypeOf(ready.items[0]), ready.items, {}, struct {
            fn less(_: void, a: @TypeOf(ready.items[0]), b: @TypeOf(ready.items[0])) bool {
                return a.index < b.index;
            }
        }.less);
        for (ready.items) |timeline| {
            if (replays == replays_max) break;
            verified.put(arena, timeline.index, {}) catch return;
            replays += 1;
            const line = replay_one(arena, io, replayer, timeline.index, timeline.hash) catch |err|
                std.fmt.allocPrint(arena, "{d} different {s} none {s}\n", .{ timeline.index, timeline.hash, @errorName(err) }) catch return;
            append(results_path, line);
        }
    }
}

/// The run is done, its tapes closed: every sampled timeline not replayed yet (within
/// replays_max), up to `jobs` at once.
fn finish_pending(
    arena: std.mem.Allocator,
    io: std.Io,
    replayer: Replayer,
    every: u32,
    jobs: u32,
    results_path: []const u8,
    text: []const u8,
    verified: *const std.AutoHashMapUnmanaged(u32, void),
    replays: u32,
) void {
    const Pending = struct { index: u32, hash: []const u8 };
    var pending: std.ArrayList(Pending) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "{\"branch\":")) continue;
        const Line = struct { branch: struct { index: u32, events_hash: []const u8 } };
        const parsed = std.json.parseFromSliceLeaky(Line, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        if (parsed.branch.index % every != every - 1) continue;
        if (verified.contains(parsed.branch.index)) continue;
        if (replays + pending.items.len == replays_max) break;
        pending.append(arena, .{ .index = parsed.branch.index, .hash = parsed.branch.events_hash }) catch return;
    }
    const Worker = struct {
        fn run(
            worker_io: std.Io,
            worker_replayer: Replayer,
            worker_results: []const u8,
            all: []const Pending,
            next: *std.atomic.Value(u32),
        ) void {
            while (true) {
                const at = next.fetchAdd(1, .monotonic);
                if (at >= all.len) return;
                const timeline = all[at];
                // Each its own arena: the workers run at once.
                var own: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
                defer own.deinit();
                const line = replay_one(own.allocator(), worker_io, worker_replayer, timeline.index, timeline.hash) catch |err|
                    std.fmt.allocPrint(own.allocator(), "{d} different {s} none {s}\n", .{ timeline.index, timeline.hash, @errorName(err) }) catch return;
                append(worker_results, line);
            }
        }
    };
    var next: std.atomic.Value(u32) = .init(0);
    const workers = @min(@max(jobs, 1), pending.items.len);
    var threads: [replays_max]std.Thread = undefined;
    var started: usize = 0;
    for (0..workers) |_| {
        threads[started] = std.Thread.spawn(.{}, Worker.run, .{ io, replayer, results_path, pending.items, &next }) catch break;
        started += 1;
    }
    // None started (no threads to be had): this one does them all.
    if (started == 0) Worker.run(io, replayer, results_path, pending.items, &next);
    for (threads[0..started]) |thread| thread.join();
}

fn replay_one(
    arena: std.mem.Allocator,
    io: std.Io,
    replayer: Replayer,
    index: u32,
    recorded: []const u8,
) ![]const u8 {
    const tapes = replayer.tapes;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, replayer.base);
    try argv.appendSlice(arena, &.{ "--tape", try std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ tapes, index }) });
    // Its events beside the tapes, while the run has its own to compare them with: kept when it
    // parts from the run, as the evidence.
    const replay_events: ?[]const u8 = if (replayer.events != null)
        try std.fmt.allocPrint(arena, "{s}/replay-{d}-events", .{ tapes, index })
    else
        null;
    if (replay_events) |directory| try argv.appendSlice(arena, &.{ "--events-dir", directory });
    const result = try std.process.run(arena, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(64 << 20),
        .stderr_limit = .limited(64 << 20),
    });
    var replayed: []const u8 = "none";
    var why: []const u8 = "";
    var hazards: []const u8 = "";
    var other_build = false;
    for ([_][]const u8{ result.stdout, result.stderr }) |output| {
        var lines = std.mem.tokenizeScalar(u8, output, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "[branch ")) {
                const key = "events_hash=";
                const at = std.mem.indexOf(u8, line, key) orelse continue;
                const start = at + key.len;
                replayed = line[start .. std.mem.indexOfScalarPos(u8, line, start, ' ') orelse line.len];
            } else if (std.mem.indexOf(u8, line, "replay diverged from its tape")) |at| {
                why = line[at..];
            } else if (std.mem.indexOf(u8, line, "its clock's hazards: ")) |at| {
                hazards = line[at..];
            } else if (std.mem.indexOf(u8, line, "recorded by another build of determinismo") != null) {
                other_build = true;
            }
        }
    }
    if (std.mem.eql(u8, replayed, recorded) and why.len == 0) {
        if (replay_events) |directory| std.Io.Dir.cwd().deleteTree(io, directory) catch {};
        return std.fmt.allocPrint(arena, "{d} same {s}\n", .{ index, recorded });
    }
    // Killed (SIGKILL: the host's OOM killer) before it ended: not replayed, which says nothing
    // about determinism.
    const killed = switch (result.term) {
        .signal => |signal| signal == .KILL,
        else => false,
    };
    if (killed and std.mem.eql(u8, replayed, "none") and why.len == 0) {
        return std.fmt.allocPrint(arena, "{d} killed {s}\n", .{ index, recorded });
    }
    // Ended without a history and without parting from its tape: it could not run (a host
    // check's container, the host itself), which says nothing about determinism either.
    if (std.mem.eql(u8, replayed, "none") and why.len == 0) {
        const log = try std.fmt.allocPrint(arena, "{s}/replay-{d}.log", .{ tapes, index });
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = log, .data = tail(result.stderr, 256 << 10) }) catch {};
        return std.fmt.allocPrint(arena, "{d} failed {s}\n", .{ index, recorded });
    }
    // Its output beside the results (the last 256 KiB): where it parted, on what CPU, its
    // clock's hazards, without replaying it again.
    const log = try std.fmt.allocPrint(arena, "{s}/replay-{d}.log", .{ tapes, index });
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = log, .data = tail(result.stderr, 256 << 10) }) catch {};
    const parted = if (replay_events) |directory| parting(
        arena,
        io,
        try std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ replayer.events.?, index }),
        try std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ directory, index }),
    ) else "";
    return std.fmt.allocPrint(arena, "{d} different {s} {s} {s}{s}{s}{s}{s}\n", .{
        index,                                                                  recorded, replayed, why, if (hazards.len > 0) "; " else "", hazards, parted,
        if (other_build) "; recorded by another build of determinismo" else "",
    });
}

/// Where a replay's events part from the run's: the last checkpoint both passed (one per second
/// of virtual time, Events.checkpoint) and the first line that differs on each side; "" when
/// either file cannot be read or they do not differ.
pub fn parting(arena: std.mem.Allocator, io: std.Io, recorded_path: []const u8, replayed_path: []const u8) []const u8 {
    const limit: std.Io.Limit = .limited(1 << 30);
    const recorded = std.Io.Dir.cwd().readFileAlloc(io, recorded_path, arena, limit) catch return "";
    const replayed = std.Io.Dir.cwd().readFileAlloc(io, replayed_path, arena, limit) catch return "";
    return parting_text(arena, recorded, replayed);
}

fn parting_text(arena: std.mem.Allocator, recorded: []const u8, replayed: []const u8) []const u8 {
    var recorded_lines = std.mem.tokenizeScalar(u8, recorded, '\n');
    var replayed_lines = std.mem.tokenizeScalar(u8, replayed, '\n');
    var passed: ?u64 = null; // The last checkpoint both passed, its virtual time.
    while (true) {
        const a = recorded_lines.next();
        const b = replayed_lines.next();
        if (a == null and b == null) return "";
        if (a != null and b != null and std.mem.eql(u8, a.?, b.?)) {
            if (std.mem.startsWith(u8, a.?, "{\"checkpoint\":")) passed = number_after(a.?, "\"vtime_ns\":");
            continue;
        }
        const after = if (passed) |ns|
            std.fmt.allocPrint(arena, "the checkpoint at {f}", .{seconds(ns)}) catch return ""
        else
            "no checkpoint";
        return std.fmt.allocPrint(arena, "; parted after {s}: recorded {s}, replayed {s}", .{
            after, place(arena, a), place(arena, b),
        }) catch "";
    }
}

/// A line's place: "seq <n> at <t> s", "a checkpoint at <t> s", or "nothing" (its file ended).
fn place(arena: std.mem.Allocator, line: ?[]const u8) []const u8 {
    const text = line orelse return "nothing";
    const vtime_ns = number_after(text, "\"vtime_ns\":") orelse return "an unreadable line";
    if (std.mem.startsWith(u8, text, "{\"checkpoint\":")) {
        return std.fmt.allocPrint(arena, "a checkpoint at {f}", .{seconds(vtime_ns)}) catch "";
    }
    const seq = number_after(text, "\"seq\":") orelse 0;
    return std.fmt.allocPrint(arena, "seq {d} at {f}", .{ seq, seconds(vtime_ns) }) catch "";
}

fn number_after(text: []const u8, key: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const start = at + key.len;
    var end = start;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    return std.fmt.parseInt(u64, text[start..end], 10) catch null;
}

/// Virtual time to the microsecond, for a person: "94.852498 s".
const Seconds = struct {
    ns: u64,
    pub fn format(value: Seconds, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}.{d:0>6} s", .{ value.ns / std.time.ns_per_s, value.ns % std.time.ns_per_s / std.time.ns_per_us });
    }
};

fn seconds(ns: u64) Seconds {
    return .{ .ns = ns };
}

/// The value after `flag` in an argument list, if it is there.
fn flag_value(argv: []const [:0]const u8, flag: []const u8) ?[]const u8 {
    for (argv, 0..) |argument, index| {
        if (std.mem.eql(u8, argument, flag) and index + 1 < argv.len) return argv[index + 1];
    }
    return null;
}

test parting_text {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const recorded =
        \\{"seq":1,"vtime_ns":500,"branches":7,"event":{"event":"a"}}
        \\{"checkpoint":{"vtime_ns":1000000123,"branches":9}}
        \\{"seq":2,"vtime_ns":94852498828,"branches":13274724501,"event":{"event":"b"}}
    ;
    const replayed =
        \\{"seq":1,"vtime_ns":500,"branches":7,"event":{"event":"a"}}
        \\{"checkpoint":{"vtime_ns":1000000123,"branches":9}}
        \\{"seq":2,"vtime_ns":94852499537,"branches":13274690239,"event":{"event":"b"}}
    ;
    try std.testing.expectEqualStrings(
        "; parted after the checkpoint at 1.000000 s: recorded seq 2 at 94.852498 s, replayed seq 2 at 94.852499 s",
        parting_text(arena.allocator(), recorded, replayed),
    );
    try std.testing.expectEqualStrings("", parting_text(arena.allocator(), recorded, recorded));
    try std.testing.expectEqualStrings(
        "; parted after no checkpoint: recorded seq 1 at 0.000000 s, replayed nothing",
        parting_text(arena.allocator(), recorded, ""),
    );
}

/// The last `size_max` bytes of `bytes` (all of them when shorter).
fn tail(bytes: []const u8, size_max: usize) []const u8 {
    return bytes[bytes.len -| size_max..];
}

test tail {
    try std.testing.expectEqualStrings("cd", tail("abcd", 2));
    try std.testing.expectEqualStrings("abcd", tail("abcd", 256 << 10));
    try std.testing.expectEqualStrings("", tail("", 4));
}

fn append(path: []const u8, line: []const u8) void {
    var path_buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= path_buffer.len) return;
    @memcpy(path_buffer[0..path.len], path);
    path_buffer[path.len] = 0;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
    const fd = linux.open(path_buffer[0..path.len :0], flags, 0o644);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.write(@intCast(fd), line.ptr, line.len);
}

fn sleep_ns(ns: u64) void {
    const duration: linux.timespec = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    _ = linux.nanosleep(&duration, null);
}

test results_parse {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const results = try results_parse(arena.allocator(), "15 same ab\n31 different ab cd diverged\n47 same ef\n63 killed gh\n79 failed ij\n");
    try std.testing.expectEqual(3, results.replayed);
    try std.testing.expectEqual(2, results.same);
    try std.testing.expectEqual(31, results.first_different.?);
    try std.testing.expectEqual(1, results.different.len);
}

test replay_argv {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const argv = [_][:0]const u8{ "determinismo", "explore", "--kernel", "k", "--branches", "64", "--resume", "--program", "p", "--record", "r" };
    const out = try replay_argv(arena.allocator(), &argv);
    try std.testing.expectEqual(6, out.len);
    try std.testing.expectEqualStrings("--kernel", out[2]);
    try std.testing.expectEqualStrings("p", out[5]);
}
