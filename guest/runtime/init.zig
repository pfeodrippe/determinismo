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
const last_output = @import("tail.zig");
const crash_names = @import("crash_names.zig");

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
    limits_raise();
    cores_setup();
    var cmdline_buffer: [cmdline_size_max]u8 = undefined;
    const cmdline = read_cmdline(&cmdline_buffer);
    for (modules) |module| module_load(module, cmdline);
    sdk_output_mount();
    coverage_mount();
    _ = spawn(&.{bin ++ "det-agent"}); // Multiverse debugging; asleep unless pushed to.
    const status = run(arena, cmdline);
    std.debug.print("[guest] done, status {d}\n", .{status});
    for (node_names) |name| {
        if (nodes.pid_of(name) == null) continue;
        sdk.assert_computed(.always, true, node_exit_property, .{ .node = name });
    }
    kernel_check();
    memory_check();
    cpu_report();
    agent_wait();
    // The sinks' last look (what the nodes wrote last), then it ends.
    if (sinks_pid) |pid| {
        _ = linux.kill(pid, .TERM);
        _ = wait_for(pid);
    }
    sdk.lifecycle("guest_done", .{ .status = status });
    reap_all();
    _ = linux.sync();
    _ = linux.reboot(.MAGIC1, .MAGIC2, .RESTART, null);
    unreachable;
}

var sinks_pid: ?linux.pid_t = null;

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
        const exits = arena.alloc([]const []const u8, system.nodes.len) catch return 1;
        for (system.nodes, exits) |node, *texts| texts.* = node.exits_known;
        exits_known = exits;
        var known: std.ArrayList([]const u8) = .empty;
        for (system.nodes) |node| known.appendSlice(arena, node.crashes_known) catch {};
        crashes_known = known.items;
    } else |_| {}
    // Antithesis's output sinks in the nodes, as events, until the timeline ends.
    sinks_pid = spawn(&.{bin ++ "det-sinks"});
    // Nodes with a writeback window: their disks synced that often, for good (nodes.zig), from
    // before they start: setup can be long (OpenSearch's took 77 s), and a loop begun after it
    // left everything written meanwhile unsynced at the first power loss (run 92).
    if (nodes.system_load(arena)) |system| {
        const windowed = for (system.nodes) |node| {
            if (node.writeback_s != null) break true;
        } else false;
        if (windowed) _ = spawn(&.{ bin ++ "det-nodes", "writeback" });
    } else |_| {}
    if (node_names.len > 0) _ = spawn(&.{ bin ++ "det-nodes", "samples" });
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

/// Docker's open-file limit (1048576, soft and hard) for everything init starts, nodes
/// included: the kernel's at boot is 1024 (4096 hard), and systems deployed in containers count
/// on Docker's. Under 1024, YugabyteDB's tablet servers could not open their tablets' files
/// ("Too many open files"), aborted and restarted in every timeline (2026-10-27).
const open_files_max = 1 << 20;

fn limits_raise() void {
    const limit: linux.rlimit = .{ .cur = open_files_max, .max = open_files_max };
    const result = linux.setrlimit(.NOFILE, &limit);
    if (linux.errno(result) != .SUCCESS) std.debug.print("[guest] open-file limit: {s}\n", .{@tagName(linux.errno(result))});
}

/// Core dumps of any process, in any node, go to det-core (cores.zig), which keeps them in
/// /run/det/cores for `determinismo extract --file runner:/run/det/cores/...`.
fn cores_setup() void {
    nodes.mkdir_all("/run/det/cores") catch {};
    const pattern = "|" ++ bin ++ "det-core %P %I %e %s";
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

/// Where libvoidstar keeps which edges were reported, shared by every process of every node for
/// the whole timeline (a node restarted, or a test command started again, reports nothing new):
/// a writable tmpfs under /opt/determinismo, which nodes see through their bind of it.
fn coverage_mount() void {
    const target = "/opt/determinismo/coverage";
    const result = linux.mount("tmpfs", target, "tmpfs", 0, @intFromPtr("mode=1777"));
    if (linux.errno(result) != .SUCCESS) {
        std.debug.print("[guest] coverage: {s}\n", .{@tagName(linux.errno(result))});
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
const node_exit_property = "no unexpected container exits";
var node_names: []const []const u8 = &.{};
const known_exit_prefix = crash_names.known_exit_prefix;
/// Each node's known exits (schema.Node.exits_known), in node_names' order.
var exits_known: []const []const []const u8 = &.{};
const output_tail_max = 64 * 1024;

/// The known exit the node's last output names, if one. Its forwarder may not have written its
/// last lines yet when the exit is seen: looked for again, for 200 ms.
fn exit_known(index: usize, name: []const u8) ?[]const u8 {
    if (index >= exits_known.len or exits_known[index].len == 0) return null;
    for (0..20) |_| {
        if (exit_known_now(index, name)) |text| return text;
        const pause: linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = linux.nanosleep(&pause, null);
    }
    return null;
}

fn exit_known_now(index: usize, name: []const u8) ?[]const u8 {
    var path_buffer: [nodes.path_size_max]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/run/det/nodes/{s}/output.log", .{name}, 0) catch return null;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    const end = linux.lseek(@intCast(fd), 0, linux.SEEK.END);
    if (linux.errno(end) != .SUCCESS) return null;
    const size: u64 = @intCast(end);
    var tail: [output_tail_max]u8 = undefined;
    const offset = size -| tail.len;
    const read = linux.pread(@intCast(fd), &tail, tail.len, @intCast(offset));
    if (linux.errno(read) != .SUCCESS) return null;
    for (exits_known[index]) |text| {
        if (std.mem.indexOf(u8, tail[0..read], text) != null) return text;
    }
    return null;
}

fn orphan_reaped(pid: linux.pid_t, status: u32) void {
    for (node_names, 0..) |name, index| {
        if (nodes.pid_recorded(name) != pid) continue;
        const code = if (status & 0x7f == 0) (status >> 8) & 0xff else 128 + (status & 0x7f);
        // As Antithesis judges a container's exit: 0, SIGKILL and SIGTERM are expected; and any
        // exit while the node's disk fails (giving up on I/O errors is legitimate). Kubernetes
        // pods' containers are judged by det-podlogs, under the same property.
        const signaled = code == 128 + 9 or code == 128 + 15;
        const expected = code == 0 or signaled or nodes.disk_failing(name);
        if (!expected) if (exit_known(index, name)) |text| {
            var property_buffer: [known_exit_prefix.len + 128]u8 = undefined;
            const shown = text[0..@min(text.len, 128)];
            const property = std.fmt.bufPrint(&property_buffer, known_exit_prefix ++ "{s}", .{shown}) catch return;
            sdk.assert_computed(.sometimes, true, property, .{ .node = name, .status = code });
            return;
        };
        // What it said last, its cause most often: its forwarder's last lines given a moment.
        var said_buffer: [last_output.said_size_max]u8 = undefined;
        const said = if (expected) "" else said: {
            const settle: linux.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
            _ = linux.nanosleep(&settle, null);
            break :said last_output.said(name, &said_buffer);
        };
        sdk.assert_computed(.always, expected, node_exit_property, .{ .node = name, .status = code, .said = said });
        return;
    }
}

/// Built-in properties from the kernel's log (all of it, whatever the console shows), read
/// once when the timeline ends: no OOM kills, no process killed by an error signal (Antithesis's
/// "no unexpected crashes"), and no warnings, BUGs, oopses or hung tasks.
///
/// A crash fails a property of its process ("no process crashes: postgres"): a system's known
/// crash (YugabyteDB's YSQL backends on exit) then leaves another process's crash its own
/// failing property, never one more failure of the same one. The kernel's line names the
/// crashing thread; det-core recorded its process (cores.zig: a YSQL backend's crash in its
/// client's rpc_tp_Transact thread is postgres's). A timeline without any crash passes
/// `crash_property`.
const oom_property = "the kernel kills no process for lack of memory";
const known_crash_prefix = crash_names.known_crash_prefix;
/// The processes whose crashes the system's nodes declare known (schema.Node.crashes_known).
var crashes_known: []const []const u8 = &.{};
const crash_property = "no process crashes (segfault, illegal instruction, ...)";
const crash_property_prefix = crash_names.crash_prefix;
const kernel_property = "the kernel reports no warnings, BUGs or hung tasks";
const kmsg_records_max = 1 << 16;

const KernelProblem = enum { oom_kill, crash, kernel };

fn kernel_check() void {
    var seen = std.EnumArray(KernelProblem, bool).initFill(false);
    var crashes_buffer: [64 * 1024]u8 = undefined;
    const crashes = read_text(crashes_path, &crashes_buffer);
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
            if (problem == .crash) {
                const crash = crash_of(crashes, record.text);
                // A core dump's: det-core judged it as it happened (with what its node said
                // last). Here only crashes no dump recorded (a process that may not dump).
                if (crash.recorded) {
                    seen.set(.crash, true);
                    continue;
                }
                const process = crash.process;
                // By name, or its start: a command name (comm) is 15 characters at most.
                const known = for (crashes_known) |name| {
                    if (std.mem.startsWith(u8, process, name)) break true;
                } else false;
                if (known) {
                    var known_buffer: [known_crash_prefix.len + 64]u8 = undefined;
                    const property = std.fmt.bufPrint(&known_buffer, known_crash_prefix ++ "{s}", .{process}) catch
                        continue;
                    sdk.assert_computed(.sometimes, true, property, .{ .kernel_us = record.time_us, .line = record.text });
                    continue;
                }
            }
            seen.set(problem, true);
            var crash_buffer: [crash_property_prefix.len + 64]u8 = undefined;
            const property = switch (problem) {
                .oom_kill => oom_property,
                .crash => std.fmt.bufPrint(&crash_buffer, crash_property_prefix ++ "{s}", .{
                    crash_of(crashes, record.text).process,
                }) catch crash_property,
                .kernel => kernel_property,
            };
            const details = .{ .kernel_us = record.time_us, .line = record.text };
            sdk.assert_computed(.always, false, property, details);
        }
    }
    if (!seen.get(.oom_kill)) sdk.assert_computed(.always, true, oom_property, .{});
    if (!seen.get(.crash)) sdk.assert_computed(.always, true, crash_property, .{});
    if (!seen.get(.kernel)) sdk.assert_computed(.always, true, kernel_property, .{});
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

const crashes_path = "/run/det/crashes"; // cores.zig's.

const Crash = struct {
    process: []const u8,
    /// The known exit its node's last output named (cores.zig), if one.
    known: ?[]const u8 = null,
    /// det-core recorded it, and judged it then (cores.zig): at its moment, not here.
    recorded: bool = false,
};

/// The process of a crash line: the one det-core recorded for its thread ("<tid> <process>"
/// lines, then "\t<known exit>" when its node's output named one), else the name the line gives.
fn crash_of(crashes: []const u8, text: []const u8) Crash {
    // "prog: thread: potentially unexpected fatal signal 11." names no thread: the same crash
    // as its "traps:"/"segfault" line, or a crash with no other line (an abort's signal 6). Its
    // process's last record says whether it was a known way down.
    const tid = crash_thread(text) orelse return crash_by_process(crashes, crash_process(text));
    var lines = std.mem.tokenizeScalar(u8, crashes, '\n');
    while (lines.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const recorded = std.fmt.parseInt(u32, line[0..space], 10) catch continue;
        if (recorded != tid or space + 1 >= line.len) continue;
        const rest = line[space + 1 ..];
        const tab = std.mem.indexOfScalar(u8, rest, '\t') orelse return .{ .process = rest, .recorded = true };
        return .{ .process = rest[0..tab], .known = rest[tab + 1 ..], .recorded = true };
    }
    return .{ .process = crash_process(text) };
}

/// The thread id in "prog[42]: ..." and "traps: prog[42] ...".
fn crash_thread(text: []const u8) ?u32 {
    const open = std.mem.indexOfScalar(u8, text, '[') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, text, open, ']') orelse return null;
    return std.fmt.parseInt(u32, text[open + 1 .. close], 10) catch null;
}

fn crash_by_process(crashes: []const u8, process: []const u8) Crash {
    var found: Crash = .{ .process = process };
    var lines = std.mem.tokenizeScalar(u8, crashes, '\n');
    while (lines.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const rest = line[space + 1 ..];
        const tab = std.mem.indexOfScalar(u8, rest, '\t');
        const recorded = rest[0 .. tab orelse rest.len];
        // The record has the command name, which the kernel cuts at 15 characters; the line
        // the program's ("det-selftest-node" for "det-selftest-no").
        if (recorded.len == 0 or !std.mem.startsWith(u8, process, recorded)) continue;
        found.known = if (tab) |at| rest[at + 1 ..] else null;
        found.recorded = true;
    }
    return found;
}

test crash_of {
    const crashes = "5471 postgres\n812 yb-tserver\n3679 mariadbd\tneed to abort\n";
    const line = "rpc_tp_Transact[5471]: segfault at 0 ip 00007f5766f6db19 sp 00007f572affce70 error 4";
    try std.testing.expectEqualStrings("postgres", crash_of(crashes, line).process);
    try std.testing.expect(crash_of(crashes, line).known == null);
    try std.testing.expectEqualStrings("yb-tserver", crash_of(crashes, "traps: rpc_worker[812] general protection fault").process);
    try std.testing.expectEqualStrings("other", crash_of(crashes, "other[9]: segfault at 0 ip 0").process);
    try std.testing.expectEqualStrings("yb-tserver", crash_of(crashes, "yb-tserver: tablet-bootstra: potentially unexpected fatal signal 6.").process);
    const galera = crash_of(crashes, "traps: mariadbd[3679] general protection fault ip:7f8f1d38c9a2");
    try std.testing.expectEqualStrings("mariadbd", galera.process);
    try std.testing.expectEqualStrings("need to abort", galera.known.?);
    // The same crash's line with no thread: by its process's last record.
    const signal = crash_of(crashes, "mariadbd: mariadbd: potentially unexpected fatal signal 11.");
    try std.testing.expectEqualStrings("need to abort", signal.known.?);
    try std.testing.expect(crash_of(crashes, "postgres: worker: potentially unexpected fatal signal 6.").known == null);
    const cut = crash_of("46 det-selftest-no\tcrashing as told\n", "det-selftest-node: det-selftest-no: potentially unexpected fatal signal 11.");
    try std.testing.expectEqualStrings("crashing as told", cut.known.?);
}

/// The process a crash line names: "prog[42]: segfault at ...", "traps: prog[42] general
/// protection fault ...", "prog: thread: potentially unexpected fatal signal 6.".
fn crash_process(text: []const u8) []const u8 {
    const rest = if (std.mem.startsWith(u8, text, "traps: ")) text["traps: ".len..] else text;
    const end = std.mem.indexOfAny(u8, rest, "[: ") orelse rest.len;
    return if (end == 0) "?" else rest[0..@min(end, 64)];
}

test crash_process {
    try std.testing.expectEqualStrings("postgres", crash_process("postgres[1057]: segfault at 0 ip 0"));
    try std.testing.expectEqualStrings("postgres", crash_process("traps: postgres[10976] general protection fault"));
    try std.testing.expectEqualStrings("yb-tserver", crash_process("yb-tserver: tablet-bootstra: potentially unexpected fatal signal 6."));
    try std.testing.expectEqualStrings("?", crash_process("[1] odd"));
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
    sdk.assert_computed(.always, peak * 100 < total * 95, memory_property, details);
}

/// Each node's CPU time (its cgroup's cpu.stat), with the guest's uptime beside it, as an event:
/// where a slow simulation spends its time (a node that busy-waits, a heavy runtime), which the
/// run's efficiency figures (idle share, clock reads) do not say. All virtual time.
fn cpu_report() void {
    var uptime_buffer: [64]u8 = undefined;
    const uptime_text = read_text("/proc/uptime", &uptime_buffer);
    const uptime_s = std.fmt.parseFloat(f64, uptime_text[0 .. std.mem.indexOfScalar(u8, uptime_text, ' ') orelse uptime_text.len]) catch 0;
    for (node_names) |name| {
        var path_buffer: [128]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buffer, nodes.cgroup_root ++ "/{s}/cpu.stat", .{name}, 0) catch continue;
        var buffer: [1024]u8 = undefined;
        const text = read_text(path, &buffer);
        const usage_usec = nodes.stat_field(text, "usage_usec") orelse continue;
        sdk.event("node_cpu", .{
            .node = name,
            .usage_ms = usage_usec / 1000,
            .user_ms = (nodes.stat_field(text, "user_usec") orelse 0) / 1000,
            .system_ms = (nodes.stat_field(text, "system_usec") orelse 0) / 1000,
            .uptime_ms = @as(u64, @intFromFloat(uptime_s * 1000)),
        });
    }
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
        const busy = linux.errno(linux.access(agent_busy_path, linux.F_OK)) == .SUCCESS;
        const held = linux.errno(linux.access(agent_hold_path, linux.F_OK)) == .SUCCESS;
        if (!busy and !held) return;
        nodes.sleep_ns(10 * std.time.ns_per_ms);
    }
}

const agent_busy_path = "/run/det-agent-busy"; // agent.zig's busy_path.
const agent_hold_path = "/run/det-agent-hold"; // agent.zig's hold_path.

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
