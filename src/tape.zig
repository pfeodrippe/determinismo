// SPDX-License-Identifier: MIT
//! Tapes (docs/PLUGINS.md): the decisions a strategy overrode in one branch, written as JSON lines
//! so the branch replays without the strategy. Replays load overrides into a fixed table.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const Strategy = @import("strategy.zig");

pub const override_count_max = 1 << 16;
const tape_version = 2;

pub const Header = struct {
    /// What the machine booted (see `inputs_hash` in main.zig): a tape replays only on the same.
    inputs: u64,
    exploration_seed: u64,
    branch: u32,
    branch_seed: u64,
    /// Set for a branch explored from a moment of another branch (a nested snapshot).
    fork: ?Fork = null,
};

/// A moment of a branch of the setup snapshot, where a nested snapshot is taken.
pub const Fork = struct {
    branch: u32,
    vtime_ns: u64,
    /// A command run at the fork point before the snapshot: the branches explore its effects.
    exec: ?[]const u8 = null,
};

pub const Override = struct { pull: u64, size: u8, bytes: [Strategy.override_size_max]u8 };

/// Overrides of one branch, ordered by pull. A replay consumes them in order.
/// The state of a branch at an event count: a replay that differs there has diverged.
pub const Checkpoint = struct { events: u64, branches: u64, events_hash: u64 };
pub const checkpoint_interval = 64;
pub const checkpoint_count_max = 1 << 14;

pub const Overrides = struct {
    entries: [override_count_max]Override,
    count: u32,
    cursor: u32,
    checkpoints: [checkpoint_count_max]Checkpoint = undefined,
    checkpoint_count: u32 = 0,
    checkpoint_cursor: u32 = 0,

    /// Compares the replay with the tape's checkpoint at this event count, if there is one.
    pub fn check(overrides: *Overrides, now: Checkpoint) !void {
        if (overrides.checkpoint_cursor == overrides.checkpoint_count) return;
        const expected = overrides.checkpoints[overrides.checkpoint_cursor];
        if (expected.events != now.events) return;
        overrides.checkpoint_cursor += 1;
        if (expected.branches != now.branches or expected.events_hash != now.events_hash) {
            return error.ReplayDiverged;
        }
    }

    /// Replaces `value` if pull `pull` was overridden. Pulls arrive in increasing order.
    pub fn apply(overrides: *Overrides, pull: u64, value: []u8) !bool {
        assert(overrides.cursor <= overrides.count);
        if (overrides.cursor == overrides.count) return false;
        const entry = &overrides.entries[overrides.cursor];
        if (entry.pull < pull) return error.TapeOutOfOrder; // The replay diverged from the tape.
        if (entry.pull > pull) return false;
        if (entry.size != value.len) return error.TapeSizeMismatch;
        @memcpy(value, entry.bytes[0..entry.size]);
        overrides.cursor += 1;
        return true;
    }
};

pub fn write_header(fd: linux.fd_t, header: Header) void {
    assert(fd >= 0);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print("{{\"tape\":{d},\"inputs\":\"{x:0>16}\",\"exploration_seed\":\"{x:0>16}\"," ++
        "\"branch\":{d},\"branch_seed\":\"{x:0>16}\"", .{
        tape_version,  header.inputs,      header.exploration_seed,
        header.branch, header.branch_seed,
    }) catch unreachable; // 256 bytes fit the keys, three hashes and a fork.
    if (header.fork) |fork| {
        writer.print(",\"from_branch\":{d},\"from_vtime_ns\":{d}", .{
            fork.branch, fork.vtime_ns,
        }) catch unreachable;
        if (fork.exec) |command| {
            writer.writeAll(",\"from_exec\":") catch unreachable;
            std.json.Stringify.value(command, .{}, &writer) catch unreachable;
        }
    }
    writer.writeAll("}\n") catch unreachable;
    write_all(fd, writer.buffered());
}

pub fn write_override(fd: linux.fd_t, pull: u64, value: []const u8) void {
    assert(fd >= 0);
    assert(value.len <= Strategy.override_size_max);
    var buffer: [64 + 2 * Strategy.override_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print("{{\"pull\":{d},\"hex\":\"", .{pull}) catch unreachable;
    for (value) |byte| writer.print("{x:0>2}", .{byte}) catch unreachable;
    writer.writeAll("\"}\n") catch unreachable;
    write_all(fd, writer.buffered());
}

/// Parses a tape file's contents into its header and `overrides`.
pub fn parse(source: []const u8, scratch: []u8, overrides: *Overrides) !Header {
    assert(scratch.len > 0);
    overrides.count = 0;
    overrides.cursor = 0;
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    const header_line = lines.next() orelse return error.EmptyTape;
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    const Value = std.json.Value;
    const header = try std.json.parseFromSliceLeaky(Value, fba.allocator(), header_line, .{});
    if (header != .object) return error.BadTape;
    if ((header.object.get("tape") orelse return error.BadTape).integer != tape_version) {
        return error.UnsupportedTape;
    }
    const result = Header{
        .inputs = try hex_field(header.object, "inputs"),
        .exploration_seed = try hex_field(header.object, "exploration_seed"),
        .branch = @intCast((header.object.get("branch") orelse return error.BadTape).integer),
        .branch_seed = try hex_field(header.object, "branch_seed"),
        .fork = if (header.object.get("from_branch")) |from_branch| .{
            .branch = @intCast(from_branch.integer),
            .vtime_ns = @intCast((header.object.get("from_vtime_ns") orelse
                return error.BadTape).integer),
            .exec = if (header.object.get("from_exec")) |command| command.string else null,
        } else null,
    };
    overrides.checkpoint_count = 0;
    overrides.checkpoint_cursor = 0;
    while (lines.next()) |line| {
        fba.reset();
        const value = try std.json.parseFromSliceLeaky(Value, fba.allocator(), line, .{});
        if (value.object.get("checkpoint")) |checkpoint| {
            try checkpoint_parse(overrides, checkpoint);
            continue;
        }
        if (overrides.count == override_count_max) return error.TapeTooLong;
        const entry = &overrides.entries[overrides.count];
        entry.pull = @intCast((value.object.get("pull") orelse return error.BadTape).integer);
        const hex = (value.object.get("hex") orelse return error.BadTape).string;
        if (hex.len > 2 * Strategy.override_size_max) return error.BadTape;
        entry.size = @intCast((try std.fmt.hexToBytes(&entry.bytes, hex)).len);
        if (overrides.count > 0) {
            if (overrides.entries[overrides.count - 1].pull >= entry.pull) return error.BadTape;
        }
        overrides.count += 1;
    }
    return result;
}

fn checkpoint_parse(overrides: *Overrides, value: std.json.Value) !void {
    if (value != .object) return error.BadTape;
    if (overrides.checkpoint_count == checkpoint_count_max) return error.TapeTooLong;
    overrides.checkpoints[overrides.checkpoint_count] = .{
        .events = @intCast((value.object.get("events") orelse return error.BadTape).integer),
        .branches = @intCast((value.object.get("branches") orelse return error.BadTape).integer),
        .events_hash = try hex_field(value.object, "events_hash"),
    };
    overrides.checkpoint_count += 1;
}

pub fn write_checkpoint(fd: linux.fd_t, checkpoint: Checkpoint) void {
    var buffer: [160]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{{\"checkpoint\":{{\"events\":{d},\"branches\":{d}," ++
        "\"events_hash\":\"{x:0>16}\"}}}}\n", .{
        checkpoint.events, checkpoint.branches, checkpoint.events_hash,
    }) catch unreachable;
    write_all(fd, line);
}

fn hex_field(object: std.json.ObjectMap, key: []const u8) !u64 {
    assert(key.len > 0);
    const value = object.get(key) orelse return error.BadTape;
    if (value != .string) return error.BadTape;
    return std.fmt.parseInt(u64, value.string, 16);
}

fn write_all(fd: linux.fd_t, bytes: []const u8) void {
    var written: u64 = 0;
    while (written < bytes.len) {
        const result = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        if (linux.errno(result) != .SUCCESS) return; // Reported when the tape fails to replay.
        written += result;
    }
    assert(written == bytes.len);
}

test "a written tape parses back" {
    const allocator = std.testing.allocator;
    const overrides = try allocator.create(Overrides);
    defer allocator.destroy(overrides);
    const scratch = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(scratch);
    const source = "{\"tape\":2,\"inputs\":\"00000000000000aa\"," ++
        "\"exploration_seed\":\"0000000000000007\",\"branch\":3," ++
        "\"branch_seed\":\"00000000000000ff\"}\n" ++
        "{\"pull\":10,\"hex\":\"0102\"}\n" ++
        "{\"pull\":12,\"hex\":\"ff\"}\n";
    const header = try parse(source, scratch, overrides);
    try std.testing.expectEqual(@as(u64, 7), header.exploration_seed);
    try std.testing.expectEqual(@as(u32, 3), header.branch);
    try std.testing.expectEqual(@as(u32, 2), overrides.count);
    var value: [2]u8 = .{ 0, 0 };
    try std.testing.expect(!try overrides.apply(9, &value));
    try std.testing.expect(try overrides.apply(10, &value));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &value);
}
