// SPDX-License-Identifier: MIT
//! The host's CPUs, shared by every run on it: a process holds a CPU while it runs a VM (a
//! timeline, a tree node's replay), pinned to it, and gives it back after. Any number of runs
//! then share the host with never two VMs on one CPU, and a lone run takes them all.
//!
//! A CPU is a lock on a file of its own (flock), named by the CPU's number, in a directory of
//! the user's: every process agrees on the CPUs, and the kernel gives a CPU back when its holder
//! dies. Locks belong to an open file, so each process opens the pool itself (never inherited).
//!
//! One thread per physical core: two VMs on a core's sibling hyperthreads perturb each other's
//! retired-branch counters, the guest's clock, and a timeline no longer replays (measured on
//! srv1, 2026-10-27: Kafka timelines replayed exactly on separate cores, beside a busy loop or a
//! memory-churning process on the sibling, and diverged within seconds with another VM there).
//! The pool holds each core's first thread; a second thread only when the first is not this
//! process's to run on (an affinity mask that leaves it out).
//!
//! A process with `DETERMINISMO_CPU_PRIORITY` set (checks, e.g. `zig build e2e`) goes first: while
//! one waits it holds a shared lock on the pool's `priority` file, and the others leave the next
//! free CPU to it. Exploration runs never have to stop for a check.
//!
//! Runs share the host: one process of a run waits for a CPU at a time (the others queue on the
//! run's `run-<key>.turn` lock), and the waiting runs are served at random (each tries again after
//! a random 10 to 30 ms, its first try included). Every run that wants CPUs then gets them
//! equally often, however many processes it has; a lone run takes them all. (With exponential
//! backoff, a run's next timeline, forked as its last one gave a CPU back, took that CPU every
//! time while other runs' waiters slept 100 ms; and served at random, runs got CPUs in
//! proportion to their waiting processes: one run with 300 held most of the host.)
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

const cpus_max = 1024;
const wait_ns_min = 10 * std.time.ns_per_ms;
const wait_ns_max = 30 * std.time.ns_per_ms;

/// The run this process belongs to: set by a run's first process before it forks the others
/// (they inherit it); a process outside any run is a run of its own.
pub var run_key: ?linux.pid_t = null;

pub const Pool = struct {
    /// The CPUs this process may run on, and their lock files.
    cpus: [cpus_max]u16 = undefined,
    fds: [cpus_max]linux.fd_t = undefined,
    count: u32 = 0,
    /// The run's turn to wait: one of its processes at a time holds it.
    turn_fd: linux.fd_t = -1,
    /// The pool's `priority` file: shared-locked by priority processes while they wait.
    priority_fd: linux.fd_t = -1,
    priority: bool = false,

    /// Opens the pool of the CPUs this process may run on.
    pub fn open(pool: *Pool) !void {
        pool.* = .{};
        var available: linux.cpu_set_t = undefined;
        const size = @sizeOf(linux.cpu_set_t);
        if (linux.errno(linux.sched_getaffinity(0, size, &available)) != .SUCCESS) {
            return error.Affinity;
        }
        var directory_buffer: [64]u8 = undefined;
        const directory = try std.fmt.bufPrintSentinel(&directory_buffer, "/tmp/determinismo-cpus-{d}", .{
            linux.getuid(),
        }, 0);
        const made = linux.mkdir(directory, 0o700);
        if (linux.errno(made) != .SUCCESS and linux.errno(made) != .EXIST) return error.PoolDirectory;
        errdefer pool.close();
        const bits = @bitSizeOf(@TypeOf(available[0]));
        for (0..available.len * bits) |cpu| {
            if (!usable(&available, cpu)) continue;
            if (pool.count == cpus_max) break;
            var path_buffer: [96]u8 = undefined;
            const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/cpu-{d}", .{ directory, cpu }, 0);
            const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
            const fd = linux.open(path, flags, 0o600);
            if (linux.errno(fd) != .SUCCESS) return error.PoolFile;
            pool.cpus[pool.count] = @intCast(cpu);
            pool.fds[pool.count] = @intCast(fd);
            pool.count += 1;
        }
        if (pool.count == 0) return error.NoCpus;
        var priority_buffer: [96]u8 = undefined;
        const priority_path = try std.fmt.bufPrintSentinel(&priority_buffer, "{s}/priority", .{
            directory,
        }, 0);
        const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
        const priority_fd = linux.open(priority_path, flags, 0o600);
        if (linux.errno(priority_fd) != .SUCCESS) return error.PoolFile;
        pool.priority_fd = @intCast(priority_fd);
        pool.priority = std.c.getenv("DETERMINISMO_CPU_PRIORITY") != null;
        var turn_buffer: [96]u8 = undefined;
        const turn_path = try std.fmt.bufPrintSentinel(&turn_buffer, "{s}/run-{d}.turn", .{
            directory, run_key orelse linux.getpid(),
        }, 0);
        const turn_fd = linux.open(turn_path, flags, 0o600);
        if (linux.errno(turn_fd) != .SUCCESS) return error.PoolFile;
        pool.turn_fd = @intCast(turn_fd);
        // Each core's first thread, then the siblings (stable: by number within each).
        var order: [cpus_max]u32 = undefined;
        for (order[0..pool.count], 0..) |*slot, index| slot.* = @intCast(index);
        std.sort.insertion(u32, order[0..pool.count], pool, sibling_after);
        const cpus = pool.cpus;
        const fds = pool.fds;
        for (order[0..pool.count], 0..) |from, to| {
            pool.cpus[to] = cpus[from];
            pool.fds[to] = fds[from];
        }
    }

    fn sibling_after(pool: *const Pool, a: u32, b: u32) bool {
        const a_sibling = sibling(pool.cpus[a]);
        const b_sibling = sibling(pool.cpus[b]);
        if (a_sibling != b_sibling) return !a_sibling;
        return pool.cpus[a] < pool.cpus[b];
    }

    pub fn close(pool: *Pool) void {
        for (pool.fds[0..pool.count]) |fd| _ = linux.close(fd);
        if (pool.priority_fd >= 0) _ = linux.close(pool.priority_fd);
        if (pool.turn_fd >= 0) _ = linux.close(pool.turn_fd);
        pool.count = 0;
    }

    /// Takes a free CPU (the first, physical cores first), waiting while none is, and pins this
    /// process to it.
    pub fn take(pool: *Pool) Held {
        assert(pool.count > 0);
        // Waiting with priority: the others see it, and leave free CPUs to it.
        if (pool.priority) _ = linux.flock(pool.priority_fd, std.posix.LOCK.SH);
        defer if (pool.priority) {
            _ = linux.flock(pool.priority_fd, std.posix.LOCK.UN);
        };
        // The run's turn: its other processes queue behind this one (in the kernel, asleep).
        if (!pool.priority) {
            while (linux.errno(linux.flock(pool.turn_fd, std.posix.LOCK.EX)) == .INTR) {}
        }
        defer if (!pool.priority) {
            _ = linux.flock(pool.turn_fd, std.posix.LOCK.UN);
        };
        // Host-side only (which CPU a timeline runs on never changes it): any seed will do.
        var random: std.Random.DefaultPrng = .init(@as(u64, @intCast(linux.getpid())) ^ monotonic_ns());
        while (true) {
            // Every CPU runs a VM, or one waits with priority: back-pressure, until one is free.
            // A priority process tries at once; the others wait their turn first, at random.
            if (!pool.priority) {
                const wait_ns = random.random().intRangeAtMost(u64, wait_ns_min, wait_ns_max);
                const pause: linux.timespec = .{ .sec = 0, .nsec = @intCast(wait_ns) };
                _ = linux.nanosleep(&pause, null);
                if (pool.priority_waiting()) continue;
            }
            // The host's memory too: no VM starts while less than the reserve is available
            // (runs share the host's memory as its CPUs, and waiting workers and holders keep
            // theirs: srv2 once had 0 GB available), until timelines end or holders go.
            const available = memory_available(); // 0: unknown, never a reason to wait.
            if (available != 0 and available < memory_reserve_bytes) {
                if (pool.priority) {
                    const pause: linux.timespec = .{ .sec = 0, .nsec = @intCast(wait_ns_max) };
                    _ = linux.nanosleep(&pause, null);
                }
                continue;
            }
            for (0..pool.count) |index| {
                const slot: u32 = @intCast(index);
                const locked = linux.flock(pool.fds[slot], std.posix.LOCK.EX | std.posix.LOCK.NB);
                if (linux.errno(locked) != .SUCCESS) continue;
                pin(pool.cpus[slot]);
                return .{ .slot = slot };
            }
            if (pool.priority) {
                const pause: linux.timespec = .{ .sec = 0, .nsec = wait_ns_min };
                _ = linux.nanosleep(&pause, null);
            }
        }
    }

    /// Whether a priority process waits for a CPU (it holds the `priority` file shared).
    fn priority_waiting(pool: *Pool) bool {
        const probe = linux.flock(pool.priority_fd, std.posix.LOCK.EX | std.posix.LOCK.NB);
        if (linux.errno(probe) != .SUCCESS) return true;
        _ = linux.flock(pool.priority_fd, std.posix.LOCK.UN);
        return false;
    }

    pub fn give(pool: *Pool, held: Held) void {
        assert(held.slot < pool.count);
        _ = linux.flock(pool.fds[held.slot], std.posix.LOCK.UN);
    }
};

pub const Held = struct { slot: u32 };

/// Memory kept free on the host: no VM starts, and no holder is made, below it.
pub const memory_reserve_bytes = 8 << 30;

/// The host's available memory (MemAvailable), or 0 if unknown.
pub fn memory_available() u64 {
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

/// How many CPUs this process's pool holds: the CPUs it may run on, one thread per core.
pub fn usable_count() u32 {
    var available: linux.cpu_set_t = undefined;
    if (linux.errno(linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &available)) != .SUCCESS) {
        return 1;
    }
    const bits = @bitSizeOf(@TypeOf(available[0]));
    var count: u32 = 0;
    for (0..available.len * bits) |cpu| {
        if (usable(&available, cpu)) count += 1;
    }
    return @max(count, 1);
}

/// In the set, and not a second hyperthread whose core's first thread is in the set too.
fn usable(available: *const linux.cpu_set_t, cpu: usize) bool {
    const bits = @bitSizeOf(@TypeOf(available[0]));
    if (available[cpu / bits] >> @intCast(cpu % bits) & 1 == 0) return false;
    const first = first_sibling(@intCast(cpu)) orelse return true;
    if (first == cpu) return true;
    return available[first / bits] >> @intCast(first % bits) & 1 == 0;
}

/// Whether the CPU is a core's second hyperthread (not the first of its siblings).
fn sibling(cpu: u16) bool {
    const first = first_sibling(cpu) orelse return false;
    return cpu != first;
}

/// The first thread of the CPU's core (itself without SMT), if the kernel says.
fn first_sibling(cpu: u16) ?u16 {
    var path_buffer: [96]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/sys/devices/system/cpu/cpu{d}/" ++
        "topology/thread_siblings_list", .{cpu}, 0) catch return null;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var text: [64]u8 = undefined;
    const size = linux.read(@intCast(fd), &text, text.len);
    if (linux.errno(size) != .SUCCESS) return null;
    return siblings_first(text[0..size]);
}

/// "0,18" or "0-1": the first is the core's first thread.
fn siblings_first(text: []const u8) ?u16 {
    const end = std.mem.indexOfAny(u8, text, ",-\n") orelse text.len;
    return std.fmt.parseInt(u16, text[0..end], 10) catch null;
}

test siblings_first {
    try std.testing.expectEqual(0, siblings_first("0,18\n"));
    try std.testing.expectEqual(4, siblings_first("4-5\n"));
    try std.testing.expectEqual(7, siblings_first("7\n"));
    try std.testing.expectEqual(null, siblings_first(""));
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

fn pin(cpu: u16) void {
    var set: linux.cpu_set_t = @splat(0);
    const bits = @bitSizeOf(@TypeOf(set[0]));
    set[cpu / bits] = @as(@TypeOf(set[0]), 1) << @intCast(cpu % bits);
    linux.sched_setaffinity(0, &set) catch {}; // Best effort: the lock is what counts.
}

/// Lets this process run on any CPU (a process that holds none, after a pinned parent).
pub fn unpin() void {
    var set: linux.cpu_set_t = @splat(~@as(@TypeOf(@as(linux.cpu_set_t, undefined)[0]), 0));
    linux.sched_setaffinity(0, &set) catch {};
}

test "a CPU is held by one process at a time, and given back" {
    var first: Pool = undefined;
    try first.open();
    defer first.close();
    var second: Pool = undefined;
    try second.open();
    defer second.close();
    const held = first.take();
    // The same CPU is taken: another process (another open file) finds another, or waits.
    const lock = linux.flock(second.fds[held.slot], std.posix.LOCK.EX | std.posix.LOCK.NB);
    try std.testing.expect(linux.errno(lock) == .AGAIN);
    first.give(held);
    const again = linux.flock(second.fds[held.slot], std.posix.LOCK.EX | std.posix.LOCK.NB);
    try std.testing.expect(linux.errno(again) == .SUCCESS);
    _ = linux.flock(second.fds[held.slot], std.posix.LOCK.UN);
    unpin();
}
