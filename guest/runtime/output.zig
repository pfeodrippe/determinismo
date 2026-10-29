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
//!
//! A line that starts as a language runtime's panic, fatal error, data race or uncaught exception
//! does (Antithesis's "No panics (Go)" and others) is also an assertion that fails, right after
//! it: queries, a run's properties and its timelines all see it as any other.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");

/// A line longer than this is cut into several events.
const line_size_max = 2048;
const read_size = 4096;
/// Output kept, as events and in the log file, at Antithesis's logging rate (200 MB an hour of
/// virtual time, the logging property's), with a burst: a node looping on an error (Redpanda's
/// controller, run 83: 4 GB of events in one timeline, its run's page slow while serve took
/// them in, and the log file in the guest's memory) has the rest dropped, counted in an
/// `output_dropped` event, so the property still sees it. Lines dropped are not checked for
/// language properties (a panic in a flood).
const kept_bytes_per_s = 200 * 1000 * 1000 / 3600;
const kept_burst_bytes = 8 * 1000 * 1000;
const report_every_ns = 10 * std.time.ns_per_s;

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
    files_close_except(from.stdout[0], from.stderr[0]);
    var name_buffer: [16]u8 = @splat(0);
    const name_size = @min(source.len, name_buffer.len - 1);
    @memcpy(name_buffer[0..name_size], source[0..name_size]);
    _ = linux.prctl(@backingInt(linux.PR.SET_NAME), @intFromPtr(&name_buffer), 0, 0, 0);
    run(source, log_path, from.stdout[0], from.stderr[0]);
    linux.exit_group(0);
}

/// Every file the forwarder inherited, but stdin, stdout, stderr and its two pipes: it forks
/// from det-faults or det-nodes at any moment, from any of their threads, and a copy it kept
/// held what they held then for as long as it ran. A device-mapper lock det-faults' durability
/// listener held as its main thread restarted a node: the lock's next taker waited forever, and
/// the fault injector with it (srv3, 2026-10-28, a Kafka timeline without faults for 69 s); and
/// another node's pipes, whose forwarder then never saw them end.
fn files_close_except(a: linux.fd_t, b: linux.fd_t) void {
    const low: u32 = @intCast(@min(a, b));
    const high: u32 = @intCast(@max(a, b));
    const last = std.math.maxInt(u32);
    for ([_][2]u32{ .{ 3, low -| 1 }, .{ low + 1, high -| 1 }, .{ high + 1, last } }) |range| {
        if (range[0] > range[1] or range[0] < 3) continue;
        _ = linux.syscall3(.close_range, range[0], range[1], 0);
    }
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
    var budget: Budget = .{ .at_ns = monotonic_ns() };
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
            if (!budget.take(size)) {
                budget.dropped_bytes += size;
                budget.dropped_lines += std.mem.count(u8, buffer[0..size], "\n");
                stream.partial_size = 0; // Its rest is dropped too.
                // Said every 10 s while dropping: a node flooding to its timeline's end has its
                // forwarder killed before it would say it.
                if (budget.seen_ns -| budget.reported_ns >= report_every_ns) budget.report(&batch);
                continue;
            }
            budget.report(&batch);
            if (log) |fd| _ = linux.write(fd, &buffer, size);
            lines_split(&batch, stream, buffer[0..size]);
        }
        batch.flush(); // What one read brought: one request.
    }
    budget.report(&batch);
    batch.flush();
}

/// A token bucket over virtual time (kept_bytes_per_s, kept_burst_bytes), and what it dropped
/// since it last said so.
const Budget = struct {
    tokens: u64 = kept_burst_bytes,
    at_ns: u64,
    dropped_bytes: u64 = 0,
    dropped_lines: u64 = 0,
    reported_ns: u64 = 0,
    /// The last moment a read was weighed: the reports' cadence.
    seen_ns: u64 = 0,

    fn take(budget: *Budget, size: u64) bool {
        const now = monotonic_ns();
        const earned = (now -| budget.at_ns) * kept_bytes_per_s / std.time.ns_per_s;
        if (earned > 0) {
            budget.tokens = @min(kept_burst_bytes, budget.tokens + earned);
            budget.at_ns = now;
        }
        budget.seen_ns = now;
        if (budget.tokens < size) return false;
        budget.tokens -= size;
        return true;
    }

    fn report(budget: *Budget, batch: *Batch) void {
        if (budget.dropped_bytes == 0) return;
        batch.event(.{ .event = "output_dropped", .details = .{
            .source = batch.source,
            .bytes = budget.dropped_bytes,
            .lines = budget.dropped_lines,
        } });
        budget.dropped_bytes = 0;
        budget.dropped_lines = 0;
        budget.reported_ns = budget.seen_ns;
    }
};

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
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

/// Events waiting to be sent, one JSON object per line, as the platform splits them (det-podlogs
/// sends a Kubernetes node's pods' output through it too).
pub const Batch = struct {
    source: []const u8,
    device: ?linux.fd_t,
    buffer: [sdk.message_size_max]u8 = undefined,
    size: usize = 0,

    pub fn line(batch: *Batch, stream: []const u8, text: []const u8) void {
        batch.event(.{ .output = .{ .source = batch.source, .stream = stream, .text = text } });
        const property = language_property(text) orelse return;
        batch.event(.{ .assert = .{
            .type = "always_or_unreachable",
            .message = property,
            .condition = false,
            .details = .{ .source = batch.source, .text = text },
        } });
    }

    fn event(batch: *Batch, value: anytype) void {
        var event_buffer: [3 * line_size_max + 512]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&event_buffer);
        std.json.Stringify.value(value, .{}, &writer) catch return;
        writer.writeAll("\n") catch return;
        const bytes = writer.buffered();
        if (bytes.len > batch.buffer.len) return; // Escaping can grow a line; never cut JSON.
        if (batch.size + bytes.len > batch.buffer.len) batch.flush();
        @memcpy(batch.buffer[batch.size..][0..bytes.len], bytes);
        batch.size += bytes.len;
    }

    /// A JSON line sent as it is (an Antithesis sink's `.jsonl` line: an event of its own).
    pub fn raw(batch: *Batch, json_line: []const u8) void {
        if (json_line.len + 1 > batch.buffer.len) return;
        if (batch.size + json_line.len + 1 > batch.buffer.len) batch.flush();
        @memcpy(batch.buffer[batch.size..][0..json_line.len], json_line);
        batch.buffer[batch.size + json_line.len] = '\n';
        batch.size += json_line.len + 1;
    }

    pub fn flush(batch: *Batch) void {
        defer batch.size = 0;
        const fd = batch.device orelse return;
        if (batch.size == 0) return;
        _ = linux.write(fd, &batch.buffer, batch.size);
    }
};

/// Language properties (Antithesis's "No panics (Go)" and others): the signature of a panic, a
/// fatal error, a data race or an uncaught exception, at the start of a line.
const language_signs = [_]struct { prefix: []const u8, property: []const u8 }{
    .{ .prefix = "panic: ", .property = "no panics (Go)" },
    .{ .prefix = "fatal error: ", .property = "no fatal errors (Go)" },
    .{ .prefix = "WARNING: DATA RACE", .property = "no data races (Go)" },
    .{ .prefix = "thread '", .property = "no panics (Rust)" },
    .{ .prefix = "Exception in thread \"", .property = "no uncaught exceptions (Java)" },
};

/// The language property a line of output violates, if any.
fn language_property(text: []const u8) ?[]const u8 {
    for (language_signs) |sign| {
        if (!std.mem.startsWith(u8, text, sign.prefix)) continue;
        // Rust's panic line: "thread 'main' panicked at src/main.rs:4:5:".
        const rust = std.mem.eql(u8, sign.prefix, "thread '");
        if (rust and std.mem.indexOf(u8, text, "' panicked at ") == null) continue;
        return sign.property;
    }
    return null;
}

test language_property {
    try std.testing.expectEqual(@as(?[]const u8, null), language_property("thread 'x' started"));
    try std.testing.expectEqualStrings("no panics (Rust)", language_property(
        "thread 'main' panicked at src/main.rs:4:5:",
    ).?);
    try std.testing.expectEqualStrings("no panics (Go)", language_property(
        "panic: runtime error: invalid memory address or nil pointer dereference",
    ).?);
    try std.testing.expectEqual(@as(?[]const u8, null), language_property("I0101 panic: later"));
}

test "a panic line is its output event, then its property's failing assertion" {
    var batch: Batch = .{ .source = "dg5", .device = null };
    batch.line("stderr", "panic: runtime error: invalid memory address or nil pointer dereference");
    batch.line("stderr", "goroutine 275 [running]:");
    const sent = batch.buffer[0..batch.size];
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, sent, "\n"));
    const output = std.mem.indexOf(u8, sent, "{\"output\":{\"source\":\"dg5\"").?;
    const assertion = std.mem.indexOf(u8, sent, "{\"assert\":{\"type\":\"always_or_unreachable\"," ++
        "\"message\":\"no panics (Go)\",\"condition\":false,\"details\":{\"source\":\"dg5\"").?;
    try std.testing.expect(output < assertion);
}
