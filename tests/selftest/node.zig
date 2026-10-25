// SPDX-License-Identifier: MIT
//! det-selftest-node: a tiny TCP service for determinismo's self-tests (a `binary` node).
//! Answers each line with the same line; on "die" it exits with status 3, as a crashing
//! service would. With DET_MUTANT set it answers in uppercase: a mutant the tests must catch.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

const port = 7000;
const connections_max = 1_000_000;

var mutant = false;

pub fn main(init: std.process.Init) !void {
    mutant = init.environ_map.get("DET_MUTANT") != null;
    const listener = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(listener) != .SUCCESS) return error.Socket;
    const fd: linux.fd_t = @intCast(listener);
    const one: u32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&one), 4);
    const address = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, port), .addr = 0 };
    if (linux.errno(linux.bind(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
        return error.Bind;
    }
    if (linux.errno(linux.listen(fd, 16)) != .SUCCESS) return error.Listen;
    for (0..connections_max) |_| {
        const client = linux.accept4(fd, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(client) != .SUCCESS) continue;
        defer _ = linux.close(@intCast(client));
        serve(@intCast(client));
    }
}

fn serve(client: linux.fd_t) void {
    assert(client >= 0);
    var buffer: [256]u8 = undefined;
    const size = linux.read(client, &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS or size == 0) return;
    const line = std.mem.trim(u8, buffer[0..size], "\r\n");
    if (std.mem.eql(u8, line, "die")) linux.exit_group(3);
    if (mutant) {
        for (buffer[0..size]) |*byte| byte.* = std.ascii.toUpper(byte.*);
    }
    _ = linux.write(client, buffer[0..size].ptr, size);
}
