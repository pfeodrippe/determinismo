// SPDX-License-Identifier: MIT
//! determinismo's side of the strategy-plugin protocol (docs/PLUGINS.md): spawns the plugin, and
//! sends it one JSON line per request and reads one JSON line back. All buffers are fixed and
//! live in this struct, which the caller reserves once.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const Events = @import("events.zig");

pub const override_size_max = 64;
/// Why a plugin chose an answer (its `reason`), kept with the decision; longer is cut.
pub const reason_size_max = 240;
const line_size_max = 16 * 1024;
const parse_buffer_size = 64 * 1024;
const argument_count_max = 16;

/// The plugin's process, or 0 for a plugin reached over TCP (it runs elsewhere).
pid: linux.pid_t,
to_plugin: linux.fd_t,
from_plugin: linux.fd_t,
request: [line_size_max]u8,
response: [line_size_max]u8,
response_start: u32,
response_end: u32,
parse_buffer: [parse_buffer_size]u8,
/// The reason the last overriding answer gave, if any.
reason: [reason_size_max]u8 = undefined,
reason_size: u8 = 0,
/// From its hello: whether it is asked for decisions and told events (a plugin that only
/// chooses where the tree returns says no: no round trip per decision), and whether the tree's
/// `returns` gives it each candidate's behaviors.
decides: bool = true,
wants_behaviors: bool = false,

const Strategy = @This();

/// `command` is the plugin's program followed by its arguments, separated by spaces; a program
/// without a slash is looked up in PATH, as a shell would. The plugin inherits `environ`. Or
/// `tcp://<IPv4 address>:<port>`: a plugin already listening there, anywhere (one connection
/// per exploration worker; an SSH tunnel brings one from a laptop).
pub fn start(
    strategy: *Strategy,
    arena: std.mem.Allocator,
    command: []const u8,
    environ: [:null]const ?[*:0]const u8,
) !void {
    assert(command.len > 0);
    if (std.mem.startsWith(u8, command, "tcp://")) return strategy.connect(command["tcp://".len..]);
    var argv: [argument_count_max + 1:null]?[*:0]const u8 = @splat(null);
    var words = std.mem.tokenizeScalar(u8, command, ' ');
    var count: u32 = 0;
    while (words.next()) |word| {
        if (count == argument_count_max) return error.TooManyArguments;
        argv[count] = try arena.dupeSentinel(u8, word, 0);
        count += 1;
    }
    const program = try program_find(arena, std.mem.span(argv[0].?), environ);
    var requests: [2]linux.fd_t = undefined;
    var responses: [2]linux.fd_t = undefined;
    try check(linux.pipe2(&requests, .{ .CLOEXEC = true }));
    try check(linux.pipe2(&responses, .{ .CLOEXEC = true }));
    const pid = linux.fork();
    try check(pid);
    if (pid == 0) {
        _ = linux.dup2(requests[0], 0);
        _ = linux.dup2(responses[1], 1);
        _ = linux.execve(program, &argv, environ.ptr);
        linux.exit_group(127);
    }
    _ = linux.close(requests[0]);
    _ = linux.close(responses[1]);
    strategy.pid = @intCast(pid);
    strategy.to_plugin = requests[1];
    strategy.from_plugin = responses[0];
    strategy.response_start = 0;
    strategy.response_end = 0;
}

fn connect(strategy: *Strategy, address_text: []const u8) !void {
    const colon = std.mem.lastIndexOfScalar(u8, address_text, ':') orelse return error.BadAddress;
    const port = std.fmt.parseInt(u16, address_text[colon + 1 ..], 10) catch
        return error.BadAddress;
    const host = address_text[0..colon];
    var address: [4]u8 = undefined;
    if (std.mem.eql(u8, host, "localhost")) {
        address = .{ 127, 0, 0, 1 };
    } else {
        var parts = std.mem.splitScalar(u8, host, '.');
        for (&address) |*byte| {
            byte.* = std.fmt.parseInt(u8, parts.next() orelse return error.BadAddress, 10) catch
                return error.BadAddress;
        }
        if (parts.next() != null) return error.BadAddress;
    }
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    try check(socket);
    const fd: linux.fd_t = @intCast(socket);
    const target = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(address),
    };
    check(linux.connect(fd, @ptrCast(&target), @sizeOf(linux.sockaddr.in))) catch {
        _ = linux.close(fd);
        std.debug.print("[determinismo] strategy: nothing listens at {s}\n", .{address_text});
        return error.PluginUnreachable;
    };
    strategy.pid = 0;
    strategy.to_plugin = fd;
    strategy.from_plugin = @intCast(linux.dup(fd)); // Closed separately, as pipes would be.
    strategy.response_start = 0;
    strategy.response_end = 0;
}

fn program_find(
    arena: std.mem.Allocator,
    name: []const u8,
    environ: [:null]const ?[*:0]const u8,
) ![*:0]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return try arena.dupeSentinel(u8, name, 0);
    const path = for (environ) |entry| {
        const text = std.mem.span(entry.?);
        if (std.mem.startsWith(u8, text, "PATH=")) break text["PATH=".len..];
    } else "/usr/local/bin:/usr/bin:/bin";
    var directories = std.mem.tokenizeScalar(u8, path, ':');
    while (directories.next()) |directory| {
        const candidate = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ directory, name }, 0);
        if (linux.errno(linux.access(candidate, linux.X_OK)) == .SUCCESS) return candidate;
    }
    std.debug.print("[determinismo] strategy: {s} not found in PATH\n", .{name});
    return error.PluginNotFound;
}

pub fn stop(strategy: *Strategy) void {
    _ = linux.close(strategy.to_plugin); // The plugin sees end of input and exits.
    _ = linux.close(strategy.from_plugin);
    if (strategy.pid == 0) return; // Remote: its connection closed.
    var status: i32 = 0;
    _ = linux.waitpid(strategy.pid, &status, 0);
}

pub fn hello(strategy: *Strategy, exploration_seed: u64) !void {
    var writer: std.Io.Writer = .fixed(&strategy.request);
    try writer.print("{{\"method\":\"hello\",\"protocol\":1,\"exploration_seed\":\"{x:0>16}\"}}", .{
        exploration_seed,
    });
    const reply = try strategy.call(writer.buffered());
    const name = reply.get("name") orelse return error.BadPluginReply;
    if (name != .string) return error.BadPluginReply;
    strategy.decides = true;
    strategy.wants_behaviors = false;
    if (reply.get("decides")) |decides| if (decides == .bool) {
        strategy.decides = decides.bool;
    };
    if (reply.get("wants")) |wants| if (wants == .array) for (wants.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, "behaviors")) {
            strategy.wants_behaviors = true;
        }
    };
    std.debug.print("[determinismo] strategy: {s}\n", .{name.string});
}

/// Where a branch starts when not at the setup snapshot: a moment of another (the tree's).
pub const From = struct { branch: u32, vtime_ns: u64 };

pub fn branch(strategy: *Strategy, index: u32, seed: u64, from: ?From) !void {
    var writer: std.Io.Writer = .fixed(&strategy.request);
    const format = "{{\"method\":\"branch\",\"index\":{d},\"seed\":\"{x:0>16}\"";
    try writer.print(format, .{ index, seed });
    if (from) |parent| {
        try writer.print(",\"from\":{{\"branch\":{d},\"vtime_ns\":{d}}}", .{
            parent.branch, parent.vtime_ns,
        });
    }
    try writer.writeAll("}");
    _ = try strategy.call(writer.buffered());
}

/// A branch of the generation that just ended, as the tree explorer saw it: `novel` behaviors no
/// branch before it had, the last of them (`moment_ns`, `label`) where it would return.
pub const Candidate = struct {
    branch: u32,
    start_ns: u64,
    end_ns: u64,
    novel: u32,
    moment_ns: ?u64,
    label: []const u8,
    /// With `"wants": ["behaviors"]` in its hello: the behaviors it reached itself (after it
    /// began), each with how many timelines of the generation reached it when no earlier
    /// generation had (0: known before), and how many timelines reached it before.
    behaviors: []const Behavior = &.{},
};

pub const Behavior = struct {
    label: []const u8,
    vtime_ns: u64,
    new_in_generation: u32,
    timelines_before: u32,
};

/// A moment of a branch to return to, and why.
pub const Return = struct { branch: u32, vtime_ns: u64, reason: []const u8 };

/// The tree explorer asks where to return after a generation: the plugin answers
/// `{"returns": [{"branch": B, "vtime_ns": T, "reason": "..."}, ...]}` (at most `count`), or
/// `{}` to leave it to the explorer. Reasons are copied into `arena`.
pub fn returns(
    strategy: *Strategy,
    arena: std.mem.Allocator,
    generation: u32,
    candidates: []const Candidate,
    count: u32,
) ![]const Return {
    // Not the fixed request buffer: with behaviors, a generation's candidates run to megabytes.
    var writer: std.Io.Writer.Allocating = .init(arena);
    try writer.writer.print("{{\"method\":\"returns\",\"generation\":{d},\"count\":{d}," ++
        "\"candidates\":{f}}}", .{ generation, count, std.json.fmt(candidates, .{}) });
    const reply = try strategy.call_long(writer.written());
    const list = reply.get("returns") orelse return &.{};
    if (list != .array) return error.BadPluginReply;
    var chosen: std.ArrayList(Return) = .empty;
    for (list.array.items) |item| {
        if (chosen.items.len == count) break;
        if (item != .object) return error.BadPluginReply;
        const index = item.object.get("branch") orelse return error.BadPluginReply;
        const vtime = item.object.get("vtime_ns") orelse return error.BadPluginReply;
        if (index != .integer or vtime != .integer) return error.BadPluginReply;
        const reason = if (item.object.get("reason")) |text| switch (text) {
            .string => |string| try arena.dupe(u8, string[0..@min(string.len, reason_size_max)]),
            else => "",
        } else "";
        try chosen.append(arena, .{
            .branch = std.math.cast(u32, index.integer) orelse return error.BadPluginReply,
            .vtime_ns = std.math.cast(u64, vtime.integer) orelse return error.BadPluginReply,
            .reason = reason,
        });
    }
    return chosen.items;
}

/// Offers the plugin a decision. Returns true when it overrode `value` (which on entry holds
/// the default and on return holds the answer).
pub fn random(
    strategy: *Strategy,
    pull: u64,
    moment: Events.Moment,
    source: []const u8,
    /// The decision's label (`{"name": ..., "options": [...]}` or `"range"`), if announced.
    label: ?[]const u8,
    value: []u8,
) !bool {
    assert(value.len > 0);
    var writer: std.Io.Writer = .fixed(&strategy.request);
    try writer.print("{{\"method\":\"random\",\"pull\":{d},\"size\":{d},\"default\":\"", .{
        pull, value.len,
    });
    for (value) |byte| try writer.print("{x:0>2}", .{byte});
    try writer.print("\",\"source\":{f},\"vtime_ns\":{d},\"branches\":{d}", .{
        std.json.fmt(source, .{}), moment.vtime_ns, moment.branches,
    });
    if (label) |decision| try writer.print(",\"decision\":{s}", .{decision});
    try writer.writeAll("}");
    const reply = try strategy.call(writer.buffered());
    strategy.reason_size = 0;
    const hex = reply.get("hex") orelse return false;
    if (reply.get("reason")) |reason| if (reason == .string) {
        const size = @min(reason.string.len, reason_size_max);
        @memcpy(strategy.reason[0..size], reason.string[0..size]);
        strategy.reason_size = @intCast(size);
    };
    if (hex != .string) return error.BadPluginReply;
    if (hex.string.len != value.len * 2) return error.BadPluginReply;
    if (value.len > override_size_max) return error.OverrideTooLarge;
    _ = std.fmt.hexToBytes(value, hex.string) catch return error.BadPluginReply;
    return true;
}

pub fn event(
    strategy: *Strategy,
    moment: Events.Moment,
    source: []const u8,
    data: []const u8,
) !void {
    assert(data.len > 0);
    const object = data[0] == '{' and data[data.len - 1] == '}';
    if (!object) return; // Only structured events are forwarded.
    var writer: std.Io.Writer = .fixed(&strategy.request);
    const format = "{{\"method\":\"event\",\"vtime_ns\":{d},\"branches\":{d},\"source\":{f}," ++
        "\"event\":";
    try writer.print(format, .{ moment.vtime_ns, moment.branches, std.json.fmt(source, .{}) });
    try writer.writeAll(data);
    try writer.writeAll("}");
    _ = try strategy.call(writer.buffered());
}

pub const BranchEnd = struct {
    index: u32,
    outcome: []const u8,
    events: u64,
    failing: []const []const u8,
};

/// Returns true when the plugin asks to stop exploring.
pub fn branch_end(strategy: *Strategy, end: BranchEnd) !bool {
    var writer: std.Io.Writer = .fixed(&strategy.request);
    try writer.print("{{\"method\":\"branch_end\",\"index\":{d},\"outcome\":\"{s}\"," ++
        "\"events\":{d},\"failing\":[", .{ end.index, end.outcome, end.events });
    for (end.failing, 0..) |name, index| {
        if (index > 0) try writer.writeAll(",");
        try std.json.Stringify.value(name, .{}, &writer);
    }
    try writer.writeAll("]}");
    const reply = try strategy.call(writer.buffered());
    const stop_value = reply.get("stop") orelse return false;
    return stop_value == .bool and stop_value.bool;
}

/// Sends one request line and parses the one reply line. The reply lives in parse_buffer until
/// the next call.
fn call(strategy: *Strategy, request: []const u8) !std.json.ObjectMap {
    assert(request.len < line_size_max);
    return strategy.call_long(request);
}

/// `call` for a request of any size (the reply still fits the fixed buffers).
fn call_long(strategy: *Strategy, request: []const u8) !std.json.ObjectMap {
    assert(request.len > 0);
    try write_all(strategy.to_plugin, request);
    try write_all(strategy.to_plugin, "\n");
    const line = try strategy.read_line();
    var fba = std.heap.FixedBufferAllocator.init(&strategy.parse_buffer);
    const value = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), line, .{}) catch {
        return error.BadPluginReply;
    };
    if (value != .object) return error.BadPluginReply;
    return value.object;
}

fn read_line(strategy: *Strategy) ![]const u8 {
    for (0..line_size_max) |_| {
        const pending = strategy.response[strategy.response_start..strategy.response_end];
        if (std.mem.indexOfScalar(u8, pending, '\n')) |index| {
            strategy.response_start += @intCast(index + 1);
            return pending[0..index];
        }
        if (strategy.response_start > 0) {
            std.mem.copyForwards(u8, strategy.response[0..pending.len], pending);
            strategy.response_start = 0;
            strategy.response_end = @intCast(pending.len);
        }
        if (strategy.response_end == line_size_max) return error.PluginLineTooLong;
        const free = strategy.response[strategy.response_end..];
        const result = linux.read(strategy.from_plugin, free.ptr, free.len);
        try check(result);
        if (result == 0) return error.PluginExited;
        strategy.response_end += @intCast(result);
    }
    return error.PluginLineTooLong;
}

fn write_all(fd: linux.fd_t, bytes: []const u8) !void {
    assert(fd >= 0);
    var written: u64 = 0;
    while (written < bytes.len) {
        const result = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        check(result) catch return error.PluginExited;
        written += result;
    }
    assert(written == bytes.len);
}

fn check(result: usize) !void {
    if (linux.errno(result) != .SUCCESS) return error.SyscallFailed;
}
