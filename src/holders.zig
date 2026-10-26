// SPDX-License-Identifier: MIT
//! In-run snapshots for the tree explorer (main.zig). When a timeline reaches a behavior the
//! tree did not know, it pauses just after it, where a replay to that moment would stop (vm.zig's
//! hold points), forks a holder and goes on. The holder keeps the machine there, copy-on-write.
//! When the explorer returns to that moment, the holder copies it into a snapshot; to a later
//! moment of the same timeline, it replays only from there. Without a holder the explorer replays
//! from the timeline's start, as before: the tree is the same either way, only faster.
//!
//! A holder costs the memory its timeline writes after it (the pages it still shares are free):
//! a timeline keeps a few, spread out, none while memory runs low, and the kernel's OOM killer
//! takes holders first (a node then costs a replay, never a timeline).
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const Snapshot = @import("snapshot.zig");
const VM = @import("vm.zig");
const fd_pass = @import("fd_pass.zig");

/// Holders a timeline keeps at most: past it, the one closest to the one before it goes, so the
/// replays from a holder to a later moment stay short wherever the moment is.
pub const per_timeline_max = 8;
/// Holders of a timeline are its length over this apart at least (a timeline reaches new
/// behaviors in bursts: one holder per burst).
const spacing_divisor = 64;
const spacing_ns_min = 10 * std.time.ns_per_ms;
/// No holder is made with less memory than this available (MemAvailable).
const memory_reserve_bytes = 8 << 30;

/// What a holder tells the explorer once made, and what the explorer asks it.
const Registration = extern struct { pid: linux.pid_t, branch: u32, vtime_ns: u64 };
const Request = extern struct { vtime_ns: u64 };

/// The explorer's end: an abstract Unix socket holders connect to as they are made. The explorer
/// becomes their subreaper, so holders whose worker exited are still its to wait for.
pub const Listener = struct {
    fd: linux.fd_t,
    address: linux.sockaddr.un,
    held: [held_max]Held = undefined,
    count: u32 = 0,

    /// A generation's holders: 16 timelines of per_timeline_max, with room.
    const held_max = 512;
    const Held = struct { pid: linux.pid_t, branch: u32, vtime_ns: u64, socket: linux.fd_t };

    pub fn init(listener: *Listener) !void {
        const flags = linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK;
        const created = linux.socket(linux.AF.UNIX, flags, 0);
        if (linux.errno(created) != .SUCCESS) return error.Socket;
        listener.* = .{ .fd = @intCast(created), .address = .{ .path = @splat(0) } };
        errdefer _ = linux.close(listener.fd);
        // Abstract (a leading NUL): no file to clean up, gone with the explorer.
        _ = try std.fmt.bufPrint(listener.address.path[1..], "determinismo-holders-{d}", .{
            linux.getpid(),
        });
        const bound = linux.bind(listener.fd, @ptrCast(&listener.address), @sizeOf(linux.sockaddr.un));
        if (linux.errno(bound) != .SUCCESS) return error.Bind;
        if (linux.errno(linux.listen(listener.fd, held_max)) != .SUCCESS) return error.Listen;
        const subreaper = linux.prctl(@intFromEnum(linux.PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0);
        if (linux.errno(subreaper) != .SUCCESS) return error.Subreaper;
    }

    pub fn deinit(listener: *Listener) void {
        listener.release();
        _ = linux.close(listener.fd);
    }

    /// After a generation's timelines ran: the holders they made (each registered before its
    /// worker went on, so all are queued by now).
    pub fn collect(listener: *Listener) void {
        while (listener.count < held_max) {
            const accepted = linux.accept4(listener.fd, null, null, linux.SOCK.CLOEXEC);
            if (linux.errno(accepted) != .SUCCESS) return; // None left (EAGAIN).
            const socket: linux.fd_t = @intCast(accepted);
            var registration: Registration = undefined;
            if (!read_exact(socket, std.mem.asBytes(&registration))) {
                _ = linux.close(socket);
                continue;
            }
            listener.held[listener.count] = .{
                .pid = registration.pid,
                .branch = registration.branch,
                .vtime_ns = registration.vtime_ns,
                .socket = socket,
            };
            listener.count += 1;
        }
    }

    pub const Taken = struct { socket: linux.fd_t, pid: linux.pid_t, replay_ns: u64 };

    /// The latest holder of `branch` at or before `vtime_ns` that takes the request (one that
    /// was dropped does not): its socket, where the snapshot comes back as from a node-making
    /// child, and its pid. Null when none does.
    pub fn take(listener: *Listener, branch: u32, vtime_ns: u64) ?Taken {
        while (true) {
            var best: ?*Held = null;
            for (listener.held[0..listener.count]) |*held| {
                if (held.socket < 0 or held.branch != branch or held.vtime_ns > vtime_ns) continue;
                if (best == null or held.vtime_ns > best.?.vtime_ns) best = held;
            }
            const held = best orelse return null;
            const socket = held.socket;
            held.socket = -1;
            const request = Request{ .vtime_ns = vtime_ns };
            const bytes = std.mem.asBytes(&request);
            const sent = linux.sendto(socket, bytes.ptr, bytes.len, linux.MSG.NOSIGNAL, null, 0);
            if (linux.errno(sent) == .SUCCESS and sent == bytes.len) {
                return .{ .socket = socket, .pid = held.pid, .replay_ns = vtime_ns - held.vtime_ns };
            }
            _ = linux.close(socket); // Gone: dropped by its timeline, or killed for memory.
            reap(held.pid);
        }
    }

    /// The holders nobody took: told to go (their socket closes) and waited for.
    pub fn release(listener: *Listener) void {
        for (listener.held[0..listener.count]) |*held| {
            if (held.socket < 0) continue;
            _ = linux.close(held.socket);
            held.socket = -1;
            reap(held.pid);
        }
        listener.count = 0;
    }
};

/// A timeline's end, in the worker that runs it: VM.Hold's owner.
pub const Owner = struct {
    address: *const linux.sockaddr.un,
    /// Behaviors the tree knew before this generation: a holder follows one it did not.
    seen: *const std.AutoHashMapUnmanaged(u64, void),
    branch: u32,
    seed: u64,
    start_ns: u64,
    spacing_ns: u64,
    /// A capture's room (large: a snapshot carries the timeline's events state).
    snapshot: *Snapshot,
    make: Make,
    hold: VM.Hold = undefined,
    /// The moment armed (as the explorer will ask for it), and whether it follows a behavior
    /// (else it is periodic: a timeline that finds nothing new for a while still has holders,
    /// for the random moments the tree then returns to).
    armed_ns: ?u64 = null,
    armed_new: bool = false,
    last_ns: ?u64 = null,
    kept: [per_timeline_max + 1]Kept = undefined,
    kept_count: u32 = 0,

    const Kept = struct { pid: linux.pid_t, vtime_ns: u64 };

    /// Replays a holder's snapshot of the timeline to a later moment of it (main.zig's
    /// node_make), in the holder.
    pub const Make = struct {
        context: *anyopaque,
        function: *const fn (
            context: *anyopaque,
            vm: *VM,
            from: *const Snapshot,
            seed: u64,
            vtime_ns: u64,
        ) anyerror!*const Snapshot,
    };

    pub fn spacing(timeline_ns: ?u64) u64 {
        const length = timeline_ns orelse return spacing_ns_min;
        return @max(spacing_ns_min, length / spacing_divisor);
    }

    /// Without new behaviors, a holder this often: the timeline's spread over the most it keeps.
    fn period(owner: *const Owner) u64 {
        return owner.spacing_ns * (spacing_divisor / per_timeline_max);
    }

    pub fn attach(owner: *Owner, vm: *VM) !void {
        owner.hold = .{ .context = owner, .behaviors = behaviors, .reached = reached };
        vm.hold = &owner.hold;
        vm.hold_behaviors = vm.events.behavior_count; // Its parents' are known.
        try owner.arm(vm, owner.start_ns + owner.period(), false);
    }

    fn arm(owner: *Owner, vm: *VM, moment_ns: u64, new: bool) !void {
        owner.armed_ns = moment_ns;
        owner.armed_new = new;
        try vm.hold_arm(moment_ns);
    }

    /// The tree returns just after a behavior it did not know (main.zig's tree_returns): a
    /// hold point there, unless one was made a moment ago.
    fn behaviors(context: *anyopaque, vm: *VM, first_new: u32) !void {
        const owner: *Owner = @ptrCast(@alignCast(context));
        if (owner.armed_new) return; // One armed already: a periodic one gives way.
        for (vm.events.behaviors[first_new..vm.events.behavior_count]) |*behavior| {
            if (behavior.vtime_ns <= owner.start_ns) continue;
            if (owner.seen.contains(behavior.hash)) continue;
            const moment = @max(
                behavior.vtime_ns + std.time.ns_per_us,
                owner.start_ns + std.time.ns_per_ms,
            );
            if (owner.last_ns) |last| if (moment < last + owner.spacing_ns) return;
            return owner.arm(vm, moment, true);
        }
    }

    fn reached(context: *anyopaque, vm: *VM) !void {
        const owner: *Owner = @ptrCast(@alignCast(context));
        const moment = owner.armed_ns.?;
        owner.armed_ns = null;
        owner.armed_new = false;
        owner.last_ns = moment;
        try owner.arm(vm, moment + owner.period(), false); // The next, unless one is new first.
        if (memory_available() < memory_reserve_bytes) return;
        try owner.snapshot.capture(vm);
        const socket = connect(owner.address) orelse return; // No explorer listening.
        const pid = linux.fork();
        if (linux.errno(pid) != .SUCCESS) {
            _ = linux.close(socket);
            return;
        }
        if (pid == 0) owner.serve(vm, socket, moment);
        const registration = Registration{
            .pid = @intCast(pid),
            .branch = owner.branch,
            .vtime_ns = moment,
        };
        const written = write_all(socket, std.mem.asBytes(&registration));
        _ = linux.close(socket);
        if (!written) return;
        owner.kept[owner.kept_count] = .{ .pid = @intCast(pid), .vtime_ns = moment };
        owner.kept_count += 1;
        if (owner.kept_count > per_timeline_max) owner.drop();
    }

    /// Drops the holder closest to the one before it (never the first or the newest).
    fn drop(owner: *Owner) void {
        assert(owner.kept_count == per_timeline_max + 1);
        var victim: u32 = 1;
        var gap_min: u64 = std.math.maxInt(u64);
        for (1..owner.kept_count - 1) |index| {
            const gap = owner.kept[index].vtime_ns - owner.kept[index - 1].vtime_ns;
            if (gap < gap_min) {
                gap_min = gap;
                victim = @intCast(index);
            }
        }
        const pid = owner.kept[victim].pid;
        _ = linux.kill(pid, .KILL);
        reap(pid);
        std.mem.copyForwards(
            Kept,
            owner.kept[victim .. owner.kept_count - 1],
            owner.kept[victim + 1 .. owner.kept_count],
        );
        owner.kept_count -= 1;
    }

    /// The holder: waits for the explorer, then makes the node it asks for and exits.
    fn serve(owner: *Owner, vm: *VM, socket: linux.fd_t, moment_ns: u64) noreturn {
        // The worker's machine is not this process's: only its memory and captured state are.
        _ = linux.close(vm.vcpu_fd);
        _ = linux.close(vm.vm_fd);
        _ = linux.close(vm.kvm_fd);
        if (vm.events.log_fd) |fd| _ = linux.close(fd);
        oom_first();
        var request: Request = undefined;
        if (!read_exact(socket, std.mem.asBytes(&request))) linux.exit_group(0); // Released.
        if (request.vtime_ns < moment_ns) linux.exit_group(1);
        owner.snapshot.capture_memory(vm.memory) catch linux.exit_group(1);
        const node = if (request.vtime_ns == moment_ns)
            owner.snapshot
        else
            owner.make.function(
                owner.make.context,
                vm,
                owner.snapshot,
                owner.seed,
                request.vtime_ns,
            ) catch linux.exit_group(1);
        fd_pass.send(socket, node.memory_fd) catch linux.exit_group(1);
        if (!write_all(socket, std.mem.asBytes(node))) linux.exit_group(1);
        linux.exit_group(0);
    }
};

/// Waits for a holder to exit (it may have been waited for already, by its worker).
fn reap(pid: linux.pid_t) void {
    var status: i32 = 0;
    _ = linux.wait4(pid, &status, 0, null);
}

fn connect(address: *const linux.sockaddr.un) ?linux.fd_t {
    const created = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(created) != .SUCCESS) return null;
    const socket: linux.fd_t = @intCast(created);
    const connected = linux.connect(socket, @ptrCast(address), @sizeOf(linux.sockaddr.un));
    if (linux.errno(connected) != .SUCCESS) {
        _ = linux.close(socket);
        return null;
    }
    return socket;
}

/// The kernel's OOM killer takes this process before any other.
fn oom_first() void {
    const fd = linux.open("/proc/self/oom_score_adj", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    _ = linux.write(@intCast(fd), "1000", 4);
    _ = linux.close(@intCast(fd));
}

/// MemAvailable from /proc/meminfo, in bytes (0 when unreadable: no holders then).
fn memory_available() u64 {
    const fd = linux.open("/proc/meminfo", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return 0;
    defer _ = linux.close(@intCast(fd));
    var buffer: [4096]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return 0;
    const key = "MemAvailable:";
    const at = std.mem.indexOf(u8, buffer[0..size], key) orelse return 0;
    var words = std.mem.tokenizeScalar(u8, buffer[at + key.len .. size], ' ');
    const kib = std.fmt.parseInt(u64, words.next() orelse return 0, 10) catch return 0;
    return kib * 1024;
}

fn read_exact(fd: linux.fd_t, target: []u8) bool {
    var done: u64 = 0;
    while (done < target.len) {
        const result = linux.read(fd, target[done..].ptr, target.len - done);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS or result == 0) return false;
        done += result;
    }
    return true;
}

fn write_all(fd: linux.fd_t, bytes: []const u8) bool {
    var done: u64 = 0;
    while (done < bytes.len) {
        const result = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS) return false;
        done += result;
    }
    return true;
}
