// SPDX-License-Identifier: MIT
//! The host's CPUs, shared by every run on it: a process holds a CPU while it runs a VM (a
//! timeline, a tree node's replay), pinned to it, and gives it back after. Any number of runs
//! then share the host with never two VMs on one CPU, and a lone run takes them all.
//!
//! A CPU is a lock on a file of its own (flock), named by the CPU's number, in a directory of
//! the user's: every process agrees on the CPUs, and the kernel gives a CPU back when its holder
//! dies. Locks belong to an open file, so each process opens the pool itself (never inherited).
//!
//! One VM per core by default; with `DETERMINISMO_SMT=1` (serve.sh's `--siblings on`) the second
//! hyperthreads too, once every core's first is busy: a VM alone on a core is fastest (with a
//! busy sibling, about 0.7x), and a busy core does about 1.4x. Not the default: twice the VMs
//! outgrew memory admission, which claims each VM's guest but not its in-run snapshots and
//! holders (a Dgraph hunt, 53 timelines killed by the OOM killer, srv3 2026-10-28). Siblings were left out when Kafka timelines diverged within seconds with two VMs on
//! one core (srv1, 2026-10-27), thought to perturb each other's branch counters; the divergences
//! were the guest kernel's, which branched on TLB state that a sibling's VM perturbs most (guest
//! patches 0001, 0002 and 0004: 150-branch spurious faults). With them, VMs on both hyperthreads
//! of two cores replayed YugabyteDB (39 s, 382 s) and Kafka timelines (three) exactly, 20
//! replays of 20 (srv3, 2026-10-28). But the first hunt with them (Kafka, run 55, srv3,
//! 2026-10-28: 32 VMs on 16 cores) replayed 7 of the 9 timelines it checked exactly, two
//! diverging with no clock hazard, while runs without them replayed 33 of 33: off, until what
//! a sibling still perturbs is found. With one thread per core, the pool holds each core's first;
//! a second only when the first is not this process's to run on (an affinity mask that leaves it
//! out).
//!
//! A process with `DETERMINISMO_CPU_PRIORITY` set (checks, e.g. `zig build e2e`) goes first: while
//! one waits it holds a shared lock on the `priority-<cpu>` file of each CPU it may run on, and
//! the others leave those CPUs to it when they come free. Only those: a check confined to cores
//! of its own (a host's reserved cores, infra/host/serve.sh) never holds back a hunt on the rest.
//!
//! The memory a VM claims counts on the whole host, whatever CPUs a process may run on: a hunt
//! and a check on cores of their own still share one memory.
//!
//! Runs share the host: one process of a run waits for a CPU at a time (the others queue on the
//! run's `run-<key>.turn` lock), and the waiting runs are served at random (each tries again after
//! a random 10 to 30 ms, its first try included). Every run that wants CPUs then gets them
//! equally often, however many processes it has; a lone run takes them all. (With exponential
//! backoff, a run's next timeline, forked as its last one gave a CPU back, took that CPU every
//! time while other runs' waiters slept 100 ms; and served at random, runs got CPUs in
//! proportion to their waiting processes: one run with 300 held most of the host.)
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const linux = std.os.linux;

const cpus_max = 1024;
const wait_ns_min = 10 * std.time.ns_per_ms;
const wait_ns_max = 30 * std.time.ns_per_ms;
/// A session waiting for memory says so after this long, and again every `memory_say_every_ns`:
/// replays through serve beside a YugabyteDB hunt waited 30 minutes and said nothing.
const memory_say_after_ns = 30 * std.time.ns_per_s;
const memory_say_every_ns = 5 * 60 * std.time.ns_per_s;

/// The run this process belongs to: set by a run's first process before it forks the others
/// (they inherit it); a process outside any run is a run of its own.
pub var run_key: ?linux.pid_t = null;

/// The memory this process's VMs may come to use (their guest's size), claimed with the CPU it
/// takes: set once at its start, forks inherit it. 0: none claimed.
pub var claim_bytes: u64 = 0;

/// The CPUs this process was given: its affinity before a pin narrowed it to the one CPU it
/// held. Its pool, its count of usable CPUs and a CPU given back go by it, never by the pinned
/// affinity: an explorer pinned while it booted and set up once counted one usable CPU (every
/// run without --jobs ran one timeline at a time, 2026-10-27), and the timelines it forked
/// opened pools of that one CPU. Read before the first pin; forks inherit it.
var given_mask: ?linux.cpu_set_t = null;

fn given() linux.cpu_set_t {
    if (given_mask) |mask| return mask;
    var mask: linux.cpu_set_t = undefined;
    if (linux.errno(linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &mask)) != .SUCCESS) {
        mask = @splat(~@as(@TypeOf(mask[0]), 0));
    }
    given_mask = mask;
    return mask;
}

pub const Pool = struct {
    /// The CPUs this process may run on, their lock files, and their `priority-<cpu>` files
    /// (shared-locked by priority processes while they wait).
    cpus: [cpus_max]u16 = undefined,
    fds: [cpus_max]linux.fd_t = undefined,
    priority_fds: [cpus_max]linux.fd_t = undefined,
    count: u32 = 0,
    /// Every CPU of the host's lock file, for the memory claimed on them (claim_fits).
    host_fds: [cpus_max]linux.fd_t = undefined,
    host_count: u32 = 0,
    /// The run's turn to wait: one of its processes at a time holds it.
    turn_fd: linux.fd_t = -1,
    priority: bool = false,
    /// Whether a claim must also find its memory available now (tests of the claims' own
    /// accounting turn it off: beside a hunt, half the host is never available).
    available_counts: bool = true,
    /// The pool's directory (its CPU, priority and nodes files).
    directory_buffer: [64]u8 = undefined,
    directory_size: usize = 0,

    /// Opens the pool of the CPUs this process may run on.
    pub fn open(pool: *Pool) !void {
        pool.* = .{};
        const available = given();
        var directory_buffer: [64]u8 = undefined;
        // Unit tests have a pool of their own: the host's runs' claims and locks are not theirs
        // (a test's claim of half the host never fit beside a hunt's, and waited forever).
        const directory = if (builtin.is_test)
            try std.fmt.bufPrintSentinel(&directory_buffer, "/tmp/determinismo-cpus-test-{d}", .{linux.getpid()}, 0)
        else
            try std.fmt.bufPrintSentinel(&directory_buffer, "/tmp/determinismo-cpus-{d}", .{linux.getuid()}, 0);
        const made = linux.mkdir(directory, 0o700);
        if (linux.errno(made) != .SUCCESS and linux.errno(made) != .EXIST) return error.PoolDirectory;
        @memcpy(pool.directory_buffer[0..directory.len], directory);
        pool.directory_size = directory.len;
        errdefer pool.close();
        const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
        const bits = @bitSizeOf(@TypeOf(available[0]));
        for (0..available.len * bits) |cpu| {
            if (!usable(&available, cpu)) continue;
            if (pool.count == cpus_max) break;
            pool.cpus[pool.count] = @intCast(cpu);
            pool.fds[pool.count] = try pool_file(directory, "cpu", cpu);
            pool.priority_fds[pool.count] = pool_file(directory, "priority", cpu) catch |err| {
                _ = linux.close(pool.fds[pool.count]);
                return err;
            };
            pool.count += 1;
        }
        if (pool.count == 0) return error.NoCpus;
        for (0..@min(host_cpu_count(), cpus_max)) |cpu| {
            pool.host_fds[pool.host_count] = try pool_file(directory, "cpu", cpu);
            pool.host_count += 1;
        }
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
        const priority_fds = pool.priority_fds;
        for (order[0..pool.count], 0..) |from, to| {
            pool.cpus[to] = cpus[from];
            pool.fds[to] = fds[from];
            pool.priority_fds[to] = priority_fds[from];
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
        for (pool.priority_fds[0..pool.count]) |fd| _ = linux.close(fd);
        for (pool.host_fds[0..pool.host_count]) |fd| _ = linux.close(fd);
        if (pool.turn_fd >= 0) _ = linux.close(pool.turn_fd);
        pool.count = 0;
        pool.host_count = 0;
    }

    /// Takes a free CPU (the first, physical cores first), waiting while none is, and pins this
    /// process to it.
    pub fn take(pool: *Pool) Held {
        assert(pool.count > 0);
        // Waiting with priority: the others see it, and leave the CPUs it may run on to it.
        if (pool.priority) for (pool.priority_fds[0..pool.count]) |fd| {
            _ = linux.flock(fd, std.posix.LOCK.SH);
        };
        defer if (pool.priority) for (pool.priority_fds[0..pool.count]) |fd| {
            _ = linux.flock(fd, std.posix.LOCK.UN);
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
        var memory_wait_ns: u64 = 0;
        var memory_since: ?u64 = null;
        var memory_said_ns: u64 = 0;
        while (true) {
            // Every CPU runs a VM, or a priority process waits for it: back-pressure, until one
            // is free. A priority process tries at once; the others wait their turn first, at
            // random.
            if (!pool.priority) {
                const wait_ns = random.random().intRangeAtMost(u64, wait_ns_min, wait_ns_max);
                const pause: linux.timespec = .{ .sec = 0, .nsec = @intCast(wait_ns) };
                _ = linux.nanosleep(&pause, null);
            }
            // The host's memory too: no VM starts while the VMs running and this one could come
            // to need more than the host has (a VM's memory grows after it starts, up to its
            // guest's size: 18 YugabyteDB VMs admitted with memory free filled srv2 and the OOM
            // killer took serve, 2026-10-27); nor while less than half the reserve is available
            // (holders go below the reserve, holders.zig: they make room before a VM waits).
            const available = memory_available(); // 0: unknown, never a reason to wait.
            const below = available != 0 and available < memory_reserve() / 2 + sessions_reserve_bytes();
            if (below or !pool.claim_fits(claim_bytes)) {
                if (memory_since == null) {
                    memory_since = monotonic_ns();
                    // A check waiting for memory: the runs leave it the sessions' room.
                    if (pool.priority) if (memory_priority_open()) |fd| {
                        _ = linux.flock(fd, std.posix.LOCK.SH);
                    };
                    // Any VM waiting: holders that keep it out go (holders.zig).
                    if (memory_wanted_open()) |fd| _ = linux.flock(fd, std.posix.LOCK.SH);
                }
                if (pool.priority) {
                    const now = monotonic_ns();
                    if (now - memory_since.? >= memory_say_after_ns and
                        (memory_said_ns == 0 or now - memory_said_ns >= memory_say_every_ns))
                    {
                        memory_said_ns = now;
                        const waited_s = (now - memory_since.?) / std.time.ns_per_s;
                        if (below) {
                            std.debug.print("[determinismo] waiting {d} s for memory: {d} MiB " ++
                                "available, below the {d} MiB kept free (the runs' VMs and holders " ++
                                "hold the rest, until they end)\n", .{
                                waited_s,
                                available >> 20,
                                (memory_reserve() / 2 + sessions_reserve_bytes()) >> 20,
                            });
                        } else {
                            std.debug.print("[determinismo] waiting {d} s for memory: a VM of {d} " ++
                                "MiB beside the running ones could outgrow the host (each may " ++
                                "grow to its guest's size)\n", .{ waited_s, claim_bytes >> 20 });
                        }
                    }
                    const pause: linux.timespec = .{ .sec = 0, .nsec = @intCast(wait_ns_max) };
                    _ = linux.nanosleep(&pause, null);
                }
                continue;
            }
            if (memory_since) |since| {
                memory_wait_ns += monotonic_ns() - since;
                if (pool.priority) if (memory_priority_open()) |fd| {
                    _ = linux.flock(fd, std.posix.LOCK.UN);
                };
                if (memory_wanted_open()) |fd| _ = linux.flock(fd, std.posix.LOCK.UN);
            }
            memory_since = null;
            for (0..pool.count) |index| {
                const slot: u32 = @intCast(index);
                if (!pool.priority and pool.priority_waiting(slot)) continue;
                const locked = linux.flock(pool.fds[slot], std.posix.LOCK.EX | std.posix.LOCK.NB);
                if (linux.errno(locked) != .SUCCESS) continue;
                // The claim, where the others read it while this process holds the CPU.
                const claim = std.mem.toBytes(claim_bytes);
                _ = linux.pwrite(pool.fds[slot], &claim, claim.len, 0);
                pin(pool.cpus[slot]);
                return .{ .slot = slot, .memory_wait_ns = memory_wait_ns };
            }
            if (pool.priority) {
                const pause: linux.timespec = .{ .sec = 0, .nsec = wait_ns_min };
                _ = linux.nanosleep(&pause, null);
            }
        }
    }

    /// Whether `bytes` more fit beside what the held CPUs' processes claimed, on any CPU of the
    /// host: within the host's memory less the reserve. A CPU's claim counts while its lock is
    /// held.
    fn claim_fits(pool: *Pool, bytes: u64) bool {
        if (bytes == 0) return true;
        // The claims are every run's, host-wide: against the host's memory and reserve. A
        // cgroup's limit bounds what this process has available (memory_available), not the
        // host's claims: compared with a session's 24 GB, a hunt's 50 GB of claims kept every
        // check's VM waiting while the hunt ran (srv3, 2026-10-29).
        const total = meminfo("MemTotal:");
        if (total == 0) return true; // Unknown: never a reason to wait.
        var claimed: u64 = 0;
        for (pool.host_fds[0..pool.host_count]) |fd| {
            const probe = linux.flock(fd, std.posix.LOCK.SH | std.posix.LOCK.NB);
            if (linux.errno(probe) == .SUCCESS) {
                _ = linux.flock(fd, std.posix.LOCK.UN);
                continue; // Free.
            }
            var claim: [8]u8 = @splat(0);
            if (linux.pread(fd, &claim, claim.len, 0) == claim.len) claimed += std.mem.bytesToValue(u64, &claim);
        }
        claimed += nodes_claimed(pool.directory_buffer[0..pool.directory_size]);
        if (!fits(claimed, bytes, total, 0, memory_reserve_bytes + sessions_reserve_bytes())) return false;
        const available = if (pool.available_counts) memory_available() else 0;
        return fits(0, bytes, std.math.maxInt(u64) / 2, available, reserve_bytes());
    }

    /// Whether a priority process waits for the CPU of `slot` (it holds its `priority-<cpu>`
    /// file shared).
    fn priority_waiting(pool: *Pool, slot: u32) bool {
        const fd = pool.priority_fds[slot];
        const probe = linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB);
        if (linux.errno(probe) != .SUCCESS) return true;
        _ = linux.flock(fd, std.posix.LOCK.UN);
        return false;
    }

    pub fn give(pool: *Pool, held: Held) void {
        assert(held.slot < pool.count);
        _ = linux.flock(pool.fds[held.slot], std.posix.LOCK.UN);
        unpin(); // Not pinned to a CPU it no longer holds (nor are what it forks or runs next).
    }
};

pub const Held = struct {
    slot: u32,
    /// How long the take waited for the host's memory (other runs' VMs and holders claim it):
    /// a run whose VMs mostly wait for memory runs fewer timelines at once than it has CPUs.
    memory_wait_ns: u64 = 0,
};

/// The pool directory's `<kind>-<cpu>` file, opened (made if new).
fn pool_file(directory: [:0]const u8, comptime kind: []const u8, cpu: usize) !linux.fd_t {
    var path_buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/" ++ kind ++ "-{d}", .{ directory, cpu }, 0);
    const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
    const fd = linux.open(path, flags, 0o600);
    if (linux.errno(fd) != .SUCCESS) return error.PoolFile;
    return @intCast(fd);
}

/// The host's CPUs, whatever this process may run on: one past the last of
/// /sys/devices/system/cpu/possible ("0-35"), or 0 if unknown (then only the pool's count).
fn host_cpu_count() usize {
    const fd = linux.open("/sys/devices/system/cpu/possible", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return 0;
    defer _ = linux.close(@intCast(fd));
    var buffer: [256]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return 0;
    return possible_count(std.mem.trim(u8, buffer[0..size], " \n"));
}

/// One past the highest CPU of a kernel CPU list ("0-35", "0,2-5").
fn possible_count(list: []const u8) usize {
    var highest: ?usize = null;
    var ranges = std.mem.splitScalar(u8, list, ',');
    while (ranges.next()) |range| {
        const last = if (std.mem.indexOfScalar(u8, range, '-')) |dash| range[dash + 1 ..] else range;
        const cpu = std.fmt.parseInt(usize, last, 10) catch continue;
        highest = @max(highest orelse 0, cpu);
    }
    return if (highest) |cpu| cpu + 1 else 0;
}

test "a check waiting for a CPU leaves the others to the rest" {
    var waiter: Pool = undefined;
    try waiter.open();
    defer waiter.close();
    var other: Pool = undefined;
    try other.open();
    defer other.close();
    if (other.count < 2) return error.SkipZigTest;
    // A priority process confined to the first CPU waits for it.
    _ = linux.flock(waiter.priority_fds[0], std.posix.LOCK.SH);
    defer _ = linux.flock(waiter.priority_fds[0], std.posix.LOCK.UN);
    try std.testing.expect(other.priority_waiting(0));
    try std.testing.expect(!other.priority_waiting(1));
}

test "a kernel CPU list's count" {
    try std.testing.expectEqual(@as(usize, 36), possible_count("0-35"));
    try std.testing.expectEqual(@as(usize, 6), possible_count("0,2-5"));
    try std.testing.expectEqual(@as(usize, 1), possible_count("0"));
    try std.testing.expectEqual(@as(usize, 0), possible_count(""));
}

/// Memory kept free on the host: no VM starts, and no holder is made, below it.
pub const memory_reserve_bytes = 8 << 30;

/// The reserve for what this process may use: the host's, or an eighth of a smaller limit (its
/// cgroup's): 8 GB kept free under a 24 GB unit would have left its checks no holders.
pub fn memory_reserve() u64 {
    const total = memory_total();
    if (total == 0) return memory_reserve_bytes;
    return @min(memory_reserve_bytes, total / 8);
}

/// Memory a host's runs leave to its user's own sessions (a host with reserved cores: their
/// builds, checks and replays) while one of the sessions' VMs waits for memory, from
/// DETERMINISMO_SESSIONS_MEMORY_MIB: serve carries it (serve.sh sets it with the reserved
/// cores), and so every process of its runs; the sessions' own processes do not. Without it a
/// hunt held all but 9 GiB of srv3's 125, and a check on the reserved cores ran one VM at a
/// time; held back always, it kept a Kafka hunt's holders from being made (they want room to
/// grow) in nearly every timeline (2026-10-28). So only while a priority process (a check)
/// waits for memory (`memory-priority`, held shared by it): runs start no VM into that room,
/// and their holders give theirs up.
pub fn sessions_reserve_bytes() u64 {
    const value = std.c.getenv("DETERMINISMO_SESSIONS_MEMORY_MIB") orelse return 0;
    const mib = std.fmt.parseInt(u64, std.mem.span(value), 10) catch return 0;
    if (!memory_priority_waiting()) return 0;
    return mib << 20;
}

/// The pool directory's `memory-priority` file, opened once by this process (-1: not yet, -2:
/// could not be).
var memory_priority_fd: linux.fd_t = -1;

fn memory_priority_open() ?linux.fd_t {
    if (memory_priority_fd == -2) return null;
    if (memory_priority_fd >= 0) return memory_priority_fd;
    var buffer: [96]u8 = undefined;
    const path = (if (builtin.is_test)
        std.fmt.bufPrintSentinel(&buffer, "/tmp/determinismo-cpus-test-{d}/memory-priority", .{linux.getpid()}, 0)
    else
        std.fmt.bufPrintSentinel(&buffer, "/tmp/determinismo-cpus-{d}/memory-priority", .{linux.getuid()}, 0)) catch {
        memory_priority_fd = -2;
        return null;
    };
    const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
    const fd = linux.open(path, flags, 0o600);
    if (linux.errno(fd) != .SUCCESS) {
        memory_priority_fd = -2;
        return null;
    }
    memory_priority_fd = @intCast(fd);
    return memory_priority_fd;
}

/// The pool directory's `memory-wanted` file, held shared by every process whose VM waits for
/// memory (-1: not opened yet, -2: could not be).
var memory_wanted_fd: linux.fd_t = -1;

fn memory_wanted_open() ?linux.fd_t {
    if (memory_wanted_fd == -2) return null;
    if (memory_wanted_fd >= 0) return memory_wanted_fd;
    var buffer: [96]u8 = undefined;
    const path = (if (builtin.is_test)
        std.fmt.bufPrintSentinel(&buffer, "/tmp/determinismo-cpus-test-{d}/memory-wanted", .{linux.getpid()}, 0)
    else
        std.fmt.bufPrintSentinel(&buffer, "/tmp/determinismo-cpus-{d}/memory-wanted", .{linux.getuid()}, 0)) catch {
        memory_wanted_fd = -2;
        return null;
    };
    const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
    const fd = linux.open(path, flags, 0o600);
    if (linux.errno(fd) != .SUCCESS) {
        memory_wanted_fd = -2;
        return null;
    }
    memory_wanted_fd = @intCast(fd);
    return memory_wanted_fd;
}

/// Whether a VM waits for memory anywhere on the host (it holds `memory-wanted` shared): a
/// holder keeping it out goes (holders.zig). Between where holders go by themselves (below the
/// reserve) and where a VM starts (its size above it), neither moved: a tree's last timeline
/// waited for ever beside its generation's holders (a 24 GB check, 2026-10-29).
pub fn memory_wanted_waiting() bool {
    const fd = memory_wanted_open() orelse return false;
    const probe = linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB);
    if (linux.errno(probe) != .SUCCESS) return true;
    _ = linux.flock(fd, std.posix.LOCK.UN);
    return false;
}

/// Whether a priority process waits for memory: it holds `memory-priority` shared.
fn memory_priority_waiting() bool {
    const fd = memory_priority_open() orelse return false;
    const probe = linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB);
    if (linux.errno(probe) != .SUCCESS) return true;
    _ = linux.flock(fd, std.posix.LOCK.UN);
    return false;
}

/// The memory this process leaves free: the host's reserve, and the sessions' if it is a run's.
pub fn reserve_bytes() u64 {
    return memory_reserve() + sessions_reserve_bytes();
}

/// The memory available to this process (MemAvailable, or less within its cgroup's limit), or 0
/// if unknown.
pub fn memory_available() u64 {
    const host = meminfo("MemAvailable:");
    const limited = cgroup_memory() orelse return host;
    return if (host == 0) limited.available else @min(host, limited.available);
}

/// The memory this process may use (MemTotal, or its cgroup's limit), 0 if unknown.
pub fn memory_total() u64 {
    const host = meminfo("MemTotal:");
    const limited = cgroup_memory() orelse return host;
    return if (host == 0) limited.total else @min(host, limited.total);
}

/// Memory limits on this process's cgroup v2 or its ancestors (systemd's MemoryMax on a unit, a
/// container's): the tightest, and what is free under it now. A user's checks confined to cores
/// of their own (MemoryMax too) once took 30 GB beside a hunt that then made no holders, since
/// VMs were admitted by the host's memory: under a limit, by the limit's.
const CgroupMemory = struct { total: u64, available: u64 };

/// The levels with a limit (`memory.max` other than "max"), found once: limits move rarely, and
/// a process under none reads nothing more.
const levels_max = 8;
var limited_levels: [levels_max][256]u8 = undefined;
var limited_level_sizes: [levels_max]u8 = undefined;
var limited_count: ?u8 = null;

fn cgroup_memory() ?CgroupMemory {
    if (limited_count == null) cgroup_levels_find();
    var found: ?CgroupMemory = null;
    for (0..limited_count.?) |index| {
        const level = limited_levels[index][0..limited_level_sizes[index]];
        const limit = cgroup_number(level, "memory.max") orelse continue;
        const current = cgroup_number(level, "memory.current") orelse continue;
        // Reclaimable: file pages not shared (memory.current counts the page cache too).
        const reclaimable = cgroup_stat(level, "inactive_file ");
        const available = limit -| (current -| reclaimable);
        found = if (found) |known| .{
            .total = @min(known.total, limit),
            .available = @min(known.available, available),
        } else .{ .total = limit, .available = available };
    }
    return found;
}

fn cgroup_levels_find() void {
    limited_count = 0;
    var buffer: [512]u8 = undefined;
    const own = read_small("/proc/self/cgroup", &buffer) orelse return;
    // cgroup v2: one line, "0::<path>".
    const start = std.mem.indexOf(u8, own, "0::") orelse return;
    const relative = std.mem.trimEnd(u8, own[start + 3 ..], "\n");
    var path_buffer: [256]u8 = undefined;
    var path: []const u8 = std.fmt.bufPrint(&path_buffer, "/sys/fs/cgroup{s}", .{if (std.mem.eql(u8, relative, "/")) "" else relative}) catch return;
    while (limited_count.? < levels_max) {
        if (cgroup_number(path, "memory.max") != null) {
            const index = limited_count.?;
            @memcpy(limited_levels[index][0..path.len], path);
            limited_level_sizes[index] = @intCast(path.len);
            limited_count = index + 1;
        }
        if (std.mem.eql(u8, path, "/sys/fs/cgroup")) return;
        path = std.fs.path.dirname(path) orelse return;
    }
}

/// A cgroup file holding one number; null for "max", or when it is not there.
fn cgroup_number(level: []const u8, comptime name: []const u8) ?u64 {
    var path_buffer: [320]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/" ++ name, .{level}, 0) catch return null;
    var buffer: [64]u8 = undefined;
    const text = read_small(path, &buffer) orelse return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n"), 10) catch null;
}

/// A field of a cgroup's memory.stat ("<key> <bytes>"), 0 when absent.
fn cgroup_stat(level: []const u8, comptime key: []const u8) u64 {
    var path_buffer: [320]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/memory.stat", .{level}, 0) catch return 0;
    var buffer: [8192]u8 = undefined;
    const text = read_small(path, &buffer) orelse return 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        return std.fmt.parseInt(u64, std.mem.trim(u8, line[key.len..], " "), 10) catch 0;
    }
    return 0;
}

fn read_small(path: [*:0]const u8, buffer: []u8) ?[]const u8 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    const size = linux.read(@intCast(fd), buffer.ptr, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    return buffer[0..size];
}

fn meminfo(comptime key: []const u8) u64 {
    const fd = linux.open("/proc/meminfo", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return 0;
    defer _ = linux.close(@intCast(fd));
    var buffer: [4096]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return 0;
    const at = std.mem.indexOf(u8, buffer[0..size], key) orelse return 0;
    var words = std.mem.tokenizeScalar(u8, buffer[at + key.len .. size], ' ');
    const kib = std.fmt.parseInt(u64, words.next() orelse return 0, 10) catch return 0;
    return kib * 1024;
}

/// How many CPUs this process's pool holds: the CPUs it was given, one thread per core.
pub fn usable_count() u32 {
    const available = given();
    const bits = @bitSizeOf(@TypeOf(available[0]));
    var count: u32 = 0;
    for (0..available.len * bits) |cpu| {
        if (usable(&available, cpu)) count += 1;
    }
    return @max(count, 1);
}

/// In the set, and, with one thread per core (the default), not a second hyperthread whose
/// core's first thread is in the set too.
fn usable(available: *const linux.cpu_set_t, cpu: usize) bool {
    const bits = @bitSizeOf(@TypeOf(available[0]));
    if (available[cpu / bits] >> @intCast(cpu % bits) & 1 == 0) return false;
    if (siblings_allowed()) return true;
    const first = first_sibling(@intCast(cpu)) orelse return true;
    if (first == cpu) return true;
    return available[first / bits] >> @intCast(first % bits) & 1 == 0;
}

fn siblings_allowed() bool {
    const value = std.c.getenv("DETERMINISMO_SMT") orelse return false;
    return std.mem.eql(u8, std.mem.span(value), "1");
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
    _ = given(); // Read before narrowing it.
    var set: linux.cpu_set_t = @splat(0);
    const bits = @bitSizeOf(@TypeOf(set[0]));
    set[cpu / bits] = @as(@TypeOf(set[0]), 1) << @intCast(cpu % bits);
    linux.sched_setaffinity(0, &set) catch {}; // Best effort: the lock is what counts.
}

/// Lets this process run on the CPUs it was given again (one that holds none, after a pin).
pub fn unpin() void {
    const set = given();
    linux.sched_setaffinity(0, &set) catch {};
}

test "pinned, a process still counts and pools the CPUs it was given" {
    const before = usable_count();
    var pool: Pool = undefined;
    try pool.open();
    defer pool.close();
    const held = pool.take(); // Pins this process to one CPU.
    try std.testing.expectEqual(before, usable_count());
    var while_pinned: Pool = undefined;
    try while_pinned.open();
    defer while_pinned.close();
    try std.testing.expectEqual(pool.count, while_pinned.count);
    pool.give(held);
    var mask: linux.cpu_set_t = undefined;
    _ = linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &mask);
    try std.testing.expectEqualSlices(usize, &given(), &mask); // Unpinned when given back.
}

/// What processes hold outside their VMs' claims (a tree explorer's in-run snapshots, the
/// setup's among them, gigabytes each): `nodes-<pid>` in the pool's directory, its bytes, counted
/// while its process holds its lock. Unclaimed, they filled a host whose VMs fit their claims
/// (Dgraph hunts, srv3 2026-10-28: 20 GB of nodes beside 96 GB of VMs).
var nodes_fd: ?linux.fd_t = null;

/// Sets this process's nodes claim (the bytes of the snapshots it holds).
pub fn nodes_claim(bytes: u64) void {
    const fd = nodes_fd orelse opened: {
        var buffer: [96]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&buffer, "/tmp/determinismo-cpus-{d}/nodes-{d}", .{
            linux.getuid(), linux.getpid(),
        }, 0) catch return;
        const result = linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
        if (linux.errno(result) != .SUCCESS) return;
        const fd: linux.fd_t = @intCast(result);
        _ = linux.flock(fd, std.posix.LOCK.EX);
        nodes_fd = fd;
        break :opened fd;
    };
    const value = std.mem.toBytes(bytes);
    _ = linux.pwrite(fd, &value, value.len, 0);
}

/// Every live process's nodes claim, in bytes; a dead process's file is removed.
fn nodes_claimed(directory: []const u8) u64 {
    if (directory.len == 0) return 0;
    var path_buffer: [128]u8 = undefined;
    const directory_z = std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{directory}, 0) catch return 0;
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const opened = linux.open(directory_z, flags, 0);
    if (linux.errno(opened) != .SUCCESS) return 0;
    const dir: linux.fd_t = @intCast(opened);
    defer _ = linux.close(dir);
    var total: u64 = 0;
    var entries: [8192]u8 align(8) = undefined;
    while (true) {
        const size = linux.getdents64(dir, &entries, entries.len);
        if (linux.errno(size) != .SUCCESS or size == 0) break;
        var at: usize = 0;
        while (at < size) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[at]);
            at += entry.reclen;
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
            if (!std.mem.startsWith(u8, name, "nodes-")) continue;
            const name_z: [*:0]const u8 = @ptrCast(&entry.name);
            const file = linux.openat(dir, name_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
            if (linux.errno(file) != .SUCCESS) continue;
            const fd: linux.fd_t = @intCast(file);
            defer _ = linux.close(fd);
            if (linux.errno(linux.flock(fd, std.posix.LOCK.SH | std.posix.LOCK.NB)) == .SUCCESS) {
                // Nobody holds it: its process is gone, or has just made it (not locked yet).
                var proc_buffer: [32]u8 = undefined;
                const proc = std.fmt.bufPrintSentinel(&proc_buffer, "/proc/{s}", .{name["nodes-".len..]}, 0) catch continue;
                if (linux.errno(linux.access(proc, std.posix.F_OK)) != .SUCCESS) _ = linux.unlinkat(dir, name_z, 0);
                continue;
            }
            var value: [8]u8 = @splat(0);
            if (linux.pread(fd, &value, value.len, 0) == value.len) total += std.mem.bytesToValue(u64, &value);
        }
    }
    return total;
}

/// Whether `bytes` more fit: within the claims (the VMs holding CPUs, each its guest's size) and
/// the reserve, and there now (`available`, 0 when unknown): claims miss what holds memory
/// without a CPU (holders, in-run snapshots, host checks' services), and a check beside a hunt
/// once fit its claims while the host ran out (srv3, 2026-10-28: the OOM killer took a hunt's
/// timeline and podman's pause process).
fn fits(claimed: u64, bytes: u64, total: u64, available: u64, reserve: u64) bool {
    if (claimed + bytes + reserve > total) return false;
    return available == 0 or bytes + reserve <= available;
}

test fits {
    const gib = 1 << 30;
    const reserve = memory_reserve_bytes;
    try std.testing.expect(fits(100 * gib, 7 * gib, 125 * gib, 40 * gib, reserve));
    try std.testing.expect(!fits(112 * gib, 7 * gib, 125 * gib, 40 * gib, reserve)); // Past the claims.
    try std.testing.expect(!fits(60 * gib, 7 * gib, 125 * gib, 12 * gib, reserve)); // Not there now.
    try std.testing.expect(fits(60 * gib, 7 * gib, 125 * gib, 0, reserve)); // Unknown: the claims alone.
    // A run leaves the sessions' memory: what a check could take, a run waits for.
    try std.testing.expect(fits(60 * gib, 2 * gib, 125 * gib, 12 * gib, reserve));
    try std.testing.expect(!fits(60 * gib, 2 * gib, 125 * gib, 12 * gib, reserve + 12 * gib));
}

test "a VM's memory claim counts while its CPU is held" {
    var holder: Pool = undefined;
    try holder.open();
    defer holder.close();
    var other: Pool = undefined;
    try other.open();
    defer other.close();
    holder.available_counts = false; // The claims' accounting alone (fits has the rest).
    other.available_counts = false;
    // The host's: claims are host-wide, whatever this test's cgroup limit (a check's unit).
    const total = meminfo("MemTotal:");
    if (total == 0) return error.SkipZigTest;
    const saved = claim_bytes;
    defer claim_bytes = saved;
    claim_bytes = total / 2;
    const held = holder.take(); // Claims half the host.
    try std.testing.expect(!other.claim_fits(total / 2)); // Half more, and the reserve: no.
    try std.testing.expect(other.claim_fits(1 << 20));
    holder.give(held);
    try std.testing.expect(other.claim_fits(total / 2)); // Given back: its claim no longer counts.
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

test "a check waiting for memory is seen by the runs" {
    var directory_buffer: [64]u8 = undefined;
    const directory = try std.fmt.bufPrintSentinel(&directory_buffer, "/tmp/determinismo-cpus-test-{d}", .{linux.getpid()}, 0);
    _ = linux.mkdir(directory, 0o700);
    try std.testing.expect(!memory_priority_waiting());
    var path_buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/memory-priority", .{directory}, 0);
    const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
    const waiter: linux.fd_t = @intCast(linux.open(path, flags, 0o600));
    defer _ = linux.close(waiter);
    _ = linux.flock(waiter, std.posix.LOCK.SH); // The check, waiting.
    try std.testing.expect(memory_priority_waiting());
    _ = linux.flock(waiter, std.posix.LOCK.UN); // Served.
    try std.testing.expect(!memory_priority_waiting());
}

test "a cgroup's limit and what is free under it" {
    var path_buffer: [64]u8 = undefined;
    const level_z = try std.fmt.bufPrintSentinel(&path_buffer, "/tmp/determinismo-cgroup-test-{d}", .{linux.getpid()}, 0);
    const level: []const u8 = level_z;
    _ = linux.mkdir(level_z, 0o755);
    defer _ = linux.rmdir(level_z);
    const files = [_][2][]const u8{
        .{ "memory.max", "25769803776\n" },
        .{ "memory.current", "10737418240\n" },
        .{ "memory.stat", "anon 6442450944\nfile 4294967296\ninactive_file 2147483648\nactive_file 1073741824\n" },
    };
    for (files) |file| {
        var file_buffer: [128]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&file_buffer, "{s}/{s}", .{ level, file[0] }, 0);
        const fd = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
        try std.testing.expect(linux.errno(fd) == .SUCCESS);
        _ = linux.write(@intCast(fd), file[1].ptr, file[1].len);
        _ = linux.close(@intCast(fd));
    }
    defer for (files) |file| {
        var file_buffer: [128]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&file_buffer, "{s}/{s}", .{ level, file[0] }, 0) catch unreachable;
        _ = linux.unlink(path);
    };
    try std.testing.expectEqual(24 << 30, cgroup_number(level, "memory.max").?);
    try std.testing.expectEqual(10 << 30, cgroup_number(level, "memory.current").?);
    try std.testing.expectEqual(2 << 30, cgroup_stat(level, "inactive_file "));
    try std.testing.expectEqual(0, cgroup_stat(level, "shmem "));
    try std.testing.expectEqual(null, cgroup_number(level, "memory.high")); // Not there.
}
