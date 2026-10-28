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

/// The hunks of a diff file, or of `git diff -U0 <range>` (only the changed lines, no context):
/// in the working directory when no such file exists, or in `repository` when one is given (a
/// directory, or a URL fetched into `cache`), where a single revision is that commit's change.
pub fn read(
    arena: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    repository: ?[]const u8,
    cache: []const u8,
) !Change {
    const cwd = std.Io.Dir.cwd();
    const patch = if (repository) |where| blk: {
        const directory = try repository_directory(arena, io, where, cache);
        break :blk try git_diff(arena, io, directory, try revisions(arena, source), source);
    } else cwd.readFileAlloc(io, source, arena, .limited(64 << 20)) catch |err| blk: {
        if (err != error.FileNotFound) return err;
        break :blk try git_diff(arena, io, ".", source, source);
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

fn git_diff(
    arena: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    range: []const u8,
    source: []const u8,
) ![]const u8 {
    const result = try std.process.run(arena, io, .{
        .argv = &.{ "git", "-C", directory, "diff", "-U0", range },
    });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("[determinismo] --changed {s}: git diff {s} in {s} failed: {s}\n", .{
            source, range, directory, result.stderr,
        });
        return error.Usage;
    }
    return result.stdout;
}

/// A range as git diff takes it (`a..b`, `a...b`, `c^!`), or a single revision: that commit's
/// change (`<revision>^!`), a release's tag or a commit's hash.
fn revisions(arena: std.mem.Allocator, given: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, given, "..") != null) return given;
    if (std.mem.indexOfScalar(u8, given, '^') != null) return given;
    return std.fmt.allocPrint(arena, "{s}^!", .{given});
}

/// A repository's directory: as given, or for a URL (`https://`, `ssh://`, `file://`, `git@`)
/// a bare clone in the cache without file contents (git fetches those a diff needs), fetched
/// again for new commits and tags.
fn repository_directory(
    arena: std.mem.Allocator,
    io: std.Io,
    where: []const u8,
    cache: []const u8,
) ![]const u8 {
    const url = std.mem.indexOf(u8, where, "://") != null or std.mem.startsWith(u8, where, "git@");
    if (!url) return where;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(where, &digest, .{});
    const name = std.fmt.bytesToHex(digest[0..8], .lower);
    const directory = try std.fmt.allocPrint(arena, "{s}/repositories/{s}", .{ cache, &name });
    const cwd = std.Io.Dir.cwd();
    const cloned = if (cwd.access(io, directory, .{})) |_| true else |_| false;
    const argv: []const []const u8 = if (cloned) &.{
        "git",     "-C",                 directory, "fetch",                      "--quiet", "--tags",
        "--force", "--filter=blob:none", "origin",  "+refs/heads/*:refs/heads/*",
    } else &.{ "git", "clone", "--quiet", "--bare", "--filter=blob:none", where, directory };
    if (!cloned) try cwd.createDirPath(io, std.fs.path.dirname(directory).?);
    const result = try std.process.run(arena, io, .{ .argv = argv });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("[determinismo] --changed-repository {s}: git {s} failed: {s}\n", .{
            where, argv[if (cloned) 3 else 1], result.stderr,
        });
        if (!cloned) return error.Usage;
        // Fetched before: what it has may be enough (a released tag, an old commit).
    }
    return directory;
}

test revisions {
    const arena = std.testing.allocator;
    try std.testing.expectEqualStrings("v1.6.0..v1.7.0", try revisions(arena, "v1.6.0..v1.7.0"));
    try std.testing.expectEqualStrings("main...feature", try revisions(arena, "main...feature"));
    try std.testing.expectEqualStrings("abc^!", try revisions(arena, "abc^!"));
    const commit = try revisions(arena, "4c8f61ac");
    defer arena.free(commit);
    try std.testing.expectEqualStrings("4c8f61ac^!", commit);
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
