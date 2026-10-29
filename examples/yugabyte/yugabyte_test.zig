// SPDX-License-Identifier: MIT
//! Example test program: YugabyteDB 1.3.1, the release of Jepsen's analysis (2019; `current`:
//! 2026.1.2.0, the latest release), three nodes
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

/// `default`: 1.3.1, Jepsen's. `current`: 2026.1.2.0, the latest release, a master of 1 GB and a
/// tablet server of 2 GB (--memory-mib 12288).
fn describe(d: *System.Describe) !void {
    inline for (.{
        .{ "default", "examples/yugabyte/Dockerfile", &[_][]const u8{}, true },
        .{ "current", "examples/yugabyte/Dockerfile.2026.1", &[_][]const u8{
            "YB_MASTER_MEMORY=1073741824",
            "YB_TSERVER_MEMORY=2147483648",
        }, false },
    }) |entry| try describe_profile(try d.profile(entry[0]), entry[1], entry[2], entry[3]);
}

fn describe_profile(
    profile: *System.Profile,
    comptime dockerfile: []const u8,
    comptime env: []const []const u8,
    comptime crashing_backends: bool,
) !void {
    const build: sdk.schema.Build = .{ .context = ".", .dockerfile = dockerfile };
    inline for (node_names) |name| {
        profile.node(@field(System.Name, name), .{
            .build = build,
            .command = &.{name},
            .env = env,
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
                // The current release's clocks skewed, within its 500 ms maximum
                // (max_clock_skew_usec): hybrid time's safety assumes no more.
                .clock_skew = !crashing_backends,
                .clock_skew_ms_max = 400,
            },
            // 1.3.1's YSQL backends segfault on their way out (README: Observed), in every
            // timeline: counted, so a run's failing timelines say something again.
            .crashes_known = if (crashing_backends) &.{"postgres"} else &.{},
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
    s.finally("final reads", final_reads);
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

/// Every committed append still there once faults stop (examples/sql/append.zig).
fn final_reads(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const all = addresses(context);
    try sql_append.final_reads(arena, &all, options);
}
