// SPDX-License-Identifier: MIT
//! det-agent: runs commands the platform pushes into the guest at a chosen moment (multiverse
//! debugging: "at this moment, run this"). It sleeps in the guest module until the platform
//! raises its interrupt, so timelines that push nothing never see it run.
//!
//! For each action (a shell command line) it emits `exec_start`, the command's output as
//! `exec_output` events, and `exec_done` with the exit status, each with the action's `id` (its
//! number). `det:background <command>` runs the command beside the next ones (Antithesis's
//! run_in_background): its exec_start says `"background":true` as soon as it is started (the
//! platform goes on to the next step then), its output and exec_done follow as it runs.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");
const faults = @import("faults.zig");

/// The platform's action where a timeline begins at a moment of another (VM.Options
/// .branch_signal): not a command, no events; the fault injector hears of it (faults.zig).
const branch_action = "det:branch";
const background_action = "det:background ";
/// A moment's script with steps of the platform's (a wait, a background command) holds the
/// timeline from its end (det-init waits for hold_path, as for busy_path) until it releases it.
const hold_action = "det:hold";
const release_action = "det:release";
/// A fresh future from the moment (VM.Options.fresh_seed): the kernel's generator reseeded from
/// a platform decision (now drawn from the new seed), so what processes draw afresh differs from
/// the timeline's too, and the fault injector perturbs at once, as at a tree's branch point.
const reseed_action = "det:reseed";
pub const hold_path = "/run/det-agent-hold";

const action_size_max = sdk.message_size_max;
/// Output travels in events, which are JSON-escaped: keep chunks well under the event limit.
const output_chunk_size = 1024;
/// How much of a command its exec_start event shows.
const command_shown_max = 512;
const ioctl_wait_action = 0xde01;
const actions_max = 1_000_000;
const output_chunks_max = 1 << 20;
/// Exists while a command runs: det-init waits for it before ending the timeline, so that a
/// command at a moment near the end still finishes.
pub const busy_path = "/run/det-agent-busy";

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
        const action = action_buffer[0..result :0];
        if (std.mem.startsWith(u8, action, branch_action)) {
            // "det:branch" and, after a space, the node the branch aims its first fault at.
            const rest = action[branch_action.len..];
            faults.branch_request(if (rest.len > 1 and rest[0] == ' ') rest[1..] else "");
            continue;
        }
        background_reap();
        if (std.mem.eql(u8, action, reseed_action)) {
            kernel_reseed();
            faults.branch_request("");
            done(0, 0, false); // Not a command: id 0.
            continue;
        }
        if (std.mem.eql(u8, action, hold_action) or std.mem.eql(u8, action, release_action)) {
            if (std.mem.eql(u8, action, hold_action)) {
                const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true };
                const hold = linux.open(hold_path, flags, 0o644);
                if (linux.errno(hold) == .SUCCESS) _ = linux.close(@intCast(hold));
            } else _ = linux.unlink(hold_path);
            done(0, 0, false); // Not a command: id 0.
            continue;
        }
        actions += 1;
        if (std.mem.startsWith(u8, action, background_action)) {
            const command = action[background_action.len.. :0];
            if (command.len == 0) continue;
            const pid = linux.fork();
            if (pid == 0) {
                run(command, actions, true);
                linux.exit_group(0);
            }
            if (linux.errno(pid) != .SUCCESS) {
                sdk.event("exec_done", .{ .status = 126, .id = actions, .background = true });
            }
            continue;
        }
        run(action, actions, false);
    }
}

/// The guest kernel's random generator reseeded from a platform decision (composer.zig's
/// kernel_reseed, at setup_complete, does the same for every timeline).
fn kernel_reseed() void {
    const rnd_add_entropy = 0x40085203; // _IOW('R', 3, int[2])
    const rnd_reseed_crng = 0x5207; // _IO('R', 7)
    const seed_size = 32;
    var request: extern struct { bits: i32, size: i32, bytes: [seed_size]u8 } = .{
        .bits = seed_size * 8,
        .size = seed_size,
        .bytes = undefined,
    };
    sdk.random_bytes(&request.bytes);
    const fd = linux.open("/dev/urandom", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.ioctl(@intCast(fd), rnd_add_entropy, @intFromPtr(&request));
    _ = linux.ioctl(@intCast(fd), rnd_reseed_crng, 0);
}

/// Commands started so far: each one's id.
var actions: u32 = 0;

/// Background commands that ended (their processes, the agent's children) are reaped.
fn background_reap() void {
    var status: i32 = 0;
    while (true) {
        const result = linux.wait4(-1, &status, linux.W.NOHANG, null);
        if (linux.errno(result) != .SUCCESS or result == 0) return;
    }
}

/// Runs one command line through /bin/sh, streaming its output as events. A background one
/// leaves the timeline's end alone (det-init waits only for the others: busy_path).
fn run(command: [:0]const u8, id: u32, background: bool) void {
    assert(command.len > 0);
    if (!background) {
        const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true };
        const busy = linux.open(busy_path, flags, 0o644);
        if (linux.errno(busy) == .SUCCESS) _ = linux.close(@intCast(busy));
    }
    defer if (!background) {
        _ = linux.unlink(busy_path);
    };
    // Long commands (inject's base64 chunks) are cut: the event must fit in one message.
    const shown = command[0..@min(command.len, command_shown_max)];
    if (background) {
        sdk.event("exec_start", .{ .command = shown, .size = command.len, .id = id, .background = true });
    } else {
        sdk.event("exec_start", .{ .command = shown, .size = command.len, .id = id });
    }
    var pipe: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) {
        done(126, id, background);
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
    stream_output(pipe[0], id);
    _ = linux.close(pipe[0]);
    var status: i32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    const bits: u32 = @bitCast(status);
    const code = if (bits & 0x7f == 0) (bits >> 8) & 0xff else 128 + (bits & 0x7f);
    done(code, id, background);
}

fn done(status: u32, id: u32, background: bool) void {
    if (background) {
        sdk.event("exec_done", .{ .status = status, .id = id, .background = true });
    } else {
        sdk.event("exec_done", .{ .status = status, .id = id });
    }
}

fn stream_output(fd: linux.fd_t, id: u32) void {
    assert(fd >= 0);
    var chunk: [output_chunk_size]u8 = undefined;
    for (0..output_chunks_max) |_| {
        const result = linux.read(fd, &chunk, chunk.len);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS) return;
        if (result == 0) return; // The command closed its output.
        sdk.event("exec_output", .{ .text = chunk[0..result], .id = id });
    }
}
