// SPDX-License-Identifier: MIT
//! A frozen machine (ARCHITECTURE.md §8): guest memory in a memfd nobody writes to any more, the
//! vCPU and interrupt-controller state KVM hands out, and the VMM's device and decision state.
//! Branches map the memory copy-on-write and restore the rest, so starting a timeline from a
//! snapshot costs a few milliseconds instead of a boot.
const std = @import("std");
const assert = std.debug.assert;
const kvm = @import("kvm.zig");
const VM = @import("vm.zig");

pub const msr_count_max = 512;

memory_fd: std.os.linux.fd_t,
memory_size: u64,
regs: kvm.Regs,
sregs: kvm.Sregs,
xsave: kvm.Xsave,
xcrs: kvm.Xcrs,
lapic: kvm.LapicState,
vcpu_events: kvm.VcpuEvents,
mp_state: u32,
debugregs: kvm.Debugregs,
msrs: kvm.Msrs(msr_count_max),
irqchips: [3]kvm.Irqchip,
/// Virtual time and branch count at the snapshot; restored VMs continue from them.
tsc: u64,
branches: u64,
/// The guest's XINUSE at the snapshot (KVM's record of it: XSAVE shows it to the guest, and
/// the XSAVE state saved here may have lost bits of it to the host's own save).
xinuse: u64,
serial: @FieldType(VM, "serial"),
rtc: @FieldType(VM, "rtc"),
pit: @FieldType(VM, "pit"),
blocks: @FieldType(VM, "blocks"),
block_count: u32,
decisions: @FieldType(VM, "decisions"),
events: @FieldType(VM, "events"),
/// The CPU modulation at the snapshot, its owed time included: a holder's replay goes on with
/// it (VM.Options.from_hold); nodes and branches start over.
modulation: ?VM.Modulation,

const Snapshot = @This();

/// Freezes `vm`: it must never run again, since branches share its memory.
pub fn take(snapshot: *Snapshot, vm: *VM) !void {
    assert(vm.deterministic);
    assert(!vm.frozen);
    try complete_pending_io(vm);
    if (vm.target_branches != 0) try vm.target_set(0); // Branches re-arm their own timer.
    try snapshot.state_save(vm, vm.memory_fd);
    vm.frozen = true;
}

/// Everything but memory of a running VM paused at a hold point, which then goes on: the state a
/// replay stopped at that moment would be frozen in (its console flushed as a run's end does).
/// The memory is copied later from a copy-on-write fork of the process (main.zig's holders).
pub fn capture(snapshot: *Snapshot, vm: *VM) !void {
    assert(vm.deterministic);
    assert(!vm.frozen);
    assert(vm.target_branches == 0); // Paused at a hold point: no stop armed.
    // As `take` does: an entry that runs nothing settles what KVM keeps lazily (its segment
    // cache, a pending event's fields, some MSRs), which its GETs report otherwise unsettled.
    // The run goes on as it would have: its next entry settles them the same way.
    try complete_pending_io(vm);
    try snapshot.state_save(vm, -1);
    snapshot.serial.output_count = 0;
}

fn state_save(snapshot: *Snapshot, vm: *VM, memory_fd: std.os.linux.fd_t) !void {
    const state = try vm.det_state();
    snapshot.* = .{
        .memory_fd = memory_fd,
        .memory_size = vm.memory.len,
        .regs = undefined,
        .sregs = undefined,
        .xsave = undefined,
        .xcrs = undefined,
        .lapic = undefined,
        .vcpu_events = undefined,
        .mp_state = undefined,
        .debugregs = undefined,
        .msrs = undefined,
        .irqchips = undefined,
        .tsc = state.tsc,
        .branches = vm.branches_offset + state.branches,
        .xinuse = state.xinuse,
        .serial = vm.serial,
        .rtc = vm.rtc,
        .pit = vm.pit,
        .blocks = vm.blocks,
        .block_count = vm.block_count,
        .decisions = vm.decisions,
        .events = vm.events,
        .modulation = if (vm.modulation) |m| m.rebased(state.branches, vm.tsc_per_branch) else null,
    };
    try save_vcpu(snapshot, vm.vcpu_fd);
    try save_msrs(snapshot, vm);
    for (&snapshot.irqchips, 0..) |*chip, index| {
        chip.* = .{ .chip_id = @intCast(index), .chip = undefined };
        _ = try kvm.ioctl(vm.vm_fd, kvm.GET_IRQCHIP, @intFromPtr(chip));
    }
    assert(snapshot.msrs.count > 0);
}

/// A captured snapshot's memory: a copy of `memory` (this process's copy-on-write view of the
/// VM's) in a memfd of its own.
pub fn capture_memory(
    snapshot: *Snapshot,
    memory: []align(std.heap.page_size_min) u8,
    backing_fd: std.os.linux.fd_t,
) !void {
    assert(snapshot.memory_fd == -1);
    assert(memory.len == snapshot.memory_size);
    snapshot.memory_fd = try memory_copy(memory, backing_fd);
}

/// Freezes a branch: its memory is a private copy-on-write mapping, so it is first copied into a
/// memfd of its own. Only resident pages that are not all zeros are copied (mincore), so memory
/// the guest never touched costs nothing.
pub fn take_copy(snapshot: *Snapshot, vm: *VM) !void {
    assert(!vm.memory_fd_owned); // A branch: its memory belongs to the parent snapshot.
    const fd = try memory_copy(vm.memory, vm.memory_fd);
    vm.memory_fd = fd;
    vm.memory_fd_owned = true;
    try snapshot.take(vm);
    assert(snapshot.memory_fd == fd);
}

const chunk_pages = 4096;

/// A copy of `memory` (mapped from the memfd `backing_fd`, shared or copy-on-write) in a memfd
/// of its own: the pages that may hold data (Candidates), those not all zeros.
fn memory_copy(memory: []align(std.heap.page_size_min) u8, backing_fd: std.os.linux.fd_t) !std.os.linux.fd_t {
    const linux = std.os.linux;
    const page = std.heap.page_size_min;
    assert(memory.len % page == 0);
    const fd = try memfd(memory.len);
    var candidates = try Candidates.init(memory, backing_fd);
    defer candidates.deinit();
    for (0..memory.len / page) |index| {
        if (!candidates.has(index)) continue;
        const bytes = memory[index * page ..][0..page];
        if (std.mem.allEqual(u8, bytes, 0)) continue; // A fresh memfd reads as zeros.
        const position: i64 = @intCast(index * page);
        const written = linux.pwrite(fd, bytes.ptr, page, position);
        if (linux.errno(written) != .SUCCESS or written != page) return error.Write;
    }
    return fd;
}

/// The pages of `memory` (a VM's, or a copy-on-write view of one) that may hold data: those
/// mapped in this process, resident or swapped out (/proc/self/pagemap), and those the memfd
/// behind it holds (SEEK_DATA: a swapped-out page of a memfd counts as data). Residency alone
/// (mincore) missed swapped-out pages, which copies then took for zeros: under the host's memory
/// pressure, nodes unlike the ones a replay makes. Without pagemap, every page.
pub const Candidates = struct {
    bits: []u64,

    const present: u64 = 1 << 63;
    const swapped: u64 = 1 << 62;
    const entries_per_read = 4096;
    const seek_data = 3;
    const seek_hole = 4;

    pub fn init(memory: []align(page_size) const u8, backing_fd: std.os.linux.fd_t) !Candidates {
        const linux = std.os.linux;
        const pages = memory.len / page_size;
        const bits = try std.heap.page_allocator.alloc(u64, @divCeil(pages, 64));
        @memset(bits, 0);
        var candidates: Candidates = .{ .bits = bits };
        const opened = linux.open("/proc/self/pagemap", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(opened) != .SUCCESS) {
            @memset(bits, std.math.maxInt(u64));
            return candidates;
        }
        const pagemap: linux.fd_t = @intCast(opened);
        defer _ = linux.close(pagemap);
        const first = @intFromPtr(memory.ptr) / page_size;
        var entries: [entries_per_read]u64 = undefined;
        var page: usize = 0;
        while (page < pages) {
            const count = @min(entries_per_read, pages - page);
            const bytes = std.mem.sliceAsBytes(entries[0..count]);
            const read = linux.pread(pagemap, bytes.ptr, bytes.len, @intCast((first + page) * @sizeOf(u64)));
            if (linux.errno(read) != .SUCCESS or read != bytes.len) {
                @memset(bits, std.math.maxInt(u64));
                return candidates;
            }
            for (entries[0..count], page..) |entry, index| {
                if (entry & (present | swapped) != 0) candidates.set(index);
            }
            page += count;
        }
        if (backing_fd >= 0) {
            var offset: i64 = 0;
            while (offset < memory.len) {
                const data = linux.lseek(backing_fd, offset, seek_data);
                if (linux.errno(data) != .SUCCESS) break; // ENXIO: no data past it.
                const hole = linux.lseek(backing_fd, @intCast(data), seek_hole);
                if (linux.errno(hole) != .SUCCESS) break;
                const end = @min(hole, memory.len);
                for (data / page_size..@divCeil(end, page_size)) |index| candidates.set(index);
                offset = @intCast(hole);
            }
        }
        return candidates;
    }

    pub fn deinit(candidates: *Candidates) void {
        std.heap.page_allocator.free(candidates.bits);
        candidates.* = undefined;
    }

    fn set(candidates: *Candidates, index: usize) void {
        candidates.bits[index / 64] |= @as(u64, 1) << @intCast(index % 64);
    }

    pub fn has(candidates: *const Candidates, index: usize) bool {
        return candidates.bits[index / 64] & (@as(u64, 1) << @intCast(index % 64)) != 0;
    }
};

fn memfd(size: u64) !std.os.linux.fd_t {
    const linux = std.os.linux;
    const created = linux.memfd_create("guest-ram-branch", 0);
    if (linux.errno(created) != .SUCCESS) return error.Memfd;
    const fd: linux.fd_t = @intCast(created);
    if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.Truncate;
    return fd;
}

// Snapshots on disk ------------------------------------------------------------------------------
//
// A directory of them, each `<name>.state` (DiskHeader, the snapshot's state, its checks' inputs,
// a bitmap of the pages it holds) and `<name>.mem` (those pages at their offsets: a sparse file).
// The first one saved holds all its pages; each later one only those that changed since its base
// (the one saved before it, named in its header), found by comparing each page's hash with the
// base's. Loading applies the chain, newest first, into a memfd: every page is read once, and
// the snapshot is then like any other (branches map it copy-on-write).

const page_size = std.heap.page_size_min;
const disk_magic: [8]u8 = "detsnap1".*;
pub const disk_name_max = 64;
/// A chain's length at most: deeper is a directory nobody pruned.
const disk_chain_max = 4096;

const DiskHeader = extern struct {
    magic: [8]u8 = disk_magic,
    /// This build's layout of the state: another build's snapshot is refused.
    snapshot_size: u64 = @sizeOf(Snapshot),
    memory_size: u64,
    check_used: u64,
    /// Saved at a hold point inside an idle skip (VM.Hold.Point): a replay of the timeline on
    /// from here goes on skipping.
    idle: u64,
    /// The snapshot whose pages this one's are changes from; empty: none, it holds them all.
    base: [disk_name_max]u8 = @splat(0),

    fn base_name(header: *const DiskHeader) []const u8 {
        return std.mem.sliceTo(&header.base, 0);
    }
};

/// The pages' hashes of the last snapshot saved (or of its base): shared with the children that
/// save, which update it (one at a time).
pub const PageHashes = struct {
    hashes: []u64,

    pub fn init(memory_size: u64) !PageHashes {
        const linux = std.os.linux;
        const size = memory_size / page_size * @sizeOf(u64);
        const address = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{
            .TYPE = .SHARED,
            .ANONYMOUS = true,
        }, -1, 0);
        if (linux.errno(address) != .SUCCESS) return error.OutOfMemory;
        const hashes = @as([*]u64, @ptrFromInt(address))[0 .. memory_size / page_size];
        return .{ .hashes = hashes }; // Zeros: every page zero, as a fresh machine's.
    }

    pub fn deinit(page_hashes: *PageHashes) void {
        _ = std.os.linux.munmap(@ptrCast(page_hashes.hashes.ptr), page_hashes.hashes.len * @sizeOf(u64));
        page_hashes.* = undefined;
    }
};

/// A page's hash: 0 for a page of zeros (or one never touched), never 0 otherwise.
fn page_hash(bytes: *const [page_size]u8) u64 {
    if (std.mem.allEqual(u8, bytes, 0)) return 0;
    return std.hash.Wyhash.hash(0x6465746572, bytes) | 1;
}

/// Saves `snapshot` (its state captured, `memory` its machine's memory as of then) as
/// `<directory>/<name>`: the pages whose hash differs from `hashes` (all of them, against a
/// fresh table), which then become the base's for the next. `base` names the snapshot whose
/// pages `hashes` holds (null: none). Plain system calls: it runs in a forked child.
pub fn disk_save(
    snapshot: *const Snapshot,
    memory: []align(page_size) const u8,
    backing_fd: std.os.linux.fd_t,
    hashes: []u64,
    directory: []const u8,
    name: []const u8,
    base: ?[]const u8,
    idle: bool,
) !void {
    const linux = std.os.linux;
    assert(memory.len == snapshot.memory_size);
    assert(hashes.len == memory.len / page_size);
    assert(name.len < disk_name_max);
    var path_buffer: [4096]u8 = undefined;
    // Written under a name of this process's, then renamed: two savers may write the same one
    // (the setup snapshot) at once, and a reader never sees half of one.
    const pid = linux.getpid();
    const memory_path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/{s}.mem.part{d}", .{ directory, name, pid }, 0);
    const memory_fd = try file_create(memory_path);
    defer _ = linux.close(memory_fd);
    if (linux.errno(linux.ftruncate(memory_fd, @intCast(memory.len))) != .SUCCESS) return error.Truncate;
    const bitmap = try std.heap.page_allocator.alloc(u64, @divCeil(hashes.len, 64));
    defer std.heap.page_allocator.free(bitmap);
    @memset(bitmap, 0);
    var candidates = try Candidates.init(memory, backing_fd);
    defer candidates.deinit();
    var offset: u64 = 0;
    while (offset < memory.len) : (offset += chunk_pages * page_size) {
        const size = @min(chunk_pages * page_size, memory.len - offset);
        const chunk = memory[offset..][0..size];
        // Changed pages, written in runs.
        var run_start: ?usize = null;
        for (0..size / page_size + 1) |index| {
            const changed = index < size / page_size and changed: {
                const at = offset / page_size + index;
                const bytes = chunk[index * page_size ..][0..page_size];
                const hash = if (!candidates.has(at)) 0 else page_hash(bytes);
                if (hash == hashes[at]) break :changed false;
                hashes[at] = hash;
                bitmap[at / 64] |= @as(u64, 1) << @intCast(at % 64);
                break :changed hash != 0; // A page now zero: in the bitmap, not the file.
            };
            if (changed) {
                if (run_start == null) run_start = index;
                continue;
            }
            const first = run_start orelse continue;
            run_start = null;
            const bytes = chunk[first * page_size .. index * page_size];
            try pwrite_all(memory_fd, bytes, offset + first * page_size);
        }
    }
    const state_path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/{s}.state.part{d}", .{ directory, name, pid }, 0);
    const state_fd = try file_create(state_path);
    defer _ = linux.close(state_fd);
    var header: DiskHeader = .{
        .memory_size = memory.len,
        .check_used = snapshot.events.check_used,
        .idle = @intFromBool(idle),
    };
    if (base) |text| {
        assert(text.len < disk_name_max);
        @memcpy(header.base[0..text.len], text);
    }
    var position: u64 = 0;
    for ([_][]const u8{
        std.mem.asBytes(&header),
        std.mem.asBytes(snapshot),
        snapshot.events.check_buffer[0..snapshot.events.check_used],
        std.mem.sliceAsBytes(bitmap),
    }) |part| {
        try pwrite_all(state_fd, part, position);
        position += part.len;
    }
    // The memory first: a state names a complete snapshot.
    for ([_][]const u8{ "mem", "state" }) |kind| {
        var from_buffer: [4096]u8 = undefined;
        const from = try std.fmt.bufPrintSentinel(&from_buffer, "{s}/{s}.{s}.part{d}", .{ directory, name, kind, pid }, 0);
        const to = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/{s}.{s}", .{ directory, name, kind }, 0);
        if (linux.errno(linux.rename(from, to)) != .SUCCESS) return error.Rename;
    }
}

/// The hashes of `memory`'s pages, into `hashes` (what disk_save compares with).
pub fn pages_hash(memory: []align(page_size) const u8, backing_fd: std.os.linux.fd_t, hashes: []u64) !void {
    assert(hashes.len == memory.len / page_size);
    var candidates = try Candidates.init(memory, backing_fd);
    defer candidates.deinit();
    for (hashes, 0..) |*hash, index| {
        const bytes = memory[index * page_size ..][0..page_size];
        hash.* = if (candidates.has(index)) page_hash(bytes) else 0;
    }
}

/// Whether `<directory>/<name>` was saved.
pub fn disk_exists(directory: []const u8, name: []const u8) bool {
    var path_buffer: [4096]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/{s}.state", .{ directory, name }, 0) catch
        return false;
    return std.os.linux.errno(std.os.linux.access(path, std.posix.F_OK)) == .SUCCESS;
}

/// Loads `<directory>/<name>` and the chain of bases it needs: its memory into a memfd of its
/// own, its checks' inputs into `check_buffer`.
pub fn disk_load(
    snapshot: *Snapshot,
    arena: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    name: []const u8,
    check_buffer: []u8,
) !void {
    const linux = std.os.linux;
    const cwd = std.Io.Dir.cwd();
    var memory_fd: ?linux.fd_t = null;
    errdefer if (memory_fd) |fd| {
        _ = linux.close(fd);
    };
    var loaded: []u64 = &.{}; // The pages already taken from a newer one.
    var current: []const u8 = name;
    var depth: u32 = 0;
    while (true) : (depth += 1) {
        if (depth == disk_chain_max) return error.SnapshotChainTooLong;
        const state_path = try std.fmt.allocPrint(arena, "{s}/{s}.state", .{ directory, current });
        const state = try cwd.readFileAlloc(io, state_path, arena, .unlimited);
        if (state.len < @sizeOf(DiskHeader)) return error.SnapshotTruncated;
        var header: DiskHeader = undefined;
        @memcpy(std.mem.asBytes(&header), state[0..@sizeOf(DiskHeader)]);
        if (!std.mem.eql(u8, &header.magic, &disk_magic)) return error.NotASnapshot;
        if (header.snapshot_size != @sizeOf(Snapshot)) return error.SnapshotOfAnotherBuild;
        const pages = header.memory_size / page_size;
        const words = @divCeil(pages, 64);
        const state_end = @sizeOf(DiskHeader) + @sizeOf(Snapshot) + header.check_used;
        if (state.len != state_end + words * @sizeOf(u64)) return error.SnapshotTruncated;
        if (depth == 0) {
            @memcpy(std.mem.asBytes(snapshot), state[@sizeOf(DiskHeader)..][0..@sizeOf(Snapshot)]);
            if (header.check_used > check_buffer.len) return error.SnapshotChecksTooLarge;
            @memcpy(check_buffer[0..header.check_used], state[@sizeOf(DiskHeader) + @sizeOf(Snapshot) ..][0..header.check_used]);
            if (snapshot.memory_size != header.memory_size) return error.SnapshotTruncated;
            memory_fd = try memfd(header.memory_size);
            loaded = try arena.alloc(u64, words);
            @memset(loaded, 0);
        } else if (header.memory_size != snapshot.memory_size) return error.SnapshotChainDiffers;
        const bitmap = try arena.alloc(u64, words);
        @memcpy(std.mem.sliceAsBytes(bitmap), state[state_end..]);
        const memory_path = try std.fmt.allocPrintSentinel(arena, "{s}/{s}.mem", .{ directory, current }, 0);
        const opened = linux.open(memory_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(opened) != .SUCCESS) return error.SnapshotMemoryMissing;
        const source: linux.fd_t = @intCast(opened);
        defer _ = linux.close(source);
        try pages_apply(source, memory_fd.?, bitmap, loaded);
        const base = header.base_name();
        if (base.len == 0) break;
        current = try arena.dupe(u8, base);
    }
    snapshot.memory_fd = memory_fd.?;
}

/// The pages of `bitmap` not in `loaded` yet: copied from `source` (zeros skipped: a memfd reads
/// as zeros), and then in `loaded`.
fn pages_apply(source: std.os.linux.fd_t, target: std.os.linux.fd_t, bitmap: []const u64, loaded: []u64) !void {
    const run_pages_max = 256;
    var buffer: [run_pages_max * page_size]u8 align(page_size) = undefined;
    var page: usize = 0;
    const pages = bitmap.len * 64;
    while (page < pages) {
        const word = bitmap[page / 64] & ~loaded[page / 64];
        if (word >> @intCast(page % 64) == 0) {
            page = (page / 64 + 1) * 64;
            continue;
        }
        if (word & (@as(u64, 1) << @intCast(page % 64)) == 0) {
            page += 1;
            continue;
        }
        // A run of pages to take, at most a buffer of them.
        var end = page;
        while (end < pages and end - page < run_pages_max) : (end += 1) {
            const bit = @as(u64, 1) << @intCast(end % 64);
            if (bitmap[end / 64] & bit == 0 or loaded[end / 64] & bit != 0) break;
            loaded[end / 64] |= bit;
        }
        const bytes = buffer[0 .. (end - page) * page_size];
        try pread_all(source, bytes, page * page_size);
        var index: usize = 0;
        while (index < end - page) {
            if (std.mem.allEqual(u8, bytes[index * page_size ..][0..page_size], 0)) {
                index += 1;
                continue;
            }
            var last = index + 1;
            while (last < end - page and !std.mem.allEqual(u8, bytes[last * page_size ..][0..page_size], 0)) last += 1;
            try pwrite_all(target, bytes[index * page_size .. last * page_size], (page + index) * page_size);
            index = last;
        }
        page = end;
    }
}

fn file_create(path: [:0]const u8) !std.os.linux.fd_t {
    const linux = std.os.linux;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const opened = linux.open(path, flags, 0o644);
    if (linux.errno(opened) != .SUCCESS) return error.SnapshotCreate;
    return @intCast(opened);
}

fn pwrite_all(fd: std.os.linux.fd_t, bytes: []const u8, offset: u64) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const written = std.os.linux.pwrite(fd, bytes[done..].ptr, bytes.len - done, @intCast(offset + done));
        if (std.os.linux.errno(written) != .SUCCESS or written == 0) return error.Write;
        done += written;
    }
}

fn pread_all(fd: std.os.linux.fd_t, bytes: []u8, offset: u64) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const read = std.os.linux.pread(fd, bytes[done..].ptr, bytes.len - done, @intCast(offset + done));
        if (std.os.linux.errno(read) != .SUCCESS) return error.Read;
        if (read == 0) return error.SnapshotTruncated;
        done += read;
    }
}

/// Loads everything but memory into a freshly created vCPU and VM.
pub fn restore(snapshot: *const Snapshot, vm: *VM) !void {
    assert(vm.deterministic);
    assert(vm.memory.len == snapshot.memory_size);
    const fd = vm.vcpu_fd;
    _ = try kvm.ioctl(fd, kvm.SET_SREGS, @intFromPtr(&snapshot.sregs));
    _ = try kvm.ioctl(fd, kvm.SET_REGS, @intFromPtr(&snapshot.regs));
    _ = try kvm.ioctl(fd, kvm.SET_XCRS, @intFromPtr(&snapshot.xcrs));
    _ = try kvm.ioctl(fd, kvm.SET_XSAVE, @intFromPtr(&snapshot.xsave));
    try restore_msrs(snapshot, fd);
    _ = try kvm.ioctl(fd, kvm.SET_LAPIC, @intFromPtr(&snapshot.lapic));
    _ = try kvm.ioctl(fd, kvm.SET_VCPU_EVENTS, @intFromPtr(&snapshot.vcpu_events));
    _ = try kvm.ioctl(fd, kvm.SET_MP_STATE, @intFromPtr(&snapshot.mp_state));
    _ = try kvm.ioctl(fd, kvm.SET_DEBUGREGS, @intFromPtr(&snapshot.debugregs));
    for (&snapshot.irqchips) |*chip| {
        _ = try kvm.ioctl(vm.vm_fd, kvm.SET_IRQCHIP, @intFromPtr(chip));
    }
    // What only means something in the process that made the snapshot (`local_count`) stays
    // this machine's: its buffers and file descriptors. A snapshot from disk was made by another.
    const output_fd = vm.serial.output_fd;
    vm.serial = snapshot.serial;
    vm.serial.output_fd = output_fd;
    vm.rtc = snapshot.rtc;
    vm.pit = snapshot.pit;
    // Disk contents never change; the devices' ring positions and registers do.
    if (vm.block_count != snapshot.block_count) return error.SnapshotDisksDiffer;
    var disk_fds: [vm.blocks.len]std.os.linux.fd_t = undefined;
    for (vm.blocks[0..vm.block_count], disk_fds[0..vm.block_count]) |block, *disk_fd| {
        disk_fd.* = block.fd;
    }
    vm.blocks = snapshot.blocks;
    for (vm.blocks[0..vm.block_count], disk_fds[0..vm.block_count]) |*block, disk_fd| {
        block.fd = disk_fd;
    }
    const parse_buffer = vm.events.parse_buffer;
    const check_buffer = vm.events.check_buffer;
    vm.events = snapshot.events;
    vm.events.parse_buffer = parse_buffer;
    vm.events.check_buffer = check_buffer;
    if (vm.events.check_used > check_buffer.len) return error.SnapshotChecksTooLarge;
    vm.branches_offset = snapshot.branches;
    assert(vm.target_branches == 0);
}

// Pointers in a snapshot's state: Events' parse and check buffers and retroactive patterns,
// which `restore` takes from the machine instead (and the checks' inputs travel apart, on
// disk). A new one must be handled there before this count changes.
comptime {
    @setEvalBranchQuota(100_000);
    if (pointer_count(Snapshot) != 3) @compileError("a snapshot's state has a new pointer: " ++
        "make restore keep the machine's own (and disk_save carry what it points to)");
}

fn pointer_count(comptime T: type) comptime_int {
    return switch (@typeInfo(T)) {
        .pointer => 1,
        .optional => |info| pointer_count(info.child),
        .array => |info| pointer_count(info.child),
        .@"struct" => |info| count: {
            var count = 0;
            for (info.field_types) |field| count += pointer_count(field);
            break :count count;
        },
        .@"union" => |info| count: {
            var count = 0;
            for (info.field_types) |field| count += pointer_count(field);
            break :count count;
        },
        else => 0,
    };
}

/// An exit that needs completion (port I/O) is completed by the next KVM_RUN. KVM's protocol for
/// saving state at such a point: run with immediate_exit set, which completes it and returns.
fn complete_pending_io(vm: *VM) !void {
    vm.run.immediate_exit = 1;
    defer vm.run.immediate_exit = 0;
    const result = kvm.ioctl(vm.vcpu_fd, kvm.RUN, 0);
    if (result) |_| return error.ImmediateExitIgnored else |err| switch (err) {
        error.Interrupted => {},
        else => return err,
    }
}

fn save_vcpu(snapshot: *Snapshot, fd: std.os.linux.fd_t) !void {
    assert(fd >= 0);
    _ = try kvm.ioctl(fd, kvm.GET_REGS, @intFromPtr(&snapshot.regs));
    _ = try kvm.ioctl(fd, kvm.GET_SREGS, @intFromPtr(&snapshot.sregs));
    _ = try kvm.ioctl(fd, kvm.GET_XSAVE, @intFromPtr(&snapshot.xsave));
    _ = try kvm.ioctl(fd, kvm.GET_XCRS, @intFromPtr(&snapshot.xcrs));
    _ = try kvm.ioctl(fd, kvm.GET_LAPIC, @intFromPtr(&snapshot.lapic));
    _ = try kvm.ioctl(fd, kvm.GET_VCPU_EVENTS, @intFromPtr(&snapshot.vcpu_events));
    _ = try kvm.ioctl(fd, kvm.GET_MP_STATE, @intFromPtr(&snapshot.mp_state));
    _ = try kvm.ioctl(fd, kvm.GET_DEBUGREGS, @intFromPtr(&snapshot.debugregs));
    assert(snapshot.regs.rip != 0);
}

/// Every MSR KVM can save, read one at a time: KVM_GET_MSRS stops at the first failure.
fn save_msrs(snapshot: *Snapshot, vm: *VM) !void {
    var list: kvm.MsrList(msr_count_max) = .{ .count = msr_count_max, .indices = undefined };
    _ = try kvm.ioctl(vm.kvm_fd, kvm.GET_MSR_INDEX_LIST, @intFromPtr(&list));
    assert(list.count <= msr_count_max);
    snapshot.msrs.count = 0;
    for (list.indices[0..list.count]) |index| {
        var one: kvm.Msrs(1) = .{ .count = 1, .entries = .{.{ .index = index, .data = 0 }} };
        const read = try kvm.ioctl(vm.vcpu_fd, kvm.GET_MSRS, @intFromPtr(&one));
        if (read != 1) continue; // Not readable for this vCPU's CPUID: nothing to restore.
        snapshot.msrs.entries[snapshot.msrs.count] = one.entries[0];
        snapshot.msrs.count += 1;
    }
    assert(snapshot.msrs.count <= list.count);
}

fn restore_msrs(snapshot: *const Snapshot, fd: std.os.linux.fd_t) !void {
    assert(snapshot.msrs.count <= msr_count_max);
    for (snapshot.msrs.entries[0..snapshot.msrs.count]) |entry| {
        var one: kvm.Msrs(1) = .{ .count = 1, .entries = .{entry} };
        const written = try kvm.ioctl(fd, kvm.SET_MSRS, @intFromPtr(&one));
        if (written != 1) std.log.debug("MSR 0x{x} not restorable", .{entry.index});
    }
}
