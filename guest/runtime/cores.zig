// SPDX-License-Identifier: MIT
//! det-core <pid> <command name> <signal>: the kernel's core dump handler (det-init sets
//! core_pattern to it). It keeps the core of a crashed process, from any node, in
//! /run/det/cores/<node>-<command>-<pid>.core (up to cores_size_max, the rest dropped) and
//! emits a `core_dump` event naming it, so that `determinismo extract --file
//! runner:<path>` takes it out at any later moment of the timeline, for gdb and the like.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");

const cores_directory = "/run/det/cores";
const cores_size_max = 256 * 1024 * 1024;
const name_size_max = 64;

pub fn main(init: std.process.Init) !u8 {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len != 4) return 2;
    const pid = std.fmt.parseInt(linux.pid_t, arguments[1], 10) catch return 2;
    const signal = std.fmt.parseInt(u32, arguments[3], 10) catch return 2;
    var command_buffer: [name_size_max]u8 = undefined;
    const command = sanitized(&command_buffer, arguments[2]);
    var node_buffer: [name_size_max]u8 = undefined;
    const node = node_of(pid, &node_buffer);
    var path_buffer: [256]u8 = undefined;
    const format = cores_directory ++ "/{s}-{s}-{d}.core";
    const path = try std.fmt.bufPrintSentinel(&path_buffer, format, .{ node, command, pid }, 0);
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const fd = linux.open(path, flags, 0o600);
    if (linux.errno(fd) != .SUCCESS) return 1;
    defer _ = linux.close(@intCast(fd));
    var size: u64 = 0;
    var dropped: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const read = linux.read(0, &buffer, buffer.len);
        if (linux.errno(read) != .SUCCESS or read == 0) break;
        // The whole dump is read, so that the kernel finishes it; what does not fit is dropped.
        const kept = @min(read, cores_size_max - size);
        if (kept < read) dropped += read - kept;
        if (kept > 0 and !write_all(@intCast(fd), buffer[0..kept])) break;
        size += kept;
    }
    sdk.event("core_dump", .{
        .node = node,
        .pid = pid,
        .command = command,
        .signal = signal,
        .path = path,
        .size = size,
        .dropped = dropped,
    });
    return 0;
}

/// The node whose cgroup holds the process (/proc/<pid>/cgroup: "0::/nodes/<node>/..."), else
/// "runner".
fn node_of(pid: linux.pid_t, buffer: *[name_size_max]u8) []const u8 {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/cgroup", .{pid}, 0) catch
        return "runner";
    var text_buffer: [512]u8 = undefined;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return "runner";
    defer _ = linux.close(@intCast(fd));
    const read = linux.read(@intCast(fd), &text_buffer, text_buffer.len);
    if (linux.errno(read) != .SUCCESS) return "runner";
    return node_from_cgroup(text_buffer[0..read], buffer);
}

fn node_from_cgroup(text: []const u8, buffer: *[name_size_max]u8) []const u8 {
    const prefix = "0::/nodes/";
    const at = std.mem.indexOf(u8, text, prefix) orelse return "runner";
    const rest = text[at + prefix.len ..];
    const end = std.mem.indexOfAny(u8, rest, "/\n") orelse rest.len;
    if (end == 0) return "runner";
    return sanitized(buffer, rest[0..end]);
}

/// Letters, digits, '.', '_' and '-' kept, anything else '_': a file name piece.
fn sanitized(buffer: *[name_size_max]u8, text: []const u8) []const u8 {
    const size = @min(text.len, buffer.len);
    for (text[0..size], buffer[0..size]) |byte, *out| {
        const keep = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-';
        out.* = if (keep) byte else '_';
    }
    return buffer[0..size];
}

fn write_all(fd: linux.fd_t, bytes: []const u8) bool {
    var written: usize = 0;
    while (written < bytes.len) {
        const result = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        if (linux.errno(result) != .SUCCESS) return false;
        written += result;
    }
    return true;
}

test node_from_cgroup {
    var buffer: [name_size_max]u8 = undefined;
    try std.testing.expectEqualStrings("redis", node_from_cgroup("0::/nodes/redis\n", &buffer));
    const pod = "0::/nodes/k3s-agent/kubepods/burstable/pod1\n";
    try std.testing.expectEqualStrings("k3s-agent", node_from_cgroup(pod, &buffer));
    try std.testing.expectEqualStrings("runner", node_from_cgroup("0::/\n", &buffer));
    try std.testing.expectEqualStrings("a_b", sanitized(&buffer, "a/b"));
}
