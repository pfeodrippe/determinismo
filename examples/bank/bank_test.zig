// SPDX-License-Identifier: MIT
//! Example test: a bank kept in Redis, with a deliberate concurrency bug.
//!
//! Transfers read both balances with separate GETs and then write both in one MULTI/EXEC. The
//! writes are atomic, the reads are not checked (no WATCH), so two concurrent transfers touching
//! the same account can lose an update and money appears or disappears. Whether that happens
//! depends on where the guest scheduler preempts a transfer between its reads and its writes,
//! which is exactly what determinismo explores and then replays.
//!
//! Commands (Antithesis test-template conventions, see sdk/zig/determinismo.zig):
//!   setup                       create the accounts, then signal setup_complete
//!   parallel_driver_transfer    random transfers between random accounts
//!   anytime_audit               the total must always equal the initial total
//!   finally_audit               same check once all drivers are done
const std = @import("std");
const assert = std.debug.assert;
const sdk = @import("determinismo");
const Connection = @import("resp.zig");

const account_count = 10;
const balance_initial = 100;
const balance_total = account_count * balance_initial;
const transfers_per_driver = 25;
const amount_max = 50;
const redis_port = 6379;

comptime {
    assert(account_count <= Connection.array_count_max);
    assert(amount_max < balance_initial);
}

const Test = struct {
    pub fn setup(_: std.process.Init) !void {
        var connection: Connection = undefined;
        try connection.open(redis_port);
        defer connection.close();
        for (0..account_count) |account| {
            var key_buffer: [16]u8 = undefined;
            _ = try connection.call(&.{ "SET", account_key(&key_buffer, account), "100" });
        }
        sdk.setup_complete(.{ .accounts = account_count, .total = balance_total });
    }

    pub fn parallel_driver_transfer(_: std.process.Init) !void {
        var connection: Connection = undefined;
        try connection.open(redis_port);
        defer connection.close();
        for (0..transfers_per_driver) |_| try transfer(&connection);
    }

    pub fn anytime_audit(_: std.process.Init) !void {
        try audit("anytime");
    }

    pub fn finally_audit(_: std.process.Init) !void {
        try audit("finally");
    }
};

pub fn main(init: std.process.Init) !void {
    return sdk.run(Test, init);
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
        sdk.sometimes(true, "transfer rejected for insufficient funds", .{ .amount = amount });
        return;
    }
    var source_value_buffer: [24]u8 = undefined;
    var target_value_buffer: [24]u8 = undefined;
    const source_balance_new = source_balance - amount;
    const target_balance_new = target_balance + amount;
    const source_value = try std.fmt.bufPrint(&source_value_buffer, "{d}", .{source_balance_new});
    const target_value = try std.fmt.bufPrint(&target_value_buffer, "{d}", .{target_balance_new});
    _ = try connection.call(&.{"MULTI"});
    _ = try connection.call(&.{ "SET", source_key, source_value });
    _ = try connection.call(&.{ "SET", target_key, target_value });
    var exec_replies: [2]?[]const u8 = undefined;
    const exec_count = try connection.call_array(&.{"EXEC"}, &exec_replies);
    assert(exec_count == 2); // Both SETs ran: nothing was WATCHed, so EXEC never aborts.
    sdk.reachable("transfer committed", .{ .amount = amount });
}

fn audit(comptime phase: []const u8) !void {
    var connection: Connection = undefined;
    try connection.open(redis_port);
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
    const details = .{ .total = total, .phase = phase };
    sdk.always(total == balance_total, "total balance is conserved", details);
    sdk.sometimes(true, phase ++ " audit ran", .{});
}

fn read_balance(connection: *Connection, key: []const u8) !i64 {
    const reply = try connection.call(&.{ "GET", key });
    if (reply != .bulk) return error.BadReply;
    return std.fmt.parseInt(i64, reply.bulk orelse return error.MissingAccount, 10);
}

fn account_key(buffer: *[16]u8, account: u64) []const u8 {
    assert(account < account_count);
    return std.fmt.bufPrint(buffer, "account:{d}", .{account}) catch unreachable;
}
