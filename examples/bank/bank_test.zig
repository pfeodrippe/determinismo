// SPDX-License-Identifier: MIT
//! Example test program: a bank kept in Redis, with a deliberate concurrency bug.
//!
//! Transfers read both balances with separate GETs and then write both in one MULTI/EXEC. The
//! writes are atomic, the reads are not checked (no WATCH), so two concurrent transfers touching
//! the same account can lose an update and money appears or disappears. Whether that happens
//! depends on where the guest scheduler preempts a transfer between its reads and its writes,
//! which is exactly what determinismo explores and then replays.
//!
//! The system: one Redis node from the official image. Profiles:
//!   default    Redis may be paused, isolated, or cut off from the tests
//!   restarts   also restarts, with an append-only file so the data survives them
//!   built      Redis built from examples/bank/redis/Dockerfile
//! Scenarios, both from the same function with a different account count:
//!   bank       10 accounts
//!   bank_hot   2 accounts: every transfer collides
const std = @import("std");
const assert = std.debug.assert;
const sdk = @import("determinismo");
const Connection = @import("resp");

const Nodes = struct { redis: sdk.Node };
const System = sdk.System(Nodes);

const redis_image = "docker.io/library/redis:7.4-alpine";
const redis_port = 6379;
const balance_initial = 100;
const transfers_per_driver = 25;
const amount_max = 50;
const audit_attempts_max = 200;

comptime {
    assert(amount_max < balance_initial);
}

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .bank = Bank(10).scenario, .bank_hot = Bank(2).scenario },
    });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.redis, .{
        .image = redis_image,
        .command = &.{ "redis-server", "--save", "", "--appendonly", "no" },
        .ready = .{ .tcp = redis_port },
    });
    const restarts = try d.profile("restarts");
    restarts.node(.redis, .{
        .image = redis_image,
        .command = &.{
            "redis-server", "--save", "", "--appendonly", "yes", "--appendfsync", "always",
        },
        .ready = .{ .tcp = redis_port },
        .faults = .{ .restart = true },
    });
    // The same Redis, built from a Dockerfile (paths are relative to where determinismo runs).
    const built = try d.profile("built");
    built.node(.redis, .{
        .build = .{ .context = "examples/bank/redis" },
        .ready = .{ .tcp = redis_port },
    });
}

/// Everything about a bank of `account_count` accounts: its scenario and its commands.
fn Bank(comptime account_count: u32) type {
    comptime assert(account_count >= 2);
    comptime assert(account_count <= Connection.array_count_max);
    return struct {
        const balance_total = account_count * balance_initial;

        fn scenario(s: *System.Scenario) void {
            s.setup("accounts", accounts);
            s.parallel_driver("transfer", transfer_many);
            s.anytime("audit_live", audit_anytime);
            s.finally("audit_final", audit_finally);
        }

        fn accounts(context: *System.Context) !void {
            var connection: Connection = undefined;
            try connection.open(context.nodes.redis.address, redis_port);
            defer connection.close();
            for (0..account_count) |account| {
                var key_buffer: [16]u8 = undefined;
                _ = try connection.call(&.{ "SET", account_key(&key_buffer, account), "100" });
            }
        }

        fn transfer_many(context: *System.Context) !void {
            var connection: Connection = undefined;
            connection.open(context.nodes.redis.address, redis_port) catch |err| {
                return unavailable(err);
            };
            defer connection.close();
            for (0..transfers_per_driver) |_| {
                transfer(&connection) catch |err| return unavailable(err);
            }
        }

        fn transfer(connection: *Connection) !void {
            const source = sdk.random_below(account_count);
            const target = (source + 1 + sdk.random_below(account_count - 1)) % account_count;
            assert(source != target);
            const amount: i64 = @intCast(1 + sdk.random_below(amount_max));

            var source_key_buffer: [16]u8 = undefined;
            var target_key_buffer: [16]u8 = undefined;
            const source_key = account_key(&source_key_buffer, source);
            const target_key = account_key(&target_key_buffer, target);
            // The bug: these reads are not protected by WATCH, so they can be stale by the EXEC.
            const source_balance = try read_balance(connection, source_key);
            const target_balance = try read_balance(connection, target_key);
            if (source_balance < amount) {
                const details = .{ .amount = amount };
                sdk.sometimes(true, "transfer rejected for insufficient funds", details);
                return;
            }
            var source_value_buffer: [24]u8 = undefined;
            var target_value_buffer: [24]u8 = undefined;
            const source_value = try print_balance(&source_value_buffer, source_balance - amount);
            const target_value = try print_balance(&target_value_buffer, target_balance + amount);
            _ = try connection.call(&.{"MULTI"});
            _ = try connection.call(&.{ "SET", source_key, source_value });
            _ = try connection.call(&.{ "SET", target_key, target_value });
            var exec_replies: [2]?[]const u8 = undefined;
            const exec_count = try connection.call_array(&.{"EXEC"}, &exec_replies);
            assert(exec_count == 2); // Both SETs ran: nothing was WATCHed, so EXEC never aborts.
            sdk.reachable("transfer committed", .{ .amount = amount });
        }

        fn audit_anytime(context: *System.Context) !void {
            audit(context, "anytime") catch |err| return unavailable(err);
        }

        /// Faults are over by now: Redis must answer again, soon.
        fn audit_finally(context: *System.Context) !void {
            for (0..audit_attempts_max) |_| {
                audit(context, "finally") catch |err| {
                    if (!Connection.is_unavailable(err)) return err;
                    sleep_ms(50);
                    continue;
                };
                return;
            }
            sdk.assert_unreachable("redis answers once faults stop", .{});
            return error.RedisUnavailable;
        }

        fn audit(context: *System.Context, comptime phase: []const u8) !void {
            var connection: Connection = undefined;
            try connection.open(context.nodes.redis.address, redis_port);
            defer connection.close();
            var keys_buffer: [account_count][16]u8 = undefined;
            var command: [account_count + 1][]const u8 = undefined;
            command[0] = "MGET";
            for (0..account_count) |account| {
                command[account + 1] = account_key(&keys_buffer[account], account);
            }
            var values: [account_count]?[]const u8 = undefined;
            const count = try connection.call_array(&command, &values);
            assert(count == account_count);
            var total: i64 = 0;
            for (values) |value| {
                const balance = value orelse return error.MissingAccount;
                total += try std.fmt.parseInt(i64, balance, 10);
            }
            const details = .{ .total = total, .phase = phase, .accounts = account_count };
            sdk.always(total == balance_total, "total balance is conserved", details);
            sdk.sometimes(true, phase ++ " audit ran", .{});
        }

        fn account_key(buffer: *[16]u8, account: u64) []const u8 {
            assert(account < account_count);
            return std.fmt.bufPrint(buffer, "account:{d}", .{account}) catch unreachable;
        }
    };
}

/// Faults make Redis unreachable for a while: a driver that meets that gives up, and we note it.
fn unavailable(err: anyerror) !void {
    if (!Connection.is_unavailable(err)) return err;
    sdk.sometimes(true, "redis was unavailable to a test command", .{ .err = @errorName(err) });
}

fn sleep_ms(duration_ms: u64) void {
    const request = std.os.linux.timespec{
        .sec = @intCast(duration_ms / std.time.ms_per_s),
        .nsec = @intCast((duration_ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    _ = std.os.linux.nanosleep(&request, null);
}

fn read_balance(connection: *Connection, key: []const u8) !i64 {
    const reply = try connection.call(&.{ "GET", key });
    if (reply != .bulk) return error.BadReply;
    return std.fmt.parseInt(i64, reply.bulk orelse return error.MissingAccount, 10);
}

fn print_balance(buffer: *[24]u8, balance: i64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d}", .{balance});
}
