// SPDX-License-Identifier: MIT
//! A Redis (RESP2) client over the SDK's TCP connection (sdk/zig/tcp.zig) that reads nested
//! replies, as EXEC gives them (an array of each command's reply, LRANGE's an array itself):
//! values are copied into the caller's arena, the connection's buffer being reused.
const std = @import("std");
const assert = std.debug.assert;
const tcp = @import("determinismo").tcp;

const command_size_max = 4096;
const depth_max = 4;
const array_count_max = 4096;

socket: tcp.Connection,

const Connection = @This();

pub const Value = union(enum) {
    status: []const u8,
    failure: []const u8,
    integer: i64,
    bulk: ?[]const u8,
    array: ?[]const Value,
};

/// A request with no answer for `timeout_ms` fails (ReadFailed): under faults, "unknown" must
/// be quick to observe.
pub fn open(connection: *Connection, address: [4]u8, port: u16, timeout_ms: u32) !void {
    try connection.socket.open(address, port, .{ .timeout_ms = timeout_ms });
}

pub fn close(connection: *Connection) void {
    connection.socket.close();
}

/// Sends commands one after another (a pipeline), then reads one reply per command.
pub fn pipeline(connection: *Connection, arena: std.mem.Allocator, commands: []const []const []const u8) ![]const Value {
    assert(commands.len > 0);
    var command_buffer: [command_size_max]u8 = undefined;
    for (commands) |parts| {
        var writer: std.Io.Writer = .fixed(&command_buffer);
        try writer.print("*{d}\r\n", .{parts.len});
        for (parts) |part| try writer.print("${d}\r\n{s}\r\n", .{ part.len, part });
        try connection.socket.write_all(writer.buffered());
    }
    const replies = try arena.alloc(Value, commands.len);
    for (replies) |*reply| reply.* = try connection.read_value(arena, 0);
    return replies;
}

fn read_value(connection: *Connection, arena: std.mem.Allocator, depth: u32) !Value {
    if (depth > depth_max) return error.BadReply;
    const line = try connection.socket.read_line();
    if (line.len == 0) return error.BadReply;
    switch (line[0]) {
        '+' => return .{ .status = try arena.dupe(u8, line[1..]) },
        '-' => return .{ .failure = try arena.dupe(u8, line[1..]) },
        ':' => return .{ .integer = try std.fmt.parseInt(i64, line[1..], 10) },
        '$' => {
            const size = try std.fmt.parseInt(i64, line[1..], 10);
            if (size < 0) return .{ .bulk = null };
            const body = try connection.socket.read_exact(@intCast(size + 2));
            return .{ .bulk = try arena.dupe(u8, body[0..@intCast(size)]) };
        },
        '*' => {
            const count = try std.fmt.parseInt(i64, line[1..], 10);
            if (count < 0) return .{ .array = null };
            if (count > array_count_max) return error.BadReply;
            const values = try arena.alloc(Value, @intCast(count));
            for (values) |*value| value.* = try connection.read_value(arena, depth + 1);
            return .{ .array = values };
        },
        else => return error.BadReply,
    }
}
