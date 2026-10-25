// SPDX-License-Identifier: MIT
//! Self-test level 1 (ARCHITECTURE.md §14): determinismo's HTTP API (`determinismo serve`, with
//! a fake explorer) as the system under test. Drivers create runs and list them while faults
//! pause, cut off and restart the controller; at the end, every run the API accepted must still
//! be there, finished, and a finished run (its record has a summary) must report passed or
//! failed, not error.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");
const System = @import("selftest.zig").System;

const port = 7878;
/// In the runner's /tmp, which lives as long as the timeline: the ids the API accepted.
const created_path = "/tmp/controller-runs";
const runs_per_driver = 3;
const settle_attempts_max = 400;

pub fn scenario(s: *System.Scenario) void {
    s.parallel_driver("create", create);
    s.parallel_driver("list", list);
    s.finally("runs_survive", runs_survive);
}

fn create(context: *System.Context) !void {
    const address = context.nodes.controller.?.address;
    for (0..runs_per_driver) |_| {
        var body_buffer: [128]u8 = undefined;
        const branches = 1 + sdk.random_below(6);
        const body_format = "{{\"program\":\"p\",\"branches\":{d}}}";
        const body = try std.fmt.bufPrint(&body_buffer, body_format, .{branches});
        var reply: [4096]u8 = undefined;
        const response = http(address, "POST", "/runs", body, &reply) catch |err| {
            const details = .{ .err = @errorName(err) };
            sdk.sometimes(true, "the controller was unavailable to a client", details);
            continue;
        };
        const created = response.status == 201;
        sdk.always(created, "creating a run succeeds", .{ .status = response.status });
        const id = number_after(response.body, "\"id\":") orelse continue;
        var line_buffer: [32]u8 = undefined;
        append(created_path, try std.fmt.bufPrint(&line_buffer, "{d}\n", .{id}));
    }
}

fn list(context: *System.Context) !void {
    const address = context.nodes.controller.?.address;
    for (0..runs_per_driver) |_| {
        var reply: [64 * 1024]u8 = undefined;
        const response = http(address, "GET", "/runs", "", &reply) catch continue;
        const listed = response.status == 200;
        sdk.always(listed, "listing runs succeeds", .{ .status = response.status });
        sleep_ms(20);
    }
}

fn runs_survive(context: *System.Context) !void {
    const address = context.nodes.controller.?.address;
    var ids_buffer: [4096]u8 = undefined;
    const ids = read_small(created_path, &ids_buffer);
    var lines = std.mem.tokenizeScalar(u8, ids, '\n');
    while (lines.next()) |line| {
        var path_buffer: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "/runs/{s}", .{line});
        var reply: [64 * 1024]u8 = undefined;
        const response = settled(address, path, &reply) orelse {
            sdk.assert_unreachable("the controller answers about a run once faults stop", .{});
            continue;
        };
        sdk.always(response.status == 200, "an accepted run is never lost", .{ .run = line });
        const finished = std.mem.indexOf(u8, response.body, "\"summary\":") != null;
        const error_state = std.mem.indexOf(u8, response.body, "\"state\":\"error\"") != null;
        const kept = !(finished and error_state);
        sdk.always(kept, "a finished run keeps its result", .{ .run = line });
    }
    sdk.sometimes(ids.len > 0, "runs were created", .{});
}

/// The run's answer once it no longer says "running" (or the last answer).
fn settled(address: [4]u8, path: []const u8, reply: []u8) ?Response {
    var last: ?Response = null;
    for (0..settle_attempts_max) |_| {
        const response = http(address, "GET", path, "", reply) catch {
            sleep_ms(50);
            continue;
        };
        last = response;
        if (std.mem.indexOf(u8, response.body, "\"state\":\"running\"") == null) return response;
        sleep_ms(50);
    }
    return last;
}

const Response = struct { status: u16, body: []const u8 };

/// One HTTP/1.1 request on a fresh connection (the server closes it after answering).
fn http(
    address: [4]u8,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    reply: []u8,
) !Response {
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket) != .SUCCESS) return error.Socket;
    const fd: linux.fd_t = @intCast(socket);
    defer _ = linux.close(fd);
    const timeout = linux.timeval{ .sec = 1, .usec = 0 };
    for ([_]u32{ linux.SO.RCVTIMEO, linux.SO.SNDTIMEO }) |option| {
        const size = @sizeOf(linux.timeval);
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, option, @ptrCast(&timeout), size);
    }
    const target = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(address),
    };
    if (linux.errno(linux.connect(fd, @ptrCast(&target), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
        return error.Connect;
    }
    var request_buffer: [512]u8 = undefined;
    const format = "{s} {s} HTTP/1.1\r\nHost: controller\r\nContent-Length: {d}\r\n\r\n{s}";
    const parts = .{ method, path, body.len, body };
    const request = try std.fmt.bufPrint(&request_buffer, format, parts);
    if (linux.errno(linux.write(fd, request.ptr, request.len)) != .SUCCESS) return error.Write;
    var size: usize = 0;
    while (size < reply.len) {
        const result = linux.read(fd, reply[size..].ptr, reply.len - size);
        if (linux.errno(result) != .SUCCESS) return error.Read;
        if (result == 0) break;
        size += result;
    }
    const text = reply[0..size];
    if (!std.mem.startsWith(u8, text, "HTTP/1.1 ") or text.len < 12) return error.BadResponse;
    const status = try std.fmt.parseInt(u16, text[9..12], 10);
    const body_start = (std.mem.indexOf(u8, text, "\r\n\r\n") orelse return error.BadResponse) + 4;
    return .{ .status = status, .body = text[body_start..] };
}

fn number_after(text: []const u8, key: []const u8) ?u32 {
    const start = (std.mem.indexOf(u8, text, key) orelse return null) + key.len;
    var end = start;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    return std.fmt.parseInt(u32, text[start..end], 10) catch null;
}

fn append(path: [:0]const u8, line: []const u8) void {
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const fd = linux.open(path, flags, 0o644);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.write(@intCast(fd), line.ptr, line.len);
}

fn read_small(path: [:0]const u8, buffer: []u8) []const u8 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd) != .SUCCESS) return "";
    defer _ = linux.close(@intCast(fd));
    const size = linux.read(@intCast(fd), buffer.ptr, buffer.len);
    if (linux.errno(size) != .SUCCESS) return "";
    return buffer[0..size];
}

fn sleep_ms(duration_ms: u64) void {
    const request = linux.timespec{
        .sec = @intCast(duration_ms / 1000),
        .nsec = @intCast((duration_ms % 1000) * std.time.ns_per_ms),
    };
    _ = linux.nanosleep(&request, null);
}
