// SPDX-License-Identifier: MIT
//! det-agent: runs commands the platform pushes into the guest at a chosen moment (multiverse
//! debugging: "at this moment, run this"). It sleeps in the guest module until the platform
//! raises its interrupt, so timelines that push nothing never see it run.
//!
//! For each action (a shell command line) it emits `exec_start`, the command's output as
//! `exec_output` events, and `exec_done` with the exit status.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");

const action_size_max = sdk.message_size_max;
/// Output travels in events, which are JSON-escaped: keep chunks well under the event limit.
const output_chunk_size = 1024;
const ioctl_wait_action = 0xde01;
const actions_max = 1_000_000;
const output_chunks_max = 1 << 20;

pub fn main() !void {
    const device = linux.open(sdk.device_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(device) != .SUCCESS) return; // Not inside determinismo: nothing to serve.
    var action_buffer: [action_size_max + 1]u8 = undefined;
    for (0..actions_max) |_| {
        const buffer_address = @intFromPtr(&action_buffer);
        const result = linux.ioctl(@intCast(device), ioctl_wait_action, buffer_address);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS) return error.WaitFailed;
        if (result == 0) continue; // Woken without an action.
        assert(result <= action_size_max);
        action_buffer[result] = 0;
        run(action_buffer[0..result :0]);
    }
}

/// Runs one command line through /bin/sh, streaming its output as events.
fn run(command: [:0]const u8) void {
    assert(command.len > 0);
    sdk.event("exec_start", .{ .command = command });
    var pipe: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) {
        sdk.event("exec_done", .{ .status = 126 });
        return;
    }
    const pid = linux.fork();
    if (pid == 0) {
        _ = linux.dup2(pipe[1], 1);
        _ = linux.dup2(pipe[1], 2);
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command.ptr };
        const environment = [_:null]?[*:0]const u8{
            "PATH=/opt/determinismo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:" ++
                "/sbin:/bin",
            "HOME=/root",
        };
        _ = linux.execve("/bin/sh", &argv, &environment);
        linux.exit_group(127);
    }
    _ = linux.close(pipe[1]);
    stream_output(pipe[0]);
    _ = linux.close(pipe[0]);
    var status: i32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    const bits: u32 = @bitCast(status);
    const code = if (bits & 0x7f == 0) (bits >> 8) & 0xff else 128 + (bits & 0x7f);
    sdk.event("exec_done", .{ .status = code });
}

fn stream_output(fd: linux.fd_t) void {
    assert(fd >= 0);
    var chunk: [output_chunk_size]u8 = undefined;
    for (0..output_chunks_max) |_| {
        const result = linux.read(fd, &chunk, chunk.len);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS) return;
        if (result == 0) return; // The command closed its output.
        sdk.event("exec_output", .{ .text = chunk[0..result] });
    }
}
