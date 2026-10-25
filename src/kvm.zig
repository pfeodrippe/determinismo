// SPDX-License-Identifier: MIT
//! Bindings for the Linux KVM API on x86-64, mirroring include/uapi/linux/kvm.h, plus the
//! determinismo extensions from kernel/patches/0001-kvm-determinismo.patch.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub const api_version = 12;
pub const pit_speaker_dummy: u32 = 1;

pub const GET_API_VERSION = ioctl_number(.none, 0x00, 0);
pub const CREATE_VM = ioctl_number(.none, 0x01, 0);
pub const GET_VCPU_MMAP_SIZE = ioctl_number(.none, 0x04, 0);
pub const GET_SUPPORTED_CPUID = ioctl_number(.read_write, 0x05, 8);
pub const CREATE_VCPU = ioctl_number(.none, 0x41, 0);
pub const SET_USER_MEMORY_REGION = ioctl_number(.write, 0x46, @sizeOf(UserspaceMemoryRegion));
pub const SET_TSS_ADDR = ioctl_number(.none, 0x47, 0);
pub const SET_IDENTITY_MAP_ADDR = ioctl_number(.write, 0x48, 8);
pub const CREATE_IRQCHIP = ioctl_number(.none, 0x60, 0);
pub const IRQ_LINE = ioctl_number(.write, 0x61, @sizeOf(IrqLevel));
pub const CREATE_PIT2 = ioctl_number(.write, 0x77, @sizeOf(PitConfig));
pub const RUN = ioctl_number(.none, 0x80, 0);
pub const GET_REGS = ioctl_number(.read, 0x81, @sizeOf(Regs));
pub const SET_REGS = ioctl_number(.write, 0x82, @sizeOf(Regs));
pub const GET_SREGS = ioctl_number(.read, 0x83, @sizeOf(Sregs));
pub const SET_SREGS = ioctl_number(.write, 0x84, @sizeOf(Sregs));
pub const SET_CPUID2 = ioctl_number(.write, 0x90, 8);

// Snapshot and restore. Most of these structs are opaque to the VMM: it saves what KVM gives it
// and hands it back unchanged.
pub const GET_MSR_INDEX_LIST = ioctl_number(.read_write, 0x02, 4);
pub const GET_IRQCHIP = ioctl_number(.read_write, 0x62, @sizeOf(Irqchip));
pub const SET_IRQCHIP = ioctl_number(.read, 0x63, @sizeOf(Irqchip)); // Sic: _IOR in <linux/kvm.h>.
pub const GET_MSRS = ioctl_number(.read_write, 0x88, 8);
pub const SET_MSRS = ioctl_number(.write, 0x89, 8);
pub const GET_LAPIC = ioctl_number(.read, 0x8e, @sizeOf(LapicState));
pub const SET_LAPIC = ioctl_number(.write, 0x8f, @sizeOf(LapicState));
pub const GET_MP_STATE = ioctl_number(.read, 0x98, 4);
pub const SET_MP_STATE = ioctl_number(.write, 0x99, 4);
pub const GET_VCPU_EVENTS = ioctl_number(.read, 0x9f, @sizeOf(VcpuEvents));
pub const SET_VCPU_EVENTS = ioctl_number(.write, 0xa0, @sizeOf(VcpuEvents));
pub const GET_DEBUGREGS = ioctl_number(.read, 0xa1, @sizeOf(Debugregs));
pub const SET_DEBUGREGS = ioctl_number(.write, 0xa2, @sizeOf(Debugregs));
pub const GET_XSAVE = ioctl_number(.read, 0xa4, @sizeOf(Xsave));
pub const SET_XSAVE = ioctl_number(.write, 0xa5, @sizeOf(Xsave));
pub const GET_XCRS = ioctl_number(.read, 0xa6, @sizeOf(Xcrs));
pub const SET_XCRS = ioctl_number(.write, 0xa7, @sizeOf(Xcrs));

pub const DET_ENABLE = ioctl_number(.write, 0xf0, @sizeOf(DetConfig));
pub const DET_SET_TARGET = ioctl_number(.write, 0xf1, 8);
pub const DET_GET_STATE = ioctl_number(.read, 0xf2, @sizeOf(DetState));
pub const DET_ADD_TSC = ioctl_number(.write, 0xf3, 8);
pub const DET_SET_SOFT_TSC = ioctl_number(.write, 0xf4, 8);

pub const Exit = enum(u32) {
    unknown = 0,
    exception = 1,
    io = 2,
    hypercall = 3,
    debug = 4,
    hlt = 5,
    mmio = 6,
    irq_window_open = 7,
    shutdown = 8,
    fail_entry = 9,
    intr = 10,
    internal_error = 17,
    system_event = 24,
    det_target = 1000,
    _,
};

pub const UserspaceMemoryRegion = extern struct {
    slot: u32,
    flags: u32,
    guest_phys_addr: u64,
    memory_size: u64,
    userspace_addr: u64,
};

pub const IrqLevel = extern struct { irq: u32, level: u32 };

pub const PitConfig = extern struct { flags: u32, pad: [15]u32 = @splat(0) };

pub const Regs = extern struct {
    rax: u64 = 0,
    rbx: u64 = 0,
    rcx: u64 = 0,
    rdx: u64 = 0,
    rsi: u64 = 0,
    rdi: u64 = 0,
    rsp: u64 = 0,
    rbp: u64 = 0,
    r8: u64 = 0,
    r9: u64 = 0,
    r10: u64 = 0,
    r11: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
    rip: u64 = 0,
    rflags: u64 = 0,
};

pub const Segment = extern struct {
    base: u64,
    limit: u32,
    selector: u16,
    type: u8,
    present: u8,
    dpl: u8,
    db: u8,
    s: u8,
    l: u8,
    g: u8,
    avl: u8,
    unusable: u8,
    padding: u8 = 0,
};

pub const Dtable = extern struct { base: u64, limit: u16, padding: [3]u16 = @splat(0) };

pub const Sregs = extern struct {
    cs: Segment,
    ds: Segment,
    es: Segment,
    fs: Segment,
    gs: Segment,
    ss: Segment,
    tr: Segment,
    ldt: Segment,
    gdt: Dtable,
    idt: Dtable,
    cr0: u64,
    cr2: u64,
    cr3: u64,
    cr4: u64,
    cr8: u64,
    efer: u64,
    apic_base: u64,
    interrupt_bitmap: [4]u64,
};

pub const CpuidEntry2 = extern struct {
    function: u32,
    index: u32,
    flags: u32,
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
    padding: [3]u32 = @splat(0),
};

/// `struct kvm_cpuid2` with room for `capacity` entries.
pub fn Cpuid2(comptime capacity: u32) type {
    return extern struct { count: u32, padding: u32 = 0, entries: [capacity]CpuidEntry2 };
}

/// The shared `struct kvm_run` page of a vCPU (only the fields we use).
pub const Run = extern struct {
    request_interrupt_window: u8,
    immediate_exit: u8,
    padding1: [6]u8,
    exit_reason: Exit,
    ready_for_interrupt_injection: u8,
    if_flag: u8,
    flags: u16,
    cr8: u64,
    apic_base: u64,
    exit: extern union {
        io: extern struct { direction: u8, size: u8, port: u16, count: u32, data_offset: u64 },
        mmio: extern struct { phys_addr: u64, data: [8]u8, len: u32, is_write: u8 },
        fail_entry: extern struct { hardware_entry_failure_reason: u64, cpu: u32 },
        internal: extern struct { suberror: u32, ndata: u32, data: [16]u64 },
        pad: [256]u8,
    },

    pub const io_in: u8 = 0;
    pub const io_out: u8 = 1;
};

pub const irqchip_pic_master: u32 = 0;
pub const irqchip_pic_slave: u32 = 1;
pub const irqchip_ioapic: u32 = 2;

pub const Irqchip = extern struct { chip_id: u32, pad: u32 = 0, chip: [512]u8 };
pub const LapicState = extern struct { regs: [1024]u8 };
pub const VcpuEvents = extern struct { bytes: [64]u8 };
pub const Debugregs = extern struct { bytes: [128]u8 };
pub const Xsave = extern struct { region: [1024]u32 };
pub const Xcrs = extern struct { bytes: [392]u8 };

pub const MsrEntry = extern struct { index: u32, reserved: u32 = 0, data: u64 };

/// `struct kvm_msrs` with room for `capacity` entries.
pub fn Msrs(comptime capacity: u32) type {
    return extern struct { count: u32, pad: u32 = 0, entries: [capacity]MsrEntry };
}

/// `struct kvm_msr_list` with room for `capacity` indices.
pub fn MsrList(comptime capacity: u32) type {
    return extern struct { count: u32, indices: [capacity]u32 };
}

pub const DetConfig = extern struct {
    event: u64,
    tsc_base: u64,
    tsc_per_branch: u32,
    margin_branches: u32,
    flags: u64 = 0,
    reserved: [4]u64 = @splat(0),
};

pub const DetState = extern struct {
    branches: u64,
    tsc: u64,
    target_branches: u64,
    reached_branches: u64,
    rdtsc_exits: u64,
    mtf_steps: u64,
    overflows: u64,
    overshoots: u64,
    /// Most branches the guest ran between a counter overflow and KVM handling it.
    skid_max: u64,
    /// Exits at an RDTSC past the soft deadline (see DET_SET_SOFT_TSC).
    soft_exits: u64,
    reserved: [6]u64,
};

comptime {
    // Layouts must match the kernel's exactly: a mismatch corrupts memory silently.
    assert(@sizeOf(Regs) == 144);
    assert(@sizeOf(Segment) == 24);
    assert(@sizeOf(Dtable) == 16);
    assert(@sizeOf(Sregs) == 312);
    assert(@sizeOf(CpuidEntry2) == 40);
    assert(@sizeOf(PitConfig) == 64);
    assert(@sizeOf(UserspaceMemoryRegion) == 32);
    assert(@offsetOf(Run, "exit") == 32);
    assert(@sizeOf(DetConfig) == 64);
    assert(@sizeOf(Irqchip) == 520);
    assert(@sizeOf(Xsave) == 4096);
    assert(@sizeOf(Xcrs) == 392);
    assert(@sizeOf(MsrEntry) == 16);
    assert(@sizeOf(DetState) == 128);
}

pub const Error = error{ Interrupted, IoctlFailed };

pub fn ioctl(fd: linux.fd_t, request: u32, argument: usize) Error!usize {
    assert(fd >= 0);
    assert(request != 0);
    const result = linux.ioctl(fd, request, argument);
    switch (linux.errno(result)) {
        .SUCCESS => return result,
        .INTR => return error.Interrupted,
        else => |errno| {
            std.log.err("ioctl 0x{x} failed: {s}", .{ request, @tagName(errno) });
            return error.IoctlFailed;
        },
    }
}

pub fn ioctl_fd(fd: linux.fd_t, request: u32, argument: usize) Error!linux.fd_t {
    const result = try ioctl(fd, request, argument);
    assert(result <= std.math.maxInt(i32));
    return @intCast(result);
}

const Direction = enum(u32) { none = 0, write = 1, read = 2, read_write = 3 };

fn ioctl_number(direction: Direction, number: u8, size_bytes: u14) u32 {
    const kvmio: u32 = 0xAE;
    if (direction == .none) assert(size_bytes == 0);
    return @backingInt(direction) << 30 | @as(u32, size_bytes) << 16 | kvmio << 8 | number;
}

test ioctl_number {
    // Values from <linux/kvm.h>.
    try std.testing.expectEqual(@as(u32, 0xAE80), RUN);
    try std.testing.expectEqual(@as(u32, 0x4020AE46), SET_USER_MEMORY_REGION);
    try std.testing.expectEqual(@as(u32, 0x8138AE83), GET_SREGS);
    try std.testing.expectEqual(@as(u32, 0xC008AE05), GET_SUPPORTED_CPUID);
    try std.testing.expectEqual(@as(u32, 0x9000AEA4), GET_XSAVE);
    try std.testing.expectEqual(@as(u32, 0xC208AE62), GET_IRQCHIP);
    try std.testing.expectEqual(@as(u32, 0x8208AE63), SET_IRQCHIP);
    try std.testing.expectEqual(@as(u32, 0x8040AE9F), GET_VCPU_EVENTS);
    try std.testing.expectEqual(@as(u32, 0xC008AE88), GET_MSRS);
}
