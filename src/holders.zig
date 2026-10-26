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

/// What the explorer asks a holder: the moment of the node to make.
const Request = extern struct { vtime_ns: u64 };

/// A holder as its timeline's summary carries it to the explorer: its process, and where it
/// listens (an abstract Unix socket named after the explorer, its worker and its number there).
pub const Held = extern struct { pid: linux.pid_t, worker: linux.pid_t, id: u32, vtime_ns: u64 };

/// The explorer's holders of a generation, from its timelines' summaries. The explorer is their
/// subreaper: holders whose worker exited are still its to wait for.
pub const Registry = struct {
    explorer: linux.pid_t,
    entries: [entries_max]Entry = undefined,
    count: u32 = 0,

    /// A generation's (the largest, of per_timeline_max each).
    const entries_max = 256 * per_timeline_max;
    const Entry = struct { held: Held, branch: u32, taken: bool };

    pub fn init(registry: *Registry) !void {
        const subreaper = linux.prctl(@backingInt(linux.PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0);
        if (linux.errno(subreaper) != .SUCCESS) return error.Subreaper;
        registry.* = .{ .explorer = linux.getpid() };
    }

    /// A timeline's holders (its summary's), after it ran.
    pub fn add(registry: *Registry, branch: u32, kept: []const Held) void {
        for (kept) |held| {
            if (registry.count == entries_max) {
                kill(held.pid); // Never with generations of at most 256 timelines.
                continue;
            }
            registry.entries[registry.count] = .{ .held = held, .branch = branch, .taken = false };
            registry.count += 1;
        }
    }

    pub const Taken = struct { socket: linux.fd_t, pid: linux.pid_t };

    /// The latest holder of `branch` at or before `vtime_ns` that takes the request (one killed
    /// for memory does not): its socket, where the snapshot comes back as from a node-making
    /// child, and its pid. Null when none does.
    pub fn take(registry: *Registry, branch: u32, vtime_ns: u64) ?Taken {
        while (true) {
            var best: ?*Entry = null;
            for (registry.entries[0..registry.count]) |*entry| {
                if (entry.taken or entry.branch != branch) continue;
                if (entry.held.vtime_ns > vtime_ns) continue; // At the moment, or replays to it.
                if (best == null or entry.held.vtime_ns > best.?.held.vtime_ns) best = entry;
            }
            const entry = best orelse return null;
            entry.taken = true;
            const held = entry.held;
            const at = address(registry.explorer, held.worker, held.id);
            if (connect(&at)) |socket| {
                const request = Request{ .vtime_ns = vtime_ns };
                if (write_all(socket, std.mem.asBytes(&request))) {
                    return .{ .socket = socket, .pid = held.pid };
                }
                _ = linux.close(socket);
            }
            kill(held.pid); // Gone, or not answering: the next one, or a replay.
        }
    }

    /// The holders nobody took go (their memory, before the next generation runs).
    pub fn release(registry: *Registry) void {
        for (registry.entries[0..registry.count]) |*entry| {
            if (!entry.taken) kill(entry.held.pid);
        }
        registry.count = 0;
    }
};

/// A timeline's end, in the worker that runs it: VM.Hold's owner.
pub const Owner = struct {
    /// The explorer and this worker: they name the holders' sockets.
    explorer: linux.pid_t,
    worker: linux.pid_t,
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
    /// Holders made so far (each one's socket number).
    made: u32 = 0,
    /// The last hold point (the holder forked there keeps it): inside an idle skip or not.
    point: VM.Hold.Point = .{ .idle = false },
    kept: [per_timeline_max + 1]Held = undefined,
    kept_count: u32 = 0,

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
            point: VM.Hold.Point,
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

    /// The holders kept, for the timeline's summary (the explorer's registry).
    pub fn holders(owner: *const Owner) []const Held {
        return owner.kept[0..owner.kept_count];
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

    fn reached(context: *anyopaque, vm: *VM, point: VM.Hold.Point) !void {
        const owner: *Owner = @ptrCast(@alignCast(context));
        const moment = owner.armed_ns.?;
        owner.armed_ns = null;
        owner.armed_new = false;
        owner.last_ns = moment;
        try owner.arm(vm, moment + owner.period(), false); // The next, unless one is new first.
        if (memory_available() < memory_reserve_bytes) return;
        try owner.snapshot.capture(vm);
        owner.point = point;
        const id = owner.made;
        owner.made += 1;
        // Listening before the fork: the explorer may connect whenever it needs the holder.
        const at = address(owner.explorer, owner.worker, id);
        const listener = listen(&at) orelse return;
        const pid = linux.fork();
        if (pid == 0) owner.serve(vm, listener, moment);
        _ = linux.close(listener);
        if (linux.errno(pid) != .SUCCESS) return;
        owner.kept[owner.kept_count] = .{
            .pid = @intCast(pid),
            .worker = owner.worker,
            .id = id,
            .vtime_ns = moment,
        };
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
        kill(owner.kept[victim].pid);
        std.mem.copyForwards(
            Held,
            owner.kept[victim .. owner.kept_count - 1],
            owner.kept[victim + 1 .. owner.kept_count],
        );
        owner.kept_count -= 1;
    }

    /// The holder: waits for the explorer, then makes the node it asks for and exits (or is
    /// killed: dropped by its timeline, released by the explorer).
    fn serve(owner: *Owner, vm: *VM, listener: linux.fd_t, moment_ns: u64) noreturn {
        // The worker's machine is not this process's: only its memory and captured state are.
        _ = linux.close(vm.vcpu_fd);
        _ = linux.close(vm.vm_fd);
        _ = linux.close(vm.kvm_fd);
        if (vm.events.log_fd) |fd| _ = linux.close(fd);
        oom_first();
        const accepted = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(accepted) != .SUCCESS) linux.exit_group(1);
        _ = linux.close(listener);
        const socket: linux.fd_t = @intCast(accepted);
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
                owner.point,
            ) catch linux.exit_group(1);
        fd_pass.send(socket, node.memory_fd) catch linux.exit_group(1);
        if (!write_all(socket, std.mem.asBytes(node))) linux.exit_group(1);
        linux.exit_group(0);
    }
};

/// Ends a holder and waits for it (it may have been waited for already, by its worker).
fn kill(pid: linux.pid_t) void {
    _ = linux.kill(pid, .KILL);
    var status: i32 = 0;
    _ = linux.wait4(pid, &status, 0, null);
}

/// A holder's socket: abstract (no file to clean up), named after its explorer, its worker and
/// its number there.
fn address(explorer: linux.pid_t, worker: linux.pid_t, id: u32) linux.sockaddr.un {
    var at: linux.sockaddr.un = .{ .path = @splat(0) };
    _ = std.fmt.bufPrint(at.path[1..], "determinismo-holder-{d}-{d}-{d}", .{
        explorer, worker, id,
    }) catch unreachable; // Three numbers fit.
    return at;
}

fn listen(at: *const linux.sockaddr.un) ?linux.fd_t {
    const created = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(created) != .SUCCESS) return null;
    const socket: linux.fd_t = @intCast(created);
    const bound = linux.bind(socket, @ptrCast(at), @sizeOf(linux.sockaddr.un));
    if (linux.errno(bound) != .SUCCESS or linux.errno(linux.listen(socket, 1)) != .SUCCESS) {
        _ = linux.close(socket);
        return null;
    }
    return socket;
}

fn connect(at: *const linux.sockaddr.un) ?linux.fd_t {
    const created = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(created) != .SUCCESS) return null;
    const socket: linux.fd_t = @intCast(created);
    const connected = linux.connect(socket, @ptrCast(at), @sizeOf(linux.sockaddr.un));
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
