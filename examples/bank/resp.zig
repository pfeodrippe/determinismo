// SPDX-License-Identifier: MIT
//! A minimal Redis (RESP2) client over a blocking TCP socket to 127.0.0.1, with fixed buffers.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

const buffer_size = 64 * 1024;
const command_size_max = 1024;
pub const array_count_max = 64;

fd: linux.fd_t,
buffer: [buffer_size]u8 = undefined,
start: u32 = 0,
end: u32 = 0,

const Connection = @This();

pub const Reply = union(enum) {
    status: []const u8,
    failure: []const u8,
    integer: i64,
    bulk: ?[]const u8,
};

pub fn open(connection: *Connection, port: u16) !void {
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket) != .SUCCESS) return error.SocketFailed;
    connection.* = .{ .fd = @intCast(socket) };
    const address = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    const result = linux.connect(connection.fd, &address, @sizeOf(linux.sockaddr.in));
    if (linux.errno(result) != .SUCCESS) return error.ConnectFailed;
    assert(connection.start == 0);
    assert(connection.end == 0);
}

pub fn close(connection: *Connection) void {
    assert(connection.fd >= 0);
    _ = linux.close(connection.fd);
    connection.fd = -1;
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
    const bytes = writer.buffered();
    var written: u32 = 0;
    while (written < bytes.len) {
        const result = linux.write(connection.fd, bytes[written..].ptr, bytes.len - written);
        if (linux.errno(result) != .SUCCESS) return error.WriteFailed;
        written += @intCast(result);
    }
    assert(written == bytes.len);
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
    for (0..buffer_size) |_| {
        const pending = connection.buffer[connection.start..connection.end];
        if (std.mem.indexOf(u8, pending, "\r\n")) |index| {
            connection.start += @intCast(index + 2);
            return pending[0..index];
        }
        try connection.fill();
    }
    return error.LineTooLong;
}

fn read_exact(connection: *Connection, size: u32) ![]const u8 {
    if (size > buffer_size) return error.ReplyTooLarge;
    while (connection.end - connection.start < size) try connection.fill();
    const bytes = connection.buffer[connection.start..][0..size];
    connection.start += size;
    return bytes;
}

fn fill(connection: *Connection) !void {
    assert(connection.start <= connection.end);
    if (connection.start > 0) {
        const pending = connection.end - connection.start;
        const source = connection.buffer[connection.start..connection.end];
        std.mem.copyForwards(u8, connection.buffer[0..pending], source);
        connection.start = 0;
        connection.end = pending;
    }
    if (connection.end == buffer_size) return error.ReplyTooLarge;
    const free = connection.buffer[connection.end..];
    const result = linux.read(connection.fd, free.ptr, free.len);
    if (linux.errno(result) != .SUCCESS) return error.ReadFailed;
    if (result == 0) return error.ConnectionClosed;
    connection.end += @intCast(result);
    assert(connection.end <= buffer_size);
}
