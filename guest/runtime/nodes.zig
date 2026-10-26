// SPDX-License-Identifier: MIT
//! The node runtime (ARCHITECTURE.md D19): runs each node of the resolved system
//! (/det/system.json) as a container we build ourselves.
//!
//! A node gets its own mount, PID, network, UTS and IPC namespaces; its root filesystem is an
//! overlay of its read-only disk and a writable layer of its own (so its writes live in guest
//! memory and are part of every snapshot): a tmpfs, or with crash faults an ext4 disk on a loop
//! device, which a crash shuts down without flushing (what was not synced is lost); its
//! processes share one cgroup, which pauses (freeze) and kills them as a unit. The guest network
//! is a full mesh: one veth pair between every two running nodes and between each node and the
//! runner (the guest's root namespace, where tests run), so a
//! partition is one link going down. Every link of a node carries the node's one /32 address,
//! with a host route per peer.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");
const schema = sdk.schema;
const netlink = @import("netlink.zig");
const output = @import("output.zig");
pub const LinkState = netlink.LinkState;

pub const system_path = "/det/system.json";
const state_root = "/run/det/nodes";
const cgroup_root = "/sys/fs/cgroup/nodes";
const system_size_max = 1 << 20;
pub const path_size_max = 256;
const arguments_max = 64;
const environment_max = 128;
/// The quiet-period command (det-stop-faults), at the same path in the runner and every node,
/// whose /opt/determinismo is the runner's, read-only. Its environment variables name it, as
/// Antithesis's ANTITHESIS_STOP_FAULTS does (scripts written for Antithesis work unchanged).
pub const stop_faults_path = "/opt/determinismo/bin/det-stop-faults";
const platform_environment = [_][:0]const u8{
    "DETERMINISMO_STOP_FAULTS=" ++ stop_faults_path,
    "ANTITHESIS_STOP_FAULTS=" ++ stop_faults_path,
};
const poll_interval_ns = 10 * std.time.ns_per_ms;
const ready_attempts_max = 6000; // 60 s of virtual time.
const stop_attempts_max = 3000;
const link_attempts_max = 500;

pub fn system_load(arena: std.mem.Allocator) !schema.System {
    const source = try read_file(arena, system_path, system_size_max);
    const system = try schema.parse(schema.System, arena, source);
    if (system.schema != schema.version) return error.SchemaVersion;
    if (system.nodes.len > schema.nodes_max) return error.TooManyNodes;
    return system;
}

/// Starts every node in order (the host checked that `after` only names earlier nodes) and
/// waits for each to be ready before starting the next.
pub fn up(arena: std.mem.Allocator, system: *const schema.System) !void {
    try mkdir_all(state_root);
    try mkdir_all(cgroup_root);
    // Controllers in node cgroups: cpu for throttling faults, memory for limits, and all of
    // them for nodes that run containers (kubelet wants cpuset, io and pids too).
    const controls = [_][:0]const u8{
        "/sys/fs/cgroup/cgroup.subtree_control", cgroup_root ++ "/cgroup.subtree_control",
    };
    for (controls) |control| {
        try file_write(control, "+cpu +memory");
        for ([_][]const u8{ "+cpuset", "+io", "+pids", "+hugetlb" }) |controller| {
            file_write(control, controller) catch {}; // Optional: not every kernel has them.
        }
    }
    try hosts_write("/etc/hosts", system);
    for (system.nodes) |*node| {
        try start(arena, system, node);
        try ready_wait(node);
    }
    sdk.event("nodes_up", .{ .nodes = system.nodes.len });
}

/// Starts one node (again, after a kill: its files survive in the overlay's upper layer).
pub fn start(
    arena: std.mem.Allocator,
    system: *const schema.System,
    node: *const schema.Resolved,
) !void {
    assert(schema.name_valid(node.name));
    if (pid_read(node.name) != null) return error.AlreadyRunning;
    var paths: Paths = undefined;
    try paths.init(node.name);
    try root_prepare(&paths, system, node);
    try memory_limit(&paths, node.memory_max_mib);
    const launch = try Launch.init(arena, node, &paths);
    const output_pipes = try output.pipes();
    var sync: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&sync, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
    const flags = linux.CLONE.NEWNS | linux.CLONE.NEWUTS | linux.CLONE.NEWIPC |
        linux.CLONE.NEWNET | linux.CLONE.NEWPID | @intFromEnum(linux.SIG.CHLD);
    const result = linux.syscall5(.clone, flags, 0, 0, 0, 0);
    if (linux.errno(result) != .SUCCESS) return error.Clone;
    if (result == 0) {
        _ = linux.close(sync[1]);
        var byte: [1]u8 = undefined;
        _ = linux.read(sync[0], &byte, 1); // The parent has set up cgroup and network.
        // Its own cgroup namespace, rooted at its cgroup (as containers have): what it creates
        // there (kubelet's pods) stays under the node, within reach of its faults.
        if (linux.errno(linux.unshare(linux.CLONE.NEWCGROUP)) != .SUCCESS) {
            die("unshare", error.Unshare);
        }
        launch.exec(output_pipes.stdout[1], output_pipes.stderr[1]); // Never returns.
    }
    const pid: linux.pid_t = @intCast(result);
    try output.forward(node.name, paths.output, output_pipes);
    for ([_][2]linux.fd_t{ output_pipes.stdout, output_pipes.stderr }) |pipe| {
        for (pipe) |fd| _ = linux.close(fd);
    }
    _ = linux.close(sync[0]);
    defer _ = linux.close(sync[1]);
    try cgroup_join(&paths, pid);
    try network_connect(system, node, pid);
    try file_write(paths.pid, try std.fmt.allocPrint(arena, "{d}\n", .{pid}));
    _ = linux.write(sync[1], "g", 1);
    sdk.event("node_start", .{ .node = node.name, .pid = pid });
}

/// Runs `argv` inside a running node (its namespaces, root, environment and user), like
/// `docker exec`, with this process's standard streams. Returns the command's exit status.
pub fn exec(
    arena: std.mem.Allocator,
    node: *const schema.Resolved,
    argv: []const []const u8,
) !u8 {
    if (argv.len == 0) return error.NoCommand;
    const pid = pid_read(node.name) orelse return error.NotRunning;
    var root_buffer: [64]u8 = undefined;
    const root = try print_z(&root_buffer, "/proc/{d}/root", .{pid});
    const exec_node = schema.Resolved{
        .name = node.name,
        .address = node.address,
        .disk = node.disk,
        .digest = node.digest,
        .command = argv,
        .env = node.env,
        .workdir = node.workdir,
        .user = node.user,
    };
    var paths: Paths = undefined;
    try paths.init(node.name);
    paths.root = root; // The node's root as this namespace sees it.
    const launch = try Launch.init(arena, &exec_node, &paths);
    // Namespace files first: after joining the mount namespace, /proc is the node's.
    var namespace_fds: [namespaces.len]linux.fd_t = undefined;
    for (namespaces, &namespace_fds) |namespace, *fd| {
        var buffer: [64]u8 = undefined;
        const path = try print_z(&buffer, "/proc/{d}/ns/{s}", .{ pid, namespace.name });
        const result = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(result) != .SUCCESS) return error.NoSuchNamespace;
        fd.* = @intCast(result);
    }
    const directory: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const root_fd = linux.open(root, directory, 0);
    if (linux.errno(root_fd) != .SUCCESS) return error.NoSuchRoot;
    const child = linux.fork();
    if (linux.errno(child) != .SUCCESS) return error.Fork;
    if (child == 0) {
        // Like the node's own processes: its CPU and memory limits, its freezes and kills.
        cgroup_join_self(&paths) catch |err| die("cgroup", err);
        for (namespaces, namespace_fds) |namespace, fd| {
            if (linux.errno(linux.setns(fd, namespace.flag)) != .SUCCESS) die("setns", error.Setns);
        }
        if (linux.errno(linux.fchdir(@intCast(root_fd))) != .SUCCESS) die("root", error.Chdir);
        if (linux.errno(linux.chroot(".")) != .SUCCESS) die("chroot", error.Chroot);
        // Joining a PID namespace places only the children: the command runs in a second
        // fork, or /proc/self would not resolve in the node (musl finds $ORIGIN through it).
        const command = linux.fork();
        if (linux.errno(command) != .SUCCESS) die("fork", error.Fork);
        if (command == 0) launch.exec_in_root(); // Never returns.
        linux.exit_group(wait_status(@intCast(command)));
    }
    return wait_status(@intCast(child));
}

/// The exit status of `pid`, or 128 + the signal that killed it (as shells report it).
fn wait_status(pid: linux.pid_t) u8 {
    var status: i32 = 0;
    _ = linux.wait4(pid, &status, 0, null);
    const bits: u32 = @bitCast(status);
    return if (bits & 0x7f == 0) @intCast((bits >> 8) & 0xff) else @intCast(128 + (bits & 0x7f));
}

const Namespace = struct { name: []const u8, flag: u32 };
/// The PID namespace applies to children: exec forks after joining.
const namespaces = [_]Namespace{
    .{ .name = "ipc", .flag = linux.CLONE.NEWIPC },
    .{ .name = "uts", .flag = linux.CLONE.NEWUTS },
    .{ .name = "net", .flag = linux.CLONE.NEWNET },
    .{ .name = "cgroup", .flag = linux.CLONE.NEWCGROUP },
    .{ .name = "pid", .flag = linux.CLONE.NEWPID },
    .{ .name = "mnt", .flag = linux.CLONE.NEWNS },
};

/// Kills every process of the node and waits until they are gone.
pub fn kill(name: []const u8) !void {
    var paths: Paths = undefined;
    try paths.init(name);
    if (pid_read(name) == null) return; // Not running.
    // The pidfile goes first: an exit of a process it names is unexpected (see det-init).
    _ = linux.unlink(paths.pid);
    try file_write(paths.cgroup_kill, "1");
    for (0..stop_attempts_max) |_| {
        if (!try cgroup_populated(&paths)) break;
        sleep_ns(poll_interval_ns);
    } else return error.NodeDidNotStop;
    sdk.event("node_kill", .{ .node = name });
}

/// A graceful stop begins: SIGTERM to its main process (its exit is expected from now on).
/// `kill_remaining` ends it if the node is still running after its grace period.
pub fn stop_signal(name: []const u8) !void {
    var paths: Paths = undefined;
    try paths.init(name);
    const pid = pid_read(name) orelse return error.NotRunning;
    // The pidfile goes first: its exit is expected (see det-init).
    _ = linux.unlink(paths.pid);
    _ = linux.kill(pid, .TERM);
    sdk.event("node_stop", .{ .node = name });
}

/// Kills whatever is left of the node (after a graceful stop: its pidfile is already gone).
pub fn kill_remaining(name: []const u8) !void {
    var paths: Paths = undefined;
    try paths.init(name);
    if (!try cgroup_populated(&paths)) return;
    try file_write(paths.cgroup_kill, "1");
    for (0..stop_attempts_max) |_| {
        if (!try cgroup_populated(&paths)) return;
        sleep_ns(poll_interval_ns);
    }
    return error.NodeDidNotStop;
}

/// A power loss: the node's disk keeps what reached it (synced, or written back already) and
/// loses the rest; its processes are gone. The next start mounts the disk again (ext4 replays
/// its journal: consistent, as after a real crash).
pub fn crash(name: []const u8) !void {
    var paths: Paths = undefined;
    try paths.init(name);
    const fd = linux.open(paths.layer, directory_flags, 0);
    if (linux.errno(fd) != .SUCCESS) return error.OpenFailed;
    var flags: u32 = ext4_going_flags_nologflush;
    const shutdown = linux.ioctl(@intCast(fd), ext4_ioc_shutdown, @intFromPtr(&flags));
    _ = linux.close(@intCast(fd));
    if (linux.errno(shutdown) != .SUCCESS) return error.NotADurableDisk; // Not ext4: no crash.
    try kill(name);
    try layer_unmount(&paths);
    sdk.event("node_crash", .{ .node = name });
}

/// The node starts fresh from its image: its writable layer is gone (with its disk, if any).
pub fn wipe(name: []const u8) !void {
    var paths: Paths = undefined;
    try paths.init(name);
    try kill(name);
    if (exists(paths.mounted)) try layer_unmount(&paths);
    var mapper_buffer: [mapper_name_size]u8 = undefined;
    _ = mapper_call(dm_dev_remove, try mapper_name(&mapper_buffer, name), 0, null) catch {};
    var text_buffer: [16]u8 = undefined;
    if (read_small(paths.loop, &text_buffer)) |text| {
        const number = std.fmt.parseInt(u32, text, 10) catch return error.BadLoop;
        var device_buffer: [32]u8 = undefined;
        const device = try print_z(&device_buffer, "/dev/loop{d}", .{number});
        const loop_fd = linux.open(device, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        if (linux.errno(loop_fd) == .SUCCESS) {
            _ = linux.ioctl(@intCast(loop_fd), loop_clr_fd, 0);
            _ = linux.close(@intCast(loop_fd));
        }
        _ = linux.unlink(paths.loop);
    }
    _ = linux.unlink(paths.image);
    sdk.event("node_wipe", .{ .node = name });
}

const directory_flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
const ext4_ioc_shutdown = 0x8004587d; // _IOR('X', 125, __u32)
const ext4_going_flags_nologflush = 2; // Neither the journal nor data are flushed.
const ext4_ioc_resize_fs = 0x40086610; // _IOW('f', 16, __u64)
const loop_ctl_get_free = 0x4c82;
const loop_set_fd = 0x4c00;
const loop_clr_fd = 0x4c01;
/// A durable disk's size (sparse: guest memory holds what is written).
const durable_size = 4 << 30;
const durable_template_path = "/opt/determinismo/durable.blocks"; // initramfs.zig's.

/// The node's writable layer: a tmpfs of its own, or (crash and disk faults) its ext4 disk,
/// through device-mapper (disk faults swap its table).
fn layer_mount(paths: *const Paths, node: *const schema.Resolved) !void {
    if (!node.faults.crash and !node.faults.disk) {
        return mount("tmpfs", paths.layer, "tmpfs", 0, null);
    }
    if (!exists(paths.image)) try durable_image_create(paths.image);
    const loop = try loop_attach(paths);
    const minor = try mapper_attach(node.name, loop);
    var device_buffer: [32]u8 = undefined;
    const device = try print_z(&device_buffer, "/dev/dm-{d}", .{minor});
    try device_wait(device);
    // noinit_itable: no background zeroing of inode tables (it would fill guest memory).
    try mount(device, paths.layer, "ext4", 0, "data=ordered,noinit_itable");
    // The template is small; grown in place to the disk's size (nothing to do the next time).
    const fd = linux.open(paths.layer, directory_flags, 0);
    if (linux.errno(fd) != .SUCCESS) return error.OpenFailed;
    defer _ = linux.close(@intCast(fd));
    var blocks: u64 = durable_size / 4096;
    const resized = linux.ioctl(@intCast(fd), ext4_ioc_resize_fs, @intFromPtr(&blocks));
    if (linux.errno(resized) != .SUCCESS) return error.ResizeFailed;
    writeback_relax();
}

/// Dirty data stays dirty until a program syncs it (no periodic writeback): what a crash loses
/// is what was not synced, as on a machine whose power fails before the flusher ran.
fn writeback_relax() void {
    const settings = [_][2][:0]const u8{
        .{ "/proc/sys/vm/dirty_writeback_centisecs", "0" },
        .{ "/proc/sys/vm/dirty_expire_centisecs", "8640000" },
        .{ "/proc/sys/vm/dirty_background_ratio", "50" },
        .{ "/proc/sys/vm/dirty_ratio", "80" },
    };
    for (settings) |setting| file_write(setting[0], setting[1]) catch {};
}

fn layer_unmount(paths: *const Paths) !void {
    _ = linux.unlink(paths.mounted);
    for ([_][:0]const u8{ paths.root, paths.layer }) |path| {
        for (0..stop_attempts_max) |_| {
            const result = linux.umount2(path, 0);
            if (linux.errno(result) == .SUCCESS or linux.errno(result) == .INVAL) break;
            sleep_ns(poll_interval_ns); // Busy until the killed processes are reaped.
        } else return error.UnmountFailed;
    }
}

/// The empty ext4 filesystem of the initramfs, written as a sparse image of `durable_size`.
fn durable_image_create(path: [:0]const u8) !void {
    const template = linux.open(durable_template_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(template) != .SUCCESS) return error.NoDurableTemplate;
    defer _ = linux.close(@intCast(template));
    const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const image = linux.open(path, flags, 0o600);
    if (linux.errno(image) != .SUCCESS) return error.OpenFailed;
    defer _ = linux.close(@intCast(image));
    var size_bytes: [8]u8 = undefined;
    try read_exact(@intCast(template), &size_bytes);
    var record: [4 + 4096]u8 = undefined;
    while (read_exact(@intCast(template), &record)) {
        const index = std.mem.readInt(u32, record[0..4], .little);
        const offset = @as(i64, index) * 4096;
        const written = linux.pwrite(@intCast(image), record[4..].ptr, 4096, offset);
        if (linux.errno(written) != .SUCCESS or written != 4096) return error.WriteFailed;
    } else |err| if (err != error.EndOfFile) return err;
    if (linux.errno(linux.ftruncate(@intCast(image), durable_size)) != .SUCCESS) {
        return error.TruncateFailed;
    }
}

fn read_exact(fd: linux.fd_t, buffer: []u8) !void {
    var done: usize = 0;
    while (done < buffer.len) {
        const result = linux.read(fd, buffer[done..].ptr, buffer.len - done);
        if (linux.errno(result) != .SUCCESS) return error.ReadFailed;
        if (result == 0) return if (done == 0) error.EndOfFile else error.ShortRead;
        done += result;
    }
}

/// The node's loop device over its image: attached once, its number kept beside the image.
fn loop_attach(paths: *const Paths) !u32 {
    var text_buffer: [16]u8 = undefined;
    if (read_small(paths.loop, &text_buffer)) |text| {
        return std.fmt.parseInt(u32, text, 10) catch error.BadLoop;
    }
    const control = linux.open("/dev/loop-control", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(control) != .SUCCESS) return error.NoLoopControl;
    defer _ = linux.close(@intCast(control));
    const free = linux.ioctl(@intCast(control), loop_ctl_get_free, 0);
    if (linux.errno(free) != .SUCCESS) return error.NoFreeLoop;
    const number: u32 = @intCast(free);
    var device_buffer: [32]u8 = undefined;
    const device = try print_z(&device_buffer, "/dev/loop{d}", .{number});
    // devtmpfs creates the device node as the device appears.
    var loop_fd: linux.fd_t = -1;
    for (0..stop_attempts_max) |_| {
        const result = linux.open(device, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        if (linux.errno(result) == .SUCCESS) {
            loop_fd = @intCast(result);
            break;
        }
        sleep_ns(poll_interval_ns);
    } else return error.NoLoopDevice;
    defer _ = linux.close(loop_fd);
    const image = linux.open(paths.image, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(image) != .SUCCESS) return error.OpenFailed;
    defer _ = linux.close(@intCast(image));
    if (linux.errno(linux.ioctl(loop_fd, loop_set_fd, image)) != .SUCCESS) return error.LoopSetFd;
    var number_buffer: [16]u8 = undefined;
    try file_write(paths.loop, try std.fmt.bufPrint(&number_buffer, "{d}", .{number}));
    return number;
}

// Disk faults ------------------------------------------------------------------------------
// A durable node's disk is a device-mapper device over its loop device: linear while healthy,
// another target while it fails (the table swapped without freezing the filesystem, so no
// dirty data is flushed by it: a crash after still loses what was not synced).

/// How a failing disk behaves.
pub const DiskFailure = enum {
    /// Every read and write fails (EIO).
    errors,
    /// Writes fail; reads work.
    write_errors,
    /// Writes are acknowledged and never stored (a lying disk or controller cache): a crash
    /// after loses them although they were synced.
    lost_writes,
    /// Reads return one byte of each request changed (bit rot); what is stored is intact.
    corrupt_reads,
    /// Every request waits (a slow or overloaded disk).
    slow,
};

/// One disk fault's parameters (platform decisions, or asked for by a scenario).
pub const DiskFault = struct {
    failure: DiskFailure,
    /// slow: how long each request waits.
    delay_ms: u32 = 0,
    /// corrupt_reads: which byte of each read (from 1) becomes `corrupt_value`.
    corrupt_byte: u32 = 1,
    corrupt_value: u8 = 0,
};

/// The node's disk fails as `fault` says until disk_heal. Its exit meanwhile is expected.
pub fn disk_fail(name: []const u8, fault: DiskFault) !void {
    var paths: Paths = undefined;
    try paths.init(name);
    const loop = try loop_read(&paths);
    var parameters_buffer: [128]u8 = undefined;
    const target: MapperTarget = switch (fault.failure) {
        // flakey: <device> <offset> <up seconds> <down seconds> [<feature count> <features>]:
        // never up, down until the table is swapped back.
        .errors => .{ .kind = "flakey", .parameters = try std.fmt.bufPrint(
            &parameters_buffer,
            "7:{d} 0 0 1",
            .{loop},
        ) },
        .write_errors => .{ .kind = "flakey", .parameters = try std.fmt.bufPrint(
            &parameters_buffer,
            "7:{d} 0 0 1 1 error_writes",
            .{loop},
        ) },
        .lost_writes => .{ .kind = "flakey", .parameters = try std.fmt.bufPrint(
            &parameters_buffer,
            "7:{d} 0 0 1 1 drop_writes",
            .{loop},
        ) },
        .corrupt_reads => .{ .kind = "flakey", .parameters = try std.fmt.bufPrint(
            &parameters_buffer,
            "7:{d} 0 0 1 5 corrupt_bio_byte {d} r {d} 0",
            .{ loop, @max(fault.corrupt_byte, 1), fault.corrupt_value },
        ) },
        .slow => .{ .kind = "delay", .parameters = try std.fmt.bufPrint(
            &parameters_buffer,
            "7:{d} 0 {d}",
            .{ loop, fault.delay_ms },
        ) },
    };
    var flag_buffer: [path_size_max]u8 = undefined;
    try file_write(try disk_failing_path(&flag_buffer, &paths), "1");
    var name_buffer: [mapper_name_size]u8 = undefined;
    try mapper_table(try mapper_name(&name_buffer, name), target);
    sdk.event("node_disk_fail", .{ .node = name, .failure = fault.failure });
}

/// The node's disk works again. True when the node must start again (the caller starts it):
/// it exited, or its filesystem gave up (ext4 remounts read-only when its journal fails); it
/// is then stopped, and its disk unmounted (mounted afresh at the start: the journal replays).
pub fn disk_heal(name: []const u8) !bool {
    var paths: Paths = undefined;
    try paths.init(name);
    var flag_buffer: [path_size_max]u8 = undefined;
    const flag = try disk_failing_path(&flag_buffer, &paths);
    defer _ = linux.unlink(flag);
    const loop = try loop_read(&paths);
    var parameters_buffer: [64]u8 = undefined;
    const parameters = try std.fmt.bufPrint(&parameters_buffer, "7:{d} 0", .{loop});
    var name_buffer: [mapper_name_size]u8 = undefined;
    const mapper = try mapper_name(&name_buffer, name);
    try mapper_table(mapper, .{ .kind = "linear", .parameters = parameters });
    sdk.event("node_disk_heal", .{ .node = name });
    if (pid_read(name) != null and !mounted_read_only(paths.layer)) return false;
    try kill(name);
    if (exists(paths.mounted)) try layer_unmount(&paths);
    return true;
}

/// Whether the node's disk is failing (a disk fault is under way): its exit is expected.
pub fn disk_failing(name: []const u8) bool {
    var paths: Paths = undefined;
    paths.init(name) catch return false;
    var flag_buffer: [path_size_max]u8 = undefined;
    return exists(disk_failing_path(&flag_buffer, &paths) catch return false);
}

fn disk_failing_path(buffer: *[path_size_max]u8, paths: *const Paths) ![:0]const u8 {
    return print_z(buffer, "{s}/disk-failing", .{paths.directory});
}

fn loop_read(paths: *const Paths) !u32 {
    var text_buffer: [16]u8 = undefined;
    const text = read_small(paths.loop, &text_buffer) orelse return error.NotADurableDisk;
    return std.fmt.parseInt(u32, text, 10) catch error.BadLoop;
}

/// Whether the filesystem at `path` is mounted read-only (statfs's ST_RDONLY).
fn mounted_read_only(path: [:0]const u8) bool {
    var buffer: [15]u64 = undefined; // struct statfs on x86_64: f_flags is its 11th field.
    const result = linux.syscall2(.statfs, @intFromPtr(path.ptr), @intFromPtr(&buffer));
    if (linux.errno(result) != .SUCCESS) return false;
    return buffer[10] & 1 != 0;
}

/// devtmpfs creates the device node as the device appears.
fn device_wait(device: [:0]const u8) !void {
    for (0..stop_attempts_max) |_| {
        if (exists(device)) return;
        sleep_ns(poll_interval_ns);
    }
    return error.NoDevice;
}

// device-mapper's ioctls (linux/dm-ioctl.h), on /dev/mapper/control.
const DmIoctl = extern struct {
    version: [3]u32 = .{ 4, 0, 0 },
    data_size: u32 = 0,
    data_start: u32 = 0,
    target_count: u32 = 0,
    open_count: i32 = 0,
    flags: u32 = 0,
    event_nr: u32 = 0,
    padding: u32 = 0,
    dev: u64 = 0,
    name: [128]u8 = @splat(0),
    uuid: [129]u8 = @splat(0),
    data: [7]u8 = @splat(0),
};
const DmTargetSpec = extern struct {
    sector_start: u64 = 0,
    length: u64,
    status: i32 = 0,
    next: u32 = 0,
    target_type: [16]u8 = @splat(0),
};
comptime {
    assert(@sizeOf(DmIoctl) == 312);
    assert(@sizeOf(DmTargetSpec) == 40);
}
const dm_dev_create = 3;
const dm_dev_remove = 4;
const dm_dev_suspend = 6; // Without DM_SUSPEND_FLAG: resume, swapping in a loaded table.
const dm_dev_status = 7;
const dm_table_load = 9;
/// Swap tables without freezing the filesystem (which would flush its dirty data).
const dm_skip_lockfs_flag = 1 << 10;
const mapper_name_size = 128;
const mapper_buffer_size = @sizeOf(DmIoctl) + @sizeOf(DmTargetSpec) + 256;

const MapperTarget = struct { kind: []const u8, parameters: []const u8 };

fn mapper_name(buffer: *[mapper_name_size]u8, node: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "det-{s}", .{node});
}

/// The node's device-mapper device over its loop device (linear), created once: its minor.
fn mapper_attach(node: []const u8, loop: u32) !u32 {
    var name_buffer: [mapper_name_size]u8 = undefined;
    const name = try mapper_name(&name_buffer, node);
    const dev = mapper_call(dm_dev_status, name, 0, null) catch blk: {
        _ = try mapper_call(dm_dev_create, name, 0, null);
        var parameters_buffer: [64]u8 = undefined;
        const parameters = try std.fmt.bufPrint(&parameters_buffer, "7:{d} 0", .{loop});
        try mapper_table(name, .{ .kind = "linear", .parameters = parameters });
        break :blk try mapper_call(dm_dev_status, name, 0, null);
    };
    // The kernel's huge_encode_dev: minor bits 0-7, then 20 and up.
    return @intCast((dev & 0xff) | ((dev >> 12) & 0xfff00));
}

/// Loads `target` over the whole disk and swaps it in.
fn mapper_table(name: []const u8, target: MapperTarget) !void {
    _ = try mapper_call(dm_table_load, name, 0, target);
    _ = try mapper_call(dm_dev_suspend, name, dm_skip_lockfs_flag, null);
}

fn mapper_call(command: u8, name: []const u8, flags: u32, target: ?MapperTarget) !u64 {
    const control = linux.open("/dev/mapper/control", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(control) != .SUCCESS) return error.NoMapperControl;
    defer _ = linux.close(@intCast(control));
    var buffer: [mapper_buffer_size]u8 align(8) = @splat(0);
    const header: *DmIoctl = @ptrCast(&buffer);
    header.* = .{ .data_size = buffer.len, .data_start = @sizeOf(DmIoctl), .flags = flags };
    if (name.len >= header.name.len) return error.NameTooLong;
    @memcpy(header.name[0..name.len], name);
    if (target) |chosen| {
        header.target_count = 1;
        const spec: *DmTargetSpec = @ptrCast(@alignCast(buffer[@sizeOf(DmIoctl)..]));
        spec.* = .{ .length = durable_size / 512 };
        if (chosen.kind.len >= spec.target_type.len) return error.TargetTooLong;
        @memcpy(spec.target_type[0..chosen.kind.len], chosen.kind);
        const parameters = buffer[@sizeOf(DmIoctl) + @sizeOf(DmTargetSpec) ..];
        if (chosen.parameters.len >= parameters.len) return error.ParametersTooLong;
        @memcpy(parameters[0..chosen.parameters.len], chosen.parameters);
    }
    // _IOWR(0xfd, command, struct dm_ioctl)
    const request: u32 = (3 << 30) | (@sizeOf(DmIoctl) << 16) | (0xfd << 8) | @as(u32, command);
    const result = linux.ioctl(@intCast(control), request, @intFromPtr(&buffer));
    return switch (linux.errno(result)) {
        .SUCCESS => header.dev,
        .NXIO => error.NoMapperDevice,
        .BUSY => error.MapperBusy,
        else => error.MapperFailed,
    };
}

/// Caps the node's CPU to `percent` of one CPU, or with null lifts the cap.
pub fn cpu_limit(name: []const u8, percent: ?u8) !void {
    var paths: Paths = undefined;
    try paths.init(name);
    var path_buffer: [path_size_max]u8 = undefined;
    const path = try print_z(&path_buffer, "{s}/cpu.max", .{paths.cgroup});
    var value_buffer: [32]u8 = undefined;
    const period_us = 100_000;
    const value = if (percent) |share| blk: {
        const quota_us = @as(u32, share) * period_us / 100;
        break :blk try std.fmt.bufPrint(&value_buffer, "{d} {d}", .{ quota_us, period_us });
    } else "max 100000";
    try file_write(path, value);
}

/// The node's processes, in the order its cgroup lists them.
pub fn processes(name: []const u8, pids: []linux.pid_t) !u32 {
    var paths: Paths = undefined;
    try paths.init(name);
    if (!exists(paths.cgroup_procs)) return error.NoCgroup;
    var count: u32 = 0;
    try processes_collect(paths.cgroup, pids, &count, 0);
    return count;
}

/// The threads of a process, in /proc's order (by id), as many as fit.
pub fn threads(pid: linux.pid_t, tids: []linux.pid_t) u32 {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/task", .{pid}, 0) catch return 0;
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const fd = linux.open(path, flags, 0);
    if (linux.errno(fd) != .SUCCESS) return 0;
    defer _ = linux.close(@intCast(fd));
    var count: u32 = 0;
    var entries: [4096]u8 align(8) = undefined;
    while (true) {
        const size = linux.getdents64(@intCast(fd), &entries, entries.len);
        if (linux.errno(size) != .SUCCESS or size == 0) return count;
        var offset: usize = 0;
        while (offset < size) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[offset]);
            const name_offset = offset + @offsetOf(linux.dirent64, "name");
            offset += entry.reclen;
            const name: [*:0]const u8 = @ptrCast(&entries[name_offset]);
            const tid = std.fmt.parseInt(linux.pid_t, std.mem.span(name), 10) catch continue;
            if (count == tids.len) return count;
            tids[count] = tid;
            count += 1;
        }
    }
}

/// Nodes that run containers (K3s) put their processes in cgroups of their own, under the
/// node's: the whole subtree, depth first.
const cgroup_depth_max = 8;

fn processes_collect(directory: [:0]const u8, pids: []linux.pid_t, count: *u32, depth: u32) !void {
    var path_buffer: [path_size_max]u8 = undefined;
    var text_buffer: [16 * 1024]u8 = undefined;
    const procs = try print_z(&path_buffer, "{s}/cgroup.procs", .{directory});
    if (read_small(procs, &text_buffer)) |text| {
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (count.* == pids.len) return;
            pids[count.*] = std.fmt.parseInt(linux.pid_t, line, 10) catch continue;
            count.* += 1;
        }
    }
    if (depth == cgroup_depth_max) return;
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const fd = linux.open(directory, flags, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    var entries: [4096]u8 align(8) = undefined;
    while (true) {
        const size = linux.getdents64(@intCast(fd), &entries, entries.len);
        if (linux.errno(size) != .SUCCESS or size == 0) return;
        var offset: usize = 0;
        while (offset < size) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[offset]);
            offset += entry.reclen;
            if (entry.type != linux.DT.DIR) continue;
            const name_offset = offset - entry.reclen + @offsetOf(linux.dirent64, "name");
            const child_name: [*:0]const u8 = @ptrCast(&entries[name_offset]);
            const child = std.mem.span(child_name);
            if (std.mem.eql(u8, child, ".") or std.mem.eql(u8, child, "..")) continue;
            var child_buffer: [path_size_max]u8 = undefined;
            const child_path = try print_z(&child_buffer, "{s}/{s}", .{ directory, child });
            try processes_collect(child_path, pids, count, depth + 1);
        }
    }
}

pub fn freeze(name: []const u8, state: enum { frozen, thawed }) !void {
    var paths: Paths = undefined;
    try paths.init(name);
    try file_write(paths.cgroup_freeze, if (state == .frozen) "1" else "0");
}

pub const State = enum { running, paused, stopped };

/// Whether the node runs, is frozen, or has no live main process.
pub fn state_of(name: []const u8) State {
    if (pid_read(name) == null) return .stopped;
    var paths: Paths = undefined;
    paths.init(name) catch return .stopped;
    var buffer: [8]u8 = undefined;
    const frozen = read_small(paths.cgroup_freeze, &buffer) orelse "0";
    return if (std.mem.startsWith(u8, frozen, "1")) .paused else .running;
}

/// The link between `a` and `b` (either may be the runner) goes up or down on both ends.
pub fn link_set(
    system: *const schema.System,
    a: []const u8,
    b: []const u8,
    state: LinkState,
) !void {
    assert(!std.mem.eql(u8, a, b));
    const pid_a = pid_of(a) orelse return; // Not running: no link to change.
    const pid_b = pid_of(b) orelse return;
    const address_a = try endpoint_address(system, a);
    const address_b = try endpoint_address(system, b);
    var name_a: [netlink.interface_name_size_max]u8 = undefined;
    var name_b: [netlink.interface_name_size_max]u8 = undefined;
    const interface_a = interface_name(&name_a, b);
    const interface_b = interface_name(&name_b, a);
    try netlink.in_namespace_of(pid_a, link_change, .{ interface_a, address_b, state });
    try netlink.in_namespace_of(pid_b, link_change, .{ interface_b, address_a, state });
}

/// Linux drops a link's routes when it goes down: bringing it up restores the host route.
fn link_change(
    socket: *netlink.Socket,
    interface: []const u8,
    peer: netlink.Address,
    state: LinkState,
) !void {
    try socket.link_set(interface, state);
    if (state == .down) return;
    socket.route_add(interface, peer) catch |err| switch (err) {
        error.Exists => {},
        else => return err,
    };
    // A node's link to the runner also carries its default route.
    if (!std.mem.eql(u8, &peer, &schema.runner_address)) return;
    socket.route_default(interface, peer) catch |err| switch (err) {
        error.Exists => {},
        else => return err,
    };
}

fn endpoint_address(system: *const schema.System, name: []const u8) !netlink.Address {
    if (std.mem.eql(u8, name, schema.runner_name)) return schema.runner_address;
    const node = system.node(name) orelse return error.UnknownNode;
    return address_now(node);
}

/// A node's address now: the system's, or the one a restart gave it (readdress).
pub fn address_now(node: *const schema.Resolved) !netlink.Address {
    var paths: Paths = undefined;
    try paths.init(node.name);
    var path_buffer: [path_size_max]u8 = undefined;
    const path = try print_z(&path_buffer, "{s}/address", .{paths.directory});
    var buffer: [32]u8 = undefined;
    if (read_small(path, &buffer)) |text| return address_parse(std.mem.trim(u8, text, " \n"));
    return address_parse(node.address);
}

/// The node, stopped, rejoins with a new address when it starts again (Faults.new_address):
/// 10.<n>.0.<x> for its n-th one (x as in its first, so no two nodes share one), and every
/// hosts file (the runner's, each node's) names it there.
pub fn readdress(system: *const schema.System, node: *const schema.Resolved) !netlink.Address {
    const old = try address_now(node);
    const new = netlink.Address{ 10, if (old[1] >= 254) 1 else old[1] + 1, 0, old[3] };
    var paths: Paths = undefined;
    try paths.init(node.name);
    var path_buffer: [path_size_max]u8 = undefined;
    const path = try print_z(&path_buffer, "{s}/address", .{paths.directory});
    var text_buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&text_buffer, "{d}.{d}.{d}.{d}\n", .{
        new[0], new[1], new[2], new[3],
    });
    try file_write(path, text);
    try hosts_write("/etc/hosts", system);
    for (system.nodes) |*other| {
        var other_paths: Paths = undefined;
        try other_paths.init(other.name);
        var hosts_buffer: [path_size_max]u8 = undefined;
        const hosts = try print_z(&hosts_buffer, "{s}/etc/hosts", .{other_paths.root});
        if (exists(hosts)) try hosts_write(hosts, system);
    }
    sdk.event("node_address", .{ .node = node.name, .address = std.mem.trimEnd(u8, text, "\n") });
    return new;
}

/// Degrades the direction `from` → `to` of a link (delay, jitter, loss), or with null restores it.
pub fn link_degrade(from: []const u8, to: []const u8, netem: ?netlink.Netem) !void {
    assert(!std.mem.eql(u8, from, to));
    const pid = pid_of(from) orelse return;
    var name: [netlink.interface_name_size_max]u8 = undefined;
    const interface = interface_name(&name, to);
    if (netem) |settings| {
        try netlink.in_namespace_of(pid, netlink.Socket.netem_set, .{ interface, settings });
    } else {
        try netlink.in_namespace_of(pid, netlink.Socket.netem_clear, .{interface});
    }
}

pub const Netem = netlink.Netem;

/// The PID (in the guest's root namespace) of the node's first process, or 1 for the runner.
pub fn pid_of(name: []const u8) ?linux.pid_t {
    if (std.mem.eql(u8, name, schema.runner_name)) return 1;
    return pid_read(name);
}

/// The PID the node's pidfile names, alive or not.
pub fn pid_recorded(name: []const u8) ?linux.pid_t {
    var paths: Paths = undefined;
    paths.init(name) catch return null;
    var buffer: [32]u8 = undefined;
    const text = read_small(paths.pid, &buffer) orelse return null;
    return std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, text, " \n"), 10) catch null;
}

fn pid_read(name: []const u8) ?linux.pid_t {
    var paths: Paths = undefined;
    paths.init(name) catch return null;
    var buffer: [32]u8 = undefined;
    const text = read_small(paths.pid, &buffer) orelse return null;
    const pid = std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, text, " \n"), 10) catch return null;
    if (linux.errno(linux.kill(pid, @enumFromInt(0))) != .SUCCESS) return null;
    return pid;
}

const Paths = struct {
    buffers: [12][path_size_max]u8 = undefined,
    directory: [:0]const u8 = "",
    lower: [:0]const u8 = "",
    /// The writable layer's mount (upper and work are in it), its disk image and loop device
    /// (crash faults), and a mark that layer and root are mounted.
    layer: [:0]const u8 = "",
    image: [:0]const u8 = "",
    loop: [:0]const u8 = "",
    mounted: [:0]const u8 = "",
    upper: [:0]const u8 = "",
    work: [:0]const u8 = "",
    root: [:0]const u8 = "",
    pid: [:0]const u8 = "",
    output: [:0]const u8 = "",
    cgroup: [:0]const u8 = "",
    cgroup_procs: [:0]const u8 = "",
    cgroup_kill: [:0]const u8 = "",
    cgroup_freeze: [:0]const u8 = "",
    cgroup_events: [:0]const u8 = "",
    cgroup_buffers: [5][path_size_max]u8 = undefined,

    /// In place: the paths point into the struct's own buffers.
    fn init(paths: *Paths, name: []const u8) !void {
        if (!schema.name_valid(name)) return error.BadNodeName;
        paths.* = .{};
        const b = &paths.buffers;
        paths.directory = try print_z(&b[0], state_root ++ "/{s}", .{name});
        paths.lower = try print_z(&b[1], state_root ++ "/{s}/lower", .{name});
        paths.upper = try print_z(&b[2], state_root ++ "/{s}/layer/upper", .{name});
        paths.work = try print_z(&b[3], state_root ++ "/{s}/layer/work", .{name});
        paths.layer = try print_z(&b[8], state_root ++ "/{s}/layer", .{name});
        paths.image = try print_z(&b[9], state_root ++ "/{s}/disk.img", .{name});
        paths.loop = try print_z(&b[10], state_root ++ "/{s}/loop", .{name});
        paths.mounted = try print_z(&b[11], state_root ++ "/{s}/mounted", .{name});
        paths.root = try print_z(&b[4], state_root ++ "/{s}/root", .{name});
        paths.pid = try print_z(&b[5], state_root ++ "/{s}/pid", .{name});
        paths.output = try print_z(&b[6], state_root ++ "/{s}/output.log", .{name});
        paths.cgroup = try print_z(&b[7], cgroup_root ++ "/{s}", .{name});
        const c = &paths.cgroup_buffers;
        paths.cgroup_procs = try print_z(&c[0], "{s}/cgroup.procs", .{paths.cgroup});
        paths.cgroup_kill = try print_z(&c[1], "{s}/cgroup.kill", .{paths.cgroup});
        paths.cgroup_freeze = try print_z(&c[2], "{s}/cgroup.freeze", .{paths.cgroup});
        paths.cgroup_events = try print_z(&c[3], "{s}/cgroup.events", .{paths.cgroup});
    }
};

/// Mounts the node's disk and overlay once, and (re)writes its network identity files.
fn root_prepare(
    paths: *const Paths,
    system: *const schema.System,
    node: *const schema.Resolved,
) !void {
    if (!exists(paths.root)) {
        try mkdir_all(paths.directory);
        for ([_][:0]const u8{ paths.lower, paths.layer, paths.root }) |path| try mkdir_all(path);
        var device_buffer: [32]u8 = undefined;
        const device = try print_z(&device_buffer, "/dev/{s}", .{node.disk});
        try mount(device, paths.lower, "erofs", linux.MS.RDONLY, null);
    }
    // Once, and again after a crash or a wipe unmounted them.
    if (!exists(paths.mounted)) {
        try layer_mount(paths, node);
        for ([_][:0]const u8{ paths.upper, paths.work }) |path| try mkdir_all(path);
        var options_buffer: [3 * path_size_max]u8 = undefined;
        const options = try print_z(&options_buffer, "lowerdir={s},upperdir={s},workdir={s}", .{
            paths.lower, paths.upper, paths.work,
        });
        try mount("overlay", paths.root, "overlay", 0, options);
        try file_write(paths.mounted, "");
    }
    try mkdir_all(paths.cgroup);
    var path_buffer: [path_size_max]u8 = undefined;
    try mkdir_all(try print_z(&path_buffer, "{s}/etc", .{paths.root}));
    try hosts_write(try print_z(&path_buffer, "{s}/etc/hosts", .{paths.root}), system);
    const resolv = try print_z(&path_buffer, "{s}/etc/resolv.conf", .{paths.root});
    _ = linux.unlink(resolv); // Often a symlink in images; ours is a plain file.
    try file_write(resolv, "# determinismo: names are in /etc/hosts\n");
    const hostname = try print_z(&path_buffer, "{s}/etc/hostname", .{paths.root});
    _ = linux.unlink(hostname);
    var line_buffer: [schema.node_name_size_max + 1]u8 = undefined;
    try file_write(hostname, try std.fmt.bufPrint(&line_buffer, "{s}\n", .{node.name}));
}

fn hosts_write(path: [:0]const u8, system: *const schema.System) !void {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.writeAll("127.0.0.1 localhost\n");
    const runner = schema.runner_address;
    try writer.print("{d}.{d}.{d}.{d} {s}\n", .{
        runner[0], runner[1], runner[2], runner[3], schema.runner_name,
    });
    for (system.nodes) |*node| {
        const address = try address_now(node);
        try writer.print("{d}.{d}.{d}.{d} {s}\n", .{
            address[0], address[1], address[2], address[3], node.name,
        });
    }
    _ = linux.unlink(path);
    try file_write(path, writer.buffered());
}

fn cgroup_join(paths: *const Paths, pid: linux.pid_t) !void {
    var buffer: [32]u8 = undefined;
    try file_write(paths.cgroup_procs, try std.fmt.bufPrint(&buffer, "{d}\n", .{pid}));
}

/// Moves the calling process into the node's cgroup or, when the node delegates controllers to
/// cgroups of its own (a container runtime in the node), into a leaf under it: cgroup v2 keeps
/// processes out of cgroups that have controllers enabled for their children.
fn cgroup_join_self(paths: *const Paths) !void {
    const enabled = blk: {
        var buffer: [256]u8 = undefined;
        var path_buffer: [path_size_max]u8 = undefined;
        const control = try print_z(&path_buffer, "{s}/cgroup.subtree_control", .{paths.cgroup});
        const text = read_small(control, &buffer) orelse break :blk false;
        break :blk std.mem.trim(u8, text, " \n").len > 0;
    };
    if (!enabled) return file_write(paths.cgroup_procs, "0");
    var leaf_buffer: [path_size_max]u8 = undefined;
    const leaf = try print_z(&leaf_buffer, "{s}/det-exec", .{paths.cgroup});
    try mkdir_all(leaf);
    var procs_buffer: [path_size_max]u8 = undefined;
    try file_write(try print_z(&procs_buffer, "{s}/cgroup.procs", .{leaf}), "0");
}

fn memory_limit(paths: *const Paths, memory_max_mib: ?u32) !void {
    var path_buffer: [path_size_max]u8 = undefined;
    const path = try print_z(&path_buffer, "{s}/memory.max", .{paths.cgroup});
    var value_buffer: [32]u8 = undefined;
    const value = if (memory_max_mib) |mib|
        try std.fmt.bufPrint(&value_buffer, "{d}\n", .{@as(u64, mib) * 1024 * 1024})
    else
        "max\n";
    try file_write(path, value);
}

fn cgroup_populated(paths: *const Paths) !bool {
    var buffer: [256]u8 = undefined;
    const events = read_small(paths.cgroup_events, &buffer) orelse return error.NoCgroup;
    return std.mem.indexOf(u8, events, "populated 1") != null;
}

/// Links the new node to the runner and to every running node.
fn network_connect(
    system: *const schema.System,
    node: *const schema.Resolved,
    pid: linux.pid_t,
) !void {
    try netlink.in_namespace_of(pid, netlink.Socket.link_set, .{ "lo", .up });
    const address = try address_now(node);
    const self = Endpoint{ .name = node.name, .address = address, .pid = pid };
    try link_create(self, .{
        .name = schema.runner_name,
        .address = schema.runner_address,
        .pid = 1,
    });
    // A default route through the runner, as containers have one: some software (K3s, etcd)
    // looks for it to choose its address. Nothing lies beyond the runner.
    var name: [netlink.interface_name_size_max]u8 = undefined;
    const runner_interface = interface_name(&name, schema.runner_name);
    const route_default = netlink.Socket.route_default;
    try netlink.in_namespace_of(pid, route_default, .{ runner_interface, schema.runner_address });
    for (system.nodes) |*peer| {
        if (std.mem.eql(u8, peer.name, node.name)) continue;
        const peer_pid = pid_read(peer.name) orelse continue;
        try link_create(self, .{
            .name = peer.name,
            .address = try address_now(peer),
            .pid = peer_pid,
        });
    }
}

const Endpoint = struct { name: []const u8, address: netlink.Address, pid: linux.pid_t };

fn link_create(a: Endpoint, b: Endpoint) !void {
    var name_a: [netlink.interface_name_size_max]u8 = undefined;
    var name_b: [netlink.interface_name_size_max]u8 = undefined;
    const interface_a = interface_name(&name_a, b.name); // In a's namespace, towards b.
    const interface_b = interface_name(&name_b, a.name);
    const ends = [2]netlink.VethEnd{
        .{ .name = interface_a, .mac = mac(a.address, b.address), .pid = a.pid },
        .{ .name = interface_b, .mac = mac(b.address, a.address), .pid = b.pid },
    };
    // After a restart, the dead namespace's links disappear when the kernel gets to it (a
    // worker, later under load): the peer's old end is removed instead of waited for (both ends
    // of a veth go together). Created from inside a's namespace: one end local, the peer moved
    // to b's.
    for (0..link_attempts_max) |_| {
        const create = netlink.Socket.veth_create;
        netlink.in_namespace_of(a.pid, create, .{ends}) catch |err| switch (err) {
            error.Exists => {
                const delete = netlink.Socket.link_delete;
                netlink.in_namespace_of(b.pid, delete, .{interface_b}) catch {};
                netlink.in_namespace_of(a.pid, delete, .{interface_a}) catch {};
                sleep_ns(poll_interval_ns);
                continue;
            },
            else => return err,
        };
        break;
    } else return error.StaleLink;
    try netlink.in_namespace_of(a.pid, link_configure, .{ interface_a, a.address, b.address });
    try netlink.in_namespace_of(b.pid, link_configure, .{ interface_b, b.address, a.address });
}

fn link_configure(
    socket: *netlink.Socket,
    interface: []const u8,
    local: netlink.Address,
    peer: netlink.Address,
) !void {
    try socket.address_add(interface, local);
    try socket.link_set(interface, .up);
    try socket.route_add(interface, peer);
}

fn interface_name(buffer: *[netlink.interface_name_size_max]u8, peer: []const u8) []const u8 {
    assert(peer.len <= schema.node_name_size_max);
    return std.fmt.bufPrint(buffer, "d-{s}", .{peer}) catch unreachable;
}

fn mac(local: netlink.Address, peer: netlink.Address) [6]u8 {
    return .{ 0x02, 0xde, local[2], local[3], peer[2], peer[3] };
}

pub fn address_parse(text: []const u8) !netlink.Address {
    var address: netlink.Address = undefined;
    var parts = std.mem.splitScalar(u8, text, '.');
    for (&address) |*byte| {
        byte.* = try std.fmt.parseInt(u8, parts.next() orelse return error.BadAddress, 10);
    }
    if (parts.next() != null) return error.BadAddress;
    return address;
}

fn ready_wait(node: *const schema.Resolved) !void {
    const ready = node.ready orelse return;
    const address = try address_now(node);
    for (0..ready_attempts_max) |_| {
        if (tcp_accepts(address, ready.tcp)) {
            sdk.event("node_ready", .{ .node = node.name });
            return;
        }
        var paths: Paths = undefined;
        try paths.init(node.name);
        if (!try cgroup_populated(&paths)) return error.NodeExited; // Its processes are gone.
        sleep_ns(poll_interval_ns);
    }
    return error.NodeNotReady;
}

fn tcp_accepts(address: netlink.Address, port: u16) bool {
    const fd = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(fd) != .SUCCESS) return false;
    defer _ = linux.close(@intCast(fd));
    var target = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(address),
    };
    const result = linux.connect(@intCast(fd), @ptrCast(&target), @sizeOf(linux.sockaddr.in));
    return linux.errno(result) == .SUCCESS;
}

/// Everything the child needs after clone, prepared before it (the child only makes syscalls).
const Launch = struct {
    root: [:0]const u8,
    hostname: []const u8,
    workdir: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    /// Absolute candidates for argv[0], one per PATH entry (or argv[0] itself).
    executables: []const [:0]const u8,
    uid: ?u32,
    gid: ?u32,
    privileged: bool,

    fn init(arena: std.mem.Allocator, node: *const schema.Resolved, paths: *const Paths) !Launch {
        if (node.command.len == 0 or node.command.len >= arguments_max) return error.BadCommand;
        if (node.env.len + platform_environment.len >= environment_max) {
            return error.TooManyEnvironmentEntries;
        }
        const argv = try arena.allocSentinel(?[*:0]const u8, node.command.len, null);
        for (node.command, argv) |argument, *slot| slot.* = try arena.dupeSentinel(u8, argument, 0);
        const envp_count = node.env.len + platform_environment.len;
        const envp = try arena.allocSentinel(?[*:0]const u8, envp_count, null);
        var path_value: []const u8 = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
        for (node.env, envp[0..node.env.len]) |entry, *slot| {
            slot.* = try arena.dupeSentinel(u8, entry, 0);
            if (std.mem.startsWith(u8, entry, "PATH=")) path_value = entry["PATH=".len..];
        }
        for (platform_environment, envp[node.env.len..]) |entry, *slot| slot.* = entry.ptr;
        const ids: ?Ids = if (node.user) |user| try user_resolve(arena, paths.root, user) else null;
        return .{
            .root = paths.root,
            .hostname = node.name,
            .workdir = try arena.dupeSentinel(u8, node.workdir, 0),
            .argv = argv.ptr,
            .envp = envp.ptr,
            .executables = try executables(arena, node.command[0], path_value),
            .uid = if (ids) |i| i.uid else null,
            .gid = if (ids) |i| i.gid else null,
            .privileged = node.privileged,
        };
    }

    /// In the child, PID 1 of the node's namespaces.
    /// Its stdout and stderr are the forwarder's pipes (output.zig): events and output.log.
    fn exec(launch: *const Launch, stdout: linux.fd_t, stderr: linux.fd_t) noreturn {
        const null_input = linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
        _ = linux.dup2(stdout, 1);
        _ = linux.dup2(stderr, 2);
        if (linux.errno(null_input) == .SUCCESS) _ = linux.dup2(@intCast(null_input), 0);
        launch.mounts() catch |err| die("mounts", err);
        _ = linux.syscall2(.sethostname, @intFromPtr(launch.hostname.ptr), launch.hostname.len);
        launch.exec_in_root();
    }

    /// In the node's root: drop to its user, enter its working directory, run the command.
    fn exec_in_root(launch: *const Launch) noreturn {
        if (launch.gid) |gid| {
            _ = linux.syscall2(.setgroups, 0, 0);
            if (linux.errno(linux.setgid(gid)) != .SUCCESS) die("setgid", error.Setgid);
        }
        if (launch.uid) |uid| {
            if (linux.errno(linux.setuid(uid)) != .SUCCESS) die("setuid", error.Setuid);
        }
        if (linux.errno(linux.chdir(launch.workdir)) != .SUCCESS) _ = linux.chdir("/");
        for (launch.executables) |path| {
            _ = linux.execve(path, launch.argv, launch.envp);
        }
        die("exec", error.ExecutableNotFound);
    }

    fn mounts(launch: *const Launch) !void {
        try mount(null, "/", null, linux.MS.REC | linux.MS.PRIVATE, null);
        var buffer: [path_size_max]u8 = undefined;
        const Target = struct {
            path: []const u8,
            fs: [:0]const u8,
            flags: u32,
            data: ?[:0]const u8,
        };
        const read_only: u32 = if (launch.privileged) 0 else linux.MS.RDONLY;
        const targets = [_]Target{
            .{ .path = "proc", .fs = "proc", .flags = 0, .data = null },
            .{ .path = "sys", .fs = "sysfs", .flags = read_only, .data = null },
            .{ .path = "sys/fs/cgroup", .fs = "cgroup2", .flags = read_only, .data = null },
            .{ .path = "dev", .fs = "devtmpfs", .flags = 0, .data = null },
            .{ .path = "dev/pts", .fs = "devpts", .flags = 0, .data = "newinstance,ptmxmode=0666" },
            .{ .path = "dev/shm", .fs = "tmpfs", .flags = 0, .data = null },
        };
        for (targets) |target| {
            const path = try print_z(&buffer, "{s}/{s}", .{ launch.root, target.path });
            try mkdir_all(path);
            const data: ?[*:0]const u8 = if (target.data) |d| d.ptr else null;
            try mount(target.fs, path, target.fs, target.flags, data);
        }
        // The platform's binaries and the fault injector's control FIFO, read-only.
        const platform = try print_z(&buffer, "{s}/opt/determinismo", .{launch.root});
        try mkdir_all(platform);
        try mount("/opt/determinismo", platform, null, linux.MS.BIND | linux.MS.REC, null);
        const remount = linux.MS.REMOUNT | linux.MS.BIND | linux.MS.RDONLY;
        try mount(null, platform, null, remount, null);
        // Antithesis's native library, where its SDKs and instrumented programs look for it.
        try mkdir_all(try print_z(&buffer, "{s}/usr/lib", .{launch.root}));
        const voidstar = try print_z(&buffer, "{s}/usr/lib/libvoidstar.so", .{launch.root});
        const create: linux.O = .{ .ACCMODE = .RDONLY, .CREAT = true, .CLOEXEC = true };
        const created = linux.open(voidstar, create, 0o644);
        if (linux.errno(created) == .SUCCESS) _ = linux.close(@intCast(created));
        try mount(voidstar_path, voidstar, null, linux.MS.BIND, null);
        try mount(null, voidstar, null, remount, null);
        // What container runtimes add to /dev (bash process substitution needs /dev/fd).
        const links = [_]struct { path: []const u8, target: [:0]const u8 }{
            .{ .path = "dev/fd", .target = "/proc/self/fd" },
            .{ .path = "dev/stdin", .target = "/proc/self/fd/0" },
            .{ .path = "dev/stdout", .target = "/proc/self/fd/1" },
            .{ .path = "dev/stderr", .target = "/proc/self/fd/2" },
        };
        for (links) |link| {
            const path = try print_z(&buffer, "{s}/{s}", .{ launch.root, link.path });
            switch (linux.errno(linux.symlink(link.target, path))) {
                .SUCCESS, .EXIST => {},
                else => return error.Symlink,
            }
        }
        // The namespace began as a copy of the guest's mounts, other nodes' disks and roots
        // among them: a copy held here would keep another node's disk alive after its crash
        // (its remount would get the old, shut down filesystem back).
        try mounts_detach_others(launch.root);
        // The guest's root is the initramfs, where pivot_root is not allowed: move the node's
        // root over it and chroot, as switch_root does. The mount namespace is the node's own.
        if (linux.errno(linux.chdir(launch.root)) != .SUCCESS) return error.Chdir;
        try mount(".", "/", null, linux.MS.MOVE, null);
        if (linux.errno(linux.chroot(".")) != .SUCCESS) return error.Chroot;
        if (linux.errno(linux.chdir("/")) != .SUCCESS) return error.Chdir;
    }
};

const voidstar_path = "/opt/determinismo/lib/libvoidstar.so"; // initramfs.zig's.
const mounts_max = 4096;
var mountinfo_buffer: [1 << 20]u8 = undefined;

/// Detaches every mount of this (new, private) namespace other than `root`, what is under it
/// and its ancestors (which hold it until it moves over `/`).
fn mounts_detach_others(root: []const u8) !void {
    const fd = linux.open("/proc/self/mountinfo", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.NoMountinfo;
    defer _ = linux.close(@intCast(fd));
    var size: usize = 0;
    while (size < mountinfo_buffer.len) {
        const free = mountinfo_buffer[size..];
        const result = linux.read(@intCast(fd), free.ptr, free.len);
        if (linux.errno(result) != .SUCCESS) return error.ReadFailed;
        if (result == 0) break;
        size += result;
    } else return error.TooManyMounts;
    var points: [mounts_max][]const u8 = undefined;
    var count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, mountinfo_buffer[0..size], '\n');
    while (lines.next()) |line| {
        // id, parent id, major:minor, root, then the mount point.
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        for (0..4) |_| _ = fields.next();
        const point = fields.next() orelse continue;
        if (count == mounts_max) return error.TooManyMounts;
        points[count] = point;
        count += 1;
    }
    var index = count;
    while (index > 0) { // Children first.
        index -= 1;
        const point = points[index];
        if (std.mem.eql(u8, point, root) or path_under(point, root) or path_under(root, point)) {
            continue;
        }
        var buffer: [path_size_max]u8 = undefined;
        const path = print_z(&buffer, "{s}", .{point}) catch continue;
        _ = linux.umount2(path, linux.MNT.DETACH); // Gone already with a detached parent.
    }
}

/// Whether `path` is strictly under `directory` ("/" is above every other path).
fn path_under(path: []const u8, directory: []const u8) bool {
    if (std.mem.eql(u8, directory, "/")) return !std.mem.eql(u8, path, "/");
    return path.len > directory.len and std.mem.startsWith(u8, path, directory) and
        path[directory.len] == '/';
}

test path_under {
    try std.testing.expect(path_under("/run/det/nodes/a/root/proc", "/run/det/nodes/a/root"));
    try std.testing.expect(path_under("/run", "/"));
    try std.testing.expect(!path_under("/", "/"));
    try std.testing.expect(!path_under("/run/det/nodes/ab", "/run/det/nodes/a"));
    try std.testing.expect(!path_under("/run/det/nodes/a/root", "/run/det/nodes/a/root"));
}

const Ids = struct { uid: u32, gid: u32 };

/// `user[:group]`, each a number or a name from the node's /etc/passwd and /etc/group.
fn user_resolve(arena: std.mem.Allocator, root: []const u8, text: []const u8) !Ids {
    var parts = std.mem.splitScalar(u8, text, ':');
    const user = parts.next().?;
    const group = parts.next();
    var buffer: [path_size_max]u8 = undefined;
    const passwd = try read_file(arena, try print_z(&buffer, "{s}/etc/passwd", .{root}), 1 << 20);
    const entry = id_lookup(passwd, user) orelse return error.UnknownUser;
    var ids = Ids{ .uid = entry.id, .gid = entry.group };
    if (group) |name| {
        const group_path = try print_z(&buffer, "{s}/etc/group", .{root});
        const groups = try read_file(arena, group_path, 1 << 20);
        ids.gid = (id_lookup(groups, name) orelse return error.UnknownGroup).id;
    }
    return ids;
}

/// Finds `name` (or a number) in passwd/group lines: `name:x:id:group...`.
fn id_lookup(database: []const u8, name: []const u8) ?struct { id: u32, group: u32 } {
    if (std.fmt.parseInt(u32, name, 10)) |id| {
        return .{ .id = id, .group = id };
    } else |_| {}
    var lines = std.mem.tokenizeScalar(u8, database, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        if (!std.mem.eql(u8, fields.next() orelse continue, name)) continue;
        _ = fields.next(); // Password.
        const id = std.fmt.parseInt(u32, fields.next() orelse return null, 10) catch return null;
        const group_text = fields.next() orelse "";
        const group = std.fmt.parseInt(u32, group_text, 10) catch id;
        return .{ .id = id, .group = group };
    }
    return null;
}

fn executables(
    arena: std.mem.Allocator,
    program: []const u8,
    path_value: []const u8,
) ![]const [:0]const u8 {
    if (std.mem.indexOfScalar(u8, program, '/') != null) {
        const single = try arena.alloc([:0]const u8, 1);
        single[0] = try arena.dupeSentinel(u8, program, 0);
        return single;
    }
    var list: std.ArrayList([:0]const u8) = .empty;
    var directories = std.mem.tokenizeScalar(u8, path_value, ':');
    while (directories.next()) |directory| {
        const path = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ directory, program }, 0);
        try list.append(arena, path);
    }
    return list.items;
}

fn die(what: []const u8, err: anyerror) noreturn {
    std.debug.print("det-nodes: {s} failed: {s}\n", .{ what, @errorName(err) });
    linux.exit_group(127);
}

fn mount(
    special: ?[*:0]const u8,
    target: [*:0]const u8,
    fs: ?[*:0]const u8,
    flags: u32,
    data: ?[*:0]const u8,
) !void {
    const result = linux.mount(special, target, fs, flags, if (data) |d| @intFromPtr(d) else 0);
    if (linux.errno(result) != .SUCCESS) {
        const errno = @tagName(linux.errno(result));
        std.debug.print("det-nodes: mount {s} failed: {s}\n", .{ target, errno });
        return error.MountFailed;
    }
}

pub fn mkdir_all(path: []const u8) !void {
    assert(path.len > 0 and path.len < path_size_max);
    var buffer: [path_size_max]u8 = undefined;
    for (path, 0..) |byte, index| {
        if (byte != '/' and index + 1 != path.len) continue;
        const end = if (byte == '/') index else index + 1;
        if (end == 0) continue;
        @memcpy(buffer[0..end], path[0..end]);
        buffer[end] = 0;
        const result = linux.mkdir(buffer[0..end :0], 0o755);
        switch (linux.errno(result)) {
            .SUCCESS, .EXIST => {},
            else => return error.Mkdir,
        }
    }
}

fn exists(path: [:0]const u8) bool {
    return linux.errno(linux.access(path, linux.F_OK)) == .SUCCESS;
}

pub fn file_write(path: [:0]const u8, content: []const u8) !void {
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const fd = linux.open(path, flags, 0o644);
    if (linux.errno(fd) != .SUCCESS) return error.OpenFailed;
    defer _ = linux.close(@intCast(fd));
    const written = linux.write(@intCast(fd), content.ptr, content.len);
    if (linux.errno(written) != .SUCCESS or written != content.len) return error.WriteFailed;
}

fn read_small(path: [:0]const u8, buffer: []u8) ?[]const u8 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    const size = linux.read(@intCast(fd), buffer.ptr, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    return buffer[0..size];
}

fn read_file(arena: std.mem.Allocator, path: [:0]const u8, size_max: u32) ![]const u8 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.OpenFailed;
    defer _ = linux.close(@intCast(fd));
    const buffer = try arena.alloc(u8, size_max);
    var size: u64 = 0;
    while (size < buffer.len) {
        const result = linux.read(@intCast(fd), buffer[size..].ptr, buffer.len - size);
        if (linux.errno(result) != .SUCCESS) return error.ReadFailed;
        if (result == 0) return buffer[0..size];
        size += result;
    }
    return error.FileTooLarge;
}

/// Formats into `buffer` as a NUL-terminated path.
pub fn print_z(buffer: []u8, comptime format: []const u8, arguments: anytype) ![:0]u8 {
    return std.fmt.bufPrintSentinel(buffer, format, arguments, 0);
}

pub fn sleep_ns(duration_ns: u64) void {
    const request = linux.timespec{
        .sec = @intCast(duration_ns / std.time.ns_per_s),
        .nsec = @intCast(duration_ns % std.time.ns_per_s),
    };
    _ = linux.nanosleep(&request, null);
}

test id_lookup {
    const passwd = "root:x:0:0:root:/root:/bin/sh\nredis:x:999:1000::/data:/bin/false\n";
    try std.testing.expectEqual(@as(u32, 999), id_lookup(passwd, "redis").?.id);
    try std.testing.expectEqual(@as(u32, 1000), id_lookup(passwd, "redis").?.group);
    try std.testing.expectEqual(@as(u32, 42), id_lookup(passwd, "42").?.id);
    try std.testing.expect(id_lookup(passwd, "nobody") == null);
}

test address_parse {
    try std.testing.expectEqual(netlink.Address{ 10, 0, 0, 7 }, try address_parse("10.0.0.7"));
    try std.testing.expectError(error.BadAddress, address_parse("10.0.0"));
}

test mac {
    const expected = [6]u8{ 2, 0xde, 0, 2, 0, 1 };
    try std.testing.expectEqual(expected, mac(.{ 10, 0, 0, 2 }, .{ 10, 0, 0, 1 }));
}
