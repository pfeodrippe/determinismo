// SPDX-License-Identifier: MIT
//! Example test program: PostgreSQL 18.6 made highly available by Patroni 4.1.0, three nodes,
//! each an etcd member (Patroni's store) beside a database; Jepsen's PostgreSQL workload
//! (list-append transactions, examples/sql/append.zig) through the primary, whatever node it is
//! now, and Elle on the whole history. Jepsen tested Stolon (2020: G2-item and lost writes on
//! failover); Patroni, the most deployed of them, it never did.
//!
//! What Patroni promises: with `synchronous_mode` (the default profile) a commit is acknowledged
//! once a synchronous standby has it, and only such a standby is promoted, so a failover loses
//! no acknowledged transaction; without (`async`, Patroni's own default) a failover may lose
//! up to `maximum_lag_on_failover` bytes of them, by design.
//!
//! Scenarios:
//!   serializable  SERIALIZABLE transactions on the primary, checked for serializability, and
//!                 every committed append read back once faults stop (final reads)
//! Faults: the default ones, restarts, graceful stops and power losses (each node's database and
//! etcd member on its own disk), and stalls and power losses at its syncs.
//!
//!   determinismo explore ... --memory-mib 4096 --program zig-out/bin/patroni-test --scenario serializable
const std = @import("std");
const sdk = @import("determinismo");
const sql_append = @import("sql_append");

const Nodes = struct { pg1: sdk.Node, pg2: sdk.Node, pg3: sdk.Node };
const System = sdk.System(Nodes);

const port = 5432;
const rest_port = 8008;
const etcd_peer_port = 2380;
const node_names = .{ "pg1", "pg2", "pg3" };
/// Setup waits this many times half a second for a leader and two standbys streaming (a
/// one-CPU guest initializes, clones and starts three databases).
const setup_attempts_max = 600;
const schema_attempts_max = 300;

const options: sql_append.Options = .{
    .port = port,
    .user = "postgres",
    .isolation = "SERIALIZABLE",
    .primary_only = true,
    // A commit waits for a synchronous standby, which may be failing over.
    .timeout_ms = 20_000,
    // A failover takes tens of seconds (ttl 15 s, after a power loss of two nodes more): ~66 s
    // of refused connections in a row before a driver gives up.
    .refused_max = 120,
};

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .serializable = serializable },
        // Serializable, as PostgreSQL promises (not real time: examples/postgres/postgres_test.zig).
        .checks = .{ .elle = sdk.elle.check(.{ .consistency = "serializable" }) },
    });
}

/// `default`: synchronous_mode (no acknowledged commit lost to a failover). `async`: Patroni's
/// default, asynchronous standbys (a failover may lose acknowledged commits, by design).
fn describe(d: *System.Describe) !void {
    inline for (.{ .{ "default", "PATRONI_SYNC=true" }, .{ "async", "PATRONI_SYNC=false" } }) |entry| {
        const profile = try d.profile(entry[0]);
        // Causality's explanation: PostgreSQL's log at debug1, persisted (postgresql.auto.conf
        // outlives restarts).
        profile.explain = "for n in pg1 pg2 pg3; do det-nodes exec $n psql -U postgres -h /var/run/postgresql " ++
            "-c \"ALTER SYSTEM SET log_min_messages = debug1\" -c \"SELECT pg_reload_conf()\"; done";
        inline for (node_names, 1..) |name, id| {
            profile.node(@field(System.Name, name), .{
                .build = .{ .context = ".", .dockerfile = "examples/patroni/Dockerfile" },
                .command = &.{std.fmt.comptimePrint("{d}", .{id})},
                .env = &.{entry[1]},
                // Ready once etcd listens to its peers: Patroni (its REST API) waits for an
                // etcd quorum, which needs the nodes after this one (the first smoke: pg1 alone,
                // waiting on etcd, the others never started).
                .ready = .{ .tcp = etcd_peer_port },
                // Clock skews too: Patroni's HA loop runs on the node's wall clock, its leader key
                // on etcd's leases; one primary at a time must not depend on clocks agreeing.
                .faults = .{ .restart = true, .crash = true, .stop = true, .clock_skew = true },
                // A host's writeback window: Patroni writes files of its own (its configuration,
                // patroni.dynamic.json) without syncing them; PostgreSQL and etcd sync their own.
                .writeback_s = 30,
                // A pg_rewind cut short (its source unreachable) leaves the target's WAL damaged;
                // Patroni retries, the retry fails on the damage, and by default
                // (remove_data_directory_on_rewind_failure off) it starts the standby anyway, whose
                // startup PANICs (SIGABRT) at every start: documented (README), counted apart.
                .exits_known = &.{"could not locate a valid checkpoint record"},
            });
        }
    }
}

fn serializable(s: *System.Scenario) void {
    // Faults in bursts with quiet stretches between them: unpaced, etcd and Patroni (a 15 s
    // lease) never held a primary through a whole timeline (the third smoke's timeline 0: 2,000 s
    // of faults, not one transaction).
    s.pacing = .{ .active_ms_max = 10_000, .quiet_ms_max = 30_000 };
    s.setup("cluster", cluster);
    s.parallel_driver("append", append);
    s.finally("final reads", final_reads);
}

fn addresses(context: *System.Context) [3][4]u8 {
    return .{ context.nodes.pg1.address, context.nodes.pg2.address, context.nodes.pg3.address };
}

/// A leader and two standbys streaming from it, then the schema, through the primary.
fn cluster(context: *System.Context) !void {
    const all = addresses(context);
    _ = try sdk.retry(setup_attempts_max, 500, cluster_formed, .{&all});
    _ = try sdk.retry(schema_attempts_max, 200, schema_on_primary, .{&all});
}

fn cluster_formed(all: *const [3][4]u8) !void {
    var buffer: [16 * 1024]u8 = undefined;
    for (all) |address| {
        const response = sdk.tcp.http_with(address, rest_port, "GET", "/cluster", "", &buffer, .{ .timeout_ms = 2000 }) catch continue;
        if (response.status != 200) continue;
        // Three members: one leader running, two standbys streaming.
        const leaders = std.mem.count(u8, response.body, "\"role\": \"leader\"") + std.mem.count(u8, response.body, "\"role\":\"leader\"");
        const streaming = std.mem.count(u8, response.body, "\"state\": \"streaming\"") + std.mem.count(u8, response.body, "\"state\":\"streaming\"");
        if (leaders == 1 and streaming == 2) return;
        return error.NotFormed;
    }
    return error.NotFormed;
}

fn schema_on_primary(all: *const [3][4]u8) !void {
    var buffer: [4096]u8 = undefined;
    for (all) |address| {
        const response = sdk.tcp.http_with(address, rest_port, "GET", "/primary", "", &buffer, .{ .timeout_ms = 2000 }) catch continue;
        if (response.status != 200) continue;
        return sql_append.schema_create(address, options);
    }
    return error.NoPrimary;
}

fn append(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    try sql_append.transactions(arena, &addresses(context), options);
}

/// Every committed append still there once faults stop, read on the primary.
fn final_reads(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    try sql_append.final_reads(arena, &addresses(context), options);
}
