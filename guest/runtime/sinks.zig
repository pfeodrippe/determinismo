// SPDX-License-Identifier: MIT
//! det-sinks: Antithesis's output sink in every node (ANTITHESIS_OUTPUT_DIR, nodes.zig's
//! sink_directory): what a node's processes write to files there becomes events, as on
//! Antithesis: a `.jsonl` file's lines are events as they are (an Antithesis SDK's assertions,
//! `antithesis_setup`, anything structured), a `.bin` file's bytes are output in base64, any other
//! file's lines are output lines, each under the node's name and the file's (follow.zig). det-init
//! starts it with the nodes and stops it (SIGTERM) at the timeline's end, after a last look.
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo");
const follow = @import("follow.zig");
const nodes = @import("nodes.zig");

const files_max = 512;
const poll_ns = 50 * std.time.ns_per_ms;
const polls_max = 1 << 40;

var files: [files_max]follow.File = undefined;
var files_count: usize = 0;
var stopping = std.atomic.Value(bool).init(false);

fn stop_requested(_: linux.SIG) callconv(.c) void {
    stopping.store(true, .release);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const system = try nodes.system_load(arena);
    const device_result = linux.open(sdk.device_path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(device_result) != .SUCCESS) return error.NoDevice;
    const device: linux.fd_t = @intCast(device_result);
    const action: linux.Sigaction = .{
        .handler = .{ .handler = stop_requested },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.TERM, &action, null);
    for (0..polls_max) |_| {
        const last = stopping.load(.acquire);
        for (system.nodes) |node| scan(node.name);
        for (files[0..files_count]) |*file| file.follow(device);
        if (last) return;
        const request = linux.timespec{ .sec = 0, .nsec = poll_ns };
        _ = linux.nanosleep(&request, null); // A stop request cuts it short.
    }
}

/// The node's sink files, followed from their start once found.
fn scan(node: []const u8) void {
    var directory_buffer: [follow.path_size_max]u8 = undefined;
    const directory = nodes.sink_path(&directory_buffer, node) catch return;
    var entries = follow.Entries.of(directory);
    while (entries.next()) |entry| {
        if (entry.directory) continue;
        var path_buffer: [follow.path_size_max]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ directory, entry.name }) catch continue;
        note(path, node, follow.Kind.of_sink(entry.name));
    }
}

fn note(path: []const u8, node: []const u8, kind: follow.Kind) void {
    for (files[0..files_count]) |*file| {
        if (std.mem.eql(u8, file.path(), path)) return;
    }
    if (files_count == files_max) return;
    files[files_count].init(path, node, kind) catch return;
    files_count += 1;
}
