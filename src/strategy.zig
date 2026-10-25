// SPDX-License-Identifier: MIT
//! determinismo's side of the strategy-plugin protocol (docs/PLUGINS.md): spawns the plugin, and
//! sends it one JSON line per request and reads one JSON line back. All buffers are fixed and
//! live in this struct, which the caller reserves once.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const Events = @import("events.zig");

pub const override_size_max = 64;
const line_size_max = 16 * 1024;
const parse_buffer_size = 64 * 1024;
const argument_count_max = 16;

pid: linux.pid_t,
to_plugin: linux.fd_t,
from_plugin: linux.fd_t,
request: [line_size_max]u8,
response: [line_size_max]u8,
response_start: u32,
response_end: u32,
parse_buffer: [parse_buffer_size]u8,

const Strategy = @This();

/// `command` is the plugin's path followed by its arguments, separated by spaces.
pub fn start(strategy: *Strategy, arena: std.mem.Allocator, command: []const u8) !void {
    assert(command.len > 0);
    var argv: [argument_count_max + 1:null]?[*:0]const u8 = @splat(null);
    var words = std.mem.tokenizeScalar(u8, command, ' ');
    var count: u32 = 0;
    while (words.next()) |word| {
        if (count == argument_count_max) return error.TooManyArguments;
        argv[count] = try arena.dupeSentinel(u8, word, 0);
        count += 1;
    }
    var requests: [2]linux.fd_t = undefined;
    var responses: [2]linux.fd_t = undefined;
    try check(linux.pipe2(&requests, .{ .CLOEXEC = true }));
    try check(linux.pipe2(&responses, .{ .CLOEXEC = true }));
    const pid = linux.fork();
    try check(pid);
    if (pid == 0) {
        _ = linux.dup2(requests[0], 0);
        _ = linux.dup2(responses[1], 1);
        _ = linux.execve(argv[0].?, &argv, &.{null});
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

pub fn stop(strategy: *Strategy) void {
    assert(strategy.pid > 0);
    _ = linux.close(strategy.to_plugin); // The plugin sees end of input and exits.
    _ = linux.close(strategy.from_plugin);
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
    std.debug.print("[determinismo] strategy: {s}\n", .{name.string});
}

pub fn branch(strategy: *Strategy, index: u32, seed: u64) !void {
    var writer: std.Io.Writer = .fixed(&strategy.request);
    const format = "{{\"method\":\"branch\",\"index\":{d},\"seed\":\"{x:0>16}\"}}";
    try writer.print(format, .{ index, seed });
    _ = try strategy.call(writer.buffered());
}

/// Offers the plugin a decision. Returns true when it overrode `value` (which on entry holds
/// the default and on return holds the answer).
pub fn random(
    strategy: *Strategy,
    pull: u64,
    moment: Events.Moment,
    source: []const u8,
    value: []u8,
) !bool {
    assert(value.len > 0);
    var writer: std.Io.Writer = .fixed(&strategy.request);
    try writer.print("{{\"method\":\"random\",\"pull\":{d},\"size\":{d},\"default\":\"", .{
        pull, value.len,
    });
    for (value) |byte| try writer.print("{x:0>2}", .{byte});
    try writer.print("\",\"source\":{f},\"vtime_ns\":{d},\"branches\":{d}}}", .{
        std.json.fmt(source, .{}), moment.vtime_ns, moment.branches,
    });
    const reply = try strategy.call(writer.buffered());
    const hex = reply.get("hex") orelse return false;
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
    assert(request.len > 0);
    assert(request.len < line_size_max);
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
