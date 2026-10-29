// SPDX-License-Identifier: MIT
//! In-run snapshots for the tree explorer (main.zig). When a timeline reaches a behavior the
//! tree did not know, it pauses just after it, where a replay to that moment would stop (vm.zig's
//! hold points), forks a holder and goes on. The holder keeps the machine there, copy-on-write.
//! When the explorer returns to that moment, the holder copies it into a snapshot; to a later
//! moment of the same timeline, it replays only from there. Without a holder the explorer replays
//! from the timeline's start, as before: the tree is the same either way, only faster.
//!
//! A holder costs the memory its timeline writes after it (the pages it still shares are free):
//! a timeline keeps a few, spread out, none while memory runs low. Its cost grows as its timeline
//! goes on, so a holder goes by itself once the host's memory runs low (a node then costs a
//! replay, never a timeline): the VMs' memory comes first (cpus.zig). 18 YugabyteDB timelines
//! and their holders once left srv2 0 GB, thrashing until the OOM killer acted (2026-10-27).
//!
//! While memory runs low, a run with a directory keeps its moments on disk instead (Disk): a
//! short-lived child writes the moment's snapshot, diffed against the timeline's previous one,
//! and the explorer loads it when it needs a node there or after it. Kafka's timelines run 12
//! virtual minutes: without holders (none in 180 of run 67's first 207), each new one replayed
//! its parent from the start, half its time on average.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const Snapshot = @import("snapshot.zig");
const VM = @import("vm.zig");
const fd_pass = @import("fd_pass.zig");
const cpus = @import("cpus.zig");

/// Holders a timeline keeps at most: past it, the one closest to the one before it goes, so the
/// replays from a holder to a later moment stay short wherever the moment is.
pub const per_timeline_max = 8;
/// Holders of a timeline are its length over this apart at least (a timeline reaches new
/// behaviors in bursts: one holder per burst).
const spacing_divisor = 64;
const spacing_ns_min = 10 * std.time.ns_per_ms;
/// Before any of the run's timelines said how long they run: each holder is a fork of the VM
/// (its page tables copied, and every page the guest writes after it copied again), so not
/// every 10 ms of a long timeline (a YugabyteDB VM of 7 GB, reaching new log lines all the
/// time, spent half its time outside the guest; srv3).
const spacing_ns_unknown = std.time.ns_per_s;
/// No holder is made with less memory than this available (MemAvailable): room to grow in; a
/// run's holders leave the sessions' memory too (cpus.sessions_reserve_bytes).
fn make_available_min() u64 {
    return 2 * cpus.memory_reserve() + cpus.sessions_reserve_bytes();
}
/// A holder goes once less than this is available, above where a VM start waits (cpus.zig).
fn keep_available_min() u64 {
    return cpus.reserve_bytes();
}
/// How often a holder looks at the host's memory, plus up to as much again by its pid: holders
/// look at different moments, so the first ones gone can give enough back for the rest.
const memory_check_ms = 200;

/// What the explorer asks a holder: the moment of the node to make; or (`disk`) to write its
/// snapshot to the run's ladder directory, diffed against `base` (Ladder).
pub const Request = extern struct {
    vtime_ns: u64,
    kind: Kind = .node,
    base_len: u32 = 0,
    base: [Snapshot.disk_name_max]u8 = @splat(0),

    pub const Kind = enum(u32) { node, disk };
};

/// A failing timeline's holders, written to disk one after the other (main.zig's ladder): each
/// `b<timeline>-<ms>`, the pages changed since the one before (its base). Set before the
/// workers fork: `hashes` is a shared mapping (Snapshot.PageHashes), the base's page hashes,
/// which each holder's save updates to its own for the next.
pub const Ladder = struct {
    directory: []const u8,
    hashes: []u64,
};

/// The name a holder's snapshot gets on disk (causality's, for a moment of the timeline).
pub fn ladder_name(buffer: *[Snapshot.disk_name_max]u8, branch: u32, vtime_ns: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "b{d}-{d}", .{ branch, vtime_ns / std.time.ns_per_ms }) catch unreachable;
}

/// A holder as its timeline's summary carries it to the explorer: its process, and where it
/// listens (an abstract Unix socket named after the explorer, its worker and its number there);
/// or (`disk` set, no process) its snapshot in the run's Disk directory, and whether its hold
/// point was inside an idle skip (VM.Hold.Point, for replays on from it).
pub const Held = extern struct {
    pid: linux.pid_t,
    worker: linux.pid_t,
    id: u32,
    vtime_ns: u64,
    disk: bool = false,
    idle: bool = false,
};

/// Where a run's holders go while memory runs low (Owner.disk_hold): `h<timeline>-<ns>` each,
/// the pages changed since the timeline's previous one (Snapshot.disk_save's chain), deleted
/// with the timeline's holders (Registry), dropped ones too (bases of later ones).
pub const Disk = struct {
    directory: []const u8,

    pub fn name(buffer: *[Snapshot.disk_name_max]u8, branch: u32, vtime_ns: u64) []const u8 {
        return std.fmt.bufPrint(buffer, "h{d}-{d}", .{ branch, vtime_ns }) catch unreachable;
    }

    /// Deletes the snapshots of `branch` (all of them for null).
    pub fn delete(disk: *const Disk, branch: ?u32) void {
        var path_buffer: [4096]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{disk.directory}, 0) catch return;
        const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
        if (linux.errno(opened) != .SUCCESS) return;
        const directory: linux.fd_t = @intCast(opened);
        defer _ = linux.close(directory);
        var prefix_buffer: [32]u8 = undefined;
        const prefix = if (branch) |index|
            std.fmt.bufPrint(&prefix_buffer, "h{d}-", .{index}) catch unreachable
        else
            "h";
        var entries: [16 * 1024]u8 align(8) = undefined;
        // Passes until one deletes nothing: a directory read while its entries go may skip some.
        for (0..passes_max) |_| {
            _ = linux.lseek(directory, 0, linux.SEEK.SET);
            var deleted: u32 = 0;
            while (true) {
                const size = linux.getdents64(directory, &entries, entries.len);
                if (linux.errno(size) != .SUCCESS or size == 0) break;
                var at: usize = 0;
                while (at < size) {
                    const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[at]);
                    at += entry.reclen;
                    const entry_name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
                    // "h12-" is no prefix of "h123-...": the number ends at its dash.
                    if (!std.mem.startsWith(u8, entry_name, prefix)) continue;
                    var name_buffer: [256]u8 = undefined;
                    const name_z = std.fmt.bufPrintSentinel(&name_buffer, "{s}", .{entry_name}, 0) catch continue;
                    if (linux.errno(linux.unlinkat(directory, name_z, 0)) == .SUCCESS) deleted += 1;
                }
            }
            if (deleted == 0) return;
        }
    }

    const passes_max = 8;
};

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
                if (!held.disk) kill(held.pid); // Never with generations of at most 256 timelines.
                continue;
            }
            registry.entries[registry.count] = .{ .held = held, .branch = branch, .taken = false };
            registry.count += 1;
        }
    }

    /// A holder's socket, where the snapshot comes back as from a node-making child, and its
    /// pid; or (`disk`) a holder on disk, which a node-making child loads.
    pub const Taken = struct { socket: linux.fd_t = -1, pid: linux.pid_t = 0, disk: ?Held = null };

    /// The latest holder of `branch` at or before `vtime_ns` that takes the request (one killed
    /// for memory does not). Null when none does.
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
            if (held.disk) return .{ .disk = held };
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

    /// The holders of `branches` that nobody took go (their memory: a generation judged), and
    /// their timelines' snapshots on disk (their nodes are made).
    pub fn release_listed(registry: *Registry, branches: []const u32, disk: ?*const Disk) void {
        var kept: u32 = 0;
        for (registry.entries[0..registry.count]) |entry| {
            const theirs = std.mem.indexOfScalar(u32, branches, entry.branch) != null;
            if (!theirs) {
                registry.entries[kept] = entry;
                kept += 1;
            } else if (!entry.taken and !entry.held.disk) kill(entry.held.pid);
        }
        registry.count = kept;
        if (disk) |known| for (branches) |branch| known.delete(branch);
    }

    /// The holders of `branch` nobody took, set aside (they are not released with their
    /// generation): the caller writes them to disk, then they go (`Taken`'s socket closed, or
    /// `kill`). Sorted by moment, into `out`.
    pub fn set_aside(registry: *Registry, branch: u32, out: []Held) []Held {
        var count: usize = 0;
        for (registry.entries[0..registry.count]) |*entry| {
            if (entry.taken or entry.branch != branch or count == out.len) continue;
            if (entry.held.disk) continue; // On disk already, outside the ladder's chain.
            entry.taken = true;
            out[count] = entry.held;
            count += 1;
        }
        std.sort.insertion(Held, out[0..count], {}, held_earlier);
        return out[0..count];
    }

    fn held_earlier(_: void, a: Held, b: Held) bool {
        return a.vtime_ns < b.vtime_ns;
    }

    /// The holders nobody took go (their memory, before the next generation runs), and every
    /// snapshot on disk.
    pub fn release(registry: *Registry, disk: ?*const Disk) void {
        for (registry.entries[0..registry.count]) |*entry| {
            if (!entry.taken and !entry.held.disk) kill(entry.held.pid);
        }
        registry.count = 0;
        if (disk) |known| known.delete(null);
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
    /// Where holders write themselves when the explorer asks (a failing timeline's ladder).
    ladder: ?*const Ladder = null,
    /// Where moments go while memory runs low (null: none made then); always there with
    /// `disk_always` (--holders-on-disk, for checks).
    disk: ?*const Disk = null,
    disk_always: bool = false,
    /// The timeline's disk holders: the page hashes of the last one written (shared with its
    /// writer, which updates them), its name (the next one's base), the chain's length, and its
    /// writer while it runs.
    disk_hashes: ?[]u64 = null,
    disk_base: [Snapshot.disk_name_max]u8 = undefined,
    disk_base_len: u32 = 0,
    disk_chain: u32 = 0,
    disk_writer: linux.pid_t = 0,
    hold: VM.Hold = undefined,
    /// The moment armed (as the explorer will ask for it), and whether it follows a behavior
    /// (else it is periodic: a timeline that finds nothing new for a while still has holders,
    /// for the random moments the tree then returns to).
    armed_ns: ?u64 = null,
    armed_new: bool = false,
    last_ns: ?u64 = null,
    /// Holders made so far (each one's socket number).
    made: u32 = 0,
    /// Whether it said that memory stopped its holders (once a timeline).
    short_said: bool = false,
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
        const length = timeline_ns orelse return spacing_ns_unknown;
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
        // Not once host checks' inputs arrived (the timeline's end): their bytes are in this
        // worker's buffer, and a node goes to any worker with its state, not that buffer's
        // content. A replay makes such a node right.
        if (vm.events.check_used > 0) return;
        const available = cpus.memory_available();
        if (owner.disk_always and owner.disk != null) return owner.disk_hold(vm, moment, point);
        if (available < make_available_min()) {
            // Said once a timeline: its nodes are then made by replays (checks read it), or from
            // disk.
            if (!owner.short_said) std.debug.print("[determinismo] holders: {s}, {d} GB " ++
                "available ({d} needed)\n", .{
                if (owner.disk != null) "on disk" else "none made",
                available >> 30,
                make_available_min() >> 30,
            });
            owner.short_said = true;
            // Not below the reserve either: its writer's fork costs the pages the VM writes
            // while it runs.
            if (owner.disk != null and available >= keep_available_min()) try owner.disk_hold(vm, moment, point);
            return;
        }
        try owner.snapshot.capture(vm);
        owner.point = point;
        const id = owner.made;
        owner.made += 1;
        // Listening before the fork: the explorer may connect whenever it needs the holder.
        const at = address(owner.explorer, owner.worker, id);
        const listener = listen(&at) orelse return;
        const pid = linux.fork();
        if (pid == 0) {
            // It waits; it runs only for whoever asks, who holds a CPU meanwhile (cpus.zig).
            cpus.unpin();
            owner.serve(vm, listener, moment);
        }
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

    /// Memory runs low: the moment goes to disk instead, written by a child forked here (the
    /// timeline goes on meanwhile), its pages diffed against the timeline's previous one. With
    /// the previous write still under way, none this time: never a stall.
    fn disk_hold(owner: *Owner, vm: *VM, moment: u64, point: VM.Hold.Point) !void {
        const disk = owner.disk.?;
        if (!owner.disk_writer_done(false)) return;
        const hashes = owner.disk_hashes orelse hashes: {
            const pages = vm.memory.len / std.heap.page_size_min;
            const bytes = pages * @sizeOf(u64);
            const mapped = linux.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .ANONYMOUS = true }, -1, 0);
            if (linux.errno(mapped) != .SUCCESS) return;
            const made: [*]u64 = @ptrFromInt(mapped);
            owner.disk_hashes = made[0..pages];
            break :hashes made[0..pages];
        };
        // A chain of at most a timeline's holders: loading one reads its bases too.
        if (owner.disk_chain == per_timeline_max) owner.disk_base_len = 0;
        if (owner.disk_base_len == 0) {
            @memset(hashes, 0); // A fresh table: every page written.
            owner.disk_chain = 0;
        }
        try owner.snapshot.capture(vm);
        var name_buffer: [Snapshot.disk_name_max]u8 = undefined;
        const name = Disk.name(&name_buffer, owner.branch, moment);
        const base: ?[]const u8 = if (owner.disk_base_len > 0) owner.disk_base[0..owner.disk_base_len] else null;
        const pid = linux.fork();
        if (pid == 0) {
            machine_forget(vm);
            cpus.unpin();
            const memory: []align(std.heap.page_size_min) const u8 = vm.memory;
            Snapshot.disk_save(owner.snapshot, memory, vm.memory_fd, hashes, disk.directory, name, base, point.idle) catch
                linux.exit_group(1);
            linux.exit_group(0);
        }
        if (linux.errno(pid) != .SUCCESS) return;
        owner.disk_writer = @intCast(pid);
        @memcpy(owner.disk_base[0..name.len], name);
        owner.disk_base_len = @intCast(name.len);
        owner.disk_chain += 1;
        owner.kept[owner.kept_count] = .{
            .pid = 0,
            .worker = owner.worker,
            .id = owner.made,
            .vtime_ns = moment,
            .disk = true,
            .idle = point.idle,
        };
        owner.made += 1;
        owner.kept_count += 1;
        if (owner.kept_count > per_timeline_max) owner.drop();
    }

    /// Whether the last disk holder's writer is done (waiting for it with `wait`). One that
    /// failed leaves no file (its node is then made by a replay) and the shared hashes partly
    /// its own: the next one starts a chain afresh.
    fn disk_writer_done(owner: *Owner, wait: bool) bool {
        if (owner.disk_writer == 0) return true;
        var status: i32 = 0;
        const flags: u32 = if (wait) 0 else linux.W.NOHANG;
        const result = linux.wait4(owner.disk_writer, &status, flags, null);
        if (linux.errno(result) == .SUCCESS and result == 0) return false; // Still writing.
        owner.disk_writer = 0;
        const code: u32 = @bitCast(status);
        const written = linux.errno(result) == .SUCCESS and linux.W.IFEXITED(code) and
            linux.W.EXITSTATUS(code) == 0;
        if (!written) owner.disk_base_len = 0;
        return true;
    }

    /// The timeline ends: its last disk holder is complete before the explorer may load it.
    pub fn disk_wait(owner: *Owner) void {
        _ = owner.disk_writer_done(true);
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
        // One on disk stays there (a later one's base): it goes with the timeline's holders.
        if (!owner.kept[victim].disk) kill(owner.kept[victim].pid);
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
        machine_forget(vm);
        oom_first();
        // Until the explorer asks, or is gone: a holder outlives its worker, never its explorer
        // (killed, or ended with timelines in flight whose holders it never heard of).
        const explorer = linux.pidfd_open(owner.explorer, 0);
        if (linux.errno(explorer) != .SUCCESS) linux.exit_group(0);
        var polled = [_]linux.pollfd{
            .{ .fd = listener, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = @intCast(explorer), .events = linux.POLL.IN, .revents = 0 },
        };
        const check_ms = memory_check_ms + @as(i32, @intCast(@mod(linux.getpid(), memory_check_ms)));
        while (true) {
            const ready = linux.poll(&polled, polled.len, check_ms);
            if (linux.errno(ready) == .INTR) continue;
            if (linux.errno(ready) != .SUCCESS or polled[1].revents != 0) linux.exit_group(0);
            if (polled[0].revents != 0) break;
            const available = cpus.memory_available(); // 0: unknown, never a reason to go.
            if (available == 0 or available >= keep_available_min()) continue;
            // Going, unless the explorer asked meanwhile.
            const asked = linux.poll(polled[0..1], 1, 0);
            if (linux.errno(asked) == .SUCCESS and polled[0].revents != 0) break;
            linux.exit_group(0);
        }
        _ = linux.close(@intCast(explorer));
        const accepted = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(accepted) != .SUCCESS) linux.exit_group(1);
        _ = linux.close(listener);
        const socket: linux.fd_t = @intCast(accepted);
        var request: Request = undefined;
        if (!read_exact(socket, std.mem.asBytes(&request))) linux.exit_group(0); // Released.
        if (request.kind == .disk) owner.disk_write(vm, socket, &request, moment_ns);
        if (request.vtime_ns < moment_ns) linux.exit_group(1);
        owner.snapshot.capture_memory(vm.memory, vm.memory_fd) catch linux.exit_group(1);
        // Running on to a later moment is a VM run: on a CPU of the host's pool (cpus.zig), never
        // two VMs on one hardware thread.
        var pool: cpus.Pool = undefined;
        const cpu: ?cpus.Held = if (request.vtime_ns != moment_ns) cpu: {
            pool.open() catch linux.exit_group(1);
            break :cpu pool.take();
        } else null;
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
        // Its CPU back before the answer, which the explorer may read after another's, one
        // waiting for a CPU (main.zig's node_make_start).
        if (cpu) |held| pool.give(held);
        fd_pass.send(socket, node.memory_fd) catch linux.exit_group(1);
        if (!write_all(socket, std.mem.asBytes(node))) linux.exit_group(1);
        linux.exit_group(0);
    }

    /// Writes this holder's snapshot to the ladder (its pages changed since the base's, whose
    /// hashes the shared table holds, then its own), answers one byte (0: written), and ends:
    /// the explorer asks the next holder after it.
    fn disk_write(owner: *Owner, vm: *VM, socket: linux.fd_t, request: *const Request, moment_ns: u64) noreturn {
        const ladder = owner.ladder orelse linux.exit_group(1);
        var name_buffer: [Snapshot.disk_name_max]u8 = undefined;
        const name = ladder_name(&name_buffer, owner.branch, moment_ns);
        const base = request.base[0..request.base_len];
        const memory: []align(std.heap.page_size_min) const u8 = vm.memory;
        Snapshot.disk_save(owner.snapshot, memory, vm.memory_fd, ladder.hashes, ladder.directory, name, base, owner.point.idle) catch {
            _ = write_all(socket, &.{1});
            linux.exit_group(1);
        };
        _ = write_all(socket, &.{0});
        linux.exit_group(0);
    }
};

/// Ends a holder set aside (Registry.set_aside) without writing it.
pub fn end(held: Held) void {
    kill(held.pid);
}

/// Asks a holder set aside (Registry.set_aside) to write itself to the ladder, diffed against
/// `base`; then it ends. Whether it did (a holder gone meanwhile, for memory, did not).
pub fn ask_disk(explorer: linux.pid_t, held: Held, base: []const u8) Written {
    defer kill(held.pid);
    const at = address(explorer, held.worker, held.id);
    const socket = connect(&at) orelse return .gone;
    defer _ = linux.close(socket);
    var request: Request = .{ .vtime_ns = held.vtime_ns, .kind = .disk, .base_len = @intCast(base.len) };
    @memcpy(request.base[0..base.len], base);
    if (!write_all(socket, std.mem.asBytes(&request))) return .gone;
    var answer: [1]u8 = undefined;
    return if (read_exact(socket, &answer) and answer[0] == 0) .written else .failed;
}

/// A ladder step: written; or the holder was gone (left for memory before it was asked: the
/// shared page hashes are untouched, still the base's); or its write failed on the way (they
/// may be partly its own).
pub const Written = enum { written, gone, failed };

/// Ends a holder and waits for it (it may have been waited for already, by its worker). Never
/// a pid of 0 or less: kill(0) is the caller's own process group (the explorer and every
/// worker, without a trace), kill(-1) every process of the user.
fn kill(pid: linux.pid_t) void {
    if (pid <= 0) {
        std.debug.print("[determinismo] a holder with pid {d}: not signalled\n", .{pid});
        return;
    }
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
/// In a fork of the worker (a holder, its disk writer): the worker's machine is not this
/// process's, only its memory and captured state are; nor is the worker's strategy plugin, which
/// would otherwise never see the end of its input when the worker stops it.
fn machine_forget(vm: *VM) void {
    _ = linux.close(vm.vcpu_fd);
    _ = linux.close(vm.vm_fd);
    _ = linux.close(vm.kvm_fd);
    if (vm.events.log_fd) |fd| _ = linux.close(fd);
    if (vm.strategy) |strategy| strategy.forget();
}

fn oom_first() void {
    const fd = linux.open("/proc/self/oom_score_adj", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    _ = linux.write(@intCast(fd), "1000", 4);
    _ = linux.close(@intCast(fd));
}

/// MemAvailable from /proc/meminfo, in bytes (0 when unreadable: no holders then).
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

test "a timeline's holders on disk go, and only its own" {
    var path_buffer: [64]u8 = undefined;
    const directory_z = try std.fmt.bufPrintSentinel(&path_buffer, "/tmp/determinismo-holders-test-{d}", .{linux.getpid()}, 0);
    const directory: []const u8 = directory_z;
    _ = linux.mkdir(directory_z, 0o755);
    defer _ = linux.rmdir(directory_z);
    const names = [_][]const u8{ "h12-5.state", "h12-5.mem", "h12-9.mem.part77", "h123-5.state", "h7-1.mem" };
    for (names) |name| {
        var file_buffer: [128]u8 = undefined;
        const file = try std.fmt.bufPrintSentinel(&file_buffer, "{s}/{s}", .{ directory, name }, 0);
        const fd = linux.open(file, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o644);
        try std.testing.expect(linux.errno(fd) == .SUCCESS);
        _ = linux.close(@intCast(fd));
    }
    const disk: Disk = .{ .directory = directory };
    disk.delete(12);
    for (names) |name| {
        var file_buffer: [128]u8 = undefined;
        const file = try std.fmt.bufPrintSentinel(&file_buffer, "{s}/{s}", .{ directory, name }, 0);
        const there = linux.errno(linux.access(file, std.posix.F_OK)) == .SUCCESS;
        try std.testing.expectEqual(!std.mem.startsWith(u8, name, "h12-"), there);
    }
    disk.delete(null);
    for (names) |name| {
        var file_buffer: [128]u8 = undefined;
        const file = try std.fmt.bufPrintSentinel(&file_buffer, "{s}/{s}", .{ directory, name }, 0);
        try std.testing.expect(linux.errno(linux.access(file, std.posix.F_OK)) != .SUCCESS);
    }
}
