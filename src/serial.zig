// SPDX-License-Identifier: MIT
//! A 16550-style UART at COM1, output only: enough for the Linux 8250 driver and console.
//! Transmit-empty interrupts go to IRQ 4 through the VM's interrupt controller.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub const port_base: u16 = 0x3f8;
pub const port_count: u16 = 8;
pub const irq: u32 = 4;

const ier_transmit_empty: u8 = 0x02;
const lcr_divisor_latch: u8 = 0x80;
const output_buffer_size = 4096;

ier: u8 = 0,
lcr: u8 = 0,
mcr: u8 = 0,
scratch: u8 = 0,
divisor_low: u8 = 0,
divisor_high: u8 = 0,
transmit_empty_pending: bool = false,
output: [output_buffer_size]u8 = undefined,
output_count: u32 = 0,
output_fd: linux.fd_t = 1,
/// Every byte the guest has written, to compare runs.
output_hash: std.hash.Wyhash = .init(0),
output_bytes: u64 = 0,
/// The line being written (cut at `line_size_max`), done at its newline: the VM turns the
/// kernel's into events.
line: [line_size_max]u8 = undefined,
line_count: u16 = 0,
line_done: bool = false,

/// A console line kept for an event: escaped as JSON (6 bytes a byte at most) it stays within
/// an event's 4 KB.
pub const line_size_max = 512;

const Serial = @This();

pub fn contains(port: u16) bool {
    comptime assert(port_base % port_count == 0);
    return port >= port_base and port < port_base + port_count;
}

/// Returns true when the guest should get an interrupt.
pub fn write(serial: *Serial, port: u16, value: u8) bool {
    assert(contains(port));
    const register = port - port_base;
    const divisor_latch = serial.lcr & lcr_divisor_latch != 0;
    switch (register) {
        0 => if (divisor_latch) {
            serial.divisor_low = value;
        } else {
            serial.emit(value);
            serial.transmit_empty_pending = true;
            return serial.ier & ier_transmit_empty != 0;
        },
        1 => if (divisor_latch) {
            serial.divisor_high = value;
        } else {
            serial.ier = value & 0x0f;
            if (serial.ier & ier_transmit_empty != 0) {
                serial.transmit_empty_pending = true;
                return true;
            }
        },
        3 => serial.lcr = value,
        4 => serial.mcr = value,
        7 => serial.scratch = value,
        else => {}, // FIFO control and read-only registers.
    }
    return false;
}

pub fn read(serial: *Serial, port: u16) u8 {
    assert(contains(port));
    const register = port - port_base;
    const divisor_latch = serial.lcr & lcr_divisor_latch != 0;
    return switch (register) {
        0 => if (divisor_latch) serial.divisor_low else 0, // Nothing is ever received.
        1 => if (divisor_latch) serial.divisor_high else serial.ier,
        2 => serial.read_interrupt_identification(),
        3 => serial.lcr,
        4 => serial.mcr,
        5 => 0x60, // Transmitter empty.
        6 => 0xb0, // DCD | DSR | CTS
        7 => serial.scratch,
        else => unreachable,
    };
}

fn read_interrupt_identification(serial: *Serial) u8 {
    assert(serial.ier & 0xf0 == 0);
    if (serial.transmit_empty_pending) {
        if (serial.ier & ier_transmit_empty != 0) {
            serial.transmit_empty_pending = false;
            return 0x02;
        }
    }
    return 0x01; // No interrupt pending.
}

fn emit(serial: *Serial, byte: u8) void {
    assert(serial.output_count < serial.output.len);
    serial.output_hash.update(&.{byte});
    serial.output_bytes += 1;
    serial.output[serial.output_count] = byte;
    serial.output_count += 1;
    if (byte == '\n') {
        serial.line_done = true;
    } else if (serial.line_count < serial.line.len) {
        serial.line[serial.line_count] = byte;
        serial.line_count += 1;
    }
    if (byte == '\n' or serial.output_count == serial.output.len) serial.flush();
    assert(serial.output_count < serial.output.len);
}

pub fn flush(serial: *Serial) void {
    assert(serial.output_count <= serial.output.len);
    var written: u32 = 0;
    while (written < serial.output_count) {
        const pending = serial.output[written..serial.output_count];
        const result = linux.write(serial.output_fd, pending.ptr, pending.len);
        if (linux.errno(result) != .SUCCESS) break; // The console is best effort.
        written += @intCast(result);
    }
    serial.output_count = 0;
    assert(written <= serial.output.len);
}

test "transmit-empty interrupt is raised once and acknowledged by IIR" {
    var serial = Serial{ .output_fd = -1 };
    try std.testing.expect(serial.write(port_base + 1, ier_transmit_empty));
    try std.testing.expectEqual(@as(u8, 0x02), serial.read(port_base + 2));
    try std.testing.expectEqual(@as(u8, 0x01), serial.read(port_base + 2));
}

test "a line is kept until its newline, a long one cut" {
    var serial = Serial{ .output_fd = -1 };
    for ("[    1.000000] ok") |byte| _ = serial.write(port_base, byte);
    try std.testing.expect(!serial.line_done);
    _ = serial.write(port_base, '\n');
    try std.testing.expect(serial.line_done);
    try std.testing.expectEqualStrings("[    1.000000] ok", serial.line[0..serial.line_count]);
    serial.line_count = 0;
    serial.line_done = false;
    for (0..line_size_max + 10) |_| _ = serial.write(port_base, 'x');
    try std.testing.expectEqual(line_size_max, serial.line_count);
}
