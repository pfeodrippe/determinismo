// SPDX-License-Identifier: MIT
//! Bencode, nREPL's wire format: integers (`i42e`), byte strings (`5:hello`), lists (`l...e`)
//! and dictionaries (`d...e`, keys sorted). Requests are flat dictionaries of strings; replies
//! are read into a small tree.
const std = @import("std");
const assert = std.debug.assert;
const tcp = @import("determinismo").tcp;

pub const Value = union(enum) {
    integer: i64,
    bytes: []const u8,
    list: []const Value,
    dictionary: []const Entry,

    pub const Entry = struct { key: []const u8, value: Value };

    pub fn get(value: Value, key: []const u8) ?Value {
        if (value != .dictionary) return null;
        for (value.dictionary) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }

    pub fn string(value: Value, key: []const u8) ?[]const u8 {
        const found = value.get(key) orelse return null;
        return if (found == .bytes) found.bytes else null;
    }

    /// Whether `status` (a list of strings) holds `wanted` ("done", "interrupted", ...).
    pub fn status_has(value: Value, wanted: []const u8) bool {
        const status = value.get("status") orelse return false;
        if (status != .list) return false;
        for (status.list) |item| {
            if (item == .bytes and std.mem.eql(u8, item.bytes, wanted)) return true;
        }
        return false;
    }
};

/// A field value written as a bencode integer (`i10e`), not a string: some operations take
/// numbers (the inspector's rows, columns and indexes).
pub fn integer(comptime value: comptime_int) []const u8 {
    return integer_mark ++ std.fmt.comptimePrint("{d}", .{value});
}
const integer_mark = "\x00";

/// A request: string keys and values (or `integer`s), written in sorted key order as bencode
/// requires.
pub fn request_write(writer: *std.Io.Writer, fields: []const [2][]const u8) !void {
    var sorted: [16][2][]const u8 = undefined;
    assert(fields.len <= sorted.len);
    @memcpy(sorted[0..fields.len], fields);
    const order = struct {
        fn before(_: void, a: [2][]const u8, b: [2][]const u8) bool {
            return std.mem.lessThan(u8, a[0], b[0]);
        }
    };
    std.mem.sort([2][]const u8, sorted[0..fields.len], {}, order.before);
    try writer.writeByte('d');
    for (sorted[0..fields.len]) |field| {
        try writer.print("{d}:{s}", .{ field[0].len, field[0] });
        if (std.mem.startsWith(u8, field[1], integer_mark)) {
            try writer.print("i{s}e", .{field[1][integer_mark.len..]});
        } else {
            try writer.print("{d}:{s}", .{ field[1].len, field[1] });
        }
    }
    try writer.writeByte('e');
}

/// Reads one value from the connection; strings are copied into `arena`.
pub fn read(arena: std.mem.Allocator, connection: *tcp.Connection) !Value {
    const first = (try connection.read_exact(1))[0];
    switch (first) {
        'i' => return .{ .integer = try integer_until(connection, 'e') },
        'l' => {
            var items: std.ArrayList(Value) = .empty;
            while (true) {
                const next = try peek(connection);
                if (next == 'e') {
                    _ = try connection.read_exact(1);
                    return .{ .list = items.items };
                }
                try items.append(arena, try read(arena, connection));
            }
        },
        'd' => {
            var entries: std.ArrayList(Value.Entry) = .empty;
            while (true) {
                const next = try peek(connection);
                if (next == 'e') {
                    _ = try connection.read_exact(1);
                    return .{ .dictionary = entries.items };
                }
                const key = try read(arena, connection);
                if (key != .bytes) return error.BadBencode;
                const value = try read(arena, connection);
                try entries.append(arena, .{ .key = key.bytes, .value = value });
            }
        },
        '0'...'9' => {
            // The length's digits up to ':', then that many bytes.
            var size: u32 = first - '0';
            while (true) {
                const byte = (try connection.read_exact(1))[0];
                if (byte == ':') break;
                if (byte < '0' or byte > '9' or size > tcp.buffer_size) return error.BadBencode;
                size = size * 10 + (byte - '0');
            }
            return .{ .bytes = try arena.dupe(u8, try connection.read_exact(size)) };
        },
        else => return error.BadBencode,
    }
}

fn peek(connection: *tcp.Connection) !u8 {
    return connection.peek();
}

fn integer_until(connection: *tcp.Connection, end: u8) !i64 {
    var value: i64 = 0;
    var negative = false;
    var count: u32 = 0;
    while (true) : (count += 1) {
        if (count > 20) return error.BadBencode;
        const byte = (try connection.read_exact(1))[0];
        if (byte == end) return if (negative) -value else value;
        if (byte == '-' and count == 0) {
            negative = true;
            continue;
        }
        if (byte < '0' or byte > '9') return error.BadBencode;
        value = value * 10 + (byte - '0');
    }
}

test request_write {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try request_write(&writer, &.{ .{ "op", "eval" }, .{ "code", "(+ 1 2)" }, .{ "id", "7" } });
    try std.testing.expectEqualStrings("d4:code7:(+ 1 2)2:id1:72:op4:evale", writer.buffered());
    writer = .fixed(&buffer);
    try request_write(&writer, &.{ .{ "op", "inspect-in" }, .{ "idx", integer(0) } });
    try std.testing.expectEqualStrings("d3:idxi0e2:op10:inspect-ine", writer.buffered());
}
