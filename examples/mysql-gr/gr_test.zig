// SPDX-License-Identifier: MIT
//! Example test program: MySQL 26.10.0 Group Replication, three members in single-primary mode
//! with `group_replication_consistency = BEFORE_ON_PRIMARY_FAILOVER`, as InnoDB Cluster runs
//! them. Jepsen analyzed MySQL (8.0.34, one server) and Galera, never Group Replication.
//!
//! What it promises: a transaction commits once a majority certified it (Paxos, XCom), so a
//! failover loses no acknowledged commit; a new primary applies its backlog before it serves
//! (BEFORE_ON_PRIMARY_FAILOVER), so its reads are not stale.
//!
//! Scenarios:
//!   serializable     SERIALIZABLE transactions on the primary, checked for strict
//!                    serializability, and every committed append read back once faults stop
//!   repeatable_read  REPEATABLE READ (MySQL's default) on the primary, checked for Repeatable
//!                    Read (Jepsen's MySQL expectation)
//! Faults: the default ones in bursts, restarts, graceful stops and power losses (each member's
//! data on its own disk), and stalls and power losses at its syncs.
//!
//!   determinismo explore ... --memory-mib 4096 --program zig-out/bin/mysql-gr-test --scenario serializable
const std = @import("std");
const sdk = @import("determinismo");
const sql_append = @import("sql_append");

const Nodes = struct { n1: sdk.Node, n2: sdk.Node, n3: sdk.Node };
const System = sdk.System(Nodes);

const node_names = .{ "n1", "n2", "n3" };
const port = 3306;
/// Setup waits this many times half a second for three members online (three servers
/// initialized on one CPU, then the group formed and joined).
const setup_attempts_max = 600;
const schema_attempts_max = 300;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{
            .serializable = Isolation("SERIALIZABLE").scenario,
            .repeatable_read = Isolation("REPEATABLE READ").scenario,
        },
        .checks = .{ .elle = sdk.elle.check(.{
            .consistency = "strict-serializable",
            .by_scenario = &.{.{ .scenario = "repeatable_read", .consistency = "repeatable-read" }},
        }) },
    });
}

fn describe(d: *System.Describe) !void {
    const profile = try d.profile("default");
    // Causality's explanation: the error log's notes (Group Replication's), persisted.
    profile.explain = "for n in n1 n2 n3; do det-nodes exec $n mysql -uroot -e " ++
        "\"SET PERSIST log_error_verbosity = 3\"; done";
    inline for (node_names, 1..) |name, id| {
        profile.node(@field(System.Name, name), .{
            .build = .{ .context = ".", .dockerfile = "examples/mysql-gr/Dockerfile" },
            .command = &.{std.fmt.comptimePrint("{d}", .{id})},
            .env = &.{"MYSQL_ALLOW_EMPTY_PASSWORD=yes"},
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
            .primary_only = true,
            // Faults aimed at the primary the drivers find (addresses' order).
            .node_names = &.{ "n1", "n2", "n3" },
            // A commit waits for the group's certification, which may be electing a primary.
            .timeout_ms = 20_000,
            // A primary elected after a member's expulsion takes seconds (its failure detection);
            // after a complete outage, the group formed again: ~66 s of refusals in a row.
            .refused_max = 120,
        };

        fn scenario(s: *System.Scenario) void {
            // Faults in bursts with quiet stretches between them (elections, rejoins and
            // distributed recovery take seconds each).
            s.pacing = .{ .active_ms_max = 10_000, .quiet_ms_max = 30_000 };
            s.setup("group", group);
            s.parallel_driver("append", append);
            s.finally("final reads", final_reads);
        }

        /// Three members online, then the database and the schema, through the primary.
        fn group(context: *System.Context) !void {
            _ = try sdk.retry(setup_attempts_max, 500, group_formed, .{context});
            _ = try sdk.retry(schema_attempts_max, 200, database_on_primary, .{context});
            const all = addresses(context);
            _ = try sdk.retry(schema_attempts_max, 200, schema_anywhere, .{&all});
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

        /// The schema through whichever member takes writes (the others refuse: read only).
        fn schema_anywhere(all: *const [3][4]u8) !void {
            for (all) |address| {
                if (sql_append.schema_create(address, options)) |_| return else |_| {}
            }
            return error.NoPrimary;
        }
    };
}

fn addresses(context: *System.Context) [3][4]u8 {
    return .{ context.nodes.n1.address, context.nodes.n2.address, context.nodes.n3.address };
}

fn group_formed(context: *System.Context) !void {
    var buffer: [256]u8 = undefined;
    const result = try context.nodes.n1.exec_output(&.{
        "mysql",                                                                                           "-uroot", "-N", "-s", "-e",
        "SELECT COUNT(*) FROM performance_schema.replication_group_members WHERE MEMBER_STATE = 'ONLINE'",
    }, &buffer);
    if (result.status != 0) return error.NotFormed;
    if (!std.mem.eql(u8, std.mem.trim(u8, result.output, " \t\r\n"), "3")) return error.NotFormed;
}

/// The database, on the member that takes writes (replicated to the others by the group).
fn database_on_primary(context: *System.Context) !void {
    var buffer: [256]u8 = undefined;
    inline for (node_names) |name| {
        const node = &@field(context.nodes, name);
        if (node.exec_output(&.{ "mysql", "-uroot", "-N", "-s", "-e", "SELECT @@global.super_read_only" }, &buffer)) |result| {
            if (result.status == 0 and std.mem.eql(u8, std.mem.trim(u8, result.output, " \t\r\n"), "0")) {
                const made = try node.exec_output(&.{ "mysql", "-uroot", "-e", "CREATE DATABASE IF NOT EXISTS jepsen" }, &buffer);
                if (made.status == 0) return;
            }
        } else |_| {}
    }
    return error.NoPrimary;
}
