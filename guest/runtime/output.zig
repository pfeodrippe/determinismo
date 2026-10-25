// SPDX-License-Identifier: MIT
//! Output as events: what a node's processes, or a test command, write to stdout and stderr,
//! line by line, as `{"output":{"source":..,"stream":"stdout"|"stderr","text":..}}`, each with
//! its moment, as Antithesis logs container and command output. The bytes also go to a file
//! (the node's output.log, or the commands' log).
//!
//! One forwarder process per node start or command reads the two pipes it writes to, and sends
//! the lines it has as one write (one request to the platform), not one per line. It takes the
//! source's name as its own (its comm), so the events' source is the node or command. It ends
//! when every process writing to the pipes has closed them.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");

/// A line longer than this is cut into several events.
const line_size_max = 2048;
const read_size = 4096;

pub const Pipes = struct { stdout: [2]linux.fd_t, stderr: [2]linux.fd_t };

pub fn pipes() !Pipes {
    var result: Pipes = undefined;
    for ([_]*[2]linux.fd_t{ &result.stdout, &result.stderr }) |pipe| {
        if (linux.errno(linux.pipe2(pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
    }
    return result;
}

/// Starts the forwarder; the caller then closes the read ends, and the write ends once the
/// writer has them. The forwarder is not the caller's child (a process in between starts it and
/// exits), so callers that wait for any child never meet it: det-init reaps it.
pub fn forward(source: []const u8, log_path: [:0]const u8, from: Pipes) !void {
    const middle = linux.fork();
    if (linux.errno(middle) != .SUCCESS) return error.Fork;
    if (middle != 0) {
        var status: i32 = 0;
        _ = linux.wait4(@intCast(middle), &status, 0, null);
        return;
    }
    const pid = linux.fork();
    if (pid != 0) linux.exit_group(0); // The forwarder is adopted by PID 1.
    _ = linux.close(from.stdout[1]);
    _ = linux.close(from.stderr[1]);
    var name_buffer: [16]u8 = @splat(0);
    const name_size = @min(source.len, name_buffer.len - 1);
    @memcpy(name_buffer[0..name_size], source[0..name_size]);
    _ = linux.prctl(@intFromEnum(linux.PR.SET_NAME), @intFromPtr(&name_buffer), 0, 0, 0);
    run(source, log_path, from.stdout[0], from.stderr[0]);
    linux.exit_group(0);
}

const Stream = struct {
    fd: linux.fd_t,
    name: []const u8,
    open: bool = true,
    partial: [line_size_max]u8 = undefined,
    partial_size: usize = 0,
};

fn run(source: []const u8, log_path: [:0]const u8, stdout: linux.fd_t, stderr: linux.fd_t) void {
    const log_flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const log_result = linux.open(log_path, log_flags, 0o644);
    const log: ?linux.fd_t = if (linux.errno(log_result) == .SUCCESS)
        @intCast(log_result)
    else
        null;
    const device_result = linux.open(sdk.device_path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    const device: ?linux.fd_t = if (linux.errno(device_result) == .SUCCESS)
        @intCast(device_result)
    else
        null;
    var streams = [_]Stream{
        .{ .fd = stdout, .name = "stdout" },
        .{ .fd = stderr, .name = "stderr" },
    };
    var batch: Batch = .{ .source = source, .device = device };
    while (streams[0].open or streams[1].open) {
        var polls: [2]linux.pollfd = undefined;
        var polled: [2]*Stream = undefined;
        var count: usize = 0;
        for (&streams) |*stream| {
            if (!stream.open) continue;
            polls[count] = .{ .fd = stream.fd, .events = linux.POLL.IN, .revents = 0 };
            polled[count] = stream;
            count += 1;
        }
        const ready = linux.poll(&polls, count, -1);
        if (linux.errno(ready) == .INTR) continue;
        if (linux.errno(ready) != .SUCCESS) break;
        for (polls[0..count], polled[0..count]) |poll, stream| {
            if (poll.revents == 0) continue;
            var buffer: [read_size]u8 = undefined;
            const size = linux.read(stream.fd, &buffer, buffer.len);
            if (linux.errno(size) == .INTR) continue;
            if (linux.errno(size) != .SUCCESS or size == 0) {
                stream.open = false;
                const rest = stream.partial[0..stream.partial_size];
                if (rest.len > 0) batch.line(stream.name, rest);
                stream.partial_size = 0;
                continue;
            }
            if (log) |fd| _ = linux.write(fd, &buffer, size);
            lines_split(&batch, stream, buffer[0..size]);
        }
        batch.flush(); // What one read brought: one request.
    }
    batch.flush();
}

fn lines_split(batch: *Batch, stream: *Stream, bytes: []const u8) void {
    for (bytes) |byte| {
        if (byte == '\n') {
            batch.line(stream.name, stream.partial[0..stream.partial_size]);
            stream.partial_size = 0;
            continue;
        }
        if (stream.partial_size == line_size_max) {
            batch.line(stream.name, &stream.partial);
            stream.partial_size = 0;
        }
        stream.partial[stream.partial_size] = byte;
        stream.partial_size += 1;
    }
}

/// Events waiting to be sent, one JSON object per line, as the platform splits them.
const Batch = struct {
    source: []const u8,
    device: ?linux.fd_t,
    buffer: [sdk.message_size_max]u8 = undefined,
    size: usize = 0,

    fn line(batch: *Batch, stream: []const u8, text: []const u8) void {
        var event_buffer: [3 * line_size_max]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&event_buffer);
        const value = .{ .output = .{ .source = batch.source, .stream = stream, .text = text } };
        std.json.Stringify.value(value, .{}, &writer) catch return;
        writer.writeAll("\n") catch return;
        const event = writer.buffered();
        if (event.len > batch.buffer.len) return; // Escaping can grow a line; never cut JSON.
        if (batch.size + event.len > batch.buffer.len) batch.flush();
        @memcpy(batch.buffer[batch.size..][0..event.len], event);
        batch.size += event.len;
    }

    fn flush(batch: *Batch) void {
        defer batch.size = 0;
        const fd = batch.device orelse return;
        if (batch.size == 0) return;
        _ = linux.write(fd, &batch.buffer, batch.size);
    }
};
