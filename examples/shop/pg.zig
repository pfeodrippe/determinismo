// SPDX-License-Identifier: MIT
//! A minimal PostgreSQL client (wire protocol 3, simple queries, trust authentication) over the
//! SDK's TCP connection (sdk/zig/tcp.zig). It also speaks to what talks PostgreSQL's protocol:
//! CockroachDB, YugabyteDB's YSQL.
const std = @import("std");
const assert = std.debug.assert;
const tcp = @import("determinismo").tcp;

const query_size_max = 4096;
const timeout_ms = 2000;
const protocol_version: u32 = 3 << 16;

socket: tcp.Connection,
/// The server's message for the last error.ServerError.
error_message: [256]u8 = undefined,
error_message_size: u32 = 0,
/// Its SQLSTATE ("40001": a serialization failure, the transaction did not happen).
error_code: [5]u8 = @splat('0'),
/// The rows the last statement affected: its command tag's count ("UPDATE 2"), 0 without one.
rows: u64 = 0,

const Connection = @This();

pub fn open(connection: *Connection, address: [4]u8, port: u16, user: []const u8) !void {
    return connection.open_with(address, port, user, null, .{ .timeout_ms = timeout_ms });
}

/// `open` with a database (null: the user's name, PostgreSQL's default) and connection options:
/// a longer timeout for servers that commit through consensus.
pub fn open_with(
    connection: *Connection,
    address: [4]u8,
    port: u16,
    user: []const u8,
    database: ?[]const u8,
    options: tcp.Options,
) !void {
    connection.error_message_size = 0;
    connection.error_code = @splat('0');
    try connection.socket.open(address, port, options);
    errdefer connection.socket.close();
    try connection.startup(user, database orelse user);
}

pub fn close(connection: *Connection) void {
    connection.socket.close();
}

pub fn last_error(connection: *const Connection) []const u8 {
    return connection.error_message[0..connection.error_message_size];
}

/// The last error's SQLSTATE.
pub fn sqlstate(connection: *const Connection) []const u8 {
    return &connection.error_code;
}

/// Runs a query and returns the first column of its first row as text, copied into `cell` (null
/// for no row or SQL NULL).
pub fn query_text(connection: *Connection, sql: []const u8, cell: []u8) !?[]const u8 {
    return connection.query(sql, cell);
}

/// Runs statements, ignoring any rows.
pub fn exec(connection: *Connection, sql: []const u8) !void {
    _ = try connection.query(sql, null);
}

/// Runs a statement and returns the rows it affected (UPDATE, INSERT, DELETE).
pub fn exec_rows(connection: *Connection, sql: []const u8) !u64 {
    _ = try connection.query(sql, null);
    return connection.rows;
}

/// Runs a query and returns the first column of its first row as an integer (null for no row
/// or SQL NULL).
pub fn query_integer(connection: *Connection, sql: []const u8) !?i64 {
    var cell: [32]u8 = undefined;
    const value = try connection.query(sql, &cell) orelse return null;
    return try std.fmt.parseInt(i64, value, 10);
}

fn startup(connection: *Connection, user: []const u8, database: []const u8) !void {
    var message: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&message);
    try writer.writeInt(u32, 0, .big); // Length, patched below.
    try writer.writeInt(u32, protocol_version, .big);
    try writer.print("user\x00{s}\x00database\x00{s}\x00\x00", .{ user, database });
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
    connection.rows = 0;
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
            'C' => connection.rows = tag_rows(reply.body),
            'Z' => return if (failed) error.ServerError else value,
            else => {}, // Row description, notices.
        }
    }
}

/// A command tag's count, its last word: "UPDATE 2", "INSERT 0 1", "SELECT 3".
fn tag_rows(body: []const u8) u64 {
    const tag = std.mem.sliceTo(body, 0);
    const space = std.mem.lastIndexOfScalar(u8, tag, ' ') orelse return 0;
    return std.fmt.parseInt(u64, tag[space + 1 ..], 10) catch 0;
}

test tag_rows {
    try std.testing.expectEqual(2, tag_rows("UPDATE 2\x00"));
    try std.testing.expectEqual(1, tag_rows("INSERT 0 1\x00"));
    try std.testing.expectEqual(0, tag_rows("BEGIN\x00"));
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
    // Fields: a type byte and a NUL-terminated string each; 'M' is the message, 'C' the SQLSTATE.
    var fields = std.mem.splitScalar(u8, body, 0);
    while (fields.next()) |field| {
        if (field.len < 1) continue;
        if (field[0] == 'C' and field.len == 6) @memcpy(&connection.error_code, field[1..6]);
        if (field[0] != 'M') continue;
        const size = @min(field.len - 1, connection.error_message.len);
        @memcpy(connection.error_message[0..size], field[1..][0..size]);
        connection.error_message_size = @intCast(size);
    }
    return error.ServerError;
}

const Message = struct { kind: u8, body: []const u8 };

fn message_read(connection: *Connection) !Message {
    // The header is copied out: the body's read may move the buffered bytes.
    const header = try connection.socket.read_exact(5);
    const kind = header[0];
    const size = std.mem.readInt(u32, header[1..5], .big);
    if (size < 4 or size > tcp.buffer_size - 1) return error.ReplyTooLarge;
    return .{ .kind = kind, .body = try connection.socket.read_exact(size - 4) };
}

fn write_all(connection: *Connection, bytes: []const u8) !void {
    try connection.socket.write_all(bytes);
}

/// Whether `err` means the server could not be reached (as opposed to an SQL or protocol error).
pub const is_unavailable = tcp.unavailable;

test first_cell {
    var cell: [8]u8 = undefined;
    const row = [_]u8{ 0, 1, 0, 0, 0, 3, '4', '2', '0' };
    try std.testing.expectEqualStrings("420", (try first_cell(&row, &cell)).?);
    const null_row = [_]u8{ 0, 1, 0xff, 0xff, 0xff, 0xff };
    try std.testing.expect(try first_cell(&null_row, &cell) == null);
}
