// SPDX-License-Identifier: MIT
//! A minimal CQL client: the native protocol, version 4 (Cassandra 2.2 and later, ScyllaDB),
//! over the SDK's TCP connection, no authentication, no compression, one request at a time.
//! Queries go as text (QUERY) at a consistency and, for lightweight transactions, a serial
//! consistency. A reply is rows of raw cells, or an error with its code and the fields that
//! tell an outcome apart. No retries: what the server answered is what the caller sees.
//!
//! A reply borrows the connection's buffer until the next request. After a request that got no
//! reply (a timeout), close the connection: its reply may still come.
const std = @import("std");
const assert = std.debug.assert;
const tcp = @import("determinismo").tcp;

const version_request = 0x04;
const version_response = 0x84;
const header_size = 9;
const request_size_max = 8192;

const opcode_error = 0x00;
const opcode_startup = 0x01;
const opcode_ready = 0x02;
const opcode_query = 0x07;
const opcode_result = 0x08;

const result_void = 0x0001;
const result_rows = 0x0002;
const result_keyspace = 0x0003;
const result_schema_change = 0x0005;

const query_flag_serial = 0x10;
const query_flag_timestamp = 0x20;

const rows_flag_global_tables = 0x0001;
const rows_flag_more_pages = 0x0002;
const rows_flag_no_metadata = 0x0004;

pub const columns_max = 8;
pub const rows_max = 16;

pub const Consistency = enum(u16) {
    any = 0x0000,
    one = 0x0001,
    two = 0x0002,
    three = 0x0003,
    quorum = 0x0004,
    all = 0x0005,
    local_quorum = 0x0006,
    each_quorum = 0x0007,
    serial = 0x0008,
    local_serial = 0x0009,
    local_one = 0x000a,
};

/// Error codes (the protocol's section 9).
pub const code = struct {
    pub const server = 0x0000;
    pub const protocol = 0x000a;
    pub const unavailable = 0x1000;
    pub const overloaded = 0x1001;
    pub const bootstrapping = 0x1002;
    pub const write_timeout = 0x1100;
    pub const read_timeout = 0x1200;
    pub const read_failure = 0x1300;
    pub const write_failure = 0x1500;
    pub const syntax = 0x2000;
    pub const invalid = 0x2200;
    pub const already_exists = 0x2400;
};

pub const Failure = struct {
    code: u32,
    message: []const u8,
    /// A write timeout's kind of write (SIMPLE, BATCH, CAS, ...); empty for other errors.
    write_type: []const u8 = "",
};

pub const Rows = struct {
    names: [columns_max][]const u8 = undefined,
    columns: u32 = 0,
    cells: [rows_max][columns_max]?[]const u8 = undefined,
    count: u32 = 0,

    pub fn column(rows: *const Rows, name: []const u8) ?u32 {
        for (rows.names[0..rows.columns], 0..) |each, index| {
            if (std.mem.eql(u8, each, name)) return @intCast(index);
        }
        return null;
    }
};

pub const Reply = union(enum) {
    done,
    rows: Rows,
    failure: Failure,
};

pub const Options = struct {
    consistency: Consistency = .one,
    /// A lightweight transaction's consistency for its Paxos rounds.
    serial: ?Consistency = null,
    /// The write's timestamp (microseconds), else the coordinator's clock.
    timestamp_us: ?i64 = null,
};

socket: tcp.Connection,
stream: i16 = 0,

const Connection = @This();

/// Connects and starts the session (STARTUP, CQL 3.0.0).
pub fn open(connection: *Connection, address: [4]u8, port: u16, options: tcp.Options) !void {
    connection.stream = 0;
    try connection.socket.open(address, port, options);
    errdefer connection.socket.close();
    var body: [64]u8 = undefined;
    var writer: Writer = .{ .buffer = &body };
    writer.short(1);
    writer.string("CQL_VERSION");
    writer.string("3.0.0");
    const frame = try connection.request(opcode_startup, writer.written());
    if (frame.opcode != opcode_ready) return error.NotReady;
}

pub fn close(connection: *Connection) void {
    connection.socket.close();
}

pub fn query(connection: *Connection, text: []const u8, options: Options) !Reply {
    var body: [request_size_max]u8 = undefined;
    if (text.len + 32 > body.len) return error.QueryTooLong;
    var writer: Writer = .{ .buffer = &body };
    writer.int(@intCast(text.len));
    writer.bytes(text);
    writer.short(@backingInt(options.consistency));
    var flags: u8 = 0;
    if (options.serial != null) flags |= query_flag_serial;
    if (options.timestamp_us != null) flags |= query_flag_timestamp;
    writer.byte(flags);
    if (options.serial) |serial| writer.short(@backingInt(serial));
    if (options.timestamp_us) |timestamp| writer.long(timestamp);
    const frame = try connection.request(opcode_query, writer.written());
    return reply_parse(frame);
}

const Frame = struct { opcode: u8, body: []const u8 };

fn request(connection: *Connection, opcode: u8, body: []const u8) !Frame {
    connection.stream = if (connection.stream == std.math.maxInt(i16)) 1 else connection.stream + 1;
    var header: [header_size]u8 = undefined;
    header[0] = version_request;
    header[1] = 0; // Flags: no compression, no tracing.
    std.mem.writeInt(i16, header[2..4], connection.stream, .big);
    header[4] = opcode;
    std.mem.writeInt(u32, header[5..9], @intCast(body.len), .big);
    try connection.socket.write_all(&header);
    try connection.socket.write_all(body);
    // Frames for other streams (events, -1) are skipped.
    while (true) {
        // The header is copied out: the body's read may move the buffered bytes.
        const reply_header = (try connection.socket.read_exact(header_size))[0..header_size].*;
        if (reply_header[0] != version_response) return error.BadReply;
        const size = std.mem.readInt(u32, reply_header[5..9], .big);
        if (size > tcp.buffer_size - header_size) return error.ReplyTooLarge;
        const reply_body = try connection.socket.read_exact(size);
        if (std.mem.readInt(i16, reply_header[2..4], .big) != connection.stream) continue;
        return .{ .opcode = reply_header[4], .body = reply_body };
    }
}

fn reply_parse(frame: Frame) !Reply {
    var reader: Reader = .{ .bytes = frame.body };
    switch (frame.opcode) {
        opcode_error => {
            var failure: Failure = .{ .code = try reader.int(), .message = try reader.string() };
            if (failure.code == code.write_timeout) {
                _ = try reader.short(); // Consistency.
                _ = try reader.int(); // Received.
                _ = try reader.int(); // Block for.
                failure.write_type = try reader.string();
            }
            return .{ .failure = failure };
        },
        opcode_result => {},
        else => return error.BadReply,
    }
    switch (try reader.int()) {
        result_void, result_keyspace, result_schema_change => return .done,
        result_rows => {},
        else => return error.BadReply,
    }
    var rows: Rows = .{};
    const flags = try reader.int();
    rows.columns = try reader.int();
    if (rows.columns > columns_max) return error.ReplyTooLarge;
    if (flags & rows_flag_more_pages != 0) _ = try reader.bytes_or_null();
    if (flags & rows_flag_no_metadata != 0) return error.BadReply; // Never asked for.
    const global = flags & rows_flag_global_tables != 0;
    if (global) {
        _ = try reader.string(); // Keyspace.
        _ = try reader.string(); // Table.
    }
    for (rows.names[0..rows.columns]) |*name| {
        if (!global) {
            _ = try reader.string();
            _ = try reader.string();
        }
        name.* = try reader.string();
        try reader.option_skip(0);
    }
    rows.count = try reader.int();
    if (rows.count > rows_max) return error.ReplyTooLarge;
    for (rows.cells[0..rows.count]) |*row| {
        for (row[0..rows.columns]) |*cell| cell.* = try reader.bytes_or_null();
    }
    return .{ .rows = rows };
}

/// A boolean cell's value (null for a null cell).
pub fn boolean(cell: ?[]const u8) ?bool {
    const bytes = cell orelse return null;
    if (bytes.len != 1) return null;
    return bytes[0] != 0;
}

/// A list<int> cell's values into `out` (a null cell is an empty list).
pub fn int_list(cell: ?[]const u8, out: []i32) ![]i32 {
    const bytes = cell orelse return out[0..0];
    var reader: Reader = .{ .bytes = bytes };
    const count = try reader.int();
    if (count > out.len) return error.ListTooLong;
    for (out[0..count]) |*value| {
        const element = (try reader.bytes_or_null()) orelse return error.BadReply;
        if (element.len != 4) return error.BadReply;
        value.* = std.mem.readInt(i32, element[0..4], .big);
    }
    return out[0..count];
}

const Writer = struct {
    buffer: []u8,
    size: usize = 0,

    fn written(writer: *const Writer) []const u8 {
        return writer.buffer[0..writer.size];
    }

    fn byte(writer: *Writer, value: u8) void {
        writer.buffer[writer.size] = value;
        writer.size += 1;
    }

    fn short(writer: *Writer, value: u16) void {
        std.mem.writeInt(u16, writer.buffer[writer.size..][0..2], value, .big);
        writer.size += 2;
    }

    fn int(writer: *Writer, value: u32) void {
        std.mem.writeInt(u32, writer.buffer[writer.size..][0..4], value, .big);
        writer.size += 4;
    }

    fn long(writer: *Writer, value: i64) void {
        std.mem.writeInt(i64, writer.buffer[writer.size..][0..8], value, .big);
        writer.size += 8;
    }

    fn bytes(writer: *Writer, value: []const u8) void {
        @memcpy(writer.buffer[writer.size..][0..value.len], value);
        writer.size += value.len;
    }

    fn string(writer: *Writer, value: []const u8) void {
        writer.short(@intCast(value.len));
        writer.bytes(value);
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn take(reader: *Reader, size: usize) ![]const u8 {
        if (reader.bytes.len - reader.position < size) return error.BadReply;
        defer reader.position += size;
        return reader.bytes[reader.position..][0..size];
    }

    fn short(reader: *Reader) !u16 {
        return std.mem.readInt(u16, (try reader.take(2))[0..2], .big);
    }

    fn int(reader: *Reader) !u32 {
        return std.mem.readInt(u32, (try reader.take(4))[0..4], .big);
    }

    fn string(reader: *Reader) ![]const u8 {
        return reader.take(try reader.short());
    }

    /// [bytes]: an int length, then that many bytes; a negative length is null.
    fn bytes_or_null(reader: *Reader) !?[]const u8 {
        const size: i32 = @bitCast(try reader.int());
        if (size < 0) return null;
        return try reader.take(@intCast(size));
    }

    /// Skips an [option]: a type id and, for custom and composite types, what describes it.
    fn option_skip(reader: *Reader, depth: u32) !void {
        if (depth > 8) return error.BadReply;
        switch (try reader.short()) {
            0x0000 => _ = try reader.string(), // Custom: its class.
            0x0020, 0x0022 => try reader.option_skip(depth + 1), // List, set.
            0x0021 => { // Map.
                try reader.option_skip(depth + 1);
                try reader.option_skip(depth + 1);
            },
            0x0030 => { // User type.
                _ = try reader.string();
                _ = try reader.string();
                for (0..try reader.short()) |_| {
                    _ = try reader.string();
                    try reader.option_skip(depth + 1);
                }
            },
            0x0031 => for (0..try reader.short()) |_| try reader.option_skip(depth + 1), // Tuple.
            else => {},
        }
    }
};

test "rows: an LWT's [applied] and a list<int>" {
    var body: [256]u8 = undefined;
    var writer: Writer = .{ .buffer = &body };
    writer.int(result_rows);
    writer.int(rows_flag_global_tables);
    writer.int(2);
    writer.string("jepsen_keyspace");
    writer.string("lists");
    writer.string("[applied]");
    writer.short(0x0004); // Boolean.
    writer.string("value");
    writer.short(0x0020); // List of int.
    writer.short(0x0009);
    writer.int(1);
    writer.int(1);
    writer.byte(1);
    writer.int(4 + 2 * 8);
    writer.int(2);
    for ([_]i32{ 7, -3 }) |value| {
        writer.int(4);
        writer.int(@bitCast(value));
    }
    const reply = try reply_parse(.{ .opcode = opcode_result, .body = writer.written() });
    const rows = reply.rows;
    try std.testing.expectEqual(1, rows.count);
    try std.testing.expectEqual(true, boolean(rows.cells[0][rows.column("[applied]").?]));
    var values: [4]i32 = undefined;
    try std.testing.expectEqualSlices(i32, &.{ 7, -3 }, try int_list(rows.cells[0][rows.column("value").?], &values));
    try std.testing.expectEqual(null, rows.column("missing"));
}

test "a write timeout's kind of write" {
    var body: [128]u8 = undefined;
    var writer: Writer = .{ .buffer = &body };
    writer.int(code.write_timeout);
    writer.string("Operation timed out");
    writer.short(@backingInt(Consistency.serial));
    writer.int(1);
    writer.int(2);
    writer.string("CAS");
    const reply = try reply_parse(.{ .opcode = opcode_error, .body = writer.written() });
    try std.testing.expectEqual(code.write_timeout, reply.failure.code);
    try std.testing.expectEqualStrings("CAS", reply.failure.write_type);
}

test "a null list is empty; a truncated reply is refused" {
    var values: [2]i32 = undefined;
    try std.testing.expectEqual(0, (try int_list(null, &values)).len);
    try std.testing.expectError(error.BadReply, reply_parse(.{ .opcode = opcode_result, .body = &.{ 0, 0 } }));
}
