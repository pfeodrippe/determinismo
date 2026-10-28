// SPDX-License-Identifier: MIT
//! det-selftest-node: a tiny TCP service for determinismo's self-tests (a `binary` node).
//! Answers each line with the same line; on "die" it exits with status 3, as a crashing
//! service would. With DET_MUTANT set it answers in uppercase: a mutant the tests must catch.
//! `det-selftest-node hog` instead touches memory until the kernel kills it (the node's memory
//! limit makes that an OOM kill). With DET_WORKERS=<n> it also supervises n worker processes,
//! replacing any that dies (what process_kill faults test). `det-selftest-node custom-fault` is
//! a custom fault: it draws a number and reports it, with where the node finds det-stop-faults.
//! With DET_DURABLE set, a first start writes /data/synced (synced: the file and its directory)
//! and /data/unsynced (not synced): what crashes and wipes must keep and lose.
//! `det-selftest-node write <path>` writes a file in /data and syncs it and its directory,
//! exiting 1 if the disk refused (disk faults). `det-selftest-node ping <a.b.c.d>` exits 0 if
//! the service at that address answers a line (a node reaching itself while isolated).
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
    // `exists <path>`: exits 0 if the file is there (the node has no shell to ask).
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "exists")) {
        const found = linux.errno(linux.access(arguments[2], linux.F_OK)) == .SUCCESS;
        linux.exit_group(if (found) 0 else 1);
    }
    if (arguments.len == 2 and std.mem.eql(u8, arguments[1], "crash")) crash();
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "ping")) {
        const address = std.Io.net.Ip4Address.parse(arguments[2], port) catch linux.exit_group(2);
        linux.exit_group(if (ping(address.bytes)) 0 else 1);
    }
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "write")) {
        synced_write(arguments[2], "written\n") catch linux.exit_group(1);
        linux.exit_group(0);
    }
    if (arguments.len == 2 and std.mem.eql(u8, arguments[1], "custom-fault")) {
        const stop_faults = init.environ_map.get("ANTITHESIS_STOP_FAULTS") orelse "";
        const draw = sdk.random_below(1000);
        sdk.event("custom_fault_ran", .{ .draw = draw, .stop_faults = stop_faults });
        return;
    }
    mutant = init.environ_map.get("DET_MUTANT") != null;
    if (init.environ_map.get("DET_DURABLE") != null) try durable_write();
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

/// On a first start (no /data/synced yet): one file synced, one not. Restarts leave them be.
fn durable_write() !void {
    if (linux.errno(linux.access("/data/synced", linux.F_OK)) == .SUCCESS) return;
    _ = linux.mkdir("/data", 0o755);
    try synced_write("/data/synced", "kept\n");
    const unsynced = try file_create("/data/unsynced", "lost in a crash\n");
    _ = linux.close(unsynced);
}

/// The file written and synced, then its directory (/data) synced: durable once it returns.
fn synced_write(path: [*:0]const u8, content: []const u8) !void {
    const file = try file_create(path, content);
    defer _ = linux.close(file);
    if (linux.errno(linux.fsync(file)) != .SUCCESS) return error.Fsync;
    const directory = linux.open("/data", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(directory) != .SUCCESS) return error.Open;
    defer _ = linux.close(@intCast(directory));
    if (linux.errno(linux.fsync(@intCast(directory))) != .SUCCESS) return error.Fsync;
}

fn file_create(path: [*:0]const u8, content: []const u8) !linux.fd_t {
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const fd = linux.open(path, flags, 0o644);
    if (linux.errno(fd) != .SUCCESS) return error.Open;
    const written = linux.write(@intCast(fd), content.ptr, content.len);
    if (linux.errno(written) != .SUCCESS or written != content.len) return error.Write;
    return @intCast(fd);
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

/// Whether the service at `address` answers "ping" within a second.
fn ping(address: [4]u8) bool {
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket) != .SUCCESS) return false;
    const fd: linux.fd_t = @intCast(socket);
    defer _ = linux.close(fd);
    const timeout = linux.timeval{ .sec = 1, .usec = 0 };
    const option = std.mem.asBytes(&timeout);
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, option.ptr, option.len);
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, option.ptr, option.len);
    const target = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast(address) };
    if (linux.errno(linux.connect(fd, @ptrCast(&target), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
        return false;
    }
    _ = linux.write(fd, "ping\n", 5);
    var reply: [16]u8 = undefined;
    const size = linux.read(fd, &reply, reply.len);
    if (linux.errno(size) != .SUCCESS) return false;
    return std.mem.eql(u8, reply[0..size], "ping\n");
}
