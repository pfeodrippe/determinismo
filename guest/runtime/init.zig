// SPDX-License-Identifier: MIT
//! det-init: PID 1 of the determinismo guest.
//!
//! Mounts the kernel filesystems, loads the guest modules, mounts the system disk (/dev/vda, the
//! test program and /det/system.json) and starts the nodes. Then it runs, by kernel parameter:
//!   det.scenario=<name>   one timeline of that scenario (det-composer)
//!   det.exec=<command>    a shell command instead (debugging; spaces as %20)
//! It reaps every orphan meanwhile (node processes outlive the det-nodes that started them), and
//! reboots at the end, which ends the VM run.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");
const nodes = @import("nodes.zig");

const bin = "/opt/determinismo/bin/";
const modules_directory = "/opt/determinismo/modules/";
/// In load order. The guest kernel (guest/kernel/) has everything else built in.
const modules = [_][]const u8{"det_guest"};
const disk_attempts_max = 1000;
const cmdline_size_max = 4096;
const command_size_max = 1024;

pub const environment = [_:null]?[*:0]const u8{
    "PATH=" ++ bin ++ ":/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "HOME=/root",
};

pub fn main(init: std.process.Init) !void {
    assert(linux.getpid() == 1);
    const arena = init.arena.allocator();
    system_mount();
    var cmdline_buffer: [cmdline_size_max]u8 = undefined;
    const cmdline = read_cmdline(&cmdline_buffer);
    for (modules) |module| module_load(module, cmdline);
    _ = spawn(&.{bin ++ "det-agent"}); // Multiverse debugging; asleep unless pushed to.
    const status = run(arena, cmdline);
    std.debug.print("[guest] done, status {d}\n", .{status});
    for (node_names) |name| {
        if (nodes.pid_of(name) != null) sdk.always(true, node_exit_property, .{ .node = name });
    }
    sdk.lifecycle("guest_done", .{ .status = status });
    reap_all();
    _ = linux.sync();
    _ = linux.reboot(.MAGIC1, .MAGIC2, .RESTART, null);
    unreachable;
}

fn run(arena: std.mem.Allocator, cmdline: []const u8) u32 {
    if (!disk_mount()) {
        std.debug.print("[guest] no system disk\n", .{});
        if (parameter(cmdline, "det.exec")) |command| return shell(arena, command);
        return 1;
    }
    if (nodes.system_load(arena)) |system| {
        const names = arena.alloc([]const u8, system.nodes.len) catch return 1;
        for (system.nodes, names) |node, *name| name.* = node.name;
        node_names = names;
    } else |_| {}
    const pid_up = spawn(&.{ bin ++ "det-nodes", "up" });
    const status_up = wait_for(pid_up);
    if (status_up != 0) {
        std.debug.print("[guest] nodes failed to start ({d}); their output:\n", .{status_up});
        const dump = "for log in /run/det/nodes/*/output.log; do " ++
            "echo \"== $log\"; cat \"$log\"; done";
        _ = wait_for(spawn(&.{ "/bin/sh", "-c", dump }));
        return status_up;
    }
    if (parameter(cmdline, "det.exec")) |command| return shell(arena, command);
    const scenario = parameter(cmdline, "det.scenario") orelse {
        std.debug.print("[guest] no det.scenario= or det.exec= given\n", .{});
        return 1;
    };
    const scenario_z = arena.dupeSentinel(u8, scenario, 0) catch return 1;
    return wait_for(spawn(&.{ bin ++ "det-composer", "--scenario", scenario_z }));
}

fn shell(arena: std.mem.Allocator, encoded: []const u8) u32 {
    const command = arena.allocSentinel(u8, encoded.len, 0) catch return 1;
    const size = std.mem.replacementSize(u8, encoded, "%20", " ");
    _ = std.mem.replace(u8, encoded, "%20", " ", command);
    command[size] = 0;
    return wait_for(spawn(&.{ "/bin/sh", "-c", command[0..size :0] }));
}

fn system_mount() void {
    const Mount = struct { fs: [*:0]const u8, target: [:0]const u8, data: ?[*:0]const u8 = null };
    const mounts = [_]Mount{
        .{ .fs = "proc", .target = "/proc" },
        .{ .fs = "sysfs", .target = "/sys" },
        .{ .fs = "devtmpfs", .target = "/dev" },
        .{ .fs = "devpts", .target = "/dev/pts" },
        .{ .fs = "tmpfs", .target = "/dev/shm" },
        .{ .fs = "tmpfs", .target = "/run" },
        .{ .fs = "tmpfs", .target = "/tmp" },
        .{ .fs = "cgroup2", .target = "/sys/fs/cgroup" },
    };
    for (mounts) |entry| {
        nodes.mkdir_all(entry.target) catch {};
        const data = if (entry.data) |d| @intFromPtr(d) else 0;
        const result = linux.mount(entry.fs, entry.target, entry.fs, 0, data);
        if (linux.errno(result) != .SUCCESS) {
            const errno = @tagName(linux.errno(result));
            std.debug.print("[guest] mount {s}: {s}\n", .{ entry.target, errno });
        }
    }
    var socket = @import("netlink.zig").Socket.open() catch return;
    defer socket.close();
    socket.link_set("lo", .up) catch {};
    _ = linux.syscall2(.sethostname, @intFromPtr("runner"), "runner".len);
}

/// Loads a module with its `<module>.<parameter>=` words from the kernel command line (what
/// modprobe would pass; the kernel applies them only to built-in code).
fn module_load(name: []const u8, cmdline: []const u8) void {
    var parameters_buffer: [cmdline_size_max]u8 = undefined;
    const parameters = module_parameters(&parameters_buffer, name, cmdline);
    var buffer: [128]u8 = undefined;
    const path = nodes.print_z(&buffer, modules_directory ++ "{s}.ko", .{name}) catch unreachable;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return; // Not shipped in this initramfs.
    defer _ = linux.close(@intCast(fd));
    const result = linux.syscall3(.finit_module, @intCast(fd), @intFromPtr(parameters.ptr), 0);
    switch (linux.errno(result)) {
        .SUCCESS, .EXIST => {},
        else => |errno| std.debug.print("[guest] module {s}: {s}\n", .{ name, @tagName(errno) }),
    }
}

fn module_parameters(
    buffer: *[cmdline_size_max]u8,
    name: []const u8,
    cmdline: []const u8,
) [:0]u8 {
    var size: usize = 0;
    var words = std.mem.tokenizeScalar(u8, cmdline, ' ');
    while (words.next()) |word| {
        if (word.len <= name.len + 1 or word[name.len] != '.') continue;
        if (!std.mem.startsWith(u8, word, name)) continue;
        const setting = word[name.len + 1 ..];
        if (size + setting.len + 2 > buffer.len) break;
        if (size > 0) {
            buffer[size] = ' ';
            size += 1;
        }
        @memcpy(buffer[size..][0..setting.len], setting);
        size += setting.len;
    }
    buffer[size] = 0;
    return buffer[0..size :0];
}

/// The system disk appears once virtio_mmio has probed it.
fn disk_mount() bool {
    nodes.mkdir_all("/det") catch return false;
    for (0..disk_attempts_max) |_| {
        const result = linux.mount("/dev/vda", "/det", "erofs", linux.MS.RDONLY, 0);
        switch (linux.errno(result)) {
            .SUCCESS => return true,
            .NOENT, .NXIO => nodes.sleep_ns(std.time.ns_per_ms),
            else => |errno| {
                std.debug.print("[guest] mount /dev/vda: {s}\n", .{@tagName(errno)});
                return false;
            },
        }
    }
    return false;
}

fn read_cmdline(buffer: []u8) []const u8 {
    const fd = linux.open("/proc/cmdline", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return "";
    defer _ = linux.close(@intCast(fd));
    const size = linux.read(@intCast(fd), buffer.ptr, buffer.len);
    if (linux.errno(size) != .SUCCESS) return "";
    return std.mem.trim(u8, buffer[0..size], " \n");
}

fn parameter(cmdline: []const u8, comptime key: []const u8) ?[]const u8 {
    var words = std.mem.tokenizeScalar(u8, cmdline, ' ');
    while (words.next()) |word| {
        if (std.mem.startsWith(u8, word, key ++ "=")) return word[key.len + 1 ..];
    }
    return null;
}

const spawn_arguments_max = 4;

fn spawn(arguments: []const [*:0]const u8) linux.pid_t {
    assert(arguments.len >= 1 and arguments.len <= spawn_arguments_max);
    const result = linux.fork();
    assert(linux.errno(result) == .SUCCESS);
    if (result == 0) {
        var argv: [spawn_arguments_max:null]?[*:0]const u8 = @splat(null);
        for (arguments, 0..) |argument, index| argv[index] = argument;
        _ = linux.execve(arguments[0], &argv, &environment);
        linux.exit_group(127);
    }
    return @intCast(result);
}

/// Waits for `pid`, reaping any orphan that exits meanwhile.
fn wait_for(pid: linux.pid_t) u32 {
    while (true) {
        var status: i32 = 0;
        const result = linux.wait4(-1, &status, 0, null);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS) return 127;
        const bits: u32 = @bitCast(status);
        if (@as(linux.pid_t, @intCast(result)) != pid) {
            orphan_reaped(@intCast(result), bits);
            continue;
        }
        if (bits & 0x7f == 0) return (bits >> 8) & 0xff;
        return 128 + (bits & 0x7f);
    }
}

/// Built-in property: a node's main process never exits on its own. Faults that kill a node
/// remove its pidfile first, so an exit of the process a pidfile names is unexpected.
const node_exit_property = "nodes do not exit unexpectedly";
var node_names: []const []const u8 = &.{};

fn orphan_reaped(pid: linux.pid_t, status: u32) void {
    for (node_names) |name| {
        if (nodes.pid_recorded(name) != pid) continue;
        const code = if (status & 0x7f == 0) (status >> 8) & 0xff else 128 + (status & 0x7f);
        sdk.always(false, node_exit_property, .{ .node = name, .status = code });
        return;
    }
}

fn reap_all() void {
    while (true) {
        var status: i32 = 0;
        const result = linux.wait4(-1, &status, linux.W.NOHANG, null);
        if (linux.errno(result) != .SUCCESS or result == 0) return;
    }
}

test module_parameters {
    var buffer: [cmdline_size_max]u8 = undefined;
    const cmdline = "quiet virtio_mmio.device=4K@0xd0000000:6 virtio_mmio_x.a=1 " ++
        "virtio_mmio.device=4K@0xd0001000:6";
    const parameters = module_parameters(&buffer, "virtio_mmio", cmdline);
    try std.testing.expectEqualStrings("device=4K@0xd0000000:6 device=4K@0xd0001000:6", parameters);
}

test parameter {
    const cmdline = "console=ttyS0 det.scenario=bank det.exec=ls%20-la";
    try std.testing.expectEqualStrings("bank", parameter(cmdline, "det.scenario").?);
    try std.testing.expectEqualStrings("ls%20-la", parameter(cmdline, "det.exec").?);
    try std.testing.expect(parameter(cmdline, "det.missing") == null);
}
