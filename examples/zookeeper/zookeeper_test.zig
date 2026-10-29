// SPDX-License-Identifier: MIT
//! Example test program: ZooKeeper 3.9, an ensemble of three servers, under list-append
//! transactions checked by Elle for strict serializability (Jepsen's register test of 2013, in
//! the form its later analyses use). Each transaction reads the keys it touches (sync, then get)
//! and commits one multi: version checks of the keys it read (a create and a delete of those it
//! read as absent: they must still be), versioned sets of those it appended to; ZooKeeper applies a multi whole or not at all, so a committed transaction's reads held at
//! its commit.
//!
//! Drivers are client processes: each opens a connection to the client node (zclient.py, kazoo
//! behind a line protocol) and runs transactions through a server drawn each time. Outcomes: `ok`
//! with the reads; `fail` when nothing was applied (refused, or no connection to send it); `info`
//! when the commit got no answer. Once faults stop, every key is read again through each server:
//! an acknowledged append missing there is lost.
//!
//! Profiles: `default` (3.9.6) and `known` (3.9.1, before ZOOKEEPER-4785's fix: a follower
//! acknowledged its leader's NEWLEADER before the transactions of its DIFF sync were on disk, and
//! lost committed transactions when it crashed then).
//!
//!   determinismo explore ... --memory-mib 3072 --program zig-out/bin/zookeeper-test --scenario append
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo");
const tcp = sdk.tcp;

const Nodes = struct {
    @"zk-1": sdk.Node,
    @"zk-2": sdk.Node,
    @"zk-3": sdk.Node,
    zclient: sdk.Node,
};
const System = sdk.System(Nodes);

const client_port = 7000;
const zk_port = 2181;
const servers = 3;
const transactions_per_driver = 20;
const mops_max = 4;
/// Keys move with virtual time, a few at once, so lists stay short.
const keys_window = 4;
const window_s = 5;
const setup_attempts_max = 300;
/// An operation's answer at most: the client's own timeouts are 5 s a request (zclient.py).
const timeout_ms = 60_000;
const line_size_max = 64 * 1024;
/// Once faults stop: the ensemble serves again within a minute, or never did.
const recovery_attempts_max = 120;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .append = append_scenario },
        .checks = .{ .elle = sdk.elle.check(.{ .consistency = "strict-serializable" }) },
    });
}

fn describe(d: *System.Describe) !void {
    inline for (.{
        .{ "default", "examples/zookeeper/Dockerfile" },
        .{ "known", "examples/zookeeper/Dockerfile.3.9.1" },
    }) |entry| {
        const profile = try d.profile(entry[0]);
        const build: sdk.schema.Build = .{ .context = ".", .dockerfile = entry[1] };
        inline for (.{ "zk-1", "zk-2", "zk-3" }, 1..) |name, id| {
            profile.node(@field(System.Name, name), .{
                .build = build,
                .command = &.{ "server", std.fmt.comptimePrint("{d}", .{id}) },
                .ready = .{ .tcp = zk_port },
                .faults = .{ .restart = true, .crash = true, .stop = true },
                // ZooKeeper syncs its transaction log but not its snapshots (takeSnapshot(false),
                // the startup one too: ZOOKEEPER-3220, open): with nothing written back unasked, a
                // power loss at any age left logs and no snapshot, and the server refused to start
                // ("No snapshot found, but there are log entries"). A host's 30 s window.
                .writeback_s = 30,
                // ZOOKEEPER-3220's refusal (a power loss within 30 s of a snapshot): known, counted.
                .exits_known = &.{"No snapshot found, but there are log entries"},
            });
        }
        profile.node(.zclient, .{
            .build = build,
            .command = &.{"client"},
            .ready = .{ .tcp = client_port },
            // The client library's node, as Jepsen's clients: its links to the servers faulted,
            // the drivers' calls into it not, and it is never paused or slowed.
            .faults = .{
                .pause = false,
                .runner_links = false,
                .sync_stall = false,
                .throttle = false,
                .process_pause = false,
            },
        });
    }
}

fn append_scenario(s: *System.Scenario) void {
    // Faults in bursts with quiet stretches between them: an ensemble restarted every second or
    // so never elects a leader long enough to commit.
    s.pacing = .{ .active_ms_max = 10_000, .quiet_ms_max = 30_000 };
    s.setup("ensemble", ensemble_serves);
    s.parallel_driver("append", appends);
    s.eventually("read", final_reads);
}

const Client = struct {
    connection: tcp.Connection,
    line: [line_size_max]u8 = undefined,

    fn open(client: *Client, context: *System.Context) !void {
        try client.connection.open(context.nodes.zclient.address, client_port, .{ .timeout_ms = timeout_ms });
    }

    /// One request line, one reply line (valid until the next request).
    fn request(client: *Client, comptime format: []const u8, arguments: anytype) ![]const u8 {
        const line = try std.fmt.bufPrint(&client.line, format ++ "\n", arguments);
        try client.connection.write_all(line);
        return client.connection.read_line();
    }
};

fn client_opened(context: *System.Context, client: *Client) !void {
    try client.open(context);
}

// Setup -----------------------------------------------------------------------------------------

/// Every server answers a transaction (the ensemble elected a leader and each follows it).
fn ensemble_serves(context: *System.Context) !void {
    for (1..servers + 1) |server| {
        _ = try sdk.retry(setup_attempts_max, 500, server_serves, .{ context, server });
    }
}

fn server_serves(context: *System.Context, server: usize) !void {
    var client: Client = undefined;
    try client.open(context);
    defer client.connection.close();
    const reply = try client.request("txn {d} r:setup", .{server});
    if (std.mem.startsWith(u8, reply, "ok")) return;
    sdk.event("zookeeper_error", .{ .command = "setup", .server = server, .reply = reply });
    return error.NotServing;
}

// The workload ----------------------------------------------------------------------------------

const Mop = struct { append: bool, key: u64, value: u64 };
const Outcome = enum { committed, not_committed, unknown };

fn appends(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    var client: Client = undefined;
    try client.open(context);
    defer client.connection.close();
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
        const server = 1 + sdk.random_below(servers);
        const outcome = run(arena, &client, server, mops[0..count], &reads);
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
                // Its client process may be gone with it (the node's connection): a fresh one.
                client.connection.close();
                client.open(context) catch return;
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

fn run(arena: std.mem.Allocator, client: *Client, server: u64, mops: []const Mop, reads: *[mops_max]?[]const u64) Outcome {
    var line: std.ArrayList(u8) = .empty;
    line.print(arena, "txn {d}", .{server}) catch return .not_committed;
    for (mops) |mop| {
        if (mop.append) {
            line.print(arena, " a:{d}:{d}", .{ mop.key, mop.value }) catch return .not_committed;
        } else {
            line.print(arena, " r:{d}", .{mop.key}) catch return .not_committed;
        }
    }
    const reply = client.request("{s}", .{line.items}) catch return .unknown;
    if (std.mem.startsWith(u8, reply, "fail")) return .not_committed;
    if (!std.mem.startsWith(u8, reply, "ok")) {
        if (!std.mem.startsWith(u8, reply, "unknown")) sdk.event("zookeeper_reply", .{ .reply = reply });
        return .unknown;
    }
    // "ok <key>:<list> ...": the reads, in the mops' order.
    var fields = std.mem.tokenizeScalar(u8, reply["ok".len..], ' ');
    for (mops, 0..) |mop, position| {
        if (mop.append) continue;
        const field = fields.next() orelse return .unknown;
        reads[position] = list_parse(arena, field) catch return .unknown;
    }
    return .committed;
}

/// "<key>:<v>,<v>,..." to its values.
fn list_parse(arena: std.mem.Allocator, field: []const u8) ![]const u64 {
    const colon = std.mem.indexOfScalar(u8, field, ':') orelse return error.BadReply;
    var values: std.ArrayList(u64) = .empty;
    var items = std.mem.tokenizeScalar(u8, field[colon + 1 ..], ',');
    while (items.next()) |item| try values.append(arena, try std.fmt.parseInt(u64, item, 10));
    return values.items;
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

// Once faults stop --------------------------------------------------------------------------------

/// Every key read again, through each server in turn, into the history: Elle then sees an
/// acknowledged append that no final read has as lost. The ensemble must serve again.
fn final_reads(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    var client: Client = undefined;
    _ = try sdk.retry(recovery_attempts_max, 500, client_opened, .{ context, &client });
    defer client.connection.close();
    const keys = sdk.retry(recovery_attempts_max, 500, keys_listed, .{ arena, &client }) catch |err| {
        sdk.assert_unreachable("the ensemble serves again once faults stop", .{ .err = @errorName(err) });
        return err;
    };
    // A sometimes, not a reachable: a message is one kind of assertion (the unreachable above).
    sdk.sometimes(true, "the final reads listed the keys", .{ .keys = keys.len });
    const history: sdk.elle.History = .{};
    for (1..servers + 1) |server| {
        // A server that refused a whole retry budget is down for good (a power loss before its
        // first snapshot reached the disk: ZOOKEEPER-3220): its other reads are failures, not
        // retried (run 91 spent its hour retrying them, key by key).
        var down = false;
        var at: usize = 0;
        while (at < keys.len) : (at += mops_max) {
            const batch = keys[at..@min(at + mops_max, keys.len)];
            var mops: [mops_max]Mop = undefined;
            for (batch, mops[0..batch.len]) |key, *mop| mop.* = .{ .append = false, .key = key, .value = 0 };
            const process = sdk.elle.process_new();
            try history.invoke(arena, process, try elle_mops(arena, mops[0..batch.len], null));
            var reads: [mops_max]?[]const u64 = @splat(null);
            // A server just back may not serve yet: refused, it is asked again.
            var outcome: Outcome = .not_committed;
            if (!down) for (0..recovery_attempts_max) |_| {
                outcome = run(arena, &client, server, mops[0..batch.len], &reads);
                if (outcome != .not_committed) break;
                sdk.sleep_ms(500);
            };
            if (outcome == .not_committed and !down) {
                down = true;
                sdk.event("zookeeper_server_down", .{ .server = server });
            }
            switch (outcome) {
                .committed => try history.ok(arena, process, try elle_mops(arena, mops[0..batch.len], &reads)),
                .not_committed => try history.fail(arena, process, try elle_mops(arena, mops[0..batch.len], null)),
                .unknown => try history.info(arena, process, try elle_mops(arena, mops[0..batch.len], null)),
            }
            sdk.sometimes(outcome == .committed, "a final read answered", .{ .server = server });
            if (outcome == .unknown) {
                client.connection.close();
                _ = try sdk.retry(recovery_attempts_max, 500, client_opened, .{ context, &client });
            }
        }
    }
}

fn keys_listed(arena: std.mem.Allocator, client: *Client) ![]const u64 {
    // Through server 1, then 2, then 3: the first that answers.
    for (1..servers + 1) |server| {
        const reply = client.request("keys {d}", .{server}) catch return error.NoAnswer;
        if (!std.mem.startsWith(u8, reply, "keys")) continue;
        var keys: std.ArrayList(u64) = .empty;
        var fields = std.mem.tokenizeScalar(u8, reply["keys".len..], ' ');
        while (fields.next()) |field| {
            const key = std.fmt.parseInt(u64, field, 10) catch continue; // "setup".
            try keys.append(arena, key);
        }
        return keys.items;
    }
    return error.NotServing;
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

test "a read's list, as the client node answers it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualSlices(u64, &.{ 7, 42, 5 }, try list_parse(arena, "12:7,42,5"));
    try std.testing.expectEqualSlices(u64, &.{}, try list_parse(arena, "12:"));
    try std.testing.expectError(error.BadReply, list_parse(arena, "12"));
}
