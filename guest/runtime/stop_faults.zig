// SPDX-License-Identifier: MIT
//! det-stop-faults <seconds>: a quiet period, as Antithesis's ANTITHESIS_STOP_FAULTS. Faults
//! stop (the one under way is undone) for that long, except clock skips; overlapping requests
//! merge into the longest. Every node and command finds it in $DETERMINISMO_STOP_FAULTS (and
//! $ANTITHESIS_STOP_FAULTS). Without a running fault injector it does nothing.
const std = @import("std");
const linux = std.os.linux;

const control_path = "/opt/determinismo/faults-control"; // faults.zig's control_path.
const seconds_max = 24 * 60 * 60;

pub fn main(init: std.process.Init) !u8 {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len != 2) return usage();
    const seconds = std.fmt.parseFloat(f64, arguments[1]) catch return usage();
    if (!(seconds >= 0 and seconds <= seconds_max)) return usage();
    const duration_ns: u64 = @intFromFloat(seconds * std.time.ns_per_s);
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true };
    const fd = linux.open(control_path, flags, 0);
    if (linux.errno(fd) != .SUCCESS) return 0; // No injector running: nothing to stop.
    defer _ = linux.close(@intCast(fd));
    const request = std.mem.toBytes(std.mem.nativeToLittle(u64, duration_ns));
    _ = linux.write(@intCast(fd), &request, request.len); // Atomic: under PIPE_BUF.
    return 0;
}

fn usage() u8 {
    std.debug.print("usage: det-stop-faults <seconds>\n", .{});
    return 2;
}
