// SPDX-License-Identifier: MIT
//! Example test program: Redis-Raft (github.com/RedisLabs/redisraft), five Redis nodes in one
//! Raft cluster, following Jepsen's Redis-Raft analysis (2020, 1b3fbf6 to e0123a9). Jepsen's
//! workload, list-append: transactions of appends (RPUSH) and reads (LRANGE) in MULTI/EXEC, on
//! random nodes, recorded for Elle (sdk.elle), which checks the history is strictly serializable.
//! Jepsen found, in 2d1cf30 (this image), history rewritten by crashes alone (#52: acknowledged
//! elements lost, duplicated, reordered), split-brain from loading snapshots (#44), and crashes.
//!
//! Outcomes: `ok` when EXEC answered; `fail` on a definite refusal (NOLEADER, TRYAGAIN,
//! CLUSTERDOWN, ...: Jepsen's #23, aborted reads, came from refusals that took effect after all);
//! `info` when no answer came.
//!
//! Faults: the default ones, restarts and power losses (each node's Raft log on its own disk).
//!
//!   determinismo explore ... --program zig-out/bin/redisraft-test --scenario append
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo");
const Resp = @import("resp.zig");

const Nodes = struct {
    @"redis-1": sdk.Node,
    @"redis-2": sdk.Node,
    @"redis-3": sdk.Node,
    @"redis-4": sdk.Node,
    @"redis-5": sdk.Node,
};
const System = sdk.System(Nodes);
const nodes_count = 5;
const port = 6379;
/// A transaction waits out an election (Redis-Raft's default election timeout is 500 ms).
const timeout_ms = 5000;
const transactions_per_driver = 20;
const mops_max = 4;
/// Keys move with virtual time, a few at once, so lists stay short.
const keys_window = 4;
const window_s = 5;
const setup_attempts_max = 300;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .append = append_scenario },
        .checks = .{ .elle = sdk.elle.check(.{ .consistency = "strict-serializable" }) },
    });
}

fn describe(d: *System.Describe) !void {
    const profile = try d.profile("default");
    inline for (.{ "redis-1", "redis-2", "redis-3", "redis-4", "redis-5" }, 1..) |name, id| {
        profile.node(@field(System.Name, name), .{
            .build = .{ .context = ".", .dockerfile = "examples/redisraft/Dockerfile" },
            .command = &.{std.fmt.comptimePrint("{d}", .{id})},
            .ready = .{ .tcp = port },
            .faults = .{ .restart = true, .crash = true },
        });
    }
}

fn append_scenario(s: *System.Scenario) void {
    s.setup("cluster", cluster_formed);
    s.parallel_driver("append", append);
}

fn addresses(context: *System.Context) [nodes_count][4]u8 {
    return .{
        context.nodes.@"redis-1".address, context.nodes.@"redis-2".address,
        context.nodes.@"redis-3".address, context.nodes.@"redis-4".address,
        context.nodes.@"redis-5".address,
    };
}

// Setup ---------------------------------------------------------------------------------------

/// Node 1 starts the cluster; each other node joins it.
fn cluster_formed(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const all = addresses(context);
    _ = try sdk.retry(setup_attempts_max, 200, command_once, .{ arena, all[0], &[_][]const u8{ "RAFT.CLUSTER", "INIT" } });
    for (all[1..], 2..) |address, id| {
        _ = id;
        _ = try sdk.retry(setup_attempts_max, 200, command_once, .{ arena, address, &[_][]const u8{ "RAFT.CLUSTER", "JOIN", "redis-1:6379" } });
    }
    // Every node answers through the cluster before the drivers start.
    for (all) |address| {
        _ = try sdk.retry(setup_attempts_max, 200, command_once, .{ arena, address, &[_][]const u8{"RAFT.INFO"} });
    }
}

fn command_once(arena: std.mem.Allocator, address: [4]u8, parts: []const []const u8) !void {
    var connection: Resp = undefined;
    try connection.open(address, port, timeout_ms);
    defer connection.close();
    const replies = try connection.pipeline(arena, &.{parts});
    switch (replies[0]) {
        .failure => |message| {
            // An earlier attempt's answer was lost: the cluster exists, the node is in it.
            if (std.mem.indexOf(u8, message, "already") != null) return;
            return error.Refused;
        },
        else => {},
    }
}

// The workload ----------------------------------------------------------------------------------

const Mop = struct { append: bool, key: u64, value: u64 };
const Outcome = enum { committed, not_committed, unknown };

fn append(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const all = addresses(context);
    const history: sdk.elle.History = .{};
    var id: u64 = undefined;
    sdk.random_bytes(std.mem.asBytes(&id));
    id &= 0xffff_ffff;
    var process = sdk.elle.process_new();
    for (0..transactions_per_driver) |sequence| {
        var mops: [mops_max]Mop = undefined;
        const count = draw(&mops, id, sequence);
        try history.invoke(arena, process, try elle_mops(arena, mops[0..count], null));
        var reads: [mops_max]?[]const u64 = @splat(null);
        const outcome = run(arena, all[sdk.random_below(nodes_count)], mops[0..count], &reads);
        switch (outcome) {
            .committed => {
                try history.ok(arena, process, try elle_mops(arena, mops[0..count], &reads));
                sdk.sometimes(true, "a transaction committed", .{});
            },
            .not_committed => {
                try history.fail(arena, process, try elle_mops(arena, mops[0..count], null));
                sdk.sometimes(true, "a transaction was refused", .{});
            },
            .unknown => {
                try history.info(arena, process, try elle_mops(arena, mops[0..count], null));
                sdk.sometimes(true, "a transaction's outcome is unknown", .{});
                process = sdk.elle.process_new(); // Elle's rule: one operation at a time.
            },
        }
    }
}

fn draw(mops: *[mops_max]Mop, id: u64, sequence: u64) u32 {
    const count: u32 = @intCast(1 + sdk.random_below(mops_max));
    const base = monotonic_ns() / std.time.ns_per_s / window_s;
    for (mops[0..count], 0..) |*mop, position| {
        mop.* = .{
            .append = sdk.random_below(2) == 0,
            .key = base + sdk.random_below(keys_window),
            // Unique per key: the driver, its transaction, the micro-operation.
            .value = (id << 20) | (sequence << 4) | position,
        };
    }
    return count;
}

/// MULTI, the micro-operations, EXEC, pipelined on a fresh connection.
fn run(arena: std.mem.Allocator, address: [4]u8, mops: []const Mop, reads: *[mops_max]?[]const u64) Outcome {
    var connection: Resp = undefined;
    connection.open(address, port, timeout_ms) catch return .not_committed; // Nothing was sent.
    defer connection.close();
    var commands: std.ArrayList([]const []const u8) = .empty;
    commands.append(arena, &.{"MULTI"}) catch return .not_committed;
    for (mops) |mop| {
        const key = std.fmt.allocPrint(arena, "{d}", .{mop.key}) catch return .not_committed;
        const command: []const []const u8 = if (mop.append)
            arena.dupe([]const u8, &.{ "RPUSH", key, std.fmt.allocPrint(arena, "{d}", .{mop.value}) catch return .not_committed }) catch return .not_committed
        else
            arena.dupe([]const u8, &.{ "LRANGE", key, "0", "-1" }) catch return .not_committed;
        commands.append(arena, command) catch return .not_committed;
    }
    commands.append(arena, &.{"EXEC"}) catch return .not_committed;
    const replies = connection.pipeline(arena, commands.items) catch return .unknown;
    const exec = replies[replies.len - 1];
    switch (exec) {
        .failure => |message| return if (refusal(message)) .not_committed else .unknown,
        .array => |maybe| {
            const results = maybe orelse return .not_committed; // EXEC aborted (WATCH): nothing.
            if (results.len != mops.len) return .unknown;
            for (mops, results, 0..) |mop, result, position| {
                if (mop.append) continue;
                const items = switch (result) {
                    .array => |list| list orelse &.{},
                    else => return .unknown,
                };
                const list = arena.alloc(u64, items.len) catch return .unknown;
                for (items, list) |item, *value| {
                    const text = switch (item) {
                        .bulk => |bytes| bytes orelse return .unknown,
                        else => return .unknown,
                    };
                    value.* = std.fmt.parseInt(u64, text, 10) catch return .unknown;
                }
                reads[position] = list;
            }
            return .committed;
        },
        else => return .unknown,
    }
}

/// Redis-Raft's refusals: the command was not applied (as it documents them).
fn refusal(message: []const u8) bool {
    const prefixes = [_][]const u8{ "NOLEADER", "TRYAGAIN", "CLUSTERDOWN", "MOVED", "EXECABORT" };
    for (prefixes) |prefix| if (std.mem.startsWith(u8, message, prefix)) return true;
    return false;
}

fn elle_mops(arena: std.mem.Allocator, mops: []const Mop, reads: ?*const [mops_max]?[]const u64) ![]const sdk.elle.Mop {
    const out = try arena.alloc(sdk.elle.Mop, mops.len);
    for (mops, out, 0..) |mop, *elle_mop, position| {
        elle_mop.* = if (mop.append)
            .{ .append = .{ .key = mop.key, .value = mop.value } }
        else
            .{ .read = .{ .key = mop.key, .list = if (reads) |known| known[position] orelse &.{} else null } };
    }
    return out;
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}
