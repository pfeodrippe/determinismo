// SPDX-License-Identifier: MIT
//! TCP for test programs: a blocking connection with timeouts and a fixed read buffer, the base
//! of protocol clients (Redis, Postgres, line protocols).
//!
//! Under faults a server is often unreachable for a while: connecting, writing or reading then
//! fails quickly (the timeouts) with an error `unavailable` recognizes, which a test notes rather
//! than treats as a bug.
//!
//!   var connection: sdk.tcp.Connection = undefined;
//!   try connection.open(ctx.nodes.bank.address, 7000, .{});
//!   defer connection.close();
//!   try connection.write_all("total\n");
//!   const line = try connection.read_line();
//!
//!   const reply = try sdk.tcp.request_line(address, 7000, "total\n", &buffer); // One shot.
//!   const response = try sdk.tcp.http(address, 8000, "GET", "/state", "", &buffer); // HTTP.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub const buffer_size = 64 * 1024;

pub const Options = struct {
    /// A connect, write or read that waits longer fails (instead of waiting out TCP's
    /// retransmissions): under network faults, "unavailable" must be quick to observe.
    timeout_ms: u32 = 1000,
};

/// Whether `err` means the server could not be reached or went away (as opposed to a protocol
/// error or a bug).
pub fn unavailable(err: anyerror) bool {
    return switch (err) {
        error.ConnectFailed, error.WriteFailed, error.ReadFailed, error.ConnectionClosed => true,
        else => false,
    };
}

pub const Connection = struct {
    fd: linux.fd_t = -1,
    buffer: [buffer_size]u8 = undefined,
    start: u32 = 0,
    end: u32 = 0,

    pub fn open(connection: *Connection, address: [4]u8, port: u16, options: Options) !void {
        const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(socket) != .SUCCESS) return error.SocketFailed;
        connection.* = .{ .fd = @intCast(socket) };
        errdefer connection.close();
        const timeout = linux.timeval{
            .sec = @intCast(options.timeout_ms / std.time.ms_per_s),
            .usec = @intCast((options.timeout_ms % std.time.ms_per_s) * std.time.us_per_ms),
        };
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
    }

    pub fn close(connection: *Connection) void {
        assert(connection.fd >= 0);
        _ = linux.close(connection.fd);
        connection.fd = -1;
    }

    pub fn write_all(connection: *Connection, bytes: []const u8) !void {
        assert(connection.fd >= 0);
        var written: usize = 0;
        while (written < bytes.len) {
            const result = linux.write(connection.fd, bytes[written..].ptr, bytes.len - written);
            if (linux.errno(result) != .SUCCESS) return error.WriteFailed;
            written += result;
        }
    }

    /// The next line, without its "\n" (or "\r\n"). It borrows the buffer until the next read.
    pub fn read_line(connection: *Connection) ![]const u8 {
        for (0..buffer_size) |_| {
            const pending = connection.buffer[connection.start..connection.end];
            if (std.mem.indexOfScalar(u8, pending, '\n')) |index| {
                connection.start += @intCast(index + 1);
                return std.mem.trimEnd(u8, pending[0..index], "\r");
            }
            try connection.fill();
        }
        return error.LineTooLong;
    }

    /// The next `size` bytes. They borrow the buffer until the next read.
    pub fn read_exact(connection: *Connection, size: u32) ![]const u8 {
        if (size > buffer_size) return error.ReplyTooLarge;
        while (connection.end - connection.start < size) try connection.fill();
        const bytes = connection.buffer[connection.start..][0..size];
        connection.start += size;
        return bytes;
    }

    /// Everything until the server closes the connection (at most the buffer).
    pub fn read_all(connection: *Connection) ![]const u8 {
        while (true) {
            connection.fill() catch |err| switch (err) {
                error.ConnectionClosed => break,
                else => return err,
            };
        }
        const bytes = connection.buffer[connection.start..connection.end];
        connection.start = connection.end;
        return bytes;
    }

    fn fill(connection: *Connection) !void {
        assert(connection.fd >= 0);
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
};

/// One request on a new connection, and the first line of the reply, copied into `reply`: what
/// line protocols need.
pub fn request_line(address: [4]u8, port: u16, request: []const u8, reply: []u8) ![]const u8 {
    var connection: Connection = undefined;
    try connection.open(address, port, .{});
    defer connection.close();
    try connection.write_all(request);
    const line = try connection.read_line();
    if (line.len > reply.len) return error.ReplyTooLarge;
    @memcpy(reply[0..line.len], line);
    return reply[0..line.len];
}

pub const Response = struct { status: u16, body: []const u8 };

/// One HTTP/1.0 request on a new connection (the server closes it after answering): its status
/// and body, copied into `buffer`. For the HTTP APIs systems under test expose.
pub fn http(
    address: [4]u8,
    port: u16,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    buffer: []u8,
) !Response {
    var connection: Connection = undefined;
    try connection.open(address, port, .{});
    defer connection.close();
    var head_buffer: [512]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buffer, "{s} {s} HTTP/1.0\r\nHost: node\r\n" ++
        "Content-Length: {d}\r\nContent-Type: application/octet-stream\r\n\r\n", .{
        method, path, body.len,
    });
    try connection.write_all(head);
    try connection.write_all(body);
    return response_parse(try connection.read_all(), buffer);
}

fn response_parse(raw: []const u8, buffer: []u8) !Response {
    // "HTTP/1.x NNN reason\r\n" headers "\r\n\r\n" body.
    if (raw.len < 12 or !std.mem.startsWith(u8, raw, "HTTP/1.")) return error.BadReply;
    const status = std.fmt.parseInt(u16, raw[9..12], 10) catch return error.BadReply;
    const end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.BadReply;
    const body = raw[end + 4 ..];
    if (body.len > buffer.len) return error.ReplyTooLarge;
    @memcpy(buffer[0..body.len], body);
    return .{ .status = status, .body = buffer[0..body.len] };
}

test response_parse {
    var buffer: [64]u8 = undefined;
    const raw = "HTTP/1.1 409 Conflict\r\nA: b\r\n\r\nleader raft-2\n";
    const response = try response_parse(raw, &buffer);
    try std.testing.expectEqual(@as(u16, 409), response.status);
    try std.testing.expectEqualStrings("leader raft-2\n", response.body);
    try std.testing.expectError(error.BadReply, response_parse("garbage", &buffer));
}

test "lines and exact reads over a socket pair" {
    var fds: [2]i32 = undefined;
    const paired = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(paired));
    defer _ = linux.close(fds[1]);
    var connection = Connection{ .fd = fds[0] };
    defer connection.close();
    const sent = "+OK\r\nhello\n$5\r\nworld\r\nrest";
    _ = linux.write(fds[1], sent, sent.len);
    try std.testing.expectEqualStrings("+OK", try connection.read_line());
    try std.testing.expectEqualStrings("hello", try connection.read_line());
    try std.testing.expectEqualStrings("$5", try connection.read_line());
    try std.testing.expectEqualStrings("world\r\n", try connection.read_exact(7));
    _ = linux.shutdown(fds[1], linux.SHUT.WR); // The server is done: end of file after "rest".
    try std.testing.expectEqualStrings("rest", try connection.read_all());
    try std.testing.expect(unavailable(error.ConnectionClosed));
    try std.testing.expect(!unavailable(error.BadReply));
}
