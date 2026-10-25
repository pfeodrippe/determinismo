// SPDX-License-Identifier: MIT
//! The guest-visible CPU. Starts from what KVM supports and removes everything that would leak host
//! time, host randomness or host topology into the guest (ARCHITECTURE.md §5).
const std = @import("std");
const assert = std.debug.assert;
const kvm = @import("kvm.zig");

pub const tsc_hz: u64 = 4_000_000_000;
const crystal_hz: u32 = 25_000_000;

comptime {
    assert(tsc_hz % crystal_hz == 0); // CPUID 0x15 expresses the ratio exactly.
    assert(tsc_hz % std.time.ns_per_s == 0); // TSC ticks per nanosecond is an integer.
}

/// Filters `entries[0..count]` in place and appends leaves 0x15 and 0x16.
pub fn make_deterministic(entries: []kvm.CpuidEntry2, count: *u32) void {
    assert(count.* <= entries.len);
    var kept: u32 = 0;
    for (entries[0..count.*]) |entry| {
        // KVM paravirt leaves: kvmclock, async page faults, steal time, PV EOI.
        if (entry.function >= 0x4000_0000 and entry.function <= 0x4000_00ff) continue;
        if (entry.function == 0x15 or entry.function == 0x16) continue; // Replaced below.
        entries[kept] = entry;
        filter(&entries[kept]);
        kept += 1;
    }
    assert(kept + 2 <= entries.len);
    // TSC frequency = crystal * ebx / eax, so the guest never calibrates against a timer.
    entries[kept] = .{
        .function = 0x15,
        .index = 0,
        .flags = 0,
        .eax = 1,
        .ebx = @intCast(tsc_hz / crystal_hz),
        .ecx = crystal_hz,
        .edx = 0,
    };
    entries[kept + 1] = .{
        .function = 0x16,
        .index = 0,
        .flags = 0,
        .eax = tsc_hz / 1_000_000,
        .ebx = tsc_hz / 1_000_000,
        .ecx = 100,
        .edx = 0,
    };
    count.* = kept + 2;
}

fn filter(entry: *kvm.CpuidEntry2) void {
    assert(entry.function < 0x4000_0000 or entry.function > 0x4000_00ff);
    switch (entry.function) {
        0 => entry.eax = @max(entry.eax, 0x16),
        1 => {
            entry.ecx &= ~(bit(30) | bit(24) | bit(15)); // RDRAND, TSC-deadline timer, PDCM
            // KVM reports the APIC ID of whichever host CPU asked: present one fixed vCPU.
            entry.ebx = (entry.ebx & 0x0000_ffff) | (1 << 16); // APIC ID 0, 1 logical CPU
            entry.edx &= ~bit(28); // HTT
        },
        4 => entry.eax &= 0x0000_3fff, // One core, no cache sharing.
        6 => entry.ecx &= ~bit(0), // APERF/MPERF
        7 => if (entry.index == 0) {
            entry.ebx &= ~(bit(18) | bit(11) | bit(4) | bit(1)); // RDSEED, RTM, HLE, TSC_ADJUST
            entry.ecx &= ~(bit(22) | bit(5)); // RDPID, WAITPKG (TSC-timed waits)
        },
        0xa => {
            // No PMU for the guest: the host owns the counters that drive virtual time.
            entry.eax = 0;
            entry.ebx = 0;
            entry.ecx = 0;
            entry.edx = 0;
        },
        0xd => if (entry.index == 1) {
            // XSAVEOPT, XSAVEC, XGETBV(ECX=1) and XSAVES expose the processor's XINUSE tracking,
            // which host-side FPU save/restore perturbs at arbitrary moments (rr masks it too).
            entry.eax &= ~(bit(0) | bit(1) | bit(2) | bit(3));
        },
        0xb, 0x1f => {
            entry.edx = 0; // x2APIC ID
            if (entry.ebx != 0) entry.ebx = 1; // One logical processor at every level.
        },
        0x8000_0001 => entry.edx &= ~bit(27), // RDTSCP
        0x8000_0007 => entry.edx |= bit(8), // Invariant TSC.
        else => {},
    }
    if (entry.function == 1) assert(entry.ebx >> 24 == 0);
    if (entry.function == 0xa) assert(entry.eax == 0);
}

fn bit(comptime index: u5) u32 {
    return @as(u32, 1) << index;
}

test make_deterministic {
    const zero = kvm.CpuidEntry2{
        .function = 0,
        .index = 0,
        .flags = 0,
        .eax = 0,
        .ebx = 0,
        .ecx = 0,
        .edx = 0,
    };
    var entries = [_]kvm.CpuidEntry2{ zero, zero, zero, zero };
    entries[0].function = 1;
    entries[0].ebx = 0x0302_0800; // APIC ID 3 from the host.
    entries[0].ecx = bit(30);
    entries[1].function = 0x4000_0000;
    var count: u32 = 2;
    make_deterministic(&entries, &count);
    try std.testing.expectEqual(@as(u32, 3), count);
    try std.testing.expectEqual(@as(u32, 0), entries[0].ebx >> 24);
    try std.testing.expectEqual(@as(u32, 0), entries[0].ecx & bit(30));
    try std.testing.expectEqual(@as(u32, 0x15), entries[1].function);
}
