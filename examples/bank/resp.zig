// SPDX-License-Identifier: MIT
//! A minimal Redis (RESP2) client over the SDK's TCP connection (sdk/zig/tcp.zig).
const std = @import("std");
const assert = std.debug.assert;
const tcp = @import("tcp");

/// A request that gets no answer for this long fails (ReadFailed) instead of waiting out TCP's
/// retransmissions: under network faults, "unavailable" must be quick to observe.
const timeout_ms = 1000;
const command_size_max = 1024;
pub const array_count_max = 64;

socket: tcp.Connection,

const Connection = @This();

pub const Reply = union(enum) {
    status: []const u8,
    failure: []const u8,
    integer: i64,
    bulk: ?[]const u8,
};

pub fn open(connection: *Connection, address: [4]u8, port: u16) !void {
    try connection.socket.open(address, port, .{ .timeout_ms = timeout_ms });
}

/// Whether `err` means the server could not be reached (as opposed to a protocol error).
pub const is_unavailable = tcp.unavailable;

pub fn close(connection: *Connection) void {
    connection.socket.close();
}

/// Sends one command and reads its (non-array) reply. The reply borrows the read buffer until
/// the next call.
pub fn call(connection: *Connection, parts: []const []const u8) !Reply {
    try connection.send(parts);
    const line = try connection.read_line();
    if (line.len == 0) return error.BadReply;
    return connection.parse(line);
}

/// For array replies (MGET, EXEC): fills `values` with each bulk element (null for anything
/// else) and returns how many elements there were.
pub fn call_array(connection: *Connection, parts: []const []const u8, values: []?[]const u8) !u32 {
    assert(values.len <= array_count_max);
    try connection.send(parts);
    const header = try connection.read_line();
    if (header.len == 0 or header[0] != '*') return error.BadReply;
    const count = try std.fmt.parseInt(u32, header[1..], 10);
    if (count > values.len) return error.BadReply;
    for (values[0..count]) |*value| {
        const line = try connection.read_line();
        if (line.len == 0) return error.BadReply;
        const reply = try connection.parse(line);
        value.* = if (reply == .bulk) reply.bulk else null;
    }
    return count;
}

fn send(connection: *Connection, parts: []const []const u8) !void {
    assert(parts.len > 0);
    var command_buffer: [command_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&command_buffer);
    try writer.print("*{d}\r\n", .{parts.len});
    for (parts) |part| try writer.print("${d}\r\n{s}\r\n", .{ part.len, part });
    try connection.socket.write_all(writer.buffered());
}

fn parse(connection: *Connection, line: []const u8) !Reply {
    assert(line.len > 0);
    switch (line[0]) {
        '+' => return .{ .status = line[1..] },
        '-' => return .{ .failure = line[1..] },
        ':' => return .{ .integer = try std.fmt.parseInt(i64, line[1..], 10) },
        '$' => {
            const size = try std.fmt.parseInt(i64, line[1..], 10);
            if (size < 0) return .{ .bulk = null };
            const body = try connection.read_exact(@intCast(size + 2));
            return .{ .bulk = body[0..@intCast(size)] };
        },
        else => return error.BadReply,
    }
}

fn read_line(connection: *Connection) ![]const u8 {
    return connection.socket.read_line();
}

fn read_exact(connection: *Connection, size: u32) ![]const u8 {
    return connection.socket.read_exact(size);
}
