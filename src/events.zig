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
    /// Where the assertion is in the code ("file:line function"), from the first event (or
    /// catalog entry) that said; empty when none did.
    location: [location_size_max]u8 = undefined,
    location_size: u8 = 0,

    pub fn where(property: *const Property) []const u8 {
        return property.location[0..property.location_size];
    }

    pub fn name(property: *const Property) []const u8 {
        assert(property.message_size > 0);
        assert(property.message_size <= message_size_max);
        return property.message[0..property.message_size];
    }

    /// Whether this timeline violates the property: an `always` that was false, an
    /// `unreachable` that was reached. `sometimes` and `reachable` (and an `always` never hit)
    /// are about the whole multiverse, as in Antithesis: no single timeline violates them
    /// (report.property_failing judges them across branches).
    pub fn passing(property: *const Property) bool {
        assert(property.trues <= property.hits);
        return switch (property.kind) {
            .always, .always_or_unreachable => property.trues == property.hits,
            .@"unreachable" => property.hits == 0,
            .sometimes, .reachable => true,
        };
    }
};

log_fd: ?linux.fd_t,
/// Output lines with one of these texts are not written (VM.Options.retroactive).
retroactive: []const []const u8 = &.{},
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
/// Output the nodes and commands printed, and since when (the first event seen): the logging
/// rate the "logging output" property checks.
output_bytes: u64 = 0,
first_vtime_ns: ?u64 = null,
/// When the guest began streaming its checks' inputs out (composer.zig's checks_stream: the
/// timeline's commands are over). A branch from later would hold only the rest of them.
checks_start_ns: ?u64 = null,
/// The latest event's moment.
last_vtime_ns: u64 = 0,
/// The behaviors this timeline reached (behavior_hash: an assertion with its outcome, an
/// event with its categorical details; and how close a guidance assertion came, by powers of
/// two), each with when it first did: where the tree explorer branches from (main.zig).
behaviors: [behavior_count_max]Behavior = undefined,
behavior_count: u32 = 0,
behavior_slots: [behavior_slot_count]u64 = @splat(0),
/// The checks' inputs (schema.Check), streamed out by the composer as the timeline ends:
/// decoded into `check_buffer` (the caller's, reserved once), one span per check.
check_buffer: []u8 = &.{},
check_used: usize = 0,
check_inputs: [check_count_max]CheckInput = @splat(.{}),

pub const check_count_max = 8;

pub const CheckInput = struct {
    start: usize = 0,
    end: usize = 0,
    /// The composer said it was all sent (`check_input`), or that there was none.
    complete: bool = false,
    missing: bool = false,
    /// Larger than what was left of the buffer: not checkable.
    overflow: bool = false,
};

/// A check's whole input, once the composer sent it all; null when it never did (the timeline
/// ended first), there was none, or it did not fit.
pub fn check_input(events: *const Events, index: usize) ?[]const u8 {
    if (index >= check_count_max) return null;
    const input = events.check_inputs[index];
    if (!input.complete or input.missing or input.overflow) return null;
    return events.check_buffer[input.start..input.end];
}

const Events = @This();

pub const Behavior = struct {
    hash: u64,
    vtime_ns: u64,
    /// What it is, for people: `always "balance is conserved": false`, `fault partition`.
    label: [behavior_label_size]u8 = undefined,
    label_size: u8 = 0,
    /// The node it came from, when it says (a node's output, an event's `details.node`):
    /// where a branch from just after it aims its first fault (VM.Options.branch_signal).
    node_name: [behavior_node_size]u8 = undefined,
    node_size: u8 = 0,

    pub fn name(behavior: *const Behavior) []const u8 {
        return behavior.label[0..behavior.label_size];
    }

    pub fn node(behavior: *const Behavior) []const u8 {
        return behavior.node_name[0..behavior.node_size];
    }
};
pub const behavior_node_size = 32;
pub const behavior_label_size = 72;
/// Room for instrumented programs' coverage (a Go service reports thousands of lines early on)
/// besides what comes after it.
pub const behavior_count_max = 8192;
const behavior_slot_count = 2 * behavior_count_max; // Open addressing, at most half full.

pub const InitOptions = struct {
    log_fd: ?linux.fd_t,
    /// Room for the checks' inputs (schema.Check), reserved once by the caller; empty: none.
    check_buffer: []u8 = &.{},
};

pub fn init(events: *Events, parse_buffer: []u8, options: InitOptions) void {
    if (options.log_fd) |fd| assert(fd >= 0);
    assert(parse_buffer.len == parse_buffer_size);
    events.* = .{
        .log_fd = options.log_fd,
        .parse_buffer = parse_buffer,
        .check_buffer = options.check_buffer,
    };
    assert(events.property_count == 0);
}

pub fn emit(events: *Events, moment: Moment, data: []const u8) !void {
    assert(data.len <= 4096);
    events.count += 1;
    if (events.first_vtime_ns == null) events.first_vtime_ns = moment.vtime_ns;
    events.last_vtime_ns = moment.vtime_ns;
    events.hash.update(std.mem.asBytes(&moment));
    events.hash.update(data);

    events.last_event_name_size = 0;
    // 64 times the largest event: a failure to parse is never for lack of room.
    var fba = std.heap.FixedBufferAllocator.init(events.parse_buffer);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), data, .{}) catch
        null;
    // Checks' inputs are the host's (they can be megabytes): hashed, not logged.
    const check_chunk = std.mem.startsWith(u8, data, "{\"event\":\"check_chunk\"");
    if (events.log_fd) |fd| if (!check_chunk and !events.retroactive_hidden(data)) {
        write_log_line(fd, .{
            .sequence = events.count,
            .moment = moment,
            .data = data,
            .json = parsed != null,
        });
    };
    // Not JSON: logged as text (`{"raw": ...}`), but carries no properties.
    const value = parsed orelse return;
    if (value != .object) return;
    if (value.object.get("event")) |name| {
        if (name == .string) {
            const checks = std.mem.eql(u8, name.string, "check_chunk") or
                std.mem.eql(u8, name.string, "check_input");
            if (checks and events.checks_start_ns == null) events.checks_start_ns = moment.vtime_ns;
            events.check_event(name.string, value.object.get("details"));
        }
        if (name == .string) {
            const size: u8 = @intCast(@min(name.string.len, events.last_event_name.len));
            @memcpy(events.last_event_name[0..size], name.string[0..size]);
            events.last_event_name_size = size;
        }
    }
    events.behavior_note(moment, value);
    if (value.object.get("lifecycle")) |lifecycle| events.on_lifecycle(moment, lifecycle);
    if (value.object.get("output")) |output| events.on_output(output);
    if (value.object.get("assert")) |assertion| try events.on_assert(moment, assertion);
    if (value.object.get("antithesis_assert")) |assertion| {
        try events.on_antithesis_assert(moment, assertion);
    }
    if (value.object.get("antithesis_setup")) |setup| {
        const status = if (setup == .object) string_field(setup.object, "status") else null;
        if (status != null and std.mem.eql(u8, status.?, "complete")) {
            events.on_lifecycle(moment, .{ .string = "setup_complete" });
        }
    }
}

/// Retroactive logging: an output line with a text it hides, not written while exploring.
fn retroactive_hidden(events: *const Events, data: []const u8) bool {
    if (events.retroactive.len == 0) return false;
    if (!std.mem.startsWith(u8, data, "{\"output\":")) return false;
    for (events.retroactive) |text| {
        if (std.mem.indexOf(u8, data, text) != null) return true;
    }
    return false;
}

fn behavior_note(events: *Events, moment: Moment, value: std.json.Value) void {
    const hash = behavior_hash(value) orelse guidance_hash(value) orelse
        output_hash(value) orelse return;
    if (events.behavior_count == behavior_count_max) return;
    const key = hash | 1; // 0 marks an empty slot.
    var slot = key % behavior_slot_count;
    while (events.behavior_slots[slot] != 0) : (slot = (slot + 1) % behavior_slot_count) {
        if (events.behavior_slots[slot] == key) return;
    }
    events.behavior_slots[slot] = key;
    const behavior = &events.behaviors[events.behavior_count];
    behavior.* = .{ .hash = key, .vtime_ns = moment.vtime_ns };
    var writer: std.Io.Writer = .fixed(&behavior.label);
    behavior_label(&writer, value);
    behavior.label_size = @intCast(writer.end);
    const node = behavior_node(value);
    const size = @min(node.len, behavior_node_size);
    @memcpy(behavior.node_name[0..size], node[0..size]);
    behavior.node_size = @intCast(size);
    events.behavior_count += 1;
}

/// The node a behavior came from: a node's output's source, an event's `details.node`; "" when
/// it does not say (an assertion's).
fn behavior_node(value: std.json.Value) []const u8 {
    if (value.object.get("output")) |output| if (output == .object) {
        return string_field(output.object, "source") orelse "";
    };
    const details = value.object.get("details") orelse return "";
    if (details != .object) return "";
    return string_field(details.object, "node") orelse "";
}

/// A behavior's label, cut where the label ends.
fn behavior_label(writer: *std.Io.Writer, value: std.json.Value) void {
    if (value.object.get("assert")) |assertion| if (assertion == .object) {
        const kind = string_field(assertion.object, "type") orelse "assert";
        const message = string_field(assertion.object, "message") orelse "";
        const condition = assertion.object.get("condition") orelse std.json.Value{ .bool = true };
        const holds = condition != .bool or condition.bool;
        writer.print("{s} \"{s}\": {}", .{ kind, message, holds }) catch {};
        return;
    };
    if (value.object.get("guidance")) |guidance| if (guidance == .object) {
        const message = string_field(guidance.object, "message") orelse "";
        writer.print("closer to \"{s}\"", .{message}) catch {};
        return;
    };
    if (value.object.get("output")) |output| if (output == .object) {
        const source = string_field(output.object, "source") orelse "";
        var template: [output_template_size]u8 = undefined;
        const text = output_template(string_field(output.object, "text") orelse "", &template);
        writer.print("{s} printed \"{s}\"", .{ source, text }) catch {};
        return;
    };
    const name_value = value.object.get("event") orelse return;
    if (name_value != .string) return;
    writer.writeAll(name_value.string) catch return;
    const details = value.object.get("details") orelse return;
    if (details != .object) return;
    for ([_][]const u8{ "kind", "flavor", "node", "peer", "state", "name" }) |key| {
        const text = string_field(details.object, key) orelse continue;
        writer.print(" {s}", .{text}) catch return;
    }
}

/// A kind of line a node printed: its text with numbers, hex and ids blanked (`#`), per source
/// and stream; a node saying something it never said before (a new error, an exception) is a
/// new behavior.
fn output_hash(value: std.json.Value) ?u64 {
    const output = value.object.get("output") orelse return null;
    if (output != .object) return null;
    const text = string_field(output.object, "text") orelse return null;
    var hasher = std.hash.Wyhash.init(0x6f7574707574);
    hasher.update(string_field(output.object, "source") orelse "");
    hasher.update(string_field(output.object, "stream") orelse "");
    var template: [output_template_size]u8 = undefined;
    hasher.update(output_template(text, &template));
    return hasher.final();
}

const output_template_size = 96;

/// `text` with every run of digits, hex digits mixed with digits, or `-`/`.`/`:` between them
/// made one `#`, cut to the buffer (where variable parts usually are past).
fn output_template(text: []const u8, buffer: *[output_template_size]u8) []const u8 {
    var size: usize = 0;
    var index: usize = 0;
    while (index < text.len and size < buffer.len) {
        const c = text[index];
        if (!std.ascii.isDigit(c)) {
            buffer[size] = c;
            size += 1;
            index += 1;
            continue;
        }
        // A number, an id or an address: digits with hex letters and separators around them.
        var end = index;
        while (end < text.len and (std.ascii.isHex(text[end]) or text[end] == '-' or
            text[end] == '.' or text[end] == ':')) end += 1;
        // Hex letters before the digits belong to it too (`a708a334-...`).
        while (size > 0 and std.ascii.isHex(buffer[size - 1]) and
            !std.ascii.isDigit(buffer[size - 1])) size -= 1;
        buffer[size] = '#';
        size += 1;
        index = end;
    }
    return buffer[0..size];
}

test output_template {
    var buffer: [output_template_size]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Exception in thread \"nREPL-session-#\" java.net.SocketException: Socket closed",
        output_template("Exception in thread \"nREPL-session-a708a334-2896-48df-891a-" ++
            "8d76d5056a9c\" java.net.SocketException: Socket closed", &buffer),
    );
    try std.testing.expectEqualStrings("took # ms", output_template("took 12.5 ms", &buffer));
}

/// A guidance assertion's distance by power of two (0 or less: there): a timeline that came
/// closer than any before reached a new behavior.
/// What the explorer counts as a behavior: an assertion with its outcome, an event with its
/// categorical details (a code coverage edge or line included); not numbers, not what
/// determinismo itself reports (commands, faults, lifecycle). The events database counts the
/// same (store.zig's `behavior`).
const runtime_events = [_][]const u8{
    "composer_start", "composer_done", "command_start", "command_exit", "faults_phase",
    "faults_start",   "faults_stop",   "fault",         "nodes_up",     "node_start",
    "node_ready",     "node_kill",     "exec_start",    "exec_output",  "exec_done",
    "faults_branch",
};
const behavior_keys = [_][]const u8{ "kind", "flavor", "mode", "name", "node", "peer", "state" };

fn behavior_hash(value: std.json.Value) ?u64 {
    if (value != .object) return null;
    var hasher = std.hash.Wyhash.init(0x6265686176696f72);
    if (value.object.get("assert")) |assertion| {
        if (assertion != .object) return null;
        for ([_][]const u8{ "type", "message", "condition" }) |key| {
            hash_field(&hasher, assertion.object, key);
        }
        return hasher.final();
    }
    const name = value.object.get("event") orelse return null;
    if (name != .string) return null;
    for (runtime_events) |runtime| if (std.mem.eql(u8, name.string, runtime)) return null;
    hasher.update(name.string);
    if (value.object.get("details")) |details| {
        if (details == .object) for (behavior_keys) |key| hash_field(&hasher, details.object, key);
    }
    return hasher.final();
}

fn hash_field(hasher: *std.hash.Wyhash, object: std.json.ObjectMap, key: []const u8) void {
    const value = object.get(key) orelse return;
    hasher.update(key);
    switch (value) {
        .string => |text| hasher.update(text),
        .bool => |flag| hasher.update(if (flag) "true" else "false"),
        else => {}, // Numbers and structures: not behaviors.
    }
}

fn guidance_hash(value: std.json.Value) ?u64 {
    const guidance = value.object.get("guidance") orelse return null;
    if (guidance != .object) return null;
    const message = string_field(guidance.object, "message") orelse return null;
    const distance: f64 = switch (guidance.object.get("distance") orelse return null) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => return null,
    };
    const bucket: i32 = if (!(distance > 0)) -1 else bucket: {
        break :bucket @floor(@log2(@min(distance, 1e300)));
    };
    var hasher = std.hash.Wyhash.init(0x6775696465);
    hasher.update(message);
    hasher.update(std.mem.asBytes(&bucket));
    return hasher.final();
}

test behavior_note {
    var buffer: [parse_buffer_size]u8 = undefined;
    var events: Events = undefined;
    events.init(&buffer, .{ .log_fd = null });
    const near = "{\"guidance\":{\"message\":\"sum\",\"distance\":5}}";
    try events.emit(.{ .vtime_ns = 10, .branches = 1 }, near);
    try events.emit(.{ .vtime_ns = 20, .branches = 2 }, near);
    const closer = "{\"guidance\":{\"message\":\"sum\",\"distance\":1}}";
    try events.emit(.{ .vtime_ns = 30, .branches = 3 }, closer);
    // Same bucket once, closer is new; when each was first reached.
    try std.testing.expectEqual(@as(u32, 2), events.behavior_count);
    try std.testing.expectEqual(@as(u64, 10), events.behaviors[0].vtime_ns);
    try std.testing.expectEqual(@as(u64, 30), events.behaviors[1].vtime_ns);
    try std.testing.expectEqualStrings("closer to \"sum\"", events.behaviors[1].name());
}

/// Language properties (a Go panic, ...) are the guest's output forwarder's assertions
/// (guest/runtime/output.zig): events as any other, for queries and a run's properties alike.
fn on_output(events: *Events, output: std.json.Value) void {
    if (output != .object) return;
    const text = string_field(output.object, "text") orelse return;
    events.output_bytes += text.len;
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
    const kind = std.meta.stringToEnum(Kind, kind_name) orelse return error.BadAssertion;
    if (declaration(assertion.object)) return events.declare(kind, assertion.object);
    return events.assertion_record(moment, kind, assertion);
}

/// `"hit": false`: the assertion is declared (Antithesis's catalog), not evaluated. A declared
/// `reachable` or `sometimes` that no timeline reaches fails, as must-hit assertions do.
fn declaration(assertion: std.json.ObjectMap) bool {
    const hit = assertion.get("hit") orelse return false;
    return hit == .bool and !hit.bool;
}

fn declare(events: *Events, kind: Kind, assertion: std.json.ObjectMap) !void {
    const message = string_field(assertion, "message") orelse return error.BadAssertion;
    const property = try events.property_get_or_put(kind, message);
    location_note(property, assertion);
}

/// An assertion from an Antithesis SDK (`{"antithesis_assert": {...}}`): its `display_type`
/// names the property kind; entries with `hit: false` only declare the assertion.
fn on_antithesis_assert(events: *Events, moment: Moment, assertion: std.json.Value) !void {
    if (assertion != .object) return error.BadAssertion;
    const display = string_field(assertion.object, "display_type") orelse
        return error.BadAssertion;
    const kinds = [_]struct { []const u8, Kind }{
        .{ "Always", .always },
        .{ "AlwaysOrUnreachable", .always_or_unreachable },
        .{ "Sometimes", .sometimes },
        .{ "Reachable", .reachable },
        .{ "Unreachable", .@"unreachable" },
    };
    for (kinds) |entry| {
        if (!std.mem.eql(u8, display, entry[0])) continue;
        if (declaration(assertion.object)) return events.declare(entry[1], assertion.object);
        return events.assertion_record(moment, entry[1], assertion);
    }
    return error.BadAssertion;
}

fn assertion_record(events: *Events, moment: Moment, kind: Kind, assertion: std.json.Value) !void {
    const message = string_field(assertion.object, "message") orelse return error.BadAssertion;
    const condition_value = assertion.object.get("condition") orelse std.json.Value{ .bool = true };
    if (condition_value != .bool) return error.BadAssertion;
    const condition = condition_value.bool;

    const property = try events.property_get_or_put(kind, message);
    assert(property.kind == kind);
    location_note(property, assertion.object);
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

const location_size_max = 120;

/// `"location": {"file", "line", "function"}` (Antithesis's SDKs send `begin_line` and
/// `class`): kept as "file:line function", once.
fn location_note(property: *Property, assertion: std.json.ObjectMap) void {
    if (property.location_size > 0) return;
    const location = assertion.get("location") orelse return;
    if (location != .object) return;
    const file = string_field(location.object, "file") orelse
        string_field(location.object, "file_name") orelse return;
    const line_value = location.object.get("line") orelse location.object.get("begin_line");
    const line: i64 = if (line_value) |value| switch (value) {
        .integer => |integer| integer,
        else => 0,
    } else 0;
    const function = string_field(location.object, "function") orelse
        string_field(location.object, "function_name") orelse "";
    var writer: std.Io.Writer = .fixed(&property.location);
    writer.print("{s}:{d}", .{ std.fs.path.basename(file), line }) catch {};
    if (function.len > 0) writer.print(" {s}", .{function}) catch {};
    property.location_size = @intCast(writer.end);
}

fn property_get_or_put(events: *Events, kind: Kind, message: []const u8) !*Property {
    assert(events.property_count <= property_count_max);
    if (message.len == 0) return error.BadAssertion;
    const size: u8 = @intCast(@min(message.len, message_size_max));
    for (events.properties[0..events.property_count]) |*property| {
        if (std.mem.eql(u8, property.name(), message[0..size])) {
            if (property.kind != kind) {
                // One property per message (as in Antithesis): a message with two kinds is a
                // test's mistake, worth saying plainly.
                std.debug.print("[determinismo] the assertion \"{s}\" is both {s} and {s}: give " ++
                    "each kind its own message\n", .{
                    property.name(), @tagName(property.kind), @tagName(kind),
                });
                return error.AssertionKindsDiffer;
            }
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

/// `check_chunk` and `check_input` events (composer.zig's checks_stream): the inputs collected.
fn check_event(events: *Events, name: []const u8, details: ?std.json.Value) void {
    const chunk = std.mem.eql(u8, name, "check_chunk");
    if (!chunk and !std.mem.eql(u8, name, "check_input")) return;
    const object = (details orelse return).object;
    const index_value = object.get("check") orelse return;
    if (index_value != .integer or index_value.integer < 0) return;
    const index: usize = @intCast(index_value.integer);
    if (index >= check_count_max) return;
    const input = &events.check_inputs[index];
    if (!chunk) {
        input.complete = true;
        input.missing = object.get("missing") != null;
        return;
    }
    const data = object.get("data") orelse return;
    if (data != .string) return;
    if (input.start == input.end) {
        input.start = events.check_used;
        input.end = events.check_used;
    }
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(data.string) catch return;
    if (input.overflow or input.end != events.check_used or events.check_used + size > events.check_buffer.len) {
        input.overflow = true;
        return;
    }
    decoder.decode(events.check_buffer[events.check_used..][0..size], data.string) catch {
        input.overflow = true;
        return;
    };
    events.check_used += size;
    input.end = events.check_used;
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

/// Virtual time from the first event to `end_ns`: what the timeline's output was printed over
/// (the logging property, judged across the multiverse: report.zig).
pub fn output_span_ns(events: *const Events, end_ns: u64) u64 {
    const start_ns = events.first_vtime_ns orelse return 0;
    return end_ns -| start_ns;
}

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

const LogLine = struct { sequence: u64, moment: Moment, data: []const u8, json: bool };

/// One JSON line (the events database ingests them, store.zig): data that is not JSON is
/// written as text, `{"raw": "..."}`.
fn write_log_line(fd: linux.fd_t, line: LogLine) void {
    assert(fd >= 0);
    assert(line.sequence > 0);
    var head_buffer: [128]u8 = undefined;
    const head_format = "{{\"seq\":{d},\"vtime_ns\":{d},\"branches\":{d},\"event\":";
    const head = std.fmt.bufPrint(&head_buffer, head_format, .{
        line.sequence, line.moment.vtime_ns, line.moment.branches,
    }) catch unreachable; // 128 bytes fit three u64s and the keys.
    write_all(fd, head);
    if (line.json) {
        write_all(fd, line.data);
    } else {
        // At most 4096 bytes, each at most 6 escaped (or 4 as a byte array, for invalid UTF-8).
        var raw_buffer: [4096 * 6 + 16]u8 = undefined;
        var raw: std.Io.Writer = .fixed(&raw_buffer);
        raw.print("{{\"raw\":{f}}}", .{std.json.fmt(line.data, .{})}) catch unreachable;
        write_all(fd, raw.buffered());
    }
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

test "a behavior keeps the node it came from" {
    const parse_buffer = try std.testing.allocator.alloc(u8, parse_buffer_size);
    defer std.testing.allocator.free(parse_buffer);
    var events: Events = undefined;
    events.init(parse_buffer, .{ .log_fd = null });
    const output = "{\"output\":{\"source\":\"yb2\",\"stream\":\"stderr\",\"text\":\"tablet 7 lagging\"}}";
    const event = "{\"event\":\"leader\",\"details\":{\"node\":\"yb3\",\"state\":\"elected\"}}";
    const assertion = "{\"assert\":{\"type\":\"sometimes\",\"message\":\"m\",\"condition\":true}}";
    try events.emit(.{ .vtime_ns = 1, .branches = 10 }, output);
    try events.emit(.{ .vtime_ns = 2, .branches = 20 }, event);
    try events.emit(.{ .vtime_ns = 3, .branches = 30 }, assertion);
    // A branch point's own event names a node, but is the platform's, not the system's.
    const branch = "{\"event\":\"faults_branch\",\"details\":{\"quiet_ended\":true,\"node\":\"yb1\"}}";
    try events.emit(.{ .vtime_ns = 4, .branches = 40 }, branch);
    try std.testing.expectEqual(@as(u32, 3), events.behavior_count);
    try std.testing.expectEqualStrings("yb2", events.behaviors[0].node());
    try std.testing.expectEqualStrings("yb3", events.behaviors[1].node());
    try std.testing.expectEqualStrings("", events.behaviors[2].node());
}
