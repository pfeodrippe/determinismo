// SPDX-License-Identifier: MIT
//! det-selftest-node: a tiny TCP service for determinismo's self-tests (a `binary` node).
//! Answers each line with the same line; on "die" it exits with status 3, as a crashing
//! service would. With DET_MUTANT set it answers in uppercase: a mutant the tests must catch.
//! `det-selftest-node hog` instead touches memory until the kernel kills it (the node's memory
//! limit makes that an OOM kill). With DET_WORKERS=<n> it also supervises n worker processes,
//! replacing any that dies (what process_kill faults test).
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");

const port = 7000;
const connections_max = 1_000_000;
const hog_chunk_size = 1 << 20;
const hog_chunks_max = 4096;

var mutant = false;

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len == 2 and std.mem.eql(u8, arguments[1], "hog")) return hog();
    if (arguments.len == 2 and std.mem.eql(u8, arguments[1], "crash")) crash();
    mutant = init.environ_map.get("DET_MUTANT") != null;
    if (init.environ_map.get("DET_WORKERS")) |text| {
        const workers = try std.fmt.parseInt(u32, text, 10);
        for (0..workers) |_| worker_start();
        _ = try std.Thread.spawn(.{}, supervise, .{});
    }
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

fn worker_start() void {
    const pid = linux.fork();
    if (pid == 0) {
        while (true) _ = linux.pause(); // A worker: here to be killed.
    }
}

/// Replaces every worker that dies.
fn supervise() void {
    while (true) {
        var status: i32 = 0;
        const result = linux.wait4(-1, &status, 0, null);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS) return; // No children left.
        sdk.reachable("a killed worker is replaced", .{});
        worker_start();
    }
}

/// A write through an invalid pointer: SIGSEGV, which the kernel logs as a segfault.
fn crash() noreturn {
    const address: usize = 8;
    const target: *volatile u8 = @ptrFromInt(address);
    target.* = 1;
    unreachable;
}

fn hog() !void {
    for (0..hog_chunks_max) |_| {
        const protection: linux.PROT = .{ .READ = true, .WRITE = true };
        const flags: linux.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
        const address = linux.mmap(null, hog_chunk_size, protection, flags, -1, 0);
        if (linux.errno(address) != .SUCCESS) return error.Mmap;
        const memory: [*]u8 = @ptrFromInt(address);
        var offset: usize = 0;
        while (offset < hog_chunk_size) : (offset += 4096) memory[offset] = 1;
    }
    return error.NotKilled; // 4 GiB touched and still alive: no limit applied.
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
