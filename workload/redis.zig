// SPDX-License-Identifier: MIT
//! A plain guest workload with no SDK (tests can be any program, in any language): drives Redis
//! with randomized operations and prints one summary line. Everything that can vary (random keys,
//! reply contents, latencies) feeds the summary, so two runs print the same line only if the
//! whole system behaved identically.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const Connection = @import("resp");

const operations_default = 2000;
const operations_max = 1_000_000;
const key_count = 64;

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var operations: u32 = operations_default;
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "--ops")) {
        operations = try std.fmt.parseInt(u32, arguments[2], 10);
    }
    if (operations == 0 or operations > operations_max) return error.BadOperationCount;

    const connection = try init.arena.allocator().create(Connection);
    try connection.open(6379);
    defer connection.close();
    var summary = Summary{};
    const time_start_ns = monotonic_ns();
    for (0..operations) |index| {
        var random_bytes: [8]u8 = undefined;
        const result = linux.getrandom(&random_bytes, random_bytes.len, 0);
        assert(result == random_bytes.len);
        const random = std.mem.readInt(u64, &random_bytes, .little);
        if (index == 0) summary.random_first = random;
        const time_operation_ns = monotonic_ns();
        try operate(connection, random, &summary.replies);
        summary.record_latency(monotonic_ns() - time_operation_ns);
    }
    summary.print(.{ .operations = operations, .elapsed_ns = monotonic_ns() - time_start_ns });
}

/// One random operation; its reply feeds `replies`.
fn operate(connection: *Connection, random: u64, replies: *std.hash.Wyhash) !void {
    var key_buffer: [16]u8 = undefined;
    var value_buffer: [16]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buffer, "k{d}", .{random % key_count}) catch unreachable;
    const value = std.fmt.bufPrint(&value_buffer, "{x:0>16}", .{random}) catch unreachable;
    const reply = switch (random >> 61) {
        0, 1, 2 => try connection.call(&.{ "SET", key, value }),
        3, 4 => try connection.call(&.{ "GET", key }),
        5 => try connection.call(&.{ "INCR", "counter" }),
        6 => try connection.call(&.{ "LPUSH", "log", value }),
        7 => try connection.call(&.{ "LLEN", "log" }),
        else => unreachable,
    };
    switch (reply) {
        .status, .failure => |text| replies.update(text),
        .integer => |integer| replies.update(std.mem.asBytes(&integer)),
        .bulk => |bulk| replies.update(bulk orelse "(nil)"),
    }
}

const Summary = struct {
    replies: std.hash.Wyhash = .init(0),
    random_first: u64 = 0,
    latency_ns_min: u64 = std.math.maxInt(u64),
    latency_ns_max: u64 = 0,
    latency_ns_sum: u64 = 0,

    fn record_latency(summary: *Summary, latency_ns: u64) void {
        summary.latency_ns_min = @min(summary.latency_ns_min, latency_ns);
        summary.latency_ns_max = @max(summary.latency_ns_max, latency_ns);
        summary.latency_ns_sum += latency_ns;
        assert(summary.latency_ns_min <= summary.latency_ns_max);
    }

    fn print(summary: *Summary, totals: struct { operations: u32, elapsed_ns: u64 }) void {
        assert(totals.operations > 0);
        var line_buffer: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buffer, "workload redis: ops={d} " ++
            "replies_hash={x:0>16} first_rand={x:0>16} lat_ns(min/avg/max)={d}/{d}/{d} " ++
            "elapsed_ns={d}\n", .{
            totals.operations,                          summary.replies.final(),
            summary.random_first,                       summary.latency_ns_min,
            summary.latency_ns_sum / totals.operations, summary.latency_ns_max,
            totals.elapsed_ns,
        }) catch unreachable;
        _ = linux.write(1, line.ptr, line.len);
    }
};

fn monotonic_ns() u64 {
    var time: linux.timespec = undefined;
    const result = linux.clock_gettime(.MONOTONIC, &time);
    assert(linux.errno(result) == .SUCCESS);
    return @as(u64, @intCast(time.sec)) * std.time.ns_per_s + @as(u64, @intCast(time.nsec));
}
