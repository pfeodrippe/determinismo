// SPDX-License-Identifier: MIT
//! Loads a Linux bzImage (and initramfs) into guest memory with the 64-bit boot protocol
//! (Documentation/arch/x86/boot.rst) and describes the initial vCPU state.
const std = @import("std");
const assert = std.debug.assert;
const kvm = @import("kvm.zig");

// Guest physical layout of everything the loader writes, low to high.
const gdt_address = 0x500;
const gdt_entries = [_]u64{
    0,
    0,
    0x00af9b000000ffff, // 0x10: 64-bit code, the protocol's __BOOT_CS
    0x00cf93000000ffff, // 0x18: data, the protocol's __BOOT_DS
    0x00008b0000000067, // 0x20: a busy 64-bit TSS, so TR is valid on VM entry
};
const setup_data_address = 0x6000;
const zero_page_address = 0x7000;
pub const stack_top_address = 0x8ff0;
const pml4_address = 0x9000;
const pdpt_address = 0xa000;
const pd_address = 0xb000;
const cmdline_address = 0x20000;
const cmdline_size_max = 0x10000;
const kernel_address = 0x100000;

const selector_code = 0x10;
const selector_data = 0x18;
const selector_tss = 0x20;
const setup_data_type_rng_seed: u32 = 9;
const magic_header: u32 = 0x53726448; // "HdrS"

comptime {
    assert(gdt_address + gdt_entries.len * 8 <= setup_data_address);
    assert(setup_data_address + 16 + 32 <= zero_page_address);
    assert(zero_page_address + 4096 <= stack_top_address);
    assert(stack_top_address < pml4_address);
    assert(pd_address + 4096 <= cmdline_address);
    assert(cmdline_address + cmdline_size_max <= 0x9fc00); // Below the EBDA.
}

pub const Options = struct {
    kernel: []const u8,
    initrd: ?[]const u8,
    cmdline: []const u8,
    /// Handed to the kernel as SETUP_RNG_SEED: its RNG is ready at boot, and every random value
    /// in the guest derives from the platform's seed.
    rng_seed: [32]u8,
};

pub const Entry = struct { rip: u64, rsi: u64 };

pub const Error = error{ NotBzImage, ProtocolTooOld, Not64Bit, TooBig, CmdlineTooLong };

pub fn load(memory: []u8, options: *const Options) Error!Entry {
    assert(memory.len >= 64 << 20);
    assert(memory.len % 4096 == 0);
    const bz = options.kernel;
    if (bz.len < 0x270) return error.NotBzImage;
    if (read(u32, bz, 0x202) != magic_header) return error.NotBzImage;
    if (read(u16, bz, 0x206) < 0x020c) return error.ProtocolTooOld;
    if (bz[0x236] & 1 == 0) return error.Not64Bit; // XLF_KERNEL_64

    const setup_sectors: u32 = if (bz[0x1f1] == 0) 4 else bz[0x1f1];
    const kernel = bz[(setup_sectors + 1) * 512 ..];
    if (kernel_address + kernel.len > memory.len) return error.TooBig;
    @memcpy(memory[kernel_address..][0..kernel.len], kernel);

    try load_boot_params(memory, options);
    if (options.initrd) |initrd| {
        try load_initrd(memory, initrd, .{ .kernel_end = kernel_address + kernel.len });
    }
    write_page_tables(memory);
    for (gdt_entries, 0..) |descriptor, index| {
        write(u64, memory, gdt_address + index * 8, descriptor);
    }
    return .{ .rip = kernel_address + 0x200, .rsi = zero_page_address };
}

/// The "zero page": the kernel's setup header plus what the loader tells the kernel.
fn load_boot_params(memory: []u8, options: *const Options) Error!void {
    const bz = options.kernel;
    const zero_page = memory[zero_page_address..][0..4096];
    @memset(zero_page, 0);
    const header_end = 0x202 + @as(u32, bz[0x201]);
    assert(header_end <= 0x290);
    @memcpy(zero_page[0x1f1..header_end], bz[0x1f1..header_end]);
    zero_page[0x210] = 0xff; // type_of_loader: undefined
    zero_page[0x211] |= 0x01 | 0x80; // loadflags: LOADED_HIGH | CAN_USE_HEAP
    write(u16, zero_page, 0x224, 0xfe00); // heap_end_ptr

    const cmdline_size_kernel_max = read(u32, bz, 0x238);
    if (options.cmdline.len + 1 > @min(cmdline_size_max, cmdline_size_kernel_max)) {
        return error.CmdlineTooLong;
    }
    @memcpy(memory[cmdline_address..][0..options.cmdline.len], options.cmdline);
    memory[cmdline_address + options.cmdline.len] = 0;
    write(u32, zero_page, 0x228, cmdline_address);

    // struct setup_data { u64 next; u32 type; u32 len; u8 data[]; }
    write(u64, memory, setup_data_address, 0);
    write(u32, memory, setup_data_address + 8, setup_data_type_rng_seed);
    write(u32, memory, setup_data_address + 12, options.rng_seed.len);
    @memcpy(memory[setup_data_address + 16 ..][0..options.rng_seed.len], &options.rng_seed);
    write(u64, zero_page, 0x250, setup_data_address);

    // E820: low RAM below the EBDA, then everything from 1 MiB up.
    const e820 = [_][3]u64{ .{ 0, 0x9fc00, 1 }, .{ 0x100000, memory.len - 0x100000, 1 } };
    for (e820, 0..) |entry, index| {
        const offset = 0x2d0 + index * 20;
        write(u64, zero_page, offset, entry[0]);
        write(u64, zero_page, offset + 8, entry[1]);
        write(u32, zero_page, offset + 16, @intCast(entry[2]));
    }
    zero_page[0x1e8] = e820.len;
}

fn load_initrd(memory: []u8, initrd: []const u8, layout: struct { kernel_end: u64 }) Error!void {
    assert(layout.kernel_end > kernel_address);
    const zero_page = memory[zero_page_address..][0..4096];
    const initrd_end_max = @min(memory.len, @as(u64, read(u32, zero_page, 0x22c)) + 1);
    if (initrd.len + layout.kernel_end > initrd_end_max) return error.TooBig;
    const address = std.mem.alignBackward(u64, initrd_end_max - initrd.len, 4096);
    assert(address >= layout.kernel_end);
    assert(address + initrd.len <= memory.len);
    @memcpy(memory[address..][0..initrd.len], initrd);
    write(u32, zero_page, 0x218, @intCast(address));
    write(u32, zero_page, 0x21c, @intCast(initrd.len));
}

/// Identity-maps the first 1 GiB with 2 MiB pages: the kernel builds its own tables early.
fn write_page_tables(memory: []u8) void {
    assert(memory.len > pd_address + 4096);
    @memset(memory[pml4_address .. pd_address + 4096], 0);
    write(u64, memory, pml4_address, pdpt_address | 3);
    write(u64, memory, pdpt_address, pd_address | 3);
    for (0..512) |index| write(u64, memory, pd_address + index * 8, (index << 21) | 0x83);
    assert(read(u64, memory, pd_address + 511 * 8) == (511 << 21) | 0x83);
}

/// Long mode with paging on and flat segments from our GDT, as the 64-bit entry point expects.
pub fn long_mode_sregs(sregs: *kvm.Sregs) void {
    const code = kvm.Segment{
        .base = 0,
        .limit = 0xffffffff,
        .selector = selector_code,
        .type = 0xb,
        .present = 1,
        .dpl = 0,
        .db = 0,
        .s = 1,
        .l = 1,
        .g = 1,
        .avl = 0,
        .unusable = 0,
    };
    var data = code;
    data.selector = selector_data;
    data.type = 0x3;
    data.db = 1;
    data.l = 0;
    sregs.cs = code;
    sregs.ds = data;
    sregs.es = data;
    sregs.fs = data;
    sregs.gs = data;
    sregs.ss = data;
    sregs.tr = .{
        .base = 0,
        .limit = 0x67,
        .selector = selector_tss,
        .type = 0xb,
        .present = 1,
        .dpl = 0,
        .db = 0,
        .s = 0,
        .l = 0,
        .g = 0,
        .avl = 0,
        .unusable = 0,
    };
    sregs.gdt = .{ .base = gdt_address, .limit = gdt_entries.len * 8 - 1 };
    sregs.idt = .{ .base = 0, .limit = 0 };
    sregs.cr3 = pml4_address;
    sregs.cr4 |= 1 << 5; // PAE
    sregs.cr0 |= (1 << 0) | (1 << 31); // PE | PG
    sregs.efer |= (1 << 8) | (1 << 10); // LME | LMA
    assert(sregs.cs.l == 1);
    assert(sregs.cs.db == 0); // L=1 requires D=0.
}

fn read(comptime T: type, buffer: []const u8, offset: u64) T {
    assert(offset + @sizeOf(T) <= buffer.len);
    return std.mem.readInt(T, buffer[offset..][0..@sizeOf(T)], .little);
}

fn write(comptime T: type, buffer: []u8, offset: u64, value: T) void {
    assert(offset + @sizeOf(T) <= buffer.len);
    std.mem.writeInt(T, buffer[offset..][0..@sizeOf(T)], value, .little);
}
