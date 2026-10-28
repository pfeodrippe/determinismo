// SPDX-License-Identifier: MIT
//! det-podlogs: a Kubernetes node's pods' output as events (`explore --kubernetes`,
//! src/kubernetes.zig starts it in the K3s node with the setup). Kubelet writes each container's
//! output to /var/log/pods/<namespace>_<pod>_<uid>/<container>/<restart>.log, a line each
//! (`<time> stdout|stderr F|P <text>`, CRI's format: P for a part of a longer line); this follows
//! every such file (follow.zig) and sends its lines as `{"output":{"source":<pod>,...}}`, as
//! Antithesis names a pod's log lines after it. Through the forwarder's batching (output.zig): a
//! Go panic in a pod fails "no panics (Go)" as in any node.
//!
//! Usage: det-podlogs [<directory>]   (/var/log/pods by default)
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo");
const follow = @import("follow.zig");

const files_max = 256;
const poll_ns = 50 * std.time.ns_per_ms;
const polls_max = 1 << 40;

var files: [files_max]follow.File = undefined;
var files_count: usize = 0;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    const root = if (arguments.len > 1) arguments[1] else "/var/log/pods";
    const device_result = linux.open(sdk.device_path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(device_result) != .SUCCESS) return error.NoDevice; // Not in determinismo.
    const device: linux.fd_t = @intCast(device_result);
    // Detached: it outlives the setup command that starts it (src/kubernetes.zig).
    const child = linux.fork();
    if (linux.errno(child) != .SUCCESS) return error.Fork;
    if (child != 0) return;
    _ = linux.setsid();
    for (0..polls_max) |_| {
        scan(root);
        for (files[0..files_count]) |*file| file.follow(device);
        const request = linux.timespec{ .sec = 0, .nsec = poll_ns };
        _ = linux.nanosleep(&request, null);
    }
}

/// Every log file under `root`, followed from its start (a pod's whole output) once found.
fn scan(root: []const u8) void {
    var pods = follow.Entries.of(root);
    while (pods.next()) |pod_directory| {
        if (!pod_directory.directory) continue;
        const pod = pod_name(pod_directory.name) orelse continue;
        var pod_buffer: [follow.path_size_max]u8 = undefined;
        const pod_path = std.fmt.bufPrint(&pod_buffer, "{s}/{s}", .{ root, pod_directory.name }) catch continue;
        var containers = follow.Entries.of(pod_path);
        while (containers.next()) |container| {
            if (!container.directory) continue;
            var container_buffer: [follow.path_size_max]u8 = undefined;
            const container_path = std.fmt.bufPrint(&container_buffer, "{s}/{s}", .{ pod_path, container.name }) catch continue;
            var logs = follow.Entries.of(container_path);
            while (logs.next()) |log| {
                if (log.directory or !std.mem.endsWith(u8, log.name, ".log")) continue;
                var log_buffer: [follow.path_size_max]u8 = undefined;
                const log_path = std.fmt.bufPrint(&log_buffer, "{s}/{s}", .{ container_path, log.name }) catch continue;
                note(log_path, pod);
            }
        }
    }
}

fn note(path: []const u8, pod: []const u8) void {
    for (files[0..files_count]) |*file| {
        if (std.mem.eql(u8, file.path(), path)) return;
    }
    if (files_count == files_max) return;
    files[files_count].init(path, pod, .cri) catch return;
    files_count += 1;
}

/// "<namespace>_<pod>_<uid>": the pod.
fn pod_name(directory: []const u8) ?[]const u8 {
    const first = std.mem.indexOfScalar(u8, directory, '_') orelse return null;
    const last = std.mem.lastIndexOfScalar(u8, directory, '_') orelse return null;
    if (last <= first + 1) return null;
    return directory[first + 1 .. last];
}

test pod_name {
    try std.testing.expectEqualStrings("redis-0", pod_name("default_redis-0_8f7c9f3b-8f51-48bf").?);
    try std.testing.expectEqualStrings("client-688f97d7cf-lwfqw", pod_name("ns_client-688f97d7cf-lwfqw_uid").?);
    try std.testing.expectEqual(@as(?[]const u8, null), pod_name("nounderscore"));
}
