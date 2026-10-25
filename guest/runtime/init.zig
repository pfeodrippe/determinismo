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
    cores_setup();
    var cmdline_buffer: [cmdline_size_max]u8 = undefined;
    const cmdline = read_cmdline(&cmdline_buffer);
    for (modules) |module| module_load(module, cmdline);
    sdk_output_mount();
    _ = spawn(&.{bin ++ "det-agent"}); // Multiverse debugging; asleep unless pushed to.
    const status = run(arena, cmdline);
    std.debug.print("[guest] done, status {d}\n", .{status});
    for (node_names) |name| {
        if (nodes.pid_of(name) != null) sdk.always(true, node_exit_property, .{ .node = name });
    }
    kernel_check();
    memory_check();
    agent_wait();
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

/// Core dumps of any process, in any node, go to det-core (cores.zig), which keeps them in
/// /run/det/cores for `determinismo extract --file runner:/run/det/cores/...`.
fn cores_setup() void {
    nodes.mkdir_all("/run/det/cores") catch {};
    const pattern = "|" ++ bin ++ "det-core %P %e %s";
    nodes.file_write("/proc/sys/kernel/core_pattern", pattern) catch |err| {
        std.debug.print("[guest] core_pattern: {s}\n", .{@errorName(err)});
    };
}

/// The SDK output as a regular file (detfs, from det_guest): /opt/determinismo/sdk/output, in
/// the runner and (through /opt/determinismo) in every node. For SDKs that truncate their
/// output file, which /dev/determinismo cannot be (Antithesis's Go SDK).
pub const sdk_output_path = "/opt/determinismo/sdk/output";

fn sdk_output_mount() void {
    const directory = "/opt/determinismo/sdk";
    _ = linux.mkdir(directory, 0o755);
    const result = linux.mount("detfs", directory, "detfs", 0, 0);
    if (linux.errno(result) != .SUCCESS) {
        std.debug.print("[guest] detfs: {s}\n", .{@tagName(linux.errno(result))});
    }
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
    return read_text("/proc/cmdline", buffer);
}

/// A small file's text (what fits in `buffer`), trimmed; empty if it cannot be read.
fn read_text(path: [*:0]const u8, buffer: []u8) []const u8 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
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
        // As Antithesis's "no unexpected container exits": 0, SIGKILL and SIGTERM are expected;
        // and any exit while the node's disk fails (giving up on I/O errors is legitimate).
        const signaled = code == 128 + 9 or code == 128 + 15;
        const expected = code == 0 or signaled or nodes.disk_failing(name);
        sdk.always(expected, node_exit_property, .{ .node = name, .status = code });
        return;
    }
}

/// Built-in properties from the kernel's log (all of it, whatever the console shows), read
/// once when the timeline ends: no OOM kills, no process killed by an error signal (Antithesis's
/// "no unexpected crashes"), and no warnings, BUGs, oopses or hung tasks.
const oom_property = "the kernel kills no process for lack of memory";
const crash_property = "no process crashes (segfault, illegal instruction, ...)";
const kernel_property = "the kernel reports no warnings, BUGs or hung tasks";
const kmsg_records_max = 1 << 16;

const KernelProblem = enum { oom_kill, crash, kernel };

fn kernel_check() void {
    var seen = std.EnumArray(KernelProblem, bool).initFill(false);
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true };
    const fd = linux.open("/dev/kmsg", flags, 0);
    if (linux.errno(fd) == .SUCCESS) {
        defer _ = linux.close(@intCast(fd));
        var buffer: [8192]u8 = undefined;
        for (0..kmsg_records_max) |_| {
            const size = linux.read(@intCast(fd), &buffer, buffer.len);
            switch (linux.errno(size)) {
                .SUCCESS => {},
                .PIPE => continue, // Overwritten while reading: the next record follows.
                else => break, // AGAIN: the whole log has been read.
            }
            const record = kmsg_record(buffer[0..size]) orelse continue;
            const problem = kernel_problem(record.text) orelse continue;
            seen.set(problem, true);
            const property = switch (problem) {
                .oom_kill => oom_property,
                .crash => crash_property,
                .kernel => kernel_property,
            };
            const details = .{ .kernel_us = record.time_us, .line = record.text };
            sdk.assert_computed(.always, false, property, details);
        }
    }
    if (!seen.get(.oom_kill)) sdk.always(true, oom_property, .{});
    if (!seen.get(.crash)) sdk.always(true, crash_property, .{});
    if (!seen.get(.kernel)) sdk.always(true, kernel_property, .{});
}

const KmsgRecord = struct { time_us: u64, text: []const u8 };

/// "<priority>,<sequence>,<microseconds>,<flags>;<text>\n" and continuation lines.
fn kmsg_record(record: []const u8) ?KmsgRecord {
    const separator = std.mem.indexOfScalar(u8, record, ';') orelse return null;
    var fields = std.mem.splitScalar(u8, record[0..separator], ',');
    _ = fields.next() orelse return null;
    _ = fields.next() orelse return null;
    const time_us = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
    const rest = record[separator + 1 ..];
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    return .{ .time_us = time_us, .text = rest[0..end] };
}

fn kernel_problem(text: []const u8) ?KernelProblem {
    // "Out of memory: Killed process ..." and "Memory cgroup out of memory: Killed process ...".
    if (std.mem.indexOf(u8, text, "of memory: Killed process") != null) return .oom_kill;
    // A user process killed by an error signal ("prog[42]: segfault at 0 ip ...", "traps:
    // prog[42] general protection fault ...", "... trap invalid opcode ...").
    const crashes = [_][]const u8{
        " segfault at ", "traps: ", "potentially unexpected fatal signal",
    };
    for (crashes) |sign| {
        if (std.mem.indexOf(u8, text, sign) != null) return .crash;
    }
    const signs = [_][]const u8{
        "WARNING: CPU:",            "BUG: ",                 "kernel BUG at", "Oops: ",
        "general protection fault", "blocked for more than", "UBSAN:",        "Kernel panic",
    };
    for (signs) |sign| {
        if (std.mem.indexOf(u8, text, sign) != null) return .kernel;
    }
    return null;
}

/// A command pushed at a moment may still run when the scenario ends: let it finish (each
/// check sleeps 10ms of virtual time; idle time costs nothing).
const agent_wait_checks_max = 60_000;

/// Built-in property, as Antithesis's "peak memory usage": the nodes' memory (their cgroups'
/// peak: processes, page cache, tmpfs) stays under 95% of the machine's.
const memory_property = "peak memory usage stays under 95% of the machine's memory";

fn memory_check() void {
    var peak_buffer: [32]u8 = undefined;
    const peak_text = read_text("/sys/fs/cgroup/nodes/memory.peak", &peak_buffer);
    const peak = std.fmt.parseInt(u64, peak_text, 10) catch return; // No nodes.
    var meminfo_buffer: [256]u8 = undefined;
    const meminfo = read_text("/proc/meminfo", &meminfo_buffer);
    const total = meminfo_total(meminfo) orelse return;
    const details = .{ .peak_mib = peak >> 20, .total_mib = total >> 20 };
    sdk.always(peak * 100 < total * 95, memory_property, details);
}

/// MemTotal from /proc/meminfo's first line, in bytes.
fn meminfo_total(meminfo: []const u8) ?u64 {
    const prefix = "MemTotal:";
    if (!std.mem.startsWith(u8, meminfo, prefix)) return null;
    const line_end = std.mem.indexOfScalar(u8, meminfo, '\n') orelse meminfo.len;
    var words = std.mem.tokenizeScalar(u8, meminfo[prefix.len..line_end], ' ');
    const kib = std.fmt.parseInt(u64, words.next() orelse return null, 10) catch return null;
    return kib * 1024;
}

test meminfo_total {
    const meminfo = "MemTotal:        2014532 kB\nMemFree:  1 kB\n";
    try std.testing.expectEqual(@as(?u64, 2014532 * 1024), meminfo_total(meminfo));
    try std.testing.expectEqual(@as(?u64, null), meminfo_total("MemFree: 1 kB\n"));
}

fn agent_wait() void {
    for (0..agent_wait_checks_max) |_| {
        const result = linux.access(agent_busy_path, linux.F_OK);
        if (linux.errno(result) != .SUCCESS) return;
        nodes.sleep_ns(10 * std.time.ns_per_ms);
    }
}

const agent_busy_path = "/run/det-agent-busy"; // agent.zig's busy_path.

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

test kernel_problem {
    const oom = "6,812,2203117,-;Memory cgroup out of memory: Killed process 301 " ++
        "(det-selftest-no) total-vm:70000kB\n SUBSYSTEM=memory";
    const record = kmsg_record(oom).?;
    try std.testing.expectEqual(@as(u64, 2203117), record.time_us);
    try std.testing.expectEqual(KernelProblem.oom_kill, kernel_problem(record.text).?);
    const warning = kmsg_record("4,90,1000,-;WARNING: CPU: 0 PID: 1 at mm/slub.c:42 f+0x1/0x2").?;
    try std.testing.expectEqual(KernelProblem.kernel, kernel_problem(warning.text).?);
    const segfault = kmsg_record("6,91,2000,-;bank[42]: segfault at 0 ip 0000 sp 0000 error 4").?;
    try std.testing.expectEqual(KernelProblem.crash, kernel_problem(segfault.text).?);
    const trap = kmsg_record("6,92,2000,-;traps: bank[42] general protection fault ip:401000").?;
    try std.testing.expectEqual(KernelProblem.crash, kernel_problem(trap.text).?);
    const fine = kmsg_record("6,1,0,-;Linux version 6.12.113").?;
    try std.testing.expect(kernel_problem(fine.text) == null);
}

test parameter {
    const cmdline = "console=ttyS0 det.scenario=bank det.exec=ls%20-la";
    try std.testing.expectEqualStrings("bank", parameter(cmdline, "det.scenario").?);
    try std.testing.expectEqualStrings("ls%20-la", parameter(cmdline, "det.exec").?);
    try std.testing.expect(parameter(cmdline, "det.missing") == null);
}
