// SPDX-License-Identifier: MIT
//! A minimal MongoDB client: commands as OP_MSG (MongoDB 3.6 and later) over the SDK's TCP
//! connection, no authentication. A command is a BSON document naming its database in `$db`; its
//! reply is the body document, with `ok` and, on errors, `code`, `errmsg` and `errorLabels`.
const std = @import("std");
const assert = std.debug.assert;
const tcp = @import("determinismo").tcp;
pub const bson = @import("bson.zig");

const op_msg = 2013;
const header_size = 16;

socket: tcp.Connection,
request_id: i32 = 0,

const Connection = @This();

pub fn open(connection: *Connection, address: [4]u8, port: u16, options: tcp.Options) !void {
    connection.request_id = 0;
    try connection.socket.open(address, port, options);
}

pub fn close(connection: *Connection) void {
    connection.socket.close();
}

/// Runs a command; returns the reply's body (valid until the next command).
pub fn command(connection: *Connection, document: []const u8) ![]const u8 {
    connection.request_id +%= 1;
    var header: [header_size + 4 + 1]u8 = undefined;
    const size: i32 = @intCast(header.len + document.len);
    std.mem.writeInt(i32, header[0..4], size, .little);
    std.mem.writeInt(i32, header[4..8], connection.request_id, .little);
    std.mem.writeInt(i32, header[8..12], 0, .little); // Not a reply.
    std.mem.writeInt(i32, header[12..16], op_msg, .little);
    std.mem.writeInt(u32, header[16..20], 0, .little); // Flags.
    header[20] = 0; // A body section: one document.
    try connection.socket.write_all(&header);
    try connection.socket.write_all(document);
    return connection.reply_read();
}

fn reply_read(connection: *Connection) ![]const u8 {
    // The header is copied out: the rest's read may move the buffered bytes.
    const header = (try connection.socket.read_exact(header_size))[0..header_size].*;
    const size = std.mem.readInt(i32, header[0..4], .little);
    const operation = std.mem.readInt(i32, header[12..16], .little);
    if (size < header_size + 5 or size - header_size > tcp.buffer_size) return error.ReplyTooLarge;
    const rest = try connection.socket.read_exact(@intCast(size - header_size));
    if (operation != op_msg) return error.BadReply;
    const flags = std.mem.readInt(u32, rest[0..4], .little);
    const checksum: usize = if (flags & 1 != 0) 4 else 0;
    if (rest[4] != 0) return error.BadReply; // The body section comes first.
    const body = rest[5 .. rest.len - checksum];
    _ = try bson.Iterator.init(body);
    return body;
}

/// Whether a reply says the command succeeded (`ok: 1`).
pub fn ok(reply: []const u8) bool {
    const element = (bson.get(reply, "ok") catch return false) orelse return false;
    return (element.integer() orelse 0) == 1;
}

/// A failed command's error code (0 for none).
pub fn code(reply: []const u8) i64 {
    const element = (bson.get(reply, "code") catch return 0) orelse return 0;
    return element.integer() orelse 0;
}

pub fn message(reply: []const u8) []const u8 {
    const element = (bson.get(reply, "errmsg") catch return "") orelse return "";
    return element.text() orelse "";
}

/// Whether a reply carries an error label ("TransientTransactionError",
/// "UnknownTransactionCommitResult").
pub fn labeled(reply: []const u8, label: []const u8) bool {
    const element = (bson.get(reply, "errorLabels") catch return false) orelse return false;
    var labels = bson.Iterator.init(element.nested() orelse return false) catch return false;
    while (labels.next() catch return false) |entry| {
        if (std.mem.eql(u8, entry.text() orelse continue, label)) return true;
    }
    return false;
}

/// A write's first error code: `writeErrors` (the write failed) or `writeConcernError` (it may
/// have happened, not as durably as asked); 0 for none.
pub fn write_error(reply: []const u8) struct { code: i64, concern: bool } {
    if (bson.get(reply, "writeConcernError") catch null) |element| {
        const concern = element.nested() orelse return .{ .code = -1, .concern = true };
        return .{ .code = code(concern), .concern = true };
    }
    const errors = (bson.get(reply, "writeErrors") catch null) orelse return .{ .code = 0, .concern = false };
    var entries = bson.Iterator.init(errors.nested() orelse return .{ .code = -1, .concern = false }) catch
        return .{ .code = -1, .concern = false };
    const first = (entries.next() catch null) orelse return .{ .code = -1, .concern = false };
    return .{ .code = code(first.nested() orelse return .{ .code = -1, .concern = false }), .concern = false };
}

/// Whether `err` means the server could not be reached (as opposed to a protocol error).
pub const is_unavailable = tcp.unavailable;

test "ok, code, labels" {
    var buffer: [256]u8 = undefined;
    var builder: bson.Builder = .init(&buffer);
    builder.double("ok", 0);
    builder.string("errmsg", "Transaction 1 has been aborted.");
    builder.int32("code", 251);
    builder.array("errorLabels");
    var name: [10]u8 = undefined;
    builder.string(bson.index(&name, 0), "TransientTransactionError");
    builder.close();
    const reply = try builder.finish();
    try std.testing.expect(!ok(reply));
    try std.testing.expectEqual(251, code(reply));
    try std.testing.expect(labeled(reply, "TransientTransactionError"));
    try std.testing.expect(!labeled(reply, "UnknownTransactionCommitResult"));
    try std.testing.expectEqualStrings("Transaction 1 has been aborted.", message(reply));
}
