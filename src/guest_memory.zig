// SPDX-License-Identifier: MIT
//! The guest's RAM as the guest sees it: one host mapping, placed at two guest physical ranges.
//! Up to 3 GiB at address 0; the rest from 4 GiB, past the hole where 32-bit devices live (the
//! virtio-mmio registers, the APIC). Code that follows guest addresses (virtio rings, requests)
//! goes through `range`, which refuses anything that is not RAM.
const std = @import("std");
const assert = std.debug.assert;

/// RAM below the hole, and where RAM resumes above it.
pub const low_size_max: u64 = 3 << 30;
pub const high_start: u64 = 4 << 30;

pub const GuestMemory = struct {
    bytes: []u8,

    pub fn low_size(memory: GuestMemory) u64 {
        return @min(memory.bytes.len, low_size_max);
    }

    pub fn high_size(memory: GuestMemory) u64 {
        return memory.bytes.len - memory.low_size();
    }

    /// The host bytes of guest physical [address, address + size), when all of it is RAM in one
    /// of the two ranges; null otherwise.
    pub fn range(memory: GuestMemory, address: u64, size: u64) ?[]u8 {
        const low = memory.low_size();
        const offset = if (address < low) blk: {
            if (size > low - address) return null;
            break :blk address;
        } else blk: {
            if (address < high_start) return null; // The hole.
            const high_offset = address - high_start;
            if (high_offset > memory.high_size() or size > memory.high_size() - high_offset) {
                return null;
            }
            break :blk low + high_offset;
        };
        return memory.bytes[@intCast(offset)..][0..@intCast(size)];
    }
};

test "the two ranges and the hole" {
    var bytes: [16]u8 = undefined;
    const memory = GuestMemory{ .bytes = &bytes };
    try std.testing.expectEqual(@as(?[]u8, null), memory.range(8, 16));
    try std.testing.expect(memory.range(0, 16) != null);
    try std.testing.expectEqual(@as(u64, 0), memory.high_size());
    try std.testing.expectEqual(@as(?[]u8, null), memory.range(high_start, 1));
}
