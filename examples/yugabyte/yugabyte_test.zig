// SPDX-License-Identifier: MIT
//! Example test program: YugabyteDB 1.3.1, the release of Jepsen's analysis (2019), three nodes
//! each a master and a tablet server (Jepsen's colocated nodes; replication factor 3) with its
//! flags, and YSQL list-append transactions (examples/sql/append.zig through PostgreSQL's
//! protocol, Jepsen's YSQL append choices: five tables, appends that update then insert, rows
//! found by primary key, SERIALIZABLE), every history checked by Elle for serializability.
//!
//! Jepsen found in 1.3.1 (YSQL): #2125, G2-item cycles in append transactions when every master
//! crashed and restarted together, or paused (fixed in 1.3.1.2); #2021, DEFAULT columns read as
//! NULL in fresh tables; #1962/#1993/#1991, DDL errors around master elections and concurrent
//! creates; #1992, recoveries from partitions taking over 100 s.
//!
//! Faults: the default ones (pauses, partitions, degraded links, sync stalls, throttling), process
//! kills (a master or a tablet server, started again by its node: as Jepsen's nemesis killed
//! them), restarts and graceful stops; no power losses (YugabyteDB does not sync its write-ahead
//! log by default).
//!
//!   determinismo explore ... --memory-mib 8192 --program zig-out/bin/yugabyte-test --scenario append
const std = @import("std");
const sdk = @import("determinismo");
const sql_append = @import("sql_append");

const Nodes = struct { yb1: sdk.Node, yb2: sdk.Node, yb3: sdk.Node };
const System = sdk.System(Nodes);
const node_names = [_][]const u8{ "yb1", "yb2", "yb3" };

const ysql_port = 5433;
/// The master's: open at once (YSQL's waits on a quorum of masters, which needs the nodes
/// started after this one).
const master_port = 7100;
const setup_attempts_max = 600;
const options: sql_append.Options = .{
    .port = ysql_port,
    .user = "postgres",
    .database = "postgres",
    .isolation = "SERIALIZABLE",
    .tables = 5,
    .upserts = &.{.update_insert_update},
    .keys = &.{.primary},
    // 1.3 has none ("SAVEPOINT <transaction> not supported yet"): Jepsen's inserted directly.
    .savepoints = false,
    // A commit through Raft waits out a tablet's leader election.
    .timeout_ms = 15_000,
};

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .append = append_scenario },
        .checks = .{ .elle = sdk.elle.check(.{ .consistency = "serializable" }) },
    });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    const build: sdk.schema.Build = .{ .context = ".", .dockerfile = "examples/yugabyte/Dockerfile" };
    inline for (node_names) |name| {
        default.node(@field(System.Name, name), .{
            .build = build,
            .command = &.{name},
            .ready = .{ .tcp = master_port },
            // No power losses: YugabyteDB does not sync its write-ahead log by default
            // (durable_wal_write), so a power loss may lose what it acknowledged, and its
            // masters' catalogs read back corrupt; Jepsen killed processes.
            // Kills of the master and the tablet server, as Jepsen's: a YSQL backend killed
            // makes its postmaster restart them all (PostgreSQL's design), every few seconds.
            .faults = .{
                .restart = true,
                .stop = true,
                .process_kill = true,
                .process_kill_names = &.{ "yb-master", "yb-tserver" },
            },
            // 1.3.1's YSQL backends segfault on their way out (README: Observed), in every
            // timeline: counted, so a run's failing timelines say something again.
            .crashes_known = &.{"postgres"},
        });
    }
}

fn addresses(context: *System.Context) [node_names.len][4]u8 {
    return .{ context.nodes.yb1.address, context.nodes.yb2.address, context.nodes.yb3.address };
}

fn append_scenario(s: *System.Scenario) void {
    // Faults in stretches of up to 10 s, quiet ones between: a tablet's leader election and a
    // master's catalog load take seconds (Jepsen's nemesis acted every 10 s).
    s.pacing = .{ .active_ms_max = 10_000, .quiet_ms_max = 10_000 };
    s.setup("schema", schema);
    s.parallel_driver("append", append);
}

/// The tables, once YSQL answers (its catalog, the tablet servers registered).
fn schema(context: *System.Context) !void {
    _ = try sdk.retry(setup_attempts_max, 500, sql_append.schema_create, .{ context.nodes.yb1.address, options });
}

fn append(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const all = addresses(context);
    try sql_append.transactions(arena, &all, options);
}
