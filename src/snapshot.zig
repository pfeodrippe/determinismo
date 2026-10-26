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
serial: @FieldType(VM, "serial"),
rtc: @FieldType(VM, "rtc"),
pit: @FieldType(VM, "pit"),
blocks: @FieldType(VM, "blocks"),
block_count: u32,
decisions: @FieldType(VM, "decisions"),
events: @FieldType(VM, "events"),

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
        .serial = vm.serial,
        .rtc = vm.rtc,
        .pit = vm.pit,
        .blocks = vm.blocks,
        .block_count = vm.block_count,
        .decisions = vm.decisions,
        .events = vm.events,
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
pub fn capture_memory(snapshot: *Snapshot, memory: []align(std.heap.page_size_min) u8) !void {
    assert(snapshot.memory_fd == -1);
    assert(memory.len == snapshot.memory_size);
    snapshot.memory_fd = try memory_copy(memory);
}

/// Freezes a branch: its memory is a private copy-on-write mapping, so it is first copied into a
/// memfd of its own. Only resident pages that are not all zeros are copied (mincore), so memory
/// the guest never touched costs nothing.
pub fn take_copy(snapshot: *Snapshot, vm: *VM) !void {
    assert(!vm.memory_fd_owned); // A branch: its memory belongs to the parent snapshot.
    const fd = try memory_copy(vm.memory);
    vm.memory_fd = fd;
    vm.memory_fd_owned = true;
    try snapshot.take(vm);
    assert(snapshot.memory_fd == fd);
}

const chunk_pages = 4096;

fn memory_copy(memory: []align(std.heap.page_size_min) u8) !std.os.linux.fd_t {
    const linux = std.os.linux;
    const page = std.heap.page_size_min;
    assert(memory.len % page == 0);
    const created = linux.memfd_create("guest-ram-branch", 0);
    if (linux.errno(created) != .SUCCESS) return error.Memfd;
    const fd: linux.fd_t = @intCast(created);
    if (linux.errno(linux.ftruncate(fd, @intCast(memory.len))) != .SUCCESS) return error.Truncate;
    var resident: [chunk_pages]u8 = undefined;
    var offset: u64 = 0;
    while (offset < memory.len) : (offset += chunk_pages * page) {
        const size = @min(chunk_pages * page, memory.len - offset);
        const chunk = memory[offset..][0..size];
        const residency = linux.mincore(chunk.ptr, size, &resident);
        if (linux.errno(residency) != .SUCCESS) return error.Mincore;
        for (0..size / page) |index| {
            if (resident[index] & 1 == 0) continue;
            const bytes = chunk[index * page ..][0..page];
            if (std.mem.allEqual(u8, bytes, 0)) continue; // A fresh memfd reads as zeros.
            const position: i64 = @intCast(offset + index * page);
            const written = linux.pwrite(fd, bytes.ptr, page, position);
            if (linux.errno(written) != .SUCCESS or written != page) return error.Write;
        }
    }
    return fd;
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
    vm.serial = snapshot.serial;
    vm.rtc = snapshot.rtc;
    vm.pit = snapshot.pit;
    // Disk contents never change; the devices' ring positions and registers do.
    if (vm.block_count != snapshot.block_count) return error.SnapshotDisksDiffer;
    vm.blocks = snapshot.blocks;
    vm.events = snapshot.events;
    vm.branches_offset = snapshot.branches;
    assert(vm.target_branches == 0);
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
