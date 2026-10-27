// SPDX-License-Identifier: MIT
//! Timelines replayed while a run explores (explore with --record and --tape-dir): a verifier
//! process reads the record as it grows and replays every `every`-th timeline from its tape,
//! each replay its own explore (a CPU of the pool, beside the run's workers: under the run's own
//! load), comparing its history (events hash) with the record's. The run ends with a property
//! of determinismo's, "timelines replay to their recorded history": a timeline that does not
//! is a determinism bug, found on a real workload as it ran (its replay's first difference is
//! where to look: explore --trace, its .rdtsc log, DETERMINISMO_ITRACE_AT).
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

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
    ) !Verifier {
        assert(every > 0);
        const results_path = try std.fmt.allocPrint(arena, "{s}.replays", .{record});
        std.Io.Dir.cwd().deleteFile(io, results_path) catch {};
        const base = try replay_argv(arena, argv);
        const explorer = linux.getpid();
        const pid = linux.fork();
        if (linux.errno(pid) != .SUCCESS) return error.Fork;
        if (pid == 0) {
            _ = linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), @backingInt(linux.SIG.KILL), 0, 0, 0);
            if (linux.getppid() != explorer) linux.exit_group(0);
            _ = linux.setpgid(0, 0); // Its replays with it: stopped as one.
            verify_loop(io, base, record, tapes, every, results_path);
            linux.exit_group(0);
        }
        return .{ .pid = @intCast(pid), .results_path = results_path };
    }

    /// Stops it (and the replay in flight) and reads what it found.
    pub fn stop(verifier: *const Verifier, arena: std.mem.Allocator, io: std.Io) !Results {
        _ = linux.kill(-verifier.pid, .KILL);
        var status: i32 = 0;
        _ = linux.waitpid(verifier.pid, &status, 0);
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
        "--branches",   "--time-budget",   "--jobs",           "--record",         "--tape-dir",
        "--events-dir", "--branching",     "--generation",     "--pipeline",       "--horizon",
        "--strategy",   "--shard",         "--verify-replays", "--save-snapshots", "--save-at-ms",
        "--serve",      "--branch",        "--tape",           "--at-vtime-ms",    "--until",
        "--exec",       "--exec-script",   "--rewind-ms",      "--from-branch",    "--from-vtime-ms",
        "--from-exec",  "--from-snapshot", "--trace",          "--events",         "--seed",
    };
    const alone = [_][]const u8{ "--resume", "--archive", "--continue" };
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

fn contains(list: []const []const u8, word: []const u8) bool {
    for (list) |each| if (std.mem.eql(u8, each, word)) return true;
    return false;
}

fn verify_loop(
    io: std.Io,
    base: []const []const u8,
    record: []const u8,
    tapes: []const u8,
    every: u32,
    results_path: []const u8,
) void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const arena = arena_state.allocator();
    var seen: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    var verified: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var replays: u32 = 0;
    while (replays < replays_max) {
        sleep_ns(scan_interval_ns);
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
            const line = replay_one(arena, io, base, tapes, timeline.index, timeline.hash) catch |err|
                std.fmt.allocPrint(arena, "{d} different {s} none {s}\n", .{ timeline.index, timeline.hash, @errorName(err) }) catch return;
            append(results_path, line);
        }
    }
}

fn replay_one(
    arena: std.mem.Allocator,
    io: std.Io,
    base: []const []const u8,
    tapes: []const u8,
    index: u32,
    recorded: []const u8,
) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, base);
    try argv.appendSlice(arena, &.{ "--tape", try std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ tapes, index }) });
    const result = try std.process.run(arena, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(64 << 20),
        .stderr_limit = .limited(64 << 20),
    });
    var replayed: []const u8 = "none";
    var why: []const u8 = "";
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
            }
        }
    }
    if (std.mem.eql(u8, replayed, recorded) and why.len == 0) {
        return std.fmt.allocPrint(arena, "{d} same {s}\n", .{ index, recorded });
    }
    return std.fmt.allocPrint(arena, "{d} different {s} {s} {s}\n", .{ index, recorded, replayed, why });
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
    const results = try results_parse(arena.allocator(), "15 same ab\n31 different ab cd diverged\n47 same ef\n");
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
