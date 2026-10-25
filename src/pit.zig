// SPDX-License-Identifier: MIT
//! Intel 8253/8254 PIT, channel 0 only, driven by virtual time. Linux, booted with
//! nolapic_timer, uses it as its clock-event device: periodic (mode 2) or one-shot (mode 4).
const std = @import("std");
const assert = std.debug.assert;

pub const port_channel_0: u16 = 0x40;
pub const port_mode: u16 = 0x43;
pub const irq: u32 = 0;
pub const frequency_hz: u64 = 1_193_182;
const reload_max: u32 = 0x10000;

tsc_hz: u64,
mode: u3 = 0,
reload: u32 = reload_max,
count_low_pending: ?u8 = null,
latched: ?u16 = null,
read_high_next: bool = false,
/// TSC at which the current count was loaded, and how many periods have fired since then.
start_tsc: u64 = 0,
fired: u64 = 0,
armed: bool = false,

const PIT = @This();

pub fn write_mode(pit: *PIT, value: u8, now_tsc: u64) void {
    assert(pit.tsc_hz > 0);
    if (value >> 6 != 0) return; // Channels 1 and 2 and read-back are unused.
    if ((value >> 4) & 3 == 0) {
        pit.latched = pit.current(now_tsc); // Counter latch command.
        pit.read_high_next = false;
        return;
    }
    pit.mode = @intCast((value >> 1) & 7);
    pit.count_low_pending = null;
    pit.armed = false;
    assert(!pit.armed);
}

/// Returns true when a new count was loaded, so the caller re-arms its deadline.
pub fn write_count(pit: *PIT, value: u8, now_tsc: u64) bool {
    assert(pit.tsc_hz > 0);
    const low = pit.count_low_pending orelse {
        pit.count_low_pending = value;
        return false;
    };
    pit.count_low_pending = null;
    const count = @as(u32, value) << 8 | low;
    pit.reload = if (count == 0) reload_max else count;
    pit.start_tsc = now_tsc;
    pit.fired = 0;
    pit.armed = pit.mode == 2 or pit.mode == 3 or pit.mode == 4;
    assert(pit.reload >= 1 and pit.reload <= reload_max);
    return true;
}

pub fn read_count(pit: *PIT, now_tsc: u64) u8 {
    assert(pit.tsc_hz > 0);
    assert(now_tsc >= pit.start_tsc or !pit.armed);
    const value = pit.latched orelse pit.current(now_tsc);
    if (pit.read_high_next) {
        pit.read_high_next = false;
        pit.latched = null;
        return @intCast(value >> 8);
    } else {
        pit.read_high_next = true;
        return @truncate(value);
    }
}

/// The TSC at which the next interrupt is due, if any.
pub fn deadline_tsc(pit: *const PIT) ?u64 {
    if (!pit.armed) return null;
    assert(pit.reload >= 1);
    return pit.start_tsc + ticks_to_tsc(pit.tsc_hz, (pit.fired + 1) * pit.reload);
}

/// The deadline was reached and the interrupt delivered.
pub fn fire(pit: *PIT) void {
    assert(pit.armed);
    pit.fired += 1;
    if (pit.mode == 0 or pit.mode == 4) pit.armed = false; // One-shot.
    if (pit.mode == 2) assert(pit.armed);
}

fn current(pit: *const PIT, now_tsc: u64) u16 {
    assert(pit.reload >= 1 and pit.reload <= reload_max);
    const elapsed = tsc_to_ticks(pit.tsc_hz, now_tsc -| pit.start_tsc);
    const periodic = pit.mode == 2 or pit.mode == 3;
    const left: u32 = if (periodic)
        pit.reload - @as(u32, @intCast(elapsed % pit.reload))
    else
        pit.reload -| @as(u32, @intCast(@min(elapsed, pit.reload)));
    return @truncate(left); // A full reload of 0x10000 reads back as 0, as on hardware.
}

fn ticks_to_tsc(tsc_hz: u64, ticks: u64) u64 {
    assert(tsc_hz > 0);
    return @intCast(@as(u128, ticks) * tsc_hz / frequency_hz);
}

fn tsc_to_ticks(tsc_hz: u64, tsc: u64) u64 {
    assert(tsc_hz > 0);
    return @intCast(@as(u128, tsc) * frequency_hz / tsc_hz);
}

test "periodic deadlines don't drift" {
    var pit = PIT{ .tsc_hz = 4_000_000_000 };
    pit.write_mode(0x34, 0);
    try std.testing.expect(!pit.write_count(0x9c, 1000));
    try std.testing.expect(pit.write_count(0x2e, 1000)); // 11932 ticks, about 10 ms.
    try std.testing.expectEqual(@as(?u64, 1000 + 40_000_603), pit.deadline_tsc());
    for (0..100) |_| pit.fire();
    const expected = 1000 + ticks_to_tsc(4_000_000_000, 101 * 11932);
    try std.testing.expectEqual(@as(?u64, expected), pit.deadline_tsc());
}

test "one-shot disarms after firing" {
    var pit = PIT{ .tsc_hz = 4_000_000_000 };
    pit.write_mode(0x38, 0);
    _ = pit.write_count(0x10, 0);
    try std.testing.expect(pit.write_count(0x00, 0));
    pit.fire();
    try std.testing.expectEqual(@as(?u64, null), pit.deadline_tsc());
}
