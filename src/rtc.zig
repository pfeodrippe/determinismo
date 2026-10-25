// SPDX-License-Identifier: MIT
//! MC146818 CMOS real-time clock (ports 0x70/0x71). The time it reports is a pure function of the
//! configured epoch and virtual time, never of the host clock.
const std = @import("std");
const assert = std.debug.assert;

pub const port_index: u16 = 0x70;
pub const port_data: u16 = 0x71;

/// Unix seconds at virtual time zero.
epoch_seconds: u64,
index: u8 = 0,
register_b: u8 = 0x02, // 24-hour mode, BCD

const RTC = @This();

pub fn write(rtc: *RTC, port: u16, value: u8) void {
    assert(port == port_index or port == port_data);
    if (port == port_index) {
        rtc.index = value & 0x7f; // Bit 7 masks NMIs; there are none to mask.
    } else {
        if (rtc.index == 0x0b) rtc.register_b = value;
    }
    assert(rtc.index < 0x80);
}

pub fn read(rtc: *const RTC, port: u16, vtime_seconds: u64) u8 {
    assert(port == port_index or port == port_data);
    if (port == port_index) return rtc.index;
    const seconds = rtc.epoch_seconds + vtime_seconds;
    const days = seconds / std.time.s_per_day;
    const second_of_day = seconds % std.time.s_per_day;
    const date = civil_from_days(days);
    return switch (rtc.index) {
        0x00 => rtc.encode(@intCast(second_of_day % 60)),
        0x02 => rtc.encode(@intCast(second_of_day / 60 % 60)),
        0x04 => rtc.encode(@intCast(second_of_day / 3600)),
        0x06 => rtc.encode(@intCast((days + 4) % 7 + 1)), // 1970-01-01 was a Thursday.
        0x07 => rtc.encode(date.day),
        0x08 => rtc.encode(date.month),
        0x09 => rtc.encode(@intCast(date.year % 100)),
        0x32 => rtc.encode(@intCast(date.year / 100)),
        0x0a => 0x26, // Divider on, and an update is never in progress.
        0x0b => rtc.register_b,
        0x0d => 0x80, // Battery good.
        else => 0,
    };
}

fn encode(rtc: *const RTC, value: u8) u8 {
    assert(value < 100);
    const binary = rtc.register_b & 0x04 != 0;
    return if (binary) value else (value / 10) << 4 | (value % 10);
}

const Date = struct { year: u32, month: u8, day: u8 };

/// Howard Hinnant's days-to-civil algorithm, for days since 1970-01-01.
fn civil_from_days(days: u64) Date {
    const z = days + 719468;
    const era = z / 146097;
    const day_of_era = z - era * 146097;
    const year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36524 -
        day_of_era / 146096) / 365;
    const day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    const month_shifted = (5 * day_of_year + 2) / 153;
    const day: u8 = @intCast(day_of_year - (153 * month_shifted + 2) / 5 + 1);
    const month: u8 = @intCast(if (month_shifted < 10) month_shifted + 3 else month_shifted - 9);
    const year: u32 = @intCast(year_of_era + era * 400 + @intFromBool(month <= 2));
    assert(month >= 1 and month <= 12);
    assert(day >= 1 and day <= 31);
    return .{ .year = year, .month = month, .day = day };
}

test civil_from_days {
    const expectEqual = std.testing.expectEqual;
    try expectEqual(Date{ .year = 1970, .month = 1, .day = 1 }, civil_from_days(0));
    try expectEqual(Date{ .year = 2026, .month = 1, .day = 1 }, civil_from_days(20454));
    try expectEqual(Date{ .year = 2024, .month = 2, .day = 29 }, civil_from_days(19782));
}
