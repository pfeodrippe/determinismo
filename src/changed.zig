// SPDX-License-Identifier: MIT
//! Targeted runs (`explore --changed <diff file | git range>`): exploration aimed at a change's
//! code. The change's hunks (lines of the new files) are matched against the line coverage the
//! timelines report (`line <file or class>:<line>`: Python, the JVM, and Antithesis's
//! instrumentors through libvoidstar); the tree explorer returns first to timelines that ran
//! changed code, just after they first did, and the report says how many timelines ran each
//! hunk and which never ran.
const std = @import("std");
const assert = std.debug.assert;
const mutate = @import("mutate.zig");

pub const Hunk = mutate.Hunk;

/// A change's hunks, and how many timelines ran each.
pub const Change = struct {
    hunks: []const Hunk,
    timelines: []u32,

    /// The hunk a behavior's label is a line of (`coverage line <place>:<n>`), if any.
    pub fn hunk_of(change: *const Change, arena: std.mem.Allocator, label: []const u8) ?usize {
        const prefix = "coverage line ";
        if (!std.mem.startsWith(u8, label, prefix)) return null;
        const place_line = label[prefix.len..];
        const colon = std.mem.lastIndexOfScalar(u8, place_line, ':') orelse return null;
        const number = std.fmt.parseInt(u32, place_line[colon + 1 ..], 10) catch return null;
        const place = place_line[0..colon];
        for (change.hunks, 0..) |hunk, index| {
            if (number < hunk.first or number > hunk.last) continue;
            if (mutate.same_source(arena, place, hunk.file)) return index;
        }
        return null;
    }

    pub fn summarize(change: *const Change, timelines: u32) void {
        var ran: u32 = 0;
        for (change.timelines) |count| ran += @intFromBool(count > 0);
        std.debug.print("[determinismo] changed code: {d} of {d} hunks ran\n", .{
            ran, change.hunks.len,
        });
        for (change.hunks, change.timelines) |hunk, count| {
            if (count == 0) {
                const line = "  NEVER RAN  {s}:{d}-{d}\n";
                std.debug.print(line, .{ hunk.file, hunk.first, hunk.last });
            } else {
                std.debug.print("  ran in {d:>4}/{d} timelines  {s}:{d}-{d}\n", .{
                    count, timelines, hunk.file, hunk.first, hunk.last,
                });
            }
        }
    }
};

/// The hunks of a diff file, or of `git diff -U0 <range>` in the working directory (only the
/// changed lines, no context) when no such file exists.
pub fn read(arena: std.mem.Allocator, io: std.Io, source: []const u8) !Change {
    const cwd = std.Io.Dir.cwd();
    const patch = cwd.readFileAlloc(io, source, arena, .limited(64 << 20)) catch |err| blk: {
        if (err != error.FileNotFound) return err;
        const result = try std.process.run(arena, io, .{
            .argv = &.{ "git", "diff", "-U0", source },
        });
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("[determinismo] --changed {s}: no such diff file, and git diff " ++
                "failed: {s}\n", .{ source, result.stderr });
            return error.Usage;
        }
        break :blk result.stdout;
    };
    const found = try mutate.hunks(arena, patch);
    if (found.len == 0) {
        std.debug.print("[determinismo] --changed {s}: no hunks\n", .{source});
        return error.Usage;
    }
    const timelines = try arena.alloc(u32, found.len);
    @memset(timelines, 0);
    return .{ .hunks = found, .timelines = timelines };
}

test "a coverage line falls in a hunk of the same file" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    var timelines = [_]u32{ 0, 0 };
    const change = Change{
        .hunks = &.{
            .{ .file = "raft.go", .first = 620, .last = 630 },
            .{ .file = "replication.go", .first = 10, .last = 12 },
        },
        .timelines = &timelines,
    };
    const expect = std.testing.expectEqual;
    try expect(@as(?usize, 0), change.hunk_of(arena, "coverage line /src/raft.go:624"));
    try expect(@as(?usize, 1), change.hunk_of(arena, "coverage line /src/replication.go:12"));
    try expect(@as(?usize, null), change.hunk_of(arena, "coverage line /src/raft.go:619"));
    try expect(@as(?usize, null), change.hunk_of(arena, "coverage edge 12"));
}
