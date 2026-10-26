// SPDX-License-Identifier: MIT
//! Host checks (schema.Check): when a timeline ends, each of the test program's checks runs on
//! the host, as `<program> check <name> <scenario>`, with the records the timeline's commands
//! made (streamed out by the composer, collected by Events) on its standard input. The
//! assertions it makes (the SDK prints them as JSON lines, outside a guest) become events of the
//! timeline at its end moment, as the built-in properties are. The guest pays nothing; a replay
//! sends the same records, so the checks reach the same verdicts. sdk.elle.check is one such
//! check: Jepsen's Elle on a transaction history.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const schema = @import("determinismo").schema;
const Events = @import("events.zig");

/// Room for the inputs of a timeline's checks (Events.check_buffer): a history of a long
/// timeline is megabytes.
pub const input_size_max = 64 << 20;
/// What a check may print: its assertions, and what it says when it fails.
const output_size_max = 4 << 20;
const event_size_max = 4096;

pub const Options = struct {
    /// The test program, run on the host (the same binary as in the guest).
    program: []const u8,
    scenario: []const u8,
};

/// Each check whose records the timeline sent: run, and its assertions emitted at `moment`.
pub fn run(events: *Events, moment: Events.Moment, checks: []const schema.Check, options: Options) !void {
    for (checks, 0..) |check, index| {
        if (index >= Events.check_count_max) break;
        const input = events.check_input(index) orelse continue;
        const output = try std.heap.page_allocator.alloc(u8, output_size_max);
        defer std.heap.page_allocator.free(output);
        const result = try check_run(options, check.name, input, output);
        var lines = std.mem.tokenizeScalar(u8, result.output, '\n');
        while (lines.next()) |line| {
            // Its assertions; the rest (traces, its own messages) stays with the host's output.
            if (!std.mem.startsWith(u8, line, "{\"assert\":") or line.len > event_size_max) {
                std.debug.print("[determinismo] check {s}: {s}\n", .{ check.name, line });
                continue;
            }
            try events.emit(moment, line);
        }
        var buffer: [512]u8 = undefined;
        try events.emit(moment, try ran_event(&buffer, check.name, result.status));
    }
}

/// `always "host checks run to completion"`: a check that crashed or failed judged nothing.
fn ran_event(buffer: []u8, name: []const u8, status: u32) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{{\"assert\":{{\"type\":\"always\",\"message\":\"host " ++
        "checks run to completion\",\"condition\":{},\"details\":{{\"check\":\"{s}\"," ++
        "\"status\":{d}}}}}}}", .{ status == 0, name, status });
}

const Result = struct { status: u32, output: []const u8 };

/// The program as `check <name> <scenario>`: its input from a memory file, what it prints to
/// standard error read into `output` (the rest dropped).
fn check_run(options: Options, name: []const u8, input: []const u8, output: []u8) !Result {
    const memory = linux.memfd_create("det-check-input", linux.MFD.CLOEXEC);
    if (linux.errno(memory) != .SUCCESS) return error.MemoryFile;
    const input_fd: linux.fd_t = @intCast(memory);
    defer _ = linux.close(input_fd);
    var written: usize = 0;
    while (written < input.len) {
        const result = linux.write(input_fd, input[written..].ptr, input.len - written);
        if (linux.errno(result) != .SUCCESS) return error.WriteFailed;
        written += result;
    }
    _ = linux.lseek(input_fd, 0, linux.SEEK.SET);
    var pipe: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
    var arguments_buffer: [3][256:0]u8 = undefined;
    const argv = [_:null]?[*:0]const u8{
        try std.fmt.bufPrintSentinel(&arguments_buffer[0], "{s}", .{options.program}, 0),
        "check",
        try std.fmt.bufPrintSentinel(&arguments_buffer[1], "{s}", .{name}, 0),
        try std.fmt.bufPrintSentinel(&arguments_buffer[2], "{s}", .{options.scenario}, 0),
        null,
    };
    const environment = [_:null]?[*:0]const u8{ "PATH=/usr/local/bin:/usr/bin:/bin", null };
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.Fork;
    if (pid == 0) {
        _ = linux.dup2(input_fd, 0);
        _ = linux.dup2(pipe[1], 2);
        _ = linux.execve(argv[0].?, &argv, &environment);
        linux.exit_group(127);
    }
    _ = linux.close(pipe[1]);
    defer _ = linux.close(pipe[0]);
    var used: usize = 0;
    while (true) {
        var scratch: [4096]u8 = undefined;
        const target = if (used < output.len) output[used..] else &scratch;
        const result = linux.read(pipe[0], target.ptr, target.len);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS or result == 0) break;
        if (used < output.len) used += result;
    }
    var status: i32 = 0;
    while (true) {
        const waited = linux.wait4(@intCast(pid), &status, 0, null);
        if (linux.errno(waited) != .INTR) break;
    }
    const bits: u32 = @bitCast(status);
    const exit_status: u32 = if (bits & 0x7f == 0) (bits >> 8) & 0xff else 128 + (bits & 0x7f);
    return .{ .status = exit_status, .output = output[0..used] };
}

test ran_event {
    var buffer: [512]u8 = undefined;
    const passed = try ran_event(&buffer, "elle", 0);
    try std.testing.expect(std.mem.indexOf(u8, passed, "\"condition\":true") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, try ran_event(&buffer, "elle", 3), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("assert") != null);
}
