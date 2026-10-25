// SPDX-License-Identifier: MIT
//! The plugin side of docs/PLUGINS.md for strategies written in Zig: reads requests from stdin,
//! dispatches them to a handler, writes responses to stdout. Fixed buffers only.
//!
//! A handler is a struct with `pub const name`, and optionally the methods `hello`, `branch`,
//! `random`, `event` (the event and its source) and `branch_end` (see `serve`). Missing methods
//! answer the default.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

const line_size_max = 64 * 1024;
const parse_buffer_size = 256 * 1024;
pub const override_size_max = 64;
pub const failing_count_max = 64;

/// A decision: its pull number, default value, and source (the asking process's name, or "").
pub const Random = struct { pull: u64, default: []const u8, source: []const u8 };

pub const BranchEnd = struct {
    index: u32,
    outcome: []const u8,
    events: u64,
    failing: []const []const u8,
};

const Buffers = struct {
    input: [line_size_max]u8 = undefined,
    input_start: u32 = 0,
    input_end: u32 = 0,
    parse: [parse_buffer_size]u8 = undefined,
    output: [line_size_max]u8 = undefined,
};

var buffers: Buffers = .{};

/// Serves requests until determinismo closes stdin.
pub fn serve(comptime Handler: type, handler: *Handler) !void {
    comptime assert(@hasDecl(Handler, "name"));
    while (try read_line()) |line| {
        var fba = std.heap.FixedBufferAllocator.init(&buffers.parse);
        const Value = std.json.Value;
        const request = try std.json.parseFromSliceLeaky(Value, fba.allocator(), line, .{});
        if (request != .object) return error.BadRequest;
        const method = (request.object.get("method") orelse return error.BadRequest).string;
        var writer: std.Io.Writer = .fixed(&buffers.output);
        try dispatch(Handler, handler, method, request.object, &writer);
        try writer.writeAll("\n");
        write_all(writer.buffered());
    }
}

fn dispatch(
    comptime Handler: type,
    handler: *Handler,
    method: []const u8,
    request: std.json.ObjectMap,
    writer: *std.Io.Writer,
) !void {
    const eql = std.mem.eql;
    if (eql(u8, method, "hello")) {
        if (@hasDecl(Handler, "hello")) handler.hello(try hex_field(request, "exploration_seed"));
        try writer.print("{{\"name\":\"{s}\"}}", .{Handler.name});
    } else if (eql(u8, method, "branch")) {
        if (@hasDecl(Handler, "branch")) {
            const index: u32 = @intCast(request.get("index").?.integer);
            handler.branch(index, try hex_field(request, "seed"));
        }
        try writer.writeAll("{}");
    } else if (eql(u8, method, "random")) {
        try dispatch_random(Handler, handler, request, writer);
    } else if (eql(u8, method, "event")) {
        if (@hasDecl(Handler, "event")) {
            handler.event(request.get("event").?, string_field(request, "source"));
        }
        try writer.writeAll("{}");
    } else if (eql(u8, method, "branch_end")) {
        const stop = if (@hasDecl(Handler, "branch_end"))
            handler.branch_end(try parse_branch_end(request))
        else
            false;
        try writer.writeAll(if (stop) "{\"stop\":true}" else "{}");
    } else {
        return error.UnknownMethod;
    }
}

fn dispatch_random(
    comptime Handler: type,
    handler: *Handler,
    request: std.json.ObjectMap,
    writer: *std.Io.Writer,
) !void {
    var default: [override_size_max]u8 = undefined;
    const default_hex = request.get("default").?.string;
    if (default_hex.len > 2 * override_size_max) return writer.writeAll("{}");
    const default_bytes = try std.fmt.hexToBytes(&default, default_hex);
    const pull: u64 = @intCast(request.get("pull").?.integer);
    if (!@hasDecl(Handler, "random")) return writer.writeAll("{}");
    const source = string_field(request, "source");
    const answer: ?[]const u8 = handler.random(.{
        .pull = pull,
        .default = default_bytes,
        .source = source,
    });
    const value = answer orelse return writer.writeAll("{}");
    assert(value.len == default_bytes.len);
    try writer.writeAll("{\"hex\":\"");
    for (value) |byte| try writer.print("{x:0>2}", .{byte});
    try writer.writeAll("\"}");
}

var failing_buffer: [failing_count_max][]const u8 = undefined;

fn parse_branch_end(request: std.json.ObjectMap) !BranchEnd {
    const failing = request.get("failing").?.array.items;
    const count = @min(failing.len, failing_count_max);
    for (failing[0..count], 0..) |name, index| failing_buffer[index] = name.string;
    return .{
        .index = @intCast(request.get("index").?.integer),
        .outcome = request.get("outcome").?.string,
        .events = @intCast(request.get("events").?.integer),
        .failing = failing_buffer[0..count],
    };
}

/// A string field, or "" when it is missing (as from older versions of determinismo).
fn string_field(object: std.json.ObjectMap, key: []const u8) []const u8 {
    const value = object.get(key) orelse return "";
    return if (value == .string) value.string else "";
}

fn hex_field(object: std.json.ObjectMap, key: []const u8) !u64 {
    const value = object.get(key) orelse return error.BadRequest;
    if (value != .string) return error.BadRequest;
    return std.fmt.parseInt(u64, value.string, 16);
}

fn read_line() !?[]const u8 {
    for (0..line_size_max) |_| {
        const pending = buffers.input[buffers.input_start..buffers.input_end];
        if (std.mem.indexOfScalar(u8, pending, '\n')) |index| {
            buffers.input_start += @intCast(index + 1);
            return pending[0..index];
        }
        if (buffers.input_start > 0) {
            std.mem.copyForwards(u8, buffers.input[0..pending.len], pending);
            buffers.input_start = 0;
            buffers.input_end = @intCast(pending.len);
        }
        if (buffers.input_end == line_size_max) return error.LineTooLong;
        const free = buffers.input[buffers.input_end..];
        const result = linux.read(0, free.ptr, free.len);
        if (linux.errno(result) != .SUCCESS) return error.ReadFailed;
        if (result == 0) return null; // determinismo is done.
        buffers.input_end += @intCast(result);
    }
    return error.LineTooLong;
}

fn write_all(bytes: []const u8) void {
    var written: u64 = 0;
    while (written < bytes.len) {
        const result = linux.write(1, bytes[written..].ptr, bytes.len - written);
        if (linux.errno(result) != .SUCCESS) linux.exit_group(1); // determinismo went away.
        written += result;
    }
}
