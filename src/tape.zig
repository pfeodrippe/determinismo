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
    /// The tree explorer's path to where this branch starts, from the setup snapshot: each
    /// ancestor (its index and seed) and the moment the next one left it. Empty: the snapshot.
    chain: []const Segment = &.{},
    /// The build of determinismo that recorded it (a hash of its executable): a replay by another
    /// may part from it for that alone (null: tapes from before 2026-10-29).
    host: ?u64 = null,
};

/// One step of a path: branch `branch` (seed `seed`) ran from the previous step's moment to
/// `vtime_ns`, where the next one branched from it.
pub const Segment = struct { branch: u32, seed: u64, vtime_ns: u64 };
pub const chain_length_max = 64;

/// A moment of a branch of the setup snapshot, where a nested snapshot is taken.
pub const Fork = struct {
    branch: u32,
    vtime_ns: u64,
    /// A command run at the fork point before the snapshot: the branches explore its effects.
    exec: ?[]const u8 = null,
};

pub const Override = struct { pull: u64, size: u8, bytes: [Strategy.override_size_max]u8 };

/// A strategy's reason for an override, replayed with it (a `decision` event in the timeline).
pub const Reason = struct { pull: u64, size: u8, text: [Strategy.reason_size_max]u8 };
pub const reason_count_max = 1024;

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
    reasons: [reason_count_max]Reason = undefined,
    reason_count: u32 = 0,
    reason_cursor: u32 = 0,

    /// The reason recorded for pull `pull`, if any. Pulls arrive in increasing order.
    pub fn reason(overrides: *Overrides, pull: u64) ?[]const u8 {
        while (overrides.reason_cursor < overrides.reason_count) {
            const entry = &overrides.reasons[overrides.reason_cursor];
            if (entry.pull > pull) return null;
            overrides.reason_cursor += 1;
            if (entry.pull == pull) return entry.text[0..entry.size];
        }
        return null;
    }

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
    assert(header.chain.len <= chain_length_max);
    var buffer: [512 + chain_length_max * 80]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print("{{\"tape\":{d},\"inputs\":\"{x:0>16}\",\"exploration_seed\":\"{x:0>16}\"," ++
        "\"branch\":{d},\"branch_seed\":\"{x:0>16}\"", .{
        tape_version,  header.inputs,      header.exploration_seed,
        header.branch, header.branch_seed,
    }) catch unreachable; // The keys, three hashes, a fork and a chain fit.
    if (header.chain.len > 0) {
        writer.writeAll(",\"chain\":[") catch unreachable;
        for (header.chain, 0..) |segment, index| {
            if (index > 0) writer.writeAll(",") catch unreachable;
            writer.print("{{\"branch\":{d},\"seed\":\"{x:0>16}\",\"vtime_ns\":{d}}}", .{
                segment.branch, segment.seed, segment.vtime_ns,
            }) catch unreachable;
        }
        writer.writeAll("]") catch unreachable;
    }
    if (header.host) |host| writer.print(",\"host\":\"{x:0>16}\"", .{host}) catch unreachable;
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

pub fn write_override(fd: linux.fd_t, pull: u64, value: []const u8, reason: []const u8) void {
    assert(fd >= 0);
    assert(value.len <= Strategy.override_size_max);
    assert(reason.len <= Strategy.reason_size_max);
    var buffer: [96 + 2 * Strategy.override_size_max + 6 * Strategy.reason_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print("{{\"pull\":{d},\"hex\":\"", .{pull}) catch unreachable;
    for (value) |byte| writer.print("{x:0>2}", .{byte}) catch unreachable;
    writer.writeAll("\"") catch unreachable;
    if (reason.len > 0) {
        writer.writeAll(",\"reason\":") catch unreachable;
        std.json.Stringify.value(reason, .{}, &writer) catch unreachable;
    }
    writer.writeAll("}\n") catch unreachable;
    write_all(fd, writer.buffered());
}

/// Parses a tape file's contents into its header and `overrides`.
pub fn parse(source: []const u8, scratch: []u8, overrides: *Overrides) !Header {
    assert(scratch.len > 0);
    overrides.count = 0;
    overrides.cursor = 0;
    overrides.reason_count = 0;
    overrides.reason_cursor = 0;
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    const header_line = lines.next() orelse return error.EmptyTape;
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    const Value = std.json.Value;
    const header = try std.json.parseFromSliceLeaky(Value, fba.allocator(), header_line, .{});
    if (header != .object) return error.BadTape;
    if ((header.object.get("tape") orelse return error.BadTape).integer != tape_version) {
        return error.UnsupportedTape;
    }
    var result = Header{
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
        .host = if (header.object.get("host") != null) try hex_field(header.object, "host") else null,
    };
    if (header.object.get("chain")) |chain| {
        if (chain != .array or chain.array.items.len > chain_length_max) return error.BadTape;
        const segments = try fba.allocator().alloc(Segment, chain.array.items.len);
        for (chain.array.items, segments) |item, *segment| {
            if (item != .object) return error.BadTape;
            segment.* = .{
                .branch = @intCast((item.object.get("branch") orelse return error.BadTape).integer),
                .seed = try hex_field(item.object, "seed"),
                .vtime_ns = @intCast((item.object.get("vtime_ns") orelse
                    return error.BadTape).integer),
            };
        }
        result.chain = segments;
    }
    // What the header points into stays; the overrides are parsed after it.
    var rest = std.heap.FixedBufferAllocator.init(scratch[fba.end_index..]);
    overrides.checkpoint_count = 0;
    overrides.checkpoint_cursor = 0;
    while (lines.next()) |line| {
        rest.reset();
        const value = try std.json.parseFromSliceLeaky(Value, rest.allocator(), line, .{});
        if (value.object.get("checkpoint")) |checkpoint| {
            try checkpoint_parse(overrides, checkpoint);
            continue;
        }
        try override_parse(overrides, value);
    }
    return result;
}

fn override_parse(overrides: *Overrides, value: std.json.Value) !void {
    if (overrides.count == override_count_max) return error.TapeTooLong;
    const entry = &overrides.entries[overrides.count];
    entry.pull = @intCast((value.object.get("pull") orelse return error.BadTape).integer);
    const hex = (value.object.get("hex") orelse return error.BadTape).string;
    if (hex.len > 2 * Strategy.override_size_max) return error.BadTape;
    entry.size = @intCast((try std.fmt.hexToBytes(&entry.bytes, hex)).len);
    if (value.object.get("reason")) |reason| if (reason == .string) {
        if (overrides.reason_count == reason_count_max) return error.TapeTooLong;
        const kept = &overrides.reasons[overrides.reason_count];
        kept.pull = entry.pull;
        kept.size = @intCast(@min(reason.string.len, Strategy.reason_size_max));
        @memcpy(kept.text[0..kept.size], reason.string[0..kept.size]);
        overrides.reason_count += 1;
    };
    if (overrides.count > 0) {
        if (overrides.entries[overrides.count - 1].pull >= entry.pull) return error.BadTape;
    }
    overrides.count += 1;
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

test "a path round-trips through the header" {
    const allocator = std.testing.allocator;
    const overrides = try allocator.create(Overrides);
    defer allocator.destroy(overrides);
    const scratch = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(scratch);
    var pipe: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.pipe(&pipe));
    defer _ = linux.close(pipe[0]);
    const chain = [_]Segment{
        .{ .branch = 0, .seed = 0xa, .vtime_ns = 1_200_000_000 },
        .{ .branch = 17, .seed = 0xb, .vtime_ns = 3_410_000_000 },
    };
    write_header(pipe[1], .{
        .inputs = 1,
        .exploration_seed = 2,
        .branch = 42,
        .branch_seed = 3,
        .chain = &chain,
        .host = 0xfeed,
    });
    _ = linux.close(pipe[1]);
    var source: [4096]u8 = undefined;
    const size = linux.read(pipe[0], &source, source.len);
    const header = try parse(source[0..size], scratch, overrides);
    try std.testing.expectEqual(@as(u32, 42), header.branch);
    try std.testing.expectEqual(@as(usize, 2), header.chain.len);
    try std.testing.expectEqual(chain[1], header.chain[1]);
    try std.testing.expectEqual(@as(?u64, 0xfeed), header.host);
}
