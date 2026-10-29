// SPDX-License-Identifier: MIT
//! Example test program: TiDB v8.5.8, three nodes each running PD, TiKV and TiDB, as Jepsen's
//! TiDB test runs them (jepsen-io/tidb: its configurations, fast elections and regions of at
//! most 5 keys, restart loops). Jepsen's analysis of 2.1.7 (the `jepsen` profile) reported that
//! TiDB's automatic retries of conflicting transactions, on by default, broke snapshot isolation
//! (lost updates, read skew).
//!
//! Scenario `append`: Jepsen's TiDB list-append transactions (`INSERT ... ON DUPLICATE KEY
//! UPDATE`, seven tables, reads by primary key; examples/sql/append.zig over MySQL's protocol)
//! through random nodes, at Repeatable Read (TiDB's snapshot isolation), Elle on every timeline's
//! history. Faults: the default ones, restarts, graceful stops and power losses (each node's
//! data on its own disk), and stalls and power losses at its syncs.
//!
//!   determinismo explore ... --program zig-out/bin/tidb-test --scenario append
const std = @import("std");
const sdk = @import("determinismo");
const sql_append = @import("sql_append");

const Nodes = struct { n1: sdk.Node, n2: sdk.Node, n3: sdk.Node };
const System = sdk.System(Nodes);

const node_names = .{ "n1", "n2", "n3" };
const pd_port = 2379;
// Each node's memory (PD, TiKV, TiDB), by profile: the guest needs three, and a gigabyte
// besides. TiKV 8.5 holds about 2.2 GB from its start, TiKV 2.1 about 0.5 GB.
const node_memory_mib = 3072; // --memory-mib 10240
const node_memory_mib_jepsen = 1024; // --memory-mib 4096
// TiDB starts once PD has a quorum and TiKV its stores: minutes, under faults.
const schema_attempts_max = 1500;

const options: sql_append.Options = .{
    .dialect = .mysql,
    .port = 4000,
    .user = "root",
    .database = "test",
    .isolation = "REPEATABLE READ",
    .tables = 7,
    .upserts = &.{.on_conflict},
    .keys = &.{.primary},
};

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .append = append_scenario },
        .checks = .{ .elle = sdk.elle.check(.{ .consistency = "snapshot-isolation" }) },
    });
}

/// `default`: TiDB v8.5.8. `jepsen`: v2.1.7, the version of Jepsen's analysis, to measure what
/// determinismo finds blind of what Jepsen reported.
fn describe(d: *System.Describe) !void {
    inline for (.{
        .{ "default", "examples/tidb/Dockerfile", node_memory_mib },
        .{ "jepsen", "examples/tidb/Dockerfile.2.1.7", node_memory_mib_jepsen },
    }) |entry| {
        const profile = try d.profile(entry[0]);
        inline for (node_names) |name| {
            profile.node(@field(System.Name, name), .{
                .build = .{ .context = ".", .dockerfile = entry[1] },
                .env = &.{
                    "TIDB_NODE=" ++ name,
                    // TiKV's gRPC resolves names with c-ares, which asks DNS and skips /etc/hosts
                    // (where the nodes' names are): the system resolver instead.
                    "GRPC_DNS_RESOLVER=native",
                },
                // PD's client port: the nodes start together, as PD needs a quorum.
                .ready = .{ .tcp = pd_port },
                // Within reach of the kernel's limit for each node, not the whole machine's.
                .memory_max_mib = entry[2],
                // PD's timestamps come from its leader's clock: a new leader behind must still
                // never hand out an older one.
                .faults = .{ .restart = true, .crash = true, .stop = true, .clock_skew = true },
            });
        }
    }
}

fn append_scenario(s: *System.Scenario) void {
    s.setup("schema", schema);
    s.parallel_driver("append", append);
    s.finally("final reads", final_reads);
}

fn schema(context: *System.Context) !void {
    _ = try sdk.retry(schema_attempts_max, 200, sql_append.schema_create, .{
        context.nodes.n1.address, options,
    });
}

fn append(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const all: [3][4]u8 = .{ context.nodes.n1.address, context.nodes.n2.address, context.nodes.n3.address };
    pd_leader_aim(arena, all[sdk.random_below(all.len)]);
    try sql_append.transactions(arena, &all, options);
}

/// The injector's faults aimed at PD's leader (sdk.fault_aim), whose clock every transaction's
/// timestamps come from: the member PD's API names ("pd-n2": node n2); nothing when none answers.
fn pd_leader_aim(arena: std.mem.Allocator, address: [4]u8) void {
    var buffer: [16 * 1024]u8 = undefined;
    const response = sdk.tcp.http_with(address, pd_port, "GET", "/pd/api/v1/leader", "", &buffer, .{ .timeout_ms = 5_000 }) catch return;
    if (response.status != 200) return;
    const Leader = struct { name: []const u8 = "" };
    const leader = std.json.parseFromSliceLeaky(Leader, arena, response.body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return;
    if (std.mem.startsWith(u8, leader.name, "pd-")) sdk.fault_aim(leader.name["pd-".len..]);
}

/// Every committed append still there once faults stop (examples/sql/append.zig).
fn final_reads(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const all: [3][4]u8 = .{ context.nodes.n1.address, context.nodes.n2.address, context.nodes.n3.address };
    try sql_append.final_reads(arena, &all, options);
}
