// SPDX-License-Identifier: MIT
//! A read-only virtio block device on the virtio-mmio transport (virtio 1.2, §4.2 and §5.2).
//!
//! The guest disk holds what a run needs and never changes: node root filesystems, the system
//! description and the test programs. The guest writes only to tmpfs, which lives in guest memory,
//! so snapshots and branches never have to copy or fork a disk.
//!
//! Requests complete synchronously in the VM exit of the queue notification, and the interrupt is
//! injected on the next entry: both happen at an exact point in the guest's instruction stream, so
//! disk I/O is deterministic.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

/// Above the guest RAM limit (3 GiB) and below the 32-bit device area.
pub const address_base: u64 = 0xd000_0000;
pub const address_size: u64 = 0x1000;
pub const irq: u32 = 6;
/// Tells the guest's virtio_mmio driver where the device is.
pub const cmdline = "virtio_mmio.device=4K@0xd0000000:6";

pub const queue_size_max = 256;
const sector_size = 512;
const magic: u32 = 0x7472_6976; // "virt"
const version: u32 = 2;
const device_id_block: u32 = 2;
const vendor_id: u32 = 0x6465_7465; // "dete"

const feature_read_only: u64 = 1 << 5;
const feature_version_1: u64 = 1 << 32;
const features: u64 = feature_read_only | feature_version_1;

const descriptor_flag_next: u16 = 1;
const descriptor_flag_write: u16 = 2;
const descriptor_size = 16;
const chain_length_max = queue_size_max;

const request_in: u32 = 0;
const request_get_id: u32 = 8;
const status_ok: u8 = 0;
const status_io_error: u8 = 1;
const status_unsupported: u8 = 2;
const id_size = 20;

const Register = enum(u32) {
    magic = 0x000,
    version = 0x004,
    device_id = 0x008,
    vendor_id = 0x00c,
    device_features = 0x010,
    device_features_select = 0x014,
    driver_features = 0x020,
    driver_features_select = 0x024,
    queue_select = 0x030,
    queue_size_max = 0x034,
    queue_size = 0x038,
    queue_ready = 0x044,
    queue_notify = 0x050,
    interrupt_status = 0x060,
    interrupt_acknowledge = 0x064,
    status = 0x070,
    queue_descriptors_low = 0x080,
    queue_descriptors_high = 0x084,
    queue_available_low = 0x090,
    queue_available_high = 0x094,
    queue_used_low = 0x0a0,
    queue_used_high = 0x0a4,
    config_generation = 0x0fc,
    _,
};
const config_offset = 0x100;

/// The disk image, read-only and shared by every branch.
fd: linux.fd_t,
capacity_sectors: u64,
device_features_select: u32 = 0,
driver_features_select: u32 = 0,
driver_features: u64 = 0,
status: u32 = 0,
interrupt_status: u32 = 0,
queue_size: u32 = queue_size_max,
queue_ready: bool = false,
queue_descriptors: u64 = 0,
queue_available: u64 = 0,
queue_used: u64 = 0,
/// The next entry of the available ring to process.
available_index: u16 = 0,
used_index: u16 = 0,
requests: u64 = 0,
bytes_read: u64 = 0,

const VirtioBlock = @This();

pub fn init(block: *VirtioBlock, fd: linux.fd_t, size_bytes: u64) void {
    assert(fd >= 0);
    assert(size_bytes % sector_size == 0);
    block.* = .{ .fd = fd, .capacity_sectors = size_bytes / sector_size };
}

pub fn contains(address: u64) bool {
    return address >= address_base and address < address_base + address_size;
}

pub fn read(block: *const VirtioBlock, offset: u64, data: []u8) void {
    assert(offset < address_size);
    assert(data.len >= 1 and data.len <= 8);
    if (offset >= config_offset) return block.read_config(offset - config_offset, data);
    const value: u32 = switch (@as(Register, @enumFromInt(offset))) {
        .magic => magic,
        .version => version,
        .device_id => device_id_block,
        .vendor_id => vendor_id,
        .device_features => switch (block.device_features_select) {
            0 => @truncate(features),
            1 => @truncate(features >> 32),
            else => 0,
        },
        .queue_size_max => queue_size_max,
        .queue_ready => @intFromBool(block.queue_ready),
        .interrupt_status => block.interrupt_status,
        .status => block.status,
        .config_generation => 0,
        else => 0,
    };
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    for (data, 0..) |*byte, index| byte.* = if (index < bytes.len) bytes[index] else 0;
}

/// Config space: `capacity` (u64, in 512-byte sectors) and nothing else we offer.
fn read_config(block: *const VirtioBlock, offset: u64, data: []u8) void {
    var config: [8]u8 = undefined;
    std.mem.writeInt(u64, &config, block.capacity_sectors, .little);
    for (data, 0..) |*byte, index| {
        const position = offset + index;
        byte.* = if (position < config.len) config[position] else 0;
    }
}

/// Returns true when the guest should get an interrupt.
pub fn write(block: *VirtioBlock, offset: u64, data: []const u8, memory: []u8) bool {
    assert(offset < address_size);
    assert(data.len >= 1 and data.len <= 8);
    if (offset >= config_offset) return false; // Our config space is read-only.
    if (data.len != 4) return false; // The transport's registers are 32 bits wide.
    const value = std.mem.readInt(u32, data[0..4], .little);
    switch (@as(Register, @enumFromInt(offset))) {
        .device_features_select => block.device_features_select = value,
        .driver_features_select => block.driver_features_select = value,
        .driver_features => switch (block.driver_features_select) {
            0 => block.driver_features = block.driver_features & ~@as(u64, 0xffff_ffff) | value,
            1 => block.driver_features = block.driver_features & 0xffff_ffff |
                @as(u64, value) << 32,
            else => {},
        },
        .queue_select => {}, // One queue: selecting another one selects nothing.
        .queue_size => block.queue_size = @min(value, queue_size_max),
        .queue_ready => block.queue_ready = value == 1,
        .queue_notify => return block.process(memory),
        .interrupt_acknowledge => block.interrupt_status &= ~value,
        .status => if (value == 0) block.reset() else {
            block.status = value;
        },
        .queue_descriptors_low => set_low(&block.queue_descriptors, value),
        .queue_descriptors_high => set_high(&block.queue_descriptors, value),
        .queue_available_low => set_low(&block.queue_available, value),
        .queue_available_high => set_high(&block.queue_available, value),
        .queue_used_low => set_low(&block.queue_used, value),
        .queue_used_high => set_high(&block.queue_used, value),
        else => {},
    }
    return false;
}

fn reset(block: *VirtioBlock) void {
    const fd = block.fd;
    const capacity_sectors = block.capacity_sectors;
    const requests = block.requests;
    const bytes_read = block.bytes_read;
    block.* = .{ .fd = fd, .capacity_sectors = capacity_sectors };
    block.requests = requests;
    block.bytes_read = bytes_read;
    assert(!block.queue_ready);
}

/// Serves every request the driver made available since the last notification.
fn process(block: *VirtioBlock, memory: []u8) bool {
    if (!block.queue_ready) return false;
    assert(block.queue_size > 0 and block.queue_size <= queue_size_max);
    const available_index = load(u16, memory, block.queue_available + 2) orelse return false;
    var served: u32 = 0;
    while (block.available_index != available_index) : (served += 1) {
        if (served == queue_size_max) break; // A driver bug; never loop forever on it.
        const slot = block.available_index % block.queue_size;
        const head = load(u16, memory, block.queue_available + 4 + 2 * slot) orelse break;
        const written = block.serve(memory, head);
        block.complete(memory, head, written);
        block.available_index +%= 1;
    }
    if (served == 0) return false;
    block.interrupt_status |= 1; // Used buffer notification.
    return true;
}

const Descriptor = struct { address: u64, size: u32, flags: u16, next: u16 };

fn descriptor(block: *const VirtioBlock, memory: []u8, index: u16) ?Descriptor {
    if (index >= block.queue_size) return null;
    const base = block.queue_descriptors + @as(u64, index) * descriptor_size;
    return .{
        .address = load(u64, memory, base) orelse return null,
        .size = load(u32, memory, base + 8) orelse return null,
        .flags = load(u16, memory, base + 12) orelse return null,
        .next = load(u16, memory, base + 14) orelse return null,
    };
}

/// Runs one request (header, data buffers, status byte) and returns the bytes it wrote.
fn serve(block: *VirtioBlock, memory: []u8, head: u16) u32 {
    block.requests += 1;
    var chain: [chain_length_max]Descriptor = undefined;
    var length: u32 = 0;
    var index = head;
    while (length < chain_length_max) {
        const entry = block.descriptor(memory, index) orelse return 0;
        chain[length] = entry;
        length += 1;
        if (entry.flags & descriptor_flag_next == 0) break;
        index = entry.next;
    }
    if (length < 2) return 0; // At least a header and a status byte.
    const header = chain[0];
    const status_descriptor = chain[length - 1];
    if (header.size < 16 or status_descriptor.size < 1) return 0;
    if (status_descriptor.flags & descriptor_flag_write == 0) return 0;
    const kind = load(u32, memory, header.address) orelse return 0;
    const sector = load(u64, memory, header.address + 8) orelse return 0;
    var written: u32 = 0;
    const status = switch (kind) {
        request_in => block.serve_read(memory, chain[1 .. length - 1], sector, &written),
        request_get_id => serve_id(memory, chain[1 .. length - 1], &written),
        else => status_unsupported, // Writes included: the device is read-only.
    };
    const status_range = guest_range(memory, status_descriptor.address, 1) orelse return written;
    status_range[0] = status;
    return written + 1;
}

fn serve_read(
    block: *VirtioBlock,
    memory: []u8,
    buffers: []const Descriptor,
    sector: u64,
    written: *u32,
) u8 {
    var offset = std.math.mul(u64, sector, sector_size) catch return status_io_error;
    for (buffers) |buffer| {
        if (buffer.flags & descriptor_flag_write == 0) return status_io_error;
        if (offset + buffer.size > block.capacity_sectors * sector_size) return status_io_error;
        const target = guest_range(memory, buffer.address, buffer.size) orelse
            return status_io_error;
        if (!pread_all(block.fd, target, offset)) return status_io_error;
        offset += buffer.size;
        written.* += buffer.size;
        block.bytes_read += buffer.size;
    }
    return status_ok;
}

fn serve_id(memory: []u8, buffers: []const Descriptor, written: *u32) u8 {
    if (buffers.len != 1) return status_io_error;
    const size = @min(buffers[0].size, id_size);
    const target = guest_range(memory, buffers[0].address, size) orelse return status_io_error;
    const id = "determinismo-disk";
    @memset(target, 0);
    @memcpy(target[0..@min(id.len, size)], id[0..@min(id.len, size)]);
    written.* += size;
    return status_ok;
}

fn complete(block: *VirtioBlock, memory: []u8, head: u16, written: u32) void {
    const slot = block.used_index % block.queue_size;
    const entry = block.queue_used + 4 + 8 * @as(u64, slot);
    store(u32, memory, entry, head);
    store(u32, memory, entry + 4, written);
    block.used_index +%= 1;
    // The entry first, then the index that publishes it (the order a second vCPU would need).
    store(u16, memory, block.queue_used + 2, block.used_index);
}

fn pread_all(fd: linux.fd_t, target: []u8, offset: u64) bool {
    var done: u64 = 0;
    while (done < target.len) {
        const position: i64 = @intCast(offset + done);
        const result = linux.pread(fd, target[done..].ptr, target.len - done, position);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS) return false;
        if (result == 0) return false; // Past the end of the image.
        done += result;
    }
    return true;
}

fn guest_range(memory: []u8, address: u64, size: u64) ?[]u8 {
    if (address > memory.len or size > memory.len - address) return null;
    return memory[@intCast(address)..][0..@intCast(size)];
}

fn load(comptime T: type, memory: []u8, address: u64) ?T {
    const bytes = guest_range(memory, address, @sizeOf(T)) orelse return null;
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn store(comptime T: type, memory: []u8, address: u64, value: T) void {
    const bytes = guest_range(memory, address, @sizeOf(T)) orelse return;
    std.mem.writeInt(T, bytes[0..@sizeOf(T)], value, .little);
}

fn set_low(target: *u64, value: u32) void {
    target.* = target.* & ~@as(u64, 0xffff_ffff) | value;
}

fn set_high(target: *u64, value: u32) void {
    target.* = target.* & 0xffff_ffff | @as(u64, value) << 32;
}

test "reads a sector through the ring" {
    var memory: [64 * 1024]u8 align(8) = @splat(0);
    const path = "/tmp/determinismo-virtio-block-test.img";
    const fd: linux.fd_t = @intCast(linux.open(path, .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .TRUNC = true,
    }, 0o600));
    defer _ = linux.close(fd);
    var image: [2 * sector_size]u8 = undefined;
    for (&image, 0..) |*byte, index| byte.* = @truncate(index / sector_size + 1);
    _ = linux.pwrite(fd, &image, image.len, 0);

    var block: VirtioBlock = undefined;
    block.init(fd, image.len);
    const register = struct {
        fn set(device: *VirtioBlock, mem: []u8, which: Register, value: u32) void {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, value, .little);
            _ = device.write(@intFromEnum(which), &bytes, mem);
        }
    }.set;
    register(&block, &memory, .queue_size, 8);
    register(&block, &memory, .queue_descriptors_low, 0x1000);
    register(&block, &memory, .queue_available_low, 0x2000);
    register(&block, &memory, .queue_used_low, 0x3000);
    register(&block, &memory, .queue_ready, 1);
    // Header at 0x4000 (read sector 1), data at 0x5000, status at 0x6000.
    std.mem.writeInt(u32, memory[0x4000..][0..4], request_in, .little);
    std.mem.writeInt(u64, memory[0x4008..][0..8], 1, .little);
    const chain = [_]struct { u64, u32, u16 }{
        .{ 0x4000, 16, descriptor_flag_next },
        .{ 0x5000, sector_size, descriptor_flag_next | descriptor_flag_write },
        .{ 0x6000, 1, descriptor_flag_write },
    };
    for (chain, 0..) |entry, index| {
        const base = 0x1000 + index * descriptor_size;
        std.mem.writeInt(u64, memory[base..][0..8], entry[0], .little);
        std.mem.writeInt(u32, memory[base + 8 ..][0..4], entry[1], .little);
        std.mem.writeInt(u16, memory[base + 12 ..][0..2], entry[2], .little);
        std.mem.writeInt(u16, memory[base + 14 ..][0..2], @intCast(index + 1), .little);
    }
    std.mem.writeInt(u16, memory[0x2004..][0..2], 0, .little); // ring[0] = head 0
    std.mem.writeInt(u16, memory[0x2002..][0..2], 1, .little); // idx = 1
    var notify: [4]u8 = @splat(0);
    try std.testing.expect(block.write(@intFromEnum(Register.queue_notify), &notify, &memory));
    try std.testing.expectEqual(@as(u8, status_ok), memory[0x6000]);
    try std.testing.expectEqual(@as(u8, 2), memory[0x5000]);
    const used_index = std.mem.readInt(u16, memory[0x3002..][0..2], .little);
    const used_written = std.mem.readInt(u32, memory[0x3008..][0..4], .little);
    try std.testing.expectEqual(@as(u16, 1), used_index);
    try std.testing.expectEqual(@as(u32, sector_size + 1), used_written);
}
