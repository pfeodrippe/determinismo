// SPDX-License-Identifier: MIT
//! Events the guest emits through /dev/determinismo: logs, lifecycle and assertions. Each one is
//! stamped with its moment and appended to a JSONL log; assertions roll up into properties.
//!
//! No allocation: properties live in a fixed table, and JSON parsing uses a buffer the caller
//! reserves once at startup (`parse_buffer_size`) and that is reset for every event.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub const property_count_max = 1024;
pub const message_size_max = 192;
pub const parse_buffer_size = 256 * 1024;

pub const Moment = struct { vtime_ns: u64, branches: u64 };

pub const Kind = enum { always, always_or_unreachable, sometimes, reachable, @"unreachable" };

pub const Property = struct {
    kind: Kind,
    message: [message_size_max]u8,
    message_size: u8,
    hits: u64 = 0,
    trues: u64 = 0,
    first_failure: ?Moment = null,

    pub fn name(property: *const Property) []const u8 {
        assert(property.message_size > 0);
        assert(property.message_size <= message_size_max);
        return property.message[0..property.message_size];
    }

    pub fn passing(property: *const Property) bool {
        assert(property.trues <= property.hits);
        return switch (property.kind) {
            .always => property.hits > 0 and property.trues == property.hits,
            .always_or_unreachable => property.trues == property.hits,
            .sometimes => property.trues > 0,
            .reachable => property.hits > 0,
            .@"unreachable" => property.hits == 0,
        };
    }
};

log_fd: ?linux.fd_t,
count: u64 = 0,
hash: std.hash.Wyhash = .init(0),
properties: [property_count_max]Property = undefined,
property_count: u32 = 0,
setup_complete: ?Moment = null,
/// The guest runtime reported the end of its scenario (it neither crashed nor hung).
guest_done: bool = false,
parse_buffer: []u8,
/// The `event` name of the most recent structured event (`{"event": name, ...}`), if any.
last_event_name: [32]u8 = undefined,
last_event_name_size: u8 = 0,

const Events = @This();

pub const InitOptions = struct { log_fd: ?linux.fd_t };

pub fn init(events: *Events, parse_buffer: []u8, options: InitOptions) void {
    if (options.log_fd) |fd| assert(fd >= 0);
    assert(parse_buffer.len == parse_buffer_size);
    events.* = .{ .log_fd = options.log_fd, .parse_buffer = parse_buffer };
    assert(events.property_count == 0);
}

pub fn emit(events: *Events, moment: Moment, data: []const u8) !void {
    assert(data.len <= 4096);
    events.count += 1;
    events.hash.update(std.mem.asBytes(&moment));
    events.hash.update(data);
    if (events.log_fd) |fd| {
        write_log_line(fd, .{ .sequence = events.count, .moment = moment, .data = data });
    }

    var fba = std.heap.FixedBufferAllocator.init(events.parse_buffer);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), data, .{}) catch {
        return; // Not JSON: kept in the log, but carries no properties.
    };
    events.last_event_name_size = 0;
    if (parsed != .object) return;
    if (parsed.object.get("event")) |name| {
        if (name == .string) {
            const size: u8 = @intCast(@min(name.string.len, events.last_event_name.len));
            @memcpy(events.last_event_name[0..size], name.string[0..size]);
            events.last_event_name_size = size;
        }
    }
    if (parsed.object.get("lifecycle")) |lifecycle| events.on_lifecycle(moment, lifecycle);
    if (parsed.object.get("assert")) |assertion| try events.on_assert(moment, assertion);
}

fn on_lifecycle(events: *Events, moment: Moment, lifecycle: std.json.Value) void {
    assert(events.count > 0);
    if (lifecycle != .string) return;
    if (std.mem.eql(u8, lifecycle.string, "setup_complete")) {
        if (events.setup_complete == null) events.setup_complete = moment;
    }
    if (std.mem.eql(u8, lifecycle.string, "guest_done")) events.guest_done = true;
    if (events.setup_complete) |setup| assert(setup.branches <= moment.branches);
}

fn on_assert(events: *Events, moment: Moment, assertion: std.json.Value) !void {
    assert(events.count > 0);
    if (assertion != .object) return error.BadAssertion;
    const kind_name = string_field(assertion.object, "type") orelse return error.BadAssertion;
    const message = string_field(assertion.object, "message") orelse return error.BadAssertion;
    const kind = std.meta.stringToEnum(Kind, kind_name) orelse return error.BadAssertion;
    const condition_value = assertion.object.get("condition") orelse std.json.Value{ .bool = true };
    if (condition_value != .bool) return error.BadAssertion;
    const condition = condition_value.bool;

    const property = try events.property_get_or_put(kind, message);
    assert(property.kind == kind);
    property.hits += 1;
    if (condition) property.trues += 1;
    const failure = switch (kind) {
        .always, .always_or_unreachable => !condition,
        .@"unreachable" => true,
        .sometimes, .reachable => false,
    };
    if (failure) {
        if (property.first_failure == null) property.first_failure = moment;
    }
    assert(property.trues <= property.hits);
}

fn property_get_or_put(events: *Events, kind: Kind, message: []const u8) !*Property {
    assert(events.property_count <= property_count_max);
    if (message.len == 0) return error.BadAssertion;
    const size: u8 = @intCast(@min(message.len, message_size_max));
    for (events.properties[0..events.property_count]) |*property| {
        if (std.mem.eql(u8, property.name(), message[0..size])) {
            if (property.kind != kind) return error.BadAssertion;
            return property;
        }
    }
    if (events.property_count == property_count_max) return error.TooManyProperties;
    const property = &events.properties[events.property_count];
    property.* = .{ .kind = kind, .message = undefined, .message_size = size };
    @memcpy(property.message[0..size], message[0..size]);
    events.property_count += 1;
    assert(events.property_count <= property_count_max);
    return property;
}

/// Built-in property, checked when a timeline ends: the guest finished its scenario, rather than
/// panicking (the kernel reboots on panic), halting for good, or failing to start.
pub fn finish(events: *Events, moment: Moment, outcome: enum { ended, cut_short }) !void {
    if (outcome == .cut_short) return; // Stopped at a moment on purpose.
    const assertion = if (events.guest_done)
        "{\"assert\":{\"type\":\"always\",\"message\":\"" ++ finish_property ++
            "\",\"condition\":true,\"details\":{}}}"
    else
        "{\"assert\":{\"type\":\"always\",\"message\":\"" ++ finish_property ++
            "\",\"condition\":false,\"details\":{}}}";
    try events.emit(moment, assertion);
}

const finish_property = "the guest finishes its scenario (no panic, hang or crash)";

pub fn last_event_is(events: *const Events, name: []const u8) bool {
    assert(name.len > 0);
    assert(events.last_event_name_size <= events.last_event_name.len);
    return std.mem.eql(u8, events.last_event_name[0..events.last_event_name_size], name);
}

pub fn failing_count(events: *const Events) u32 {
    var count: u32 = 0;
    for (events.properties[0..events.property_count]) |*property| {
        count += @intFromBool(!property.passing());
    }
    assert(count <= events.property_count);
    return count;
}

fn string_field(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    assert(key.len > 0);
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

const LogLine = struct { sequence: u64, moment: Moment, data: []const u8 };

fn write_log_line(fd: linux.fd_t, line: LogLine) void {
    assert(fd >= 0);
    assert(line.sequence > 0);
    var head_buffer: [128]u8 = undefined;
    const head_format = "{{\"seq\":{d},\"vtime_ns\":{d},\"branches\":{d},\"event\":";
    const head = std.fmt.bufPrint(&head_buffer, head_format, .{
        line.sequence, line.moment.vtime_ns, line.moment.branches,
    }) catch unreachable; // 128 bytes fit three u64s and the keys.
    write_all(fd, head);
    write_all(fd, line.data);
    write_all(fd, "}\n");
}

fn write_all(fd: linux.fd_t, bytes: []const u8) void {
    assert(fd >= 0);
    var written: u64 = 0;
    while (written < bytes.len) {
        const result = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        if (linux.errno(result) != .SUCCESS) return; // The event log is best effort.
        written += result;
    }
    assert(written <= bytes.len);
}

test "always fails on the first false condition and records its moment" {
    const parse_buffer = try std.testing.allocator.alloc(u8, parse_buffer_size);
    defer std.testing.allocator.free(parse_buffer);
    var events: Events = undefined;
    events.init(parse_buffer, .{ .log_fd = null });
    const pass = "{\"assert\":{\"type\":\"always\",\"message\":\"m\",\"condition\":true}}";
    const fail = "{\"assert\":{\"type\":\"always\",\"message\":\"m\",\"condition\":false}}";
    try events.emit(.{ .vtime_ns = 1, .branches = 10 }, pass);
    try std.testing.expectEqual(@as(u32, 0), events.failing_count());
    try events.emit(.{ .vtime_ns = 2, .branches = 20 }, fail);
    try std.testing.expectEqual(@as(u32, 1), events.failing_count());
    try std.testing.expectEqual(@as(u64, 20), events.properties[0].first_failure.?.branches);
}
