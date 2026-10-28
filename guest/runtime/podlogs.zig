// SPDX-License-Identifier: MIT
//! det-podlogs: a Kubernetes node's pods' output as events (`explore --kubernetes`,
//! src/kubernetes.zig starts it in the K3s node with the setup). Kubelet writes each container's
//! output to /var/log/pods/<namespace>_<pod>_<uid>/<container>/<restart>.log, a line each
//! (`<time> stdout|stderr F|P <text>`, CRI's format: P for a part of a longer line); this follows
//! every such file (follow.zig) and sends its lines as `{"output":{"source":<pod>,...}}`, as
//! Antithesis names a pod's log lines after it. Through the forwarder's batching (output.zig): a
//! Go panic in a pod fails "no panics (Go)" as in any node.
//!
//! And the pods' containers' exits, as Antithesis judges a container's ("no unexpected container
//! exits": 0, SIGKILL's 137 and SIGTERM's 143 expected): containerd's task exits (`ctr events`,
//! K3s's: `k3s ctr` is no subcommand), each container named by kubelet's /var/log/containers/<pod>_<namespace>_<container>-
//! <id>.log (a pod's sandbox has none: not a container of the system).
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
    var exits: Exits = .{};
    for (0..polls_max) |poll| {
        scan(root);
        for (files[0..files_count]) |*file| file.follow(device);
        exits.follow(poll);
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

const container_exit_property = "no unexpected container exits";
/// K3s's ctr: a link to the k3s binary, which runs the tool it is called as.
const ctr_path = "/bin/ctr";
const containers_directory = "/var/log/containers";

/// `ctr events`, read as it goes: started again when it ends (K3s restarting), a second
/// apart at most.
const Exits = struct {
    fd: ?linux.fd_t = null,
    pid: linux.pid_t = 0,
    started_poll: u64 = 0,
    buffer: [16384]u8 = undefined,
    size: usize = 0,

    fn follow(exits: *Exits, poll: u64) void {
        if (exits.fd == null) {
            if (exits.started_poll != 0 and poll < exits.started_poll + 20) return;
            exits.start(poll);
            return;
        }
        while (true) {
            if (exits.size == exits.buffer.len) exits.size = 0; // A line too long: dropped.
            const result = linux.read(exits.fd.?, exits.buffer[exits.size..].ptr, exits.buffer.len - exits.size);
            const errno = linux.errno(result);
            if (errno == .AGAIN) break;
            if (errno != .SUCCESS or result == 0) {
                exits.stop();
                break;
            }
            exits.size += result;
            exits.lines();
        }
    }

    fn start(exits: *Exits, poll: u64) void {
        exits.started_poll = poll;
        var ends: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&ends, .{ .CLOEXEC = true, .NONBLOCK = true })) != .SUCCESS) return;
        const child = linux.fork();
        if (linux.errno(child) != .SUCCESS) {
            _ = linux.close(ends[0]);
            _ = linux.close(ends[1]);
            return;
        }
        if (child == 0) {
            _ = linux.dup2(ends[1], 1);
            const argv = [_:null]?[*:0]const u8{ "ctr", "-n", "k8s.io", "events" };
            const envp = [_:null]?[*:0]const u8{"PATH=/bin:/usr/bin:/sbin:/usr/sbin"};
            _ = linux.execve(ctr_path, &argv, &envp);
            linux.exit(127);
        }
        _ = linux.close(ends[1]);
        exits.fd = ends[0];
        exits.pid = @intCast(child);
        exits.size = 0;
    }

    fn stop(exits: *Exits) void {
        _ = linux.close(exits.fd.?);
        exits.fd = null;
        var status: i32 = 0;
        _ = linux.waitpid(exits.pid, &status, 0);
    }

    fn lines(exits: *Exits) void {
        var at: usize = 0;
        while (std.mem.indexOfScalarPos(u8, exits.buffer[0..exits.size], at, '\n')) |end| {
            exit_judge(exits.buffer[at..end]);
            at = end + 1;
        }
        std.mem.copyForwards(u8, exits.buffer[0 .. exits.size - at], exits.buffer[at..exits.size]);
        exits.size -= at;
    }
};

const TaskExit = struct { container_id: []const u8 = "", id: []const u8 = "", exit_status: u32 = 0 };

/// One line of `ctr events`: "<time> <namespace> /tasks/exit {...}" judged when it is a
/// container's own process (an exec's, a template command's, has its own id) and a container of
/// a pod (not its sandbox).
fn exit_judge(line: []const u8) void {
    const topic = std.mem.indexOf(u8, line, " /tasks/exit ") orelse return;
    const brace = std.mem.indexOfScalarPos(u8, line, topic, '{') orelse return;
    var memory: [4096]u8 = undefined;
    var allocator: std.heap.FixedBufferAllocator = .init(&memory);
    const exit = std.json.parseFromSliceLeaky(TaskExit, allocator.allocator(), line[brace..], .{
        .ignore_unknown_fields = true,
    }) catch return;
    if (exit.container_id.len == 0 or !std.mem.eql(u8, exit.container_id, exit.id)) return;
    var name_buffer: [follow.path_size_max]u8 = undefined;
    const container = container_named(exit.container_id, &name_buffer) orelse return;
    const status = exit.exit_status;
    const expected = status == 0 or status == 128 + 9 or status == 128 + 15;
    sdk.assert_computed(.always, expected, container_exit_property, .{
        .pod = container.pod,
        .namespace = container.namespace,
        .container = container.name,
        .status = status,
    });
}

const Container = struct { pod: []const u8, namespace: []const u8, name: []const u8 };

/// A container's pod, namespace and name, from kubelet's link to its log.
fn container_named(id: []const u8, buffer: []u8) ?Container {
    var entries = follow.Entries.of(containers_directory);
    while (entries.next()) |entry| {
        if (container_parse(entry.name, id) == null) continue;
        if (entry.name.len > buffer.len) return null;
        @memcpy(buffer[0..entry.name.len], entry.name);
        return container_parse(buffer[0..entry.name.len], id);
    }
    return null;
}

/// "<pod>_<namespace>_<container>-<id>.log" (no part has an underscore: RFC 1123 names).
fn container_parse(file: []const u8, id: []const u8) ?Container {
    if (!std.mem.endsWith(u8, file, ".log")) return null;
    const stem = file[0 .. file.len - ".log".len];
    if (stem.len <= id.len + 1 or !std.mem.endsWith(u8, stem, id) or stem[stem.len - id.len - 1] != '-') return null;
    const named = stem[0 .. stem.len - id.len - 1];
    var parts = std.mem.splitScalar(u8, named, '_');
    const pod = parts.next() orelse return null;
    const namespace = parts.next() orelse return null;
    const container = parts.rest();
    if (pod.len == 0 or namespace.len == 0 or container.len == 0) return null;
    return .{ .pod = pod, .namespace = namespace, .name = container };
}

test container_parse {
    const parsed = container_parse("redis-0_default_redis-0123abcd.log", "0123abcd").?;
    try std.testing.expectEqualStrings("redis-0", parsed.pod);
    try std.testing.expectEqualStrings("default", parsed.namespace);
    try std.testing.expectEqualStrings("redis", parsed.name);
    try std.testing.expectEqual(@as(?Container, null), container_parse("redis-0_default_redis-ffff.log", "0123abcd"));
}

test pod_name {
    try std.testing.expectEqualStrings("redis-0", pod_name("default_redis-0_8f7c9f3b-8f51-48bf").?);
    try std.testing.expectEqualStrings("client-688f97d7cf-lwfqw", pod_name("ns_client-688f97d7cf-lwfqw_uid").?);
    try std.testing.expectEqual(@as(?[]const u8, null), pod_name("nounderscore"));
}
