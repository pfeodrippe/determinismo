// SPDX-License-Identifier: MIT
//! A minimal MySQL client (protocol 4.1, text queries, a user without a password) over the SDK's
//! TCP connection (sdk/zig/tcp.zig), with pg.zig's interface: MySQL, MariaDB (and Galera),
//! Percona, TiDB.
const std = @import("std");
const assert = std.debug.assert;
const tcp = @import("determinismo").tcp;

const query_size_max = 4096;
const packet_size_max = 1 << 24;
const timeout_ms = 2000;

// Capabilities (protocol 4.1): affected rows count the rows matched (an UPDATE that rewrites a
// row with its own value still counts it).
const client_long_password: u32 = 1 << 0;
const client_found_rows: u32 = 1 << 1;
const client_connect_with_db: u32 = 1 << 3;
const client_protocol_41: u32 = 1 << 9;
const client_transactions: u32 = 1 << 13;
const client_secure_connection: u32 = 1 << 15;
const client_plugin_auth: u32 = 1 << 19;
const charset_utf8mb4 = 45;

socket: tcp.Connection,
/// The server's message for the last error.ServerError.
error_message: [256]u8 = undefined,
error_message_size: u32 = 0,
/// Its SQLSTATE ("40001": a deadlock or, in Galera, a certification failure: the transaction
/// did not happen).
error_code: [5]u8 = @splat('0'),
/// Its MySQL error number (1213: a deadlock, 1062: a duplicate key).
error_number: u16 = 0,
/// The rows the last statement affected (matched, for an UPDATE).
rows: u64 = 0,
/// The next packet's sequence number.
sequence: u8 = 0,

const Connection = @This();

pub fn open(connection: *Connection, address: [4]u8, port: u16, user: []const u8) !void {
    return connection.open_with(address, port, user, null, .{ .timeout_ms = timeout_ms });
}

/// `open` with a database (null: none) and connection options.
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
    connection.error_number = 0;
    connection.sequence = 0;
    try connection.socket.open(address, port, options);
    errdefer connection.socket.close();
    try connection.handshake(user, database);
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

/// Runs a statement, ignoring any rows.
pub fn exec(connection: *Connection, sql: []const u8) !void {
    _ = try connection.query(sql, null);
}

/// Runs a statement and returns the rows it affected (matched, for an UPDATE).
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

/// Whether `err` means the server could not be reached (as opposed to an SQL or protocol error).
pub const is_unavailable = tcp.unavailable;

fn handshake(connection: *Connection, user: []const u8, database: ?[]const u8) !void {
    const greeting = try connection.packet_read();
    if (greeting.len > 0 and greeting[0] == 0xff) return connection.server_error(greeting);
    const plugin = try greeting_plugin(greeting);
    var message: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&message);
    var capabilities = client_long_password | client_found_rows | client_protocol_41 |
        client_transactions | client_secure_connection | client_plugin_auth;
    if (database != null) capabilities |= client_connect_with_db;
    try writer.writeInt(u32, capabilities, .little);
    try writer.writeInt(u32, packet_size_max, .little);
    try writer.writeByte(charset_utf8mb4);
    try writer.splatByteAll(0, 23);
    try writer.print("{s}\x00", .{user});
    try writer.writeByte(0); // No password: an empty authentication response.
    if (database) |name| try writer.print("{s}\x00", .{name});
    try writer.print("{s}\x00", .{plugin});
    try connection.packet_write(writer.buffered());
    for (0..4) |_| {
        const reply = try connection.packet_read();
        if (reply.len == 0) return error.BadReply;
        switch (reply[0]) {
            0x00 => return,
            0xff => return connection.server_error(reply),
            // Another authentication method: again, an empty response.
            0xfe => try connection.packet_write(""),
            // More data: 3 is a cached password's fast success (an OK follows); 4 asks for the
            // password in full.
            0x01 => if (reply.len < 2 or reply[1] != 3) return error.PasswordRequired,
            else => return error.BadReply,
        }
    }
    return error.BadReply;
}

/// The authentication method a greeting (protocol 10) names.
fn greeting_plugin(greeting: []const u8) ![]const u8 {
    if (greeting.len < 1 or greeting[0] != 10) return error.UnsupportedProtocol;
    const version_end = std.mem.indexOfScalarPos(u8, greeting, 1, 0) orelse return error.BadReply;
    // Connection id (4), salt (8), filler (1), capabilities (2), charset (1), status (2),
    // capabilities (2), salt length (1), reserved (10), salt (at least 13).
    var at = version_end + 1 + 4 + 8 + 1;
    if (greeting.len < at + 2) return "mysql_native_password";
    at += 2 + 1 + 2 + 2;
    if (greeting.len < at + 1) return "mysql_native_password";
    const salt_size = greeting[at];
    at += 1 + 10 + @max(13, salt_size -| 8);
    if (greeting.len <= at) return "mysql_native_password";
    const end = std.mem.indexOfScalarPos(u8, greeting, at, 0) orelse greeting.len;
    return greeting[at..end];
}

/// Sends one text query; copies the first cell of the first row into `cell`, if given.
fn query(connection: *Connection, sql: []const u8, cell: ?[]u8) !?[]const u8 {
    if (sql.len + 1 > query_size_max) return error.QueryTooLarge;
    var message: [query_size_max]u8 = undefined;
    message[0] = 0x03; // COM_QUERY.
    @memcpy(message[1..][0..sql.len], sql);
    connection.sequence = 0;
    connection.rows = 0;
    try connection.packet_write(message[0 .. sql.len + 1]);
    const first = try connection.packet_read();
    if (first.len == 0) return error.BadReply;
    switch (first[0]) {
        0x00 => {
            var at: usize = 1;
            connection.rows = try length_encoded(first, &at);
            return null;
        },
        0xff => return connection.server_error(first),
        0xfb => return error.Unsupported, // LOCAL INFILE.
        else => {},
    }
    var at: usize = 0;
    const columns = try length_encoded(first, &at);
    for (0..columns) |_| _ = try connection.packet_read();
    const end_of_columns = try connection.packet_read();
    if (!is_eof(end_of_columns)) return error.BadReply;
    var value: ?[]const u8 = null;
    var rows: u64 = 0;
    while (true) {
        const row = try connection.packet_read();
        if (is_eof(row)) break;
        if (row.len > 0 and row[0] == 0xff) return connection.server_error(row);
        if (rows == 0 and cell != null) value = try first_cell(row, cell.?);
        rows += 1;
    }
    connection.rows = rows;
    return value;
}

fn is_eof(packet: []const u8) bool {
    return packet.len > 0 and packet.len < 9 and packet[0] == 0xfe;
}

fn first_cell(row: []const u8, cell: []u8) !?[]const u8 {
    if (row.len == 0) return error.BadReply;
    if (row[0] == 0xfb) return null; // NULL.
    var at: usize = 0;
    const size = try length_encoded(row, &at);
    if (size > cell.len or at + size > row.len) return error.BadReply;
    const bytes = row[at..][0..@intCast(size)];
    @memcpy(cell[0..bytes.len], bytes);
    return cell[0..bytes.len];
}

fn length_encoded(packet: []const u8, at: *usize) !u64 {
    if (at.* >= packet.len) return error.BadReply;
    const first = packet[at.*];
    const size: usize = switch (first) {
        0...0xfa => {
            at.* += 1;
            return first;
        },
        0xfc => 2,
        0xfd => 3,
        0xfe => 8,
        else => return error.BadReply,
    };
    if (at.* + 1 + size > packet.len) return error.BadReply;
    var value: u64 = 0;
    for (packet[at.* + 1 ..][0..size], 0..) |byte, index| value |= @as(u64, byte) << @intCast(8 * index);
    at.* += 1 + size;
    return value;
}

fn server_error(connection: *Connection, packet: []const u8) error{ServerError} {
    // 0xff, the error number (2), then (protocol 4.1) '#' and the SQLSTATE (5), the message.
    connection.error_code = "HY000".*;
    if (packet.len >= 3) connection.error_number = std.mem.readInt(u16, packet[1..3], .little);
    var message = if (packet.len >= 3) packet[3..] else "";
    if (message.len >= 6 and message[0] == '#') {
        @memcpy(&connection.error_code, message[1..6]);
        message = message[6..];
    }
    const size = @min(message.len, connection.error_message.len);
    @memcpy(connection.error_message[0..size], message[0..size]);
    connection.error_message_size = @intCast(size);
    return error.ServerError;
}

/// A packet's payload: a 3-byte little-endian length and a sequence number before it.
fn packet_read(connection: *Connection) ![]const u8 {
    // The header is copied out: the payload's read may move the buffered bytes.
    const header = (try connection.socket.read_exact(4))[0..4].*;
    const size = std.mem.readInt(u24, header[0..3], .little);
    if (size >= tcp.buffer_size) return error.ReplyTooLarge;
    connection.sequence = header[3] +% 1;
    return connection.socket.read_exact(size);
}

fn packet_write(connection: *Connection, payload: []const u8) !void {
    assert(payload.len < packet_size_max);
    var header: [4]u8 = undefined;
    std.mem.writeInt(u24, header[0..3], @intCast(payload.len), .little);
    header[3] = connection.sequence;
    connection.sequence +%= 1;
    try connection.socket.write_all(&header);
    try connection.socket.write_all(payload);
}

test length_encoded {
    var at: usize = 0;
    try std.testing.expectEqual(5, try length_encoded(&.{5}, &at));
    try std.testing.expectEqual(1, at);
    at = 0;
    try std.testing.expectEqual(0x1234, try length_encoded(&.{ 0xfc, 0x34, 0x12 }, &at));
    try std.testing.expectEqual(3, at);
}

test first_cell {
    var cell: [8]u8 = undefined;
    try std.testing.expectEqualStrings("420", (try first_cell(&.{ 3, '4', '2', '0' }, &cell)).?);
    try std.testing.expect(try first_cell(&.{0xfb}, &cell) == null);
}

test greeting_plugin {
    // Protocol 10, "8.0.34", id, salt, filler, capabilities, charset, status, capabilities, salt
    // length 21, reserved, salt (13), the plugin.
    const greeting = "\x0a8.0.34\x00" ++ "\x01\x00\x00\x00" ++ "abcdefgh" ++ "\x00" ++ "\xff\xff" ++
        "\x2d" ++ "\x02\x00" ++ "\xff\xdf" ++ "\x15" ++ "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++ "ijklmnopqrst\x00" ++
        "caching_sha2_password\x00";
    try std.testing.expectEqualStrings("caching_sha2_password", try greeting_plugin(greeting));
}

test server_error {
    var connection: Connection = undefined;
    connection.error_message_size = 0;
    const packet = "\xff\xbd\x04#40001Deadlock found";
    try std.testing.expectEqual(error.ServerError, connection.server_error(packet));
    try std.testing.expectEqualStrings("40001", connection.sqlstate());
    try std.testing.expectEqual(1213, connection.error_number);
    try std.testing.expectEqualStrings("Deadlock found", connection.last_error());
}
