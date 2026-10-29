// SPDX-License-Identifier: MIT
//! Example test program: MySQL 26.10.0, one server, following Jepsen's MySQL 8.0.34 analysis
//! (2023: Repeatable Read allowed G2-item, G-single, lost update and non-repeatable reads):
//! list-append transactions (examples/sql/append.zig, MySQL's protocol) whose whole history Elle
//! checks.
//!
//! Scenarios:
//!   serializable     SERIALIZABLE transactions, checked for strict serializability
//!   repeatable_read  REPEATABLE READ transactions (MySQL's default), checked for Repeatable Read
//! Faults: the default ones, restarts, graceful stops and power losses (the data on its own
//! disk: InnoDB syncs its log at each commit, so committed transactions must survive), and
//! stalls and power losses at its syncs.
//!
//!   determinismo explore ... --program zig-out/bin/mysql-test --scenario repeatable_read
const std = @import("std");
const sdk = @import("determinismo");
const sql_append = @import("sql_append");

const Nodes = struct { mysql: sdk.Node };
const System = sdk.System(Nodes);

const port = 3306;
const image = "docker.io/library/mysql:26.10.0";
const image_jepsen = "docker.io/library/mysql:8.0.34";
const schema_attempts_max = 300;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{
            .serializable = Isolation("SERIALIZABLE").scenario,
            .repeatable_read = Isolation("REPEATABLE READ").scenario,
        },
        // Elle, on the host, on every timeline's history: each scenario against its level.
        .checks = .{ .elle = sdk.elle.check(.{
            .consistency = "strict-serializable",
            .by_scenario = &.{.{ .scenario = "repeatable_read", .consistency = "repeatable-read" }},
        }) },
    });
}

/// `default`: MySQL 26.10.0. `jepsen`: 8.0.34, the version of Jepsen's analysis, to measure what
/// determinismo finds blind of what Jepsen reported.
fn describe(d: *System.Describe) !void {
    inline for (.{ .{ "default", image }, .{ "jepsen", image_jepsen } }) |entry| {
        const profile = try d.profile(entry[0]);
        profile.node(.mysql, .{
            .image = entry[1],
            .env = &.{ "MYSQL_ALLOW_EMPTY_PASSWORD=yes", "MYSQL_DATABASE=jepsen" },
            .ready = .{ .tcp = port },
            .faults = .{ .restart = true, .crash = true, .stop = true },
        });
    }
}

fn Isolation(comptime level: []const u8) type {
    return struct {
        const options: sql_append.Options = .{
            .dialect = .mysql,
            .port = port,
            .user = "root",
            .database = "jepsen",
            .isolation = level,
        };

        fn scenario(s: *System.Scenario) void {
            s.setup("schema", schema);
            s.parallel_driver("append", append);
            s.finally("final reads", final_reads);
        }

        fn schema(context: *System.Context) !void {
            _ = try sdk.retry(schema_attempts_max, 200, sql_append.schema_create, .{
                context.nodes.mysql.address, options,
            });
        }

        fn append(context: *System.Context) !void {
            const arena = context.init.arena.allocator();
            try sql_append.transactions(arena, &.{context.nodes.mysql.address}, options);
        }

        /// Every committed append still there once faults stop (examples/sql/append.zig).
        fn final_reads(context: *System.Context) !void {
            const arena = context.init.arena.allocator();
            try sql_append.final_reads(arena, &.{context.nodes.mysql.address}, options);
        }
    };
}
