// SPDX-License-Identifier: MIT
//! Example test program: MariaDB 13.0.2 with Galera 4, three nodes, as Jepsen's Galera test runs
//! them (jepsen-io/mysql: its configuration, n1 starting the cluster, list-append transactions
//! at Repeatable Read checked for snapshot isolation). Jepsen's analysis of 12.1.2 (the `jepsen`
//! profile) reported committed transactions lost when nodes crash together (the log is not
//! flushed at commit, as MariaDB recommends for Galera), and lost updates and stale reads.
//!
//! Scenario `append`: transactions through random nodes (examples/sql/append.zig, MySQL's
//! protocol), Elle on every timeline's history, and once faults stop, a read of every key that
//! must hold each committed append. Faults: the default ones, restarts, graceful
//! stops and power losses (each node's data on its own disk), and stalls and power losses at its
//! syncs.
//!
//!   determinismo explore ... --program zig-out/bin/galera-test --scenario append
const std = @import("std");
const sdk = @import("determinismo");
const sql_append = @import("sql_append");

const Nodes = struct { n1: sdk.Node, n2: sdk.Node, n3: sdk.Node };
const System = sdk.System(Nodes);

const node_names = .{ "n1", "n2", "n3" };
const port = 3306;
const schema_attempts_max = 600;

const options: sql_append.Options = .{
    .dialect = .mysql,
    .port = port,
    .user = "root",
    .database = "jepsen",
    .isolation = "REPEATABLE READ",
    // Final reads wait until the node applied every commit of the cluster: a lagging node's
    // read is then no excuse for a missing append.
    .final_session = "SET SESSION wsrep_sync_wait = 1",
};

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .append = append_scenario },
        // Jepsen's expectation for Galera at Repeatable Read.
        .checks = .{ .elle = sdk.elle.check(.{ .consistency = "snapshot-isolation" }) },
    });
}

/// `default`: MariaDB 13.0.2, nodes recovering their position before each start as MariaDB's
/// systemd unit does. `jepsen`: 12.1.2, the version of Jepsen's analysis, started as Jepsen's
/// wrapper does (no position recovery), to measure what determinismo finds blind of what Jepsen
/// reported. `jepsen-dirsync`: 12.1.2 with gvwstate.dat's rename made durable (dirsync.c), to
/// tell whether that rename causes the EVS abort (README). `jepsen-recovered`: that, with the
/// systemd unit's position recovery, to tell Galera's own behavior from the wrapper's. `default`
/// and `jepsen-recovered` flush InnoDB's log at every commit: with it once a second (Jepsen's,
/// the `jepsen` profiles) a whole primary failing within that second loses its last commits, as
/// Galera documents (run 202), which hid any other loss.
fn describe(d: *System.Describe) !void {
    inline for (.{
        .{ "default", "examples/galera/Dockerfile", true },
        .{ "jepsen", "examples/galera/Dockerfile.12.1.2", false },
        .{ "jepsen-dirsync", "examples/galera/Dockerfile.12.1.2-dirsync", false },
        .{ "jepsen-recovered", "examples/galera/Dockerfile.12.1.2-dirsync", true },
    }) |entry| {
        const profile = try d.profile(entry[0]);
        inline for (node_names) |name| {
            const first = comptime std.mem.eql(u8, name, "n1");
            const env = .{
                "GALERA_NODE=" ++ name,
                "MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1",
                "MARIADB_DATABASE=jepsen",
            };
            profile.node(@field(System.Name, name), .{
                .build = .{ .context = ".", .dockerfile = entry[1] },
                .env = &(if (entry[2]) env ++ .{ "GALERA_RECOVER=1", "GALERA_FLUSH_AT_COMMIT=1" } else env),
                .ready = .{ .tcp = port },
                // The others join the cluster n1 started.
                .after = if (first) &.{} else &.{.n1},
                .faults = .{ .restart = true, .crash = true, .stop = true },
                // Galera's own abort when a joiner's state transfer loses its donor: by design
                // (README), and its signal 11 inside abort() looks like any crash. 114 of hunt run
                // 97's 299 timelines failed "no process crashes: mariadbd" on it alone, the EVS
                // aborts hidden among them.
                // And a node that finds no primary component within gcomm's wait (pc.wait_prim)
                // gives up starting, by design; it is started again.
                .exits_known = &.{
                    "State transfer cannot be completed, need to abort",
                    "failed to reach primary view",
                },
            });
        }
    }
}

fn append_scenario(s: *System.Scenario) void {
    s.setup("schema", schema);
    s.parallel_driver("append", append);
    s.finally("final reads", final_reads);
}

fn addresses(context: *System.Context) [3][4]u8 {
    return .{ context.nodes.n1.address, context.nodes.n2.address, context.nodes.n3.address };
}

fn schema(context: *System.Context) !void {
    _ = try sdk.retry(schema_attempts_max, 200, sql_append.schema_create, .{
        context.nodes.n1.address, options,
    });
}

fn append(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const all = addresses(context);
    try sql_append.transactions(arena, &all, options);
}

/// Every committed append still there once faults stop (run 123 lost one, Elle none the wiser),
/// and no node in a primary component without a history: stateless nodes restoring their
/// component together run under the nil history UUID, and a node that saves it never starts
/// again (README).
fn final_reads(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const all = addresses(context);
    try sql_append.final_reads(arena, &all, options);
    inline for (node_names) |name| history_check(&@field(context.nodes, name), name);
}

const history_query = "SELECT variable_value FROM information_schema.global_status WHERE " ++
    "variable_name IN ('wsrep_cluster_state_uuid', 'wsrep_cluster_status') ORDER BY variable_name";
const nil_history = "00000000-0000-0000-0000-000000000000";

/// The node's cluster history and whether it is in the primary component (a node down or not
/// answering says nothing).
fn history_check(node: *const sdk.Node, comptime name: []const u8) void {
    var buffer: [512]u8 = undefined;
    const result = node.exec_output(&.{ "mariadb", "-N", "-e", history_query }, &buffer) catch return;
    if (result.status != 0) return;
    // The state UUID's line first (ORDER BY its name), then the status's; an empty value is an
    // empty line (a node not connected has no UUID), kept so the two stay apart.
    var lines = std.mem.splitScalar(u8, result.output, '\n');
    const uuid = std.mem.trim(u8, lines.next() orelse return, " \t\r");
    const status = std.mem.trim(u8, lines.next() orelse return, " \t\r");
    const primary = std.mem.eql(u8, status, "Primary");
    sdk.always(!(primary and std.mem.eql(u8, uuid, nil_history)), "no primary component runs under a nil history", .{
        .node = name,
        .uuid = uuid,
        .status = status,
    });
}
