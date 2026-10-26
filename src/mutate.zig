// SPDX-License-Identifier: MIT
//! determinismo mutate: a mutation testing campaign (antithesis.com/blog/2026/mutation-testing).
//! Each mutant is a patch to a node's build context; the system is explored once as it is and
//! once per mutant (built from a patched copy of the context), with the same seed and options,
//! and each mutant is judged:
//!
//!   caught      a property fails that does not fail without it
//!   never ran   no timeline ran the mutated lines (coverage of them is known, and none was hit)
//!   unnoticed   it ran (or whether it did is unknown: no coverage of its language) and no
//!               property noticed: a gap in the properties
//!
//!   determinismo mutate <explore options> --mutants <mutants.jsonl> [--out <dir>]
//!
//! mutants.jsonl: one mutant per line, {"name": "...", "node": "<node>", "patch": "<diff file>"}
//! (a unified diff relative to the node's build context, as `git diff` writes it). Results go to
//! <dir>/results.jsonl, each exploration's record and events beside it.
const std = @import("std");
const assert = std.debug.assert;

const Mutant = struct { name: []const u8, node: []const u8, patch: []const u8 };

const Verdict = enum { caught, never_ran, unnoticed };

const Result = struct {
    name: []const u8,
    verdict: Verdict,
    /// Properties failing with it that pass without it (caught).
    failing: []const []const u8,
    /// Whether a timeline ran a mutated line: null when its language reports no line coverage.
    ran: ?bool,
};

pub fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    self: []const u8,
    arguments: []const [:0]const u8,
) !u8 {
    var mutants_path: ?[]const u8 = null;
    var out: []const u8 = "mutation-results";
    var rest: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const flag = arguments[index];
        const has_value = index + 1 < arguments.len;
        if (std.mem.eql(u8, flag, "--mutants") and has_value) {
            index += 1;
            mutants_path = arguments[index];
        } else if (std.mem.eql(u8, flag, "--out") and has_value) {
            index += 1;
            out = arguments[index];
        } else try rest.append(arena, flag);
    }
    const path = mutants_path orelse return error.Usage;
    const cwd = std.Io.Dir.cwd();
    const listing = try cwd.readFileAlloc(io, path, arena, .limited(1 << 20));
    const mutants = try mutants_read(arena, listing);
    try cwd.createDirPath(io, out);
    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const writer = &stdout.interface;
    try writer.print("[determinismo] mutate: the system as it is, then {d} mutants\n", .{
        mutants.len,
    });
    try writer.flush();
    const baseline = try explore(arena, io, self, rest.items, out, "original", null);
    var results: std.ArrayList(Result) = .empty;
    for (mutants, 0..) |mutant, number| {
        const label = try std.fmt.allocPrint(arena, "mutant-{d}", .{number});
        const which = try std.fmt.allocPrint(arena, "{s}={s}", .{ mutant.node, mutant.patch });
        const explored = try explore(arena, io, self, rest.items, out, label, which);
        var failing: std.ArrayList([]const u8) = .empty;
        for (explored.failing) |name| {
            if (!contains(baseline.failing, name)) try failing.append(arena, name);
        }
        const patch = try cwd.readFileAlloc(io, mutant.patch, arena, .limited(1 << 24));
        const changed = try hunks(arena, patch);
        const ran = try mutated_lines_ran(arena, io, self, explored.events, changed);
        const verdict: Verdict = if (failing.items.len > 0)
            .caught
        else if (ran != null and !ran.?) .never_ran else .unnoticed;
        try results.append(arena, .{
            .name = mutant.name,
            .verdict = verdict,
            .failing = failing.items,
            .ran = ran,
        });
        try writer.print("  {s:<10} {s}{s}\n", .{ @tagName(verdict), mutant.name, switch (verdict) {
            .caught => try std.fmt.allocPrint(arena, " (by: {s})", .{
                try std.mem.join(arena, "; ", failing.items),
            }),
            .never_ran => " (no timeline ran its lines)",
            .unnoticed => if (ran == null) " (whether it ran is unknown)" else " (it ran)",
        } });
        try writer.flush();
    }
    var lines: std.Io.Writer.Allocating = .init(arena);
    for (results.items) |result| {
        try lines.writer.print("{f}\n", .{std.json.fmt(result, .{})});
    }
    const results_path = try std.fs.path.join(arena, &.{ out, "results.jsonl" });
    try cwd.writeFile(io, .{ .sub_path = results_path, .data = lines.written() });
    var caught: u32 = 0;
    for (results.items) |result| caught += @intFromBool(result.verdict == .caught);
    try writer.print("[determinismo] mutate: {d} of {d} mutants caught ({s})\n", .{
        caught, results.items.len, results_path,
    });
    try writer.flush();
    return 0;
}

fn mutants_read(arena: std.mem.Allocator, source: []const u8) ![]const Mutant {
    var mutants: std.ArrayList(Mutant) = .empty;
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        try mutants.append(arena, try std.json.parseFromSliceLeaky(Mutant, arena, line, .{
            .ignore_unknown_fields = true,
        }));
    }
    if (mutants.items.len == 0) return error.NoMutants;
    return mutants.items;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |other| if (std.mem.eql(u8, other, name)) return true;
    return false;
}

const Explored = struct { failing: []const []const u8, events: []const u8 };

/// One exploration (a child `determinismo explore`): the properties it failed, and where its
/// events are.
fn explore(
    arena: std.mem.Allocator,
    io: std.Io,
    self: []const u8,
    rest: []const []const u8,
    out: []const u8,
    label: []const u8,
    mutant: ?[]const u8,
) !Explored {
    const record = try std.fmt.allocPrint(arena, "{s}/{s}.jsonl", .{ out, label });
    const events = try std.fmt.allocPrint(arena, "{s}/{s}-events", .{ out, label });
    std.Io.Dir.cwd().deleteFile(io, record) catch {};
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ self, "explore" });
    try argv.appendSlice(arena, rest);
    try argv.appendSlice(arena, &.{ "--record", record, "--events-dir", events });
    if (mutant) |which| try argv.appendSlice(arena, &.{ "--mutant", which });
    const result = try std.process.run(arena, io, .{ .argv = argv.items });
    const status: u8 = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };
    if (status != 0 and status != 3) {
        std.debug.print("[determinismo] mutate: {s} did not explore ({d}):\n{s}\n", .{
            label, status, result.stderr,
        });
        return error.ExploreFailed;
    }
    const lines = try std.Io.Dir.cwd().readFileAlloc(io, record, arena, .unlimited);
    const Summary = struct {
        summary: struct { properties: []const struct { message: []const u8, failing: bool } },
    };
    var failing: std.ArrayList([]const u8) = .empty;
    var records = std.mem.tokenizeScalar(u8, lines, '\n');
    while (records.next()) |line| {
        if (!std.mem.startsWith(u8, line, "{\"summary\":")) continue;
        const summary = try std.json.parseFromSliceLeaky(Summary, arena, line, .{
            .ignore_unknown_fields = true,
        });
        for (summary.summary.properties) |property| {
            if (property.failing) try failing.append(arena, property.message);
        }
    }
    return .{ .failing = failing.items, .events = events };
}

/// The lines a patch changes in each file: its added lines' ranges in the new file.
pub const Hunk = struct { file: []const u8, first: u32, last: u32 };

pub fn hunks(arena: std.mem.Allocator, patch: []const u8) ![]const Hunk {
    var found: std.ArrayList(Hunk) = .empty;
    var file: []const u8 = "";
    var lines = std.mem.splitScalar(u8, patch, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "+++ ")) {
            const name = std.mem.trim(u8, line[4..], " \t\r");
            file = if (std.mem.startsWith(u8, name, "b/")) name[2..] else name;
            continue;
        }
        if (!std.mem.startsWith(u8, line, "@@ ")) continue;
        // "@@ -a,b +c,d @@": the new file's lines c to c+d-1.
        const plus = std.mem.indexOfScalar(u8, line, '+') orelse continue;
        const end = std.mem.indexOfScalarPos(u8, line, plus, ' ') orelse continue;
        const range = line[plus + 1 .. end];
        const comma = std.mem.indexOfScalar(u8, range, ',');
        const start = if (comma) |at| range[0..at] else range;
        const first = std.fmt.parseInt(u32, start, 10) catch continue;
        const count = if (comma) |at| std.fmt.parseInt(u32, range[at + 1 ..], 10) catch 1 else 1;
        const last = first + @max(count, 1) - 1;
        try found.append(arena, .{ .file = file, .first = first, .last = last });
    }
    return found.items;
}

test hunks {
    const patch =
        \\--- a/src/bank.py
        \\+++ b/src/bank.py
        \\@@ -10,3 +10,4 @@ def transfer():
        \\ x
    ;
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const found = try hunks(state.allocator(), patch);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("src/bank.py", found[0].file);
    try std.testing.expectEqual(@as(u32, 13), found[0].last);
}

/// Whether some timeline ran a mutated line, from the line coverage events the SDKs send
/// (`line <file or class>:<line>`); null when there are none (C and Zig report edges).
fn mutated_lines_ran(
    arena: std.mem.Allocator,
    io: std.Io,
    self: []const u8,
    events: []const u8,
    changed: []const Hunk,
) !?bool {
    const result = try std.process.run(arena, io, .{ .argv = &.{
        self, "query", events, "event=coverage", "--json",
    } });
    var any = false;
    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const Line = struct { event: struct { details: struct { name: []const u8 } } };
        const parsed = std.json.parseFromSliceLeaky(Line, arena, line, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        const name = parsed.event.details.name;
        if (!std.mem.startsWith(u8, name, "line ")) continue;
        any = true;
        const colon = std.mem.lastIndexOfScalar(u8, name, ':') orelse continue;
        const number = std.fmt.parseInt(u32, name[colon + 1 ..], 10) catch continue;
        const place = name["line ".len..colon];
        for (changed) |hunk| {
            if (number < hunk.first or number > hunk.last) continue;
            if (same_source(arena, place, hunk.file)) return true;
        }
    }
    return if (any) false else null;
}

/// A coverage place (a file path, a JVM class name) and a patched file: the same code when the
/// paths end alike (the whole patched path, or at least its directory and name: a repository's
/// layout and an image's differ), or when the file's path without its extension, as dots and
/// with Clojure's munging, ends the place's (or the place begins with it, for a class and its
/// inner classes).
pub fn same_source(arena: std.mem.Allocator, place: []const u8, file: []const u8) bool {
    if (std.mem.endsWith(u8, place, file)) return true; // A path.
    if (path_tail(file, 2)) |tail| {
        const boundary = place.len == tail.len or
            (place.len > tail.len and place[place.len - tail.len - 1] == '/');
        if (std.mem.endsWith(u8, place, tail) and boundary) return true;
    }
    const stem = file[0 .. std.mem.lastIndexOfScalar(u8, file, '.') orelse file.len];
    const dotted = arena.dupe(u8, stem) catch return false;
    for (dotted) |*byte| {
        if (byte.* == '/') byte.* = '.';
        if (byte.* == '-') byte.* = '_';
    }
    // src/nrepl/middleware/session.clj -> ...nrepl.middleware.session; classes start with it.
    var parts = std.mem.splitScalar(u8, dotted, '.');
    var suffix: []const u8 = dotted;
    while (parts.next()) |_| {
        if (std.mem.startsWith(u8, place, suffix)) {
            const rest = place[suffix.len..];
            if (rest.len == 0 or rest[0] == '$' or rest[0] == '.') return true;
        }
        const dot = std.mem.indexOfScalar(u8, suffix, '.') orelse break;
        suffix = suffix[dot + 1 ..];
    }
    return false;
}

/// The last `count` components of a path, if it has more.
fn path_tail(path: []const u8, count: u32) ?[]const u8 {
    var start = path.len;
    for (0..count) |_| {
        start = std.mem.lastIndexOfScalar(u8, path[0..start], '/') orelse return null;
    }
    return path[start + 1 ..];
}

test same_source {
    const arena = std.testing.allocator;
    var state: std.heap.ArenaAllocator = .init(arena);
    defer state.deinit();
    const a = state.allocator();
    const session = "src/nrepl/middleware/session.clj";
    try std.testing.expect(same_source(a, "nrepl.middleware.session$fn__123", session));
    try std.testing.expect(same_source(a, "/app/src/bank.py", "src/bank.py"));
    try std.testing.expect(!same_source(a, "nrepl.server", session));
    const maze = "tests/antithesis-compat/python/client/maze/singleton_driver_maze.py";
    const deployed = "/opt/antithesis/test/v1/maze/singleton_driver_maze.py";
    try std.testing.expect(same_source(a, deployed, maze));
    try std.testing.expect(!same_source(a, "/opt/other/singleton_driver_maze.py", maze));
    try std.testing.expect(!same_source(a, "/src/xmaze/singleton_driver_maze.py", maze));
}
