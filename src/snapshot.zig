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
decisions: @FieldType(VM, "decisions"),
events: @FieldType(VM, "events"),

const Snapshot = @This();

/// Freezes `vm`: it must never run again, since branches share its memory.
pub fn take(snapshot: *Snapshot, vm: *VM) !void {
    assert(vm.deterministic);
    assert(!vm.frozen);
    try complete_pending_io(vm);
    if (vm.target_branches != 0) try vm.target_set(0); // Branches re-arm their own timer.
    const state = try vm.det_state();
    snapshot.* = .{
        .memory_fd = vm.memory_fd,
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
        .decisions = vm.decisions,
        .events = vm.events,
    };
    try save_vcpu(snapshot, vm.vcpu_fd);
    try save_msrs(snapshot, vm);
    for (&snapshot.irqchips, 0..) |*chip, index| {
        chip.* = .{ .chip_id = @intCast(index), .chip = undefined };
        _ = try kvm.ioctl(vm.vm_fd, kvm.GET_IRQCHIP, @intFromPtr(chip));
    }
    vm.frozen = true;
    assert(snapshot.msrs.count > 0);
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
