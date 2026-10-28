// SPDX-License-Identifier: MIT
//! Example test program: PostgreSQL 18.6, one server, following Jepsen's PostgreSQL 12.3
//! analysis (2020: Serializable allowed G2-item, fixed in 12.4): list-append transactions
//! (examples/sql/append.zig) whose whole history Elle checks.
//!
//! Scenarios:
//!   serializable     SERIALIZABLE transactions, checked for strict serializability
//!   repeatable_read  REPEATABLE READ transactions, checked for snapshot isolation (what
//!                    PostgreSQL's Repeatable Read is)
//! Faults: the default ones, restarts, graceful stops and power losses (the data on its own
//! disk: committed transactions are synced first, so they must survive), and stalls and power
//! losses at its syncs.
//!
//!   determinismo explore ... --program zig-out/bin/postgres-test --scenario serializable
const std = @import("std");
const sdk = @import("determinismo");
const sql_append = @import("sql_append");

const Nodes = struct { postgres: sdk.Node };
const System = sdk.System(Nodes);

const port = 5432;
const image = "docker.io/library/postgres:18.6-alpine";
const image_jepsen = "docker.io/library/postgres:12.3-alpine";
const schema_attempts_max = 300;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{
            .serializable = Isolation("SERIALIZABLE").scenario,
            .repeatable_read = Isolation("REPEATABLE READ").scenario,
        },
        // Elle, on the host, on every timeline's history: each scenario against what its level
        // promises. Serializable, not strict serializable: PostgreSQL promises some serial order,
        // not real time (Jepsen checked the same); run 43's first anomaly, G2-item-realtime, was
        // a serializable history whose order put a session's later transaction first.
        .checks = .{ .elle = sdk.elle.check(.{
            .consistency = "serializable",
            .by_scenario = &.{.{ .scenario = "repeatable_read", .consistency = "snapshot-isolation" }},
        }) },
    });
}

/// `default`: PostgreSQL 18.6. `jepsen`: 12.3, the version of Jepsen's analysis (2020: G2-item at
/// Serializable), to measure what determinismo finds blind of what Jepsen reported.
fn describe(d: *System.Describe) !void {
    inline for (.{ .{ "default", image }, .{ "jepsen", image_jepsen } }) |entry| {
        const profile = try d.profile(entry[0]);
        profile.node(.postgres, .{
            .image = entry[1],
            .env = &.{"POSTGRES_HOST_AUTH_METHOD=trust"},
            .ready = .{ .tcp = port },
            .faults = .{ .restart = true, .crash = true, .stop = true },
        });
    }
}

fn Isolation(comptime level: []const u8) type {
    return struct {
        const options: sql_append.Options = .{ .port = port, .user = "postgres", .isolation = level };

        fn scenario(s: *System.Scenario) void {
            s.setup("schema", schema);
            s.parallel_driver("append", append);
        }

        fn schema(context: *System.Context) !void {
            _ = try sdk.retry(schema_attempts_max, 200, sql_append.schema_create, .{
                context.nodes.postgres.address, options,
            });
        }

        fn append(context: *System.Context) !void {
            const arena = context.init.arena.allocator();
            try sql_append.transactions(arena, &.{context.nodes.postgres.address}, options);
        }
    };
}
