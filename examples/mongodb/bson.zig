// SPDX-License-Identifier: MIT
//! A minimal BSON encoder and reader: what MongoDB's commands and their replies need. The encoder
//! writes into a caller's buffer (nested documents patched with their sizes as they close); the
//! reader walks a document's elements without copying.
const std = @import("std");
const assert = std.debug.assert;

pub const Kind = enum(u8) {
    double = 0x01,
    string = 0x02,
    document = 0x03,
    array = 0x04,
    binary = 0x05,
    object_id = 0x07,
    boolean = 0x08,
    datetime = 0x09,
    null = 0x0a,
    int32 = 0x10,
    timestamp = 0x11,
    int64 = 0x12,
    decimal128 = 0x13,
    _,
};

pub const binary_uuid = 4;
const depth_max = 8;

pub const Builder = struct {
    buffer: []u8,
    end: u32 = 0,
    /// Where each open document starts (its size, patched when it closes).
    starts: [depth_max]u32 = undefined,
    depth: u32 = 0,
    /// Set when the buffer ran out: `finish` reports it.
    overflow: bool = false,

    pub fn init(buffer: []u8) Builder {
        var builder: Builder = .{ .buffer = buffer };
        builder.open();
        return builder;
    }

    pub fn string(builder: *Builder, name: []const u8, value: []const u8) void {
        builder.head(.string, name);
        builder.int(i32, @intCast(value.len + 1));
        builder.bytes(value);
        builder.bytes(&.{0});
    }

    pub fn int32(builder: *Builder, name: []const u8, value: i32) void {
        builder.head(.int32, name);
        builder.int(i32, value);
    }

    pub fn int64(builder: *Builder, name: []const u8, value: i64) void {
        builder.head(.int64, name);
        builder.int(i64, value);
    }

    pub fn double(builder: *Builder, name: []const u8, value: f64) void {
        builder.head(.double, name);
        builder.int(u64, @bitCast(value));
    }

    pub fn boolean(builder: *Builder, name: []const u8, value: bool) void {
        builder.head(.boolean, name);
        builder.bytes(&.{@intFromBool(value)});
    }

    pub fn binary(builder: *Builder, name: []const u8, subtype: u8, value: []const u8) void {
        builder.head(.binary, name);
        builder.int(i32, @intCast(value.len));
        builder.bytes(&.{subtype});
        builder.bytes(value);
    }

    /// An embedded document as it was read (a reply's element, sent back as is).
    pub fn embedded(builder: *Builder, name: []const u8, value: []const u8) void {
        assert(value.len >= 5);
        builder.head(.document, name);
        builder.bytes(value);
    }

    /// Opens an embedded document; `close` ends it.
    pub fn document(builder: *Builder, name: []const u8) void {
        builder.head(.document, name);
        builder.open();
    }

    /// Opens an array: its elements are named "0", "1", ... (`index`); `close` ends it.
    pub fn array(builder: *Builder, name: []const u8) void {
        builder.head(.array, name);
        builder.open();
    }

    pub fn close(builder: *Builder) void {
        assert(builder.depth > 1); // The root closes with `finish`.
        builder.seal();
    }

    /// The document, or error.DocumentTooLarge when the buffer ran out.
    pub fn finish(builder: *Builder) ![]const u8 {
        assert(builder.depth == 1);
        builder.seal();
        if (builder.overflow) return error.DocumentTooLarge;
        return builder.buffer[0..builder.end];
    }

    fn open(builder: *Builder) void {
        assert(builder.depth < depth_max);
        builder.starts[builder.depth] = builder.end;
        builder.depth += 1;
        builder.int(i32, 0); // The size, patched by `seal`.
    }

    fn seal(builder: *Builder) void {
        builder.bytes(&.{0});
        builder.depth -= 1;
        const start = builder.starts[builder.depth];
        if (builder.overflow) return;
        const size: i32 = @intCast(builder.end - start);
        std.mem.writeInt(i32, builder.buffer[start..][0..4], size, .little);
    }

    fn head(builder: *Builder, kind: Kind, name: []const u8) void {
        assert(std.mem.indexOfScalar(u8, name, 0) == null);
        builder.bytes(&.{@backingInt(kind)});
        builder.bytes(name);
        builder.bytes(&.{0});
    }

    fn int(builder: *Builder, comptime T: type, value: T) void {
        var raw: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &raw, value, .little);
        builder.bytes(&raw);
    }

    fn bytes(builder: *Builder, value: []const u8) void {
        if (builder.overflow or builder.end + value.len > builder.buffer.len) {
            builder.overflow = true;
            return;
        }
        @memcpy(builder.buffer[builder.end..][0..value.len], value);
        builder.end += @intCast(value.len);
    }
};

/// An array element's name: its index.
pub fn index(buffer: *[10]u8, position: usize) []const u8 {
    return std.fmt.bufPrint(buffer, "{d}", .{position}) catch unreachable;
}

pub const Element = struct {
    kind: Kind,
    name: []const u8,
    /// The value's bytes, as encoded.
    value: []const u8,

    /// A number of any of BSON's numeric kinds, as an integer.
    pub fn integer(element: Element) ?i64 {
        return switch (element.kind) {
            .int32 => std.mem.readInt(i32, element.value[0..4], .little),
            .int64 => std.mem.readInt(i64, element.value[0..8], .little),
            .double => @intFromFloat(@as(f64, @bitCast(std.mem.readInt(u64, element.value[0..8], .little)))),
            else => null,
        };
    }

    pub fn text(element: Element) ?[]const u8 {
        if (element.kind != .string) return null;
        return element.value[4 .. element.value.len - 1];
    }

    pub fn truth(element: Element) ?bool {
        if (element.kind != .boolean) return null;
        return element.value[0] != 0;
    }

    /// An embedded document or array, to read with `Iterator`.
    pub fn nested(element: Element) ?[]const u8 {
        return switch (element.kind) {
            .document, .array => element.value,
            else => null,
        };
    }
};

pub const Iterator = struct {
    document: []const u8,
    at: usize = 4,

    pub fn init(document: []const u8) !Iterator {
        if (document.len < 5) return error.BadDocument;
        const size = std.mem.readInt(i32, document[0..4], .little);
        if (size < 5 or size > document.len or document[@intCast(size - 1)] != 0) return error.BadDocument;
        return .{ .document = document[0..@intCast(size)] };
    }

    pub fn next(iterator: *Iterator) !?Element {
        const document = iterator.document;
        if (iterator.at >= document.len - 1) return null;
        const kind: Kind = @fromBackingInt(@intCast(document[iterator.at]));
        const name_start = iterator.at + 1;
        const name_end = std.mem.indexOfScalarPos(u8, document, name_start, 0) orelse return error.BadDocument;
        const value_start = name_end + 1;
        const size = try value_size(kind, document[value_start..]);
        if (value_start + size > document.len - 1) return error.BadDocument;
        iterator.at = value_start + size;
        return .{ .kind = kind, .name = document[name_start..name_end], .value = document[value_start..][0..size] };
    }
};

/// The element named `name` at the document's top level.
pub fn get(document: []const u8, name: []const u8) !?Element {
    var iterator = try Iterator.init(document);
    while (try iterator.next()) |element| {
        if (std.mem.eql(u8, element.name, name)) return element;
    }
    return null;
}

fn value_size(kind: Kind, rest: []const u8) !usize {
    const fixed: ?usize = switch (kind) {
        .double, .datetime, .timestamp, .int64 => 8,
        .int32 => 4,
        .boolean => 1,
        .null => 0,
        .object_id => 12,
        .decimal128 => 16,
        else => null,
    };
    if (fixed) |size| return size;
    if (rest.len < 4) return error.BadDocument;
    const length: usize = @intCast(@max(0, std.mem.readInt(i32, rest[0..4], .little)));
    return switch (kind) {
        .string => 4 + length,
        .document, .array => length,
        .binary => 4 + 1 + length,
        else => error.UnsupportedKind,
    };
}

test Builder {
    var buffer: [256]u8 = undefined;
    var builder: Builder = .init(&buffer);
    builder.string("find", "jepsencoll");
    builder.document("filter");
    builder.int64("_id", 7);
    builder.close();
    builder.array("labels");
    var name: [10]u8 = undefined;
    builder.string(index(&name, 0), "a");
    builder.close();
    builder.boolean("singleBatch", true);
    const document = try builder.finish();
    try std.testing.expectEqualStrings("jepsencoll", (try get(document, "find")).?.text().?);
    const filter = (try get(document, "filter")).?.nested().?;
    try std.testing.expectEqual(7, (try get(filter, "_id")).?.integer().?);
    var labels = try Iterator.init((try get(document, "labels")).?.nested().?);
    try std.testing.expectEqualStrings("a", (try labels.next()).?.text().?);
    try std.testing.expect(try labels.next() == null);
    try std.testing.expect((try get(document, "singleBatch")).?.truth().?);
    try std.testing.expect(try get(document, "missing") == null);
}

test "Builder: a full buffer is an error" {
    var buffer: [16]u8 = undefined;
    var builder: Builder = .init(&buffer);
    builder.string("find", "a collection name longer than the buffer");
    try std.testing.expectError(error.DocumentTooLarge, builder.finish());
}
