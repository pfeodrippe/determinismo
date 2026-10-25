// SPDX-License-Identifier: MIT
//! A minimal PostgreSQL client (wire protocol 3, simple queries, trust authentication) over a
//! blocking TCP socket, with fixed buffers.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

const buffer_size = 64 * 1024;
const query_size_max = 4096;
const timeout_ms = 2000;
const protocol_version: u32 = 3 << 16;

fd: linux.fd_t,
buffer: [buffer_size]u8 = undefined,
start: u32 = 0,
end: u32 = 0,
/// The server's message for the last error.ServerError.
error_message: [256]u8 = undefined,
error_message_size: u32 = 0,

const Connection = @This();

pub fn open(connection: *Connection, address: [4]u8, port: u16, user: []const u8) !void {
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket) != .SUCCESS) return error.SocketFailed;
    connection.* = .{ .fd = @intCast(socket) };
    errdefer _ = linux.close(connection.fd);
    const timeout = linux.timeval{ .sec = 0, .usec = timeout_ms * std.time.us_per_ms };
    for ([_]u32{ linux.SO.RCVTIMEO, linux.SO.SNDTIMEO }) |option| {
        const size = @sizeOf(linux.timeval);
        _ = linux.setsockopt(connection.fd, linux.SOL.SOCKET, option, @ptrCast(&timeout), size);
    }
    const target = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(address), // Already in network order.
    };
    const result = linux.connect(connection.fd, @ptrCast(&target), @sizeOf(linux.sockaddr.in));
    if (linux.errno(result) != .SUCCESS) return error.ConnectFailed;
    try connection.startup(user);
}

pub fn close(connection: *Connection) void {
    assert(connection.fd >= 0);
    _ = linux.close(connection.fd);
    connection.fd = -1;
}

pub fn last_error(connection: *const Connection) []const u8 {
    return connection.error_message[0..connection.error_message_size];
}

/// Runs statements, ignoring any rows.
pub fn exec(connection: *Connection, sql: []const u8) !void {
    _ = try connection.query(sql, null);
}

/// Runs a query and returns the first column of its first row as an integer (null for no row
/// or SQL NULL).
pub fn query_integer(connection: *Connection, sql: []const u8) !?i64 {
    var cell: [32]u8 = undefined;
    const value = try connection.query(sql, &cell) orelse return null;
    return try std.fmt.parseInt(i64, value, 10);
}

fn startup(connection: *Connection, user: []const u8) !void {
    var message: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&message);
    try writer.writeInt(u32, 0, .big); // Length, patched below.
    try writer.writeInt(u32, protocol_version, .big);
    try writer.print("user\x00{s}\x00database\x00{s}\x00\x00", .{ user, user });
    const size: u32 = @intCast(writer.end);
    std.mem.writeInt(u32, message[0..4], size, .big);
    try connection.write_all(message[0..size]);
    while (true) {
        const reply = try connection.message_read();
        switch (reply.kind) {
            'R' => {
                if (reply.body.len < 4) return error.BadReply;
                const code = std.mem.readInt(u32, reply.body[0..4], .big);
                if (code != 0) return error.PasswordRequired; // Only trust authentication.
            },
            'E' => return connection.server_error(reply.body),
            'Z' => return,
            else => {}, // Parameter status, backend key, notices.
        }
    }
}

/// Sends one simple query; copies the first cell of the first row into `cell`, if given.
fn query(connection: *Connection, sql: []const u8, cell: ?[]u8) !?[]const u8 {
    if (sql.len + 6 > query_size_max) return error.QueryTooLarge;
    var message: [query_size_max]u8 = undefined;
    message[0] = 'Q';
    std.mem.writeInt(u32, message[1..5], @intCast(sql.len + 5), .big);
    @memcpy(message[5..][0..sql.len], sql);
    message[5 + sql.len] = 0;
    try connection.write_all(message[0 .. sql.len + 6]);
    var value: ?[]const u8 = null;
    var failed = false;
    while (true) {
        const reply = try connection.message_read();
        switch (reply.kind) {
            'D' => if (value == null and cell != null) {
                value = try first_cell(reply.body, cell.?);
            },
            'E' => {
                _ = connection.server_error(reply.body) catch {};
                failed = true;
            },
            'Z' => return if (failed) error.ServerError else value,
            else => {}, // Row description, command complete, notices.
        }
    }
}

fn first_cell(body: []const u8, cell: []u8) !?[]const u8 {
    if (body.len < 6) return error.BadReply;
    const columns = std.mem.readInt(u16, body[0..2], .big);
    if (columns == 0) return null;
    const size = std.mem.readInt(i32, body[2..6], .big);
    if (size < 0) return null; // NULL.
    if (size > cell.len or 6 + size > body.len) return error.BadReply;
    const bytes = body[6..][0..@intCast(size)];
    @memcpy(cell[0..bytes.len], bytes);
    return cell[0..bytes.len];
}

fn server_error(connection: *Connection, body: []const u8) error{ServerError} {
    // Fields: a type byte and a NUL-terminated string each; 'M' is the message.
    var fields = std.mem.splitScalar(u8, body, 0);
    while (fields.next()) |field| {
        if (field.len < 1 or field[0] != 'M') continue;
        const size = @min(field.len - 1, connection.error_message.len);
        @memcpy(connection.error_message[0..size], field[1..][0..size]);
        connection.error_message_size = @intCast(size);
        break;
    }
    return error.ServerError;
}

const Message = struct { kind: u8, body: []const u8 };

fn message_read(connection: *Connection) !Message {
    try connection.fill(5);
    const header = connection.buffer[connection.start..][0..5];
    const kind = header[0]; // Copied: the next fill may move the buffered bytes.
    const size = std.mem.readInt(u32, header[1..5], .big);
    if (size < 4 or size > buffer_size - 1) return error.ReplyTooLarge;
    try connection.fill(1 + size);
    const message = Message{
        .kind = kind,
        .body = connection.buffer[connection.start + 5 ..][0 .. size - 4],
    };
    connection.start += 1 + size;
    return message;
}

/// Ensures `size` unread bytes are buffered.
fn fill(connection: *Connection, size: u32) !void {
    assert(size <= buffer_size);
    if (connection.end - connection.start >= size) return;
    const pending = connection.end - connection.start;
    const unread = connection.buffer[connection.start..connection.end];
    std.mem.copyForwards(u8, connection.buffer[0..pending], unread);
    connection.start = 0;
    connection.end = pending;
    while (connection.end < size) {
        const free = connection.buffer[connection.end..];
        const result = linux.read(connection.fd, free.ptr, free.len);
        if (linux.errno(result) != .SUCCESS) return error.ReadFailed;
        if (result == 0) return error.ConnectionClosed;
        connection.end += @intCast(result);
    }
}

fn write_all(connection: *Connection, bytes: []const u8) !void {
    var written: u64 = 0;
    while (written < bytes.len) {
        const result = linux.write(connection.fd, bytes[written..].ptr, bytes.len - written);
        if (linux.errno(result) != .SUCCESS) return error.WriteFailed;
        written += result;
    }
}

/// Whether `err` means the server could not be reached (as opposed to an SQL or protocol error).
pub fn is_unavailable(err: anyerror) bool {
    return switch (err) {
        error.ConnectFailed, error.WriteFailed, error.ReadFailed, error.ConnectionClosed => true,
        else => false,
    };
}

test first_cell {
    var cell: [8]u8 = undefined;
    const row = [_]u8{ 0, 1, 0, 0, 0, 3, '4', '2', '0' };
    try std.testing.expectEqualStrings("420", (try first_cell(&row, &cell)).?);
    const null_row = [_]u8{ 0, 1, 0xff, 0xff, 0xff, 0xff };
    try std.testing.expect(try first_cell(&null_row, &cell) == null);
}
