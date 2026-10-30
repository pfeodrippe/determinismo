// SPDX-License-Identifier: MIT
//! Example test program: CockroachDB v26.3.3, three nodes, following Jepsen's CockroachDB
//! analysis (2016: serializability violations, fixed then): list-append transactions
//! (examples/sql/append.zig, through PostgreSQL's protocol) whose every timeline's history Elle
//! checks on the host for serializability, CockroachDB's claim (with no stale reads of single
//! keys; across keys it allows causal reversal, so not strict serializability).
//!
//! Faults: the default ones, restarts, graceful stops and power losses (each node's store on its
//! own disk), and stalls and power losses at the nodes' syncs. Ranges are test-sized (64 KiB),
//! so they split, merge and move leases during a timeline.
//!
//!   determinismo explore ... --program zig-out/bin/cockroachdb-test --scenario append
const std = @import("std");
const sdk = @import("determinismo");
const sql_append = @import("sql_append");

const Nodes = struct { @"crdb-1": sdk.Node, @"crdb-2": sdk.Node, @"crdb-3": sdk.Node };
const System = sdk.System(Nodes);
const node_names = [_][]const u8{ "crdb-1", "crdb-2", "crdb-3" };

const port = 26257;
const image = "docker.io/cockroachdb/cockroach:v26.3.3";
const setup_attempts_max = 300;
const options: sql_append.Options = .{
    .port = port,
    .user = "root",
    .database = "defaultdb",
    .isolation = "SERIALIZABLE",
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
    // Causality's explanation: the transaction and replica code's logs up in every node, at
    // runtime (crdb_internal.set_vmodule; a restart resets it).
    default.explain = "for n in crdb-1 crdb-2 crdb-3; do det-nodes exec $n /cockroach/cockroach sql --insecure " ++
        "--host=$n:26257 -e \"SELECT crdb_internal.set_vmodule('txn*=2,replica*=2,store*=1')\"; done";
    inline for (node_names) |name| {
        default.node(@field(System.Name, name), .{
            .image = image,
            .command = &.{
                "start",
                "--insecure",
                "--join=crdb-1:26257,crdb-2:26257,crdb-3:26257",
                "--listen-addr=0.0.0.0:26257",
                "--advertise-addr=" ++ name ++ ":26257",
                "--http-addr=0.0.0.0:8080",
                "--store=/cockroach/cockroach-data",
                // Small caches: three nodes share the machine.
                "--cache=64MiB",
                "--max-sql-memory=64MiB",
            },
            // Test-sized ranges allowed (zone_sql): 64 MiB is the smallest range_max_bytes
            // otherwise, as CockroachDB's own roachtests lower it.
            .env = &.{"COCKROACH_MIN_RANGE_MAX_BYTES=65536"},
            .ready = .{ .tcp = port },
            // A wipe is left out: a node that lost its store cannot rejoin as itself. Clocks
            // skewed within its maximum offset (500 ms; a node past 80% of it stops on purpose).
            .faults = .{ .restart = true, .crash = true, .stop = true, .clock_skew = true, .clock_skew_ms_max = 300 },
        });
    }
}

fn addresses(context: *System.Context) [node_names.len][4]u8 {
    return .{
        context.nodes.@"crdb-1".address,
        context.nodes.@"crdb-2".address,
        context.nodes.@"crdb-3".address,
    };
}

fn append_scenario(s: *System.Scenario) void {
    s.setup("cluster", cluster_ready);
    s.parallel_driver("append", append);
    s.finally("final reads", final_reads);
}

/// Ranges split at 64 KiB (512 MiB by default, which a test's data never reaches; below 64 MiB
/// only with COCKROACH_MIN_RANGE_MAX_BYTES lowered: the first smoke's setup was refused) and
/// merge under 16 KiB: splits, merges and the lease and replica moves after them
/// happen within a timeline, as Jepsen's split nemesis made them. No internal time series (a
/// write every 10 s on every node that nothing reads here).
const zone_sql = "ALTER RANGE default CONFIGURE ZONE USING range_min_bytes = 16384, range_max_bytes = 65536";
/// Its own statement: a cluster setting is refused inside a transaction, and one `-e` with both
/// is one (the second smoke's setup).
const timeseries_sql = "SET CLUSTER SETTING timeseries.storage.enabled = false";

/// The cluster initialized (once: a second init says it already is), its ranges test-sized, then
/// the table.
fn cluster_ready(context: *System.Context) !void {
    var buffer: [4096]u8 = undefined;
    const init_output = try context.nodes.@"crdb-1".exec_output(&.{
        "/cockroach/cockroach", "init", "--insecure", "--host=crdb-1:26257",
    }, &buffer);
    sdk.event("cluster_init", .{ .status = init_output.status, .output = init_output.output });
    _ = try sdk.retry(setup_attempts_max, 200, settings_apply, .{context});
    _ = try sdk.retry(setup_attempts_max, 200, sql_append.schema_create, .{
        context.nodes.@"crdb-1".address, options,
    });
}

fn settings_apply(context: *System.Context) !void {
    var buffer: [4096]u8 = undefined;
    const result = try context.nodes.@"crdb-1".exec_output(&.{
        "/cockroach/cockroach", "sql", "--insecure", "--host=crdb-1:26257", "-e", zone_sql, "-e", timeseries_sql,
    }, &buffer);
    if (result.status != 0) {
        sdk.event("cluster_settings_refused", .{ .status = result.status, .output = result.output });
        return error.SettingsRefused;
    }
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
