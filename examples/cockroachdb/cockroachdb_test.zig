// SPDX-License-Identifier: MIT
//! Example test program: CockroachDB v26.3.3, three nodes, following Jepsen's CockroachDB
//! analysis (2016: serializability violations, fixed then): list-append transactions
//! (examples/sql/append.zig, through PostgreSQL's protocol) whose every timeline's history Elle
//! checks on the host for serializability, CockroachDB's claim (with no stale reads of single
//! keys; across keys it allows causal reversal, so not strict serializability).
//!
//! Faults: the default ones, restarts, graceful stops and power losses (each node's store on its
//! own disk), and stalls and power losses at the nodes' syncs.
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
            .ready = .{ .tcp = port },
            // A wipe is left out: a node that lost its store cannot rejoin as itself.
            .faults = .{ .restart = true, .crash = true, .stop = true },
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
}

/// The cluster initialized (once: a second init says it already is), then the table.
fn cluster_ready(context: *System.Context) !void {
    var buffer: [4096]u8 = undefined;
    const init_output = try context.nodes.@"crdb-1".exec_output(&.{
        "/cockroach/cockroach", "init", "--insecure", "--host=crdb-1:26257",
    }, &buffer);
    sdk.event("cluster_init", .{ .status = init_output.status, .output = init_output.output });
    _ = try sdk.retry(setup_attempts_max, 200, sql_append.schema_create, .{
        context.nodes.@"crdb-1".address, options,
    });
}

fn append(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const all = addresses(context);
    try sql_append.transactions(arena, &all, options);
}
