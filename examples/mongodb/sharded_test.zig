// SPDX-License-Identifier: MIT
//! Example test program: a sharded MongoDB cluster as Jepsen's analysis of 4.2.6 ran it
//! (jepsen-io/mongodb): a config server replica set and two shards, each three nodes, the
//! collection sharded by hashed `_id` in seven initial chunks, clients through mongos. Jepsen's
//! list-append workload: transactions of appends (`$push`, upsert) and reads by `_id` at snapshot
//! read concern and majority write concern, run the way the drivers' `withTransaction` runs them:
//! a commit with no clear outcome is retried (with the router's recovery token, on any router),
//! and a transaction the server reports aborted (TransientTransactionError) is run again.
//!
//! Jepsen saw duplicated effects, read skew and cyclic information flow; MongoDB traced them to
//! SERVER-48307 (fixed in 4.2.8): a transaction writing to one shard and reading from another,
//! whose commit is retried after a failover of a shard it only read from, is reported aborted
//! though it committed, and the driver runs it again. Elle checks every timeline's history for
//! snapshot isolation: a transaction applied twice shows as a duplicated element.
//!
//!   determinismo explore ... --program zig-out/bin/mongodb-sharded-test --profile jepsen \
//!     --scenario append --memory-mib 8192
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");
const Mongo = @import("client.zig");
const bson = Mongo.bson;

const Nodes = struct {
    cfg1: sdk.Node,
    cfg2: sdk.Node,
    cfg3: sdk.Node,
    s1a: sdk.Node,
    s1b: sdk.Node,
    s1c: sdk.Node,
    s2a: sdk.Node,
    s2b: sdk.Node,
    s2c: sdk.Node,
    r1: sdk.Node,
    r2: sdk.Node,
    r3: sdk.Node,
};
const System = sdk.System(Nodes);

const ReplicaSet = struct { name: []const u8, members: [3][]const u8, config_server: bool };
const config_set: ReplicaSet = .{ .name = "rs_config", .members = .{ "cfg1", "cfg2", "cfg3" }, .config_server = true };
const shards = [_]ReplicaSet{
    .{ .name = "rs_shard1", .members = .{ "s1a", "s1b", "s1c" }, .config_server = false },
    .{ .name = "rs_shard2", .members = .{ "s2a", "s2b", "s2c" }, .config_server = false },
};
const router_names = [_][]const u8{ "r1", "r2", "r3" };
const port = 27017;
const database = "jepsendb";
const collection = "jepsencoll";
const image = "docker.io/library/mongo:9.0.4";
const image_jepsen = "docker.io/library/mongo:4.2.6";

const setup_attempts_max = 600;
const transactions_per_driver = 15;
const timeout_ms = 10_000;
const mops_max = 4;
const window_s = 10;
const keys_window = 4;
const command_size_max = 2048;
const token_size_max = 512;
/// withTransaction's retries, bounded: whole transactions, and commits of one.
const attempts_max = 5;
const commit_attempts_max = 5;
/// Error codes after which a command certainly did not happen: not the primary (10107, 13435,
/// 13436), no such transaction (251), a write conflict (112), a duplicate key (11000), the
/// primary stepping down before it ran (189: PrimarySteppedDown).
const definite_codes = [_]i64{ 10107, 13435, 13436, 251, 112, 11000, 189 };

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .append = append_scenario },
        .checks = .{ .elle = sdk.elle.check(.{ .consistency = "snapshot-isolation" }) },
    });
}

/// `jepsen`: 4.2.6, the version of Jepsen's analysis (2020). `default`: 9.0.4.
fn describe(d: *System.Describe) !void {
    inline for (.{ .{ "default", image }, .{ "jepsen", image_jepsen } }) |entry| {
        const profile = try d.profile(entry[0]);
        inline for (.{config_set} ++ shards) |set| {
            inline for (set.members) |name| {
                profile.node(@field(System.Name, name), .{
                    .image = entry[1],
                    .command = &.{
                        "mongod",        if (set.config_server) "--configsvr" else "--shardsvr",
                        "--replSet",     set.name,
                        "--bind_ip_all", "--port",
                        "27017",
                        // Nine share the machine: a small cache each (by default half of it).
                                "--wiredTigerCacheSizeGB",
                        "0.25",
                    },
                    .ready = .{ .tcp = port },
                    .faults = .{ .restart = true, .crash = true, .stop = true },
                });
            }
        }
        inline for (router_names) |name| {
            profile.node(@field(System.Name, name), .{
                .image = entry[1],
                .command = &.{
                    "mongos",        "--configdb", "rs_config/cfg1:27017,cfg2:27017,cfg3:27017",
                    "--bind_ip_all", "--port",     "27017",
                },
                // Not ready until the config servers form a replica set: the setup does that.
                .faults = .{ .restart = true, .crash = true },
            });
        }
    }
}

fn append_scenario(s: *System.Scenario) void {
    s.setup("cluster", cluster_setup);
    s.parallel_driver("append", append);
}

fn address_of(context: *System.Context, name: []const u8) [4]u8 {
    inline for (comptime std.meta.fieldNames(Nodes)) |field| {
        if (std.mem.eql(u8, field, name)) return @field(context.nodes, field).address;
    }
    unreachable;
}

fn routers(context: *System.Context) [router_names.len][4]u8 {
    var addresses: [router_names.len][4]u8 = undefined;
    for (router_names, &addresses) |name, *address| address.* = address_of(context, name);
    return addresses;
}

// Setup -----------------------------------------------------------------------------------------

/// The replica sets, then the shards added through a router, then the collection sharded.
fn cluster_setup(context: *System.Context) !void {
    _ = try sdk.retry(setup_attempts_max, 200, initiate, .{ address_of(context, config_set.members[0]), &config_set });
    for (&shards) |*set| {
        _ = try sdk.retry(setup_attempts_max, 200, initiate, .{ address_of(context, set.members[0]), set });
    }
    const all = routers(context);
    for (&shards) |*set| _ = try sdk.retry(setup_attempts_max, 200, shard_add, .{ &all, set });
    _ = try sdk.retry(setup_attempts_max, 200, collection_shard, .{&all});
    // Every router knows the sharded collection before the drivers start.
    for (all) |address| _ = try sdk.retry(setup_attempts_max, 200, collection_read, .{address});
}

/// Jepsen's replica set: fast heartbeats and elections, priorities 3, 2, 1.
fn initiate(address: [4]u8, set: *const ReplicaSet) !void {
    var buffer: [command_size_max]u8 = undefined;
    var builder: bson.Builder = .init(&buffer);
    builder.document("replSetInitiate");
    builder.string("_id", set.name);
    if (set.config_server) builder.boolean("configsvr", true);
    builder.document("settings");
    // Below the election timeout: newer versions refuse 1 s elections with the default 2 s
    // heartbeat interval (4.2 did not check).
    builder.int32("heartbeatIntervalMillis", 500);
    builder.int32("heartbeatTimeoutSecs", 1);
    builder.int32("electionTimeoutMillis", 1000);
    builder.int32("catchUpTimeoutMillis", 1000);
    builder.int32("catchUpTakeoverDelayMillis", 3000);
    builder.close();
    builder.array("members");
    for (set.members, 0..) |name, position| {
        var index: [10]u8 = undefined;
        var host: [32]u8 = undefined;
        builder.document(bson.index(&index, position));
        builder.int32("_id", @intCast(position));
        builder.string("host", std.fmt.bufPrint(&host, "{s}:{d}", .{ name, port }) catch unreachable);
        builder.int32("priority", @intCast(set.members.len - position));
        builder.close();
    }
    builder.close();
    builder.close();
    builder.string("$db", "admin");
    // 23: already initialized.
    return admin_command(address, try builder.finish(), "replSetInitiate", &.{23});
}

fn shard_add(all: *const [router_names.len][4]u8, set: *const ReplicaSet) !void {
    var hosts: [128]u8 = undefined;
    const seed = std.fmt.bufPrint(&hosts, "{s}/{s}:{d},{s}:{d},{s}:{d}", .{
        set.name, set.members[0], port, set.members[1], port, set.members[2], port,
    }) catch unreachable;
    var buffer: [command_size_max]u8 = undefined;
    var builder: bson.Builder = .init(&buffer);
    builder.string("addShard", seed);
    builder.string("name", set.name);
    builder.string("$db", "admin");
    return admin_command(all[sdk.random_below(all.len)], try builder.finish(), "addShard", &.{});
}

fn collection_shard(all: *const [router_names.len][4]u8) !void {
    const address = all[sdk.random_below(all.len)];
    var buffer: [command_size_max]u8 = undefined;
    var builder: bson.Builder = .init(&buffer);
    builder.string("enableSharding", database);
    builder.string("$db", "admin");
    // 23: already enabled.
    try admin_command(address, try builder.finish(), "enableSharding", &.{23});
    builder = .init(&buffer);
    builder.string("shardCollection", database ++ "." ++ collection);
    builder.document("key");
    builder.string("_id", "hashed");
    builder.close();
    builder.int32("numInitialChunks", 7);
    builder.string("$db", "admin");
    return admin_command(address, try builder.finish(), "shardCollection", &.{});
}

fn collection_read(address: [4]u8) !void {
    var connection: Mongo = undefined;
    try connection.open(address, port, .{ .timeout_ms = timeout_ms });
    defer connection.close();
    var buffer: [command_size_max]u8 = undefined;
    var builder: bson.Builder = .init(&buffer);
    builder.string("find", collection);
    builder.int32("limit", 1);
    builder.string("$db", database);
    const reply = try connection.command(try builder.finish());
    if (!Mongo.ok(reply)) return error.NotReadable;
}

/// Runs a setup command; done when it succeeds, says it was done already ("already" in its
/// message, or one of `done_codes`).
fn admin_command(address: [4]u8, document: []const u8, name: []const u8, done_codes: []const i64) !void {
    var connection: Mongo = undefined;
    try connection.open(address, port, .{ .timeout_ms = timeout_ms });
    defer connection.close();
    const reply = try connection.command(document);
    if (Mongo.ok(reply)) return;
    if (std.mem.indexOfScalar(i64, done_codes, Mongo.code(reply)) != null) return;
    if (std.mem.indexOf(u8, Mongo.message(reply), "already") != null) return;
    sdk.event("mongo_error", .{ .command = name, .code = Mongo.code(reply), .message = Mongo.message(reply) });
    return error.Refused;
}

// The workload ----------------------------------------------------------------------------------

const Mop = struct { append: bool, key: u64, value: u64 };
const Outcome = enum { committed, not_committed, unknown };

fn append(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const all = routers(context);
    const history: sdk.elle.History = .{};
    var id: u64 = undefined;
    sdk.random_bytes(std.mem.asBytes(&id));
    id &= 0xffff_ffff;
    var process = sdk.elle.process_new();
    for (0..transactions_per_driver) |sequence| {
        var mops: [mops_max]Mop = undefined;
        const count = draw(&mops, id, sequence);
        try history.invoke(arena, process, try elle_mops(arena, mops[0..count], null));
        var reads: [mops_max]?[]const u64 = @splat(null);
        const outcome = with_transaction(arena, &all, mops[0..count], &reads);
        switch (outcome) {
            .committed => try history.ok(arena, process, try elle_mops(arena, mops[0..count], &reads)),
            .not_committed => try history.fail(arena, process, try elle_mops(arena, mops[0..count], null)),
            .unknown => {
                try history.info(arena, process, try elle_mops(arena, mops[0..count], null));
                sdk.sometimes(true, "a transaction's outcome is unknown", .{});
                process = sdk.elle.process_new(); // Elle's rule: one operation at a time.
            },
        }
    }
}

fn draw(mops: *[mops_max]Mop, id: u64, sequence: u64) u32 {
    const count: u32 = @intCast(1 + sdk.random_below(mops_max));
    const base = monotonic_ns() / std.time.ns_per_s / window_s;
    for (mops[0..count], 0..) |*mop, position| {
        mop.* = .{
            .append = sdk.random_below(2) == 0,
            .key = base + sdk.random_below(keys_window),
            // Unique per key: the driver, its transaction, the micro-operation.
            .value = (id << 20) | (sequence << 4) | position,
        };
    }
    return count;
}

/// A session's transaction: its number, and the router's recovery token from its last reply
/// (a commit retried on another router finds the decision with it).
const Transaction = struct {
    lsid: [16]u8,
    number: i64 = 0,
    started: bool = false,
    token: [token_size_max]u8 = undefined,
    token_size: u32 = 0,

    fn begin(transaction: *Transaction) void {
        transaction.number += 1;
        transaction.started = false;
        transaction.token_size = 0;
    }

    fn fields(transaction: *Transaction, builder: *bson.Builder) void {
        builder.document("lsid");
        builder.binary("id", bson.binary_uuid, &transaction.lsid);
        builder.close();
        builder.int64("txnNumber", transaction.number);
        builder.boolean("autocommit", false);
        if (transaction.started) return;
        transaction.started = true;
        builder.boolean("startTransaction", true);
        builder.document("readConcern");
        builder.string("level", "snapshot");
        builder.close();
    }

    fn token_keep(transaction: *Transaction, reply: []const u8) void {
        const element = (bson.get(reply, "recoveryToken") catch return) orelse return;
        const token = element.nested() orelse return;
        if (token.len > token_size_max) return;
        @memcpy(transaction.token[0..token.len], token);
        transaction.token_size = @intCast(token.len);
    }
};

/// As the drivers' withTransaction: the transaction on a router; a commit without a clear
/// outcome retried (any router, the recovery token, majority write concern); the whole
/// transaction again when the server says it aborted (TransientTransactionError).
fn with_transaction(
    arena: std.mem.Allocator,
    all: *const [router_names.len][4]u8,
    mops: []const Mop,
    reads: *[mops_max]?[]const u64,
) Outcome {
    var transaction: Transaction = .{ .lsid = undefined };
    sdk.random_bytes(&transaction.lsid);
    var outcome: Outcome = .not_committed;
    for (0..attempts_max) |attempt| {
        if (attempt > 0) sdk.sometimes(true, "a transaction ran again after a transient error", .{});
        transaction.begin();
        reads.* = @splat(null);
        outcome = switch (attempt_run(arena, all, &transaction, mops, reads)) {
            .committed => return .committed,
            .unknown => return .unknown,
            .not_committed => return .not_committed,
            .transient => continue,
        };
    }
    // Every attempt aborted, as the server said.
    return outcome;
}

const Attempt = enum { committed, not_committed, unknown, transient };

fn attempt_run(
    arena: std.mem.Allocator,
    all: *const [router_names.len][4]u8,
    transaction: *Transaction,
    mops: []const Mop,
    reads: *[mops_max]?[]const u64,
) Attempt {
    var connection: Mongo = undefined;
    connection.open(all[sdk.random_below(all.len)], port, .{ .timeout_ms = timeout_ms }) catch return .transient;
    for (mops, 0..) |mop, position| {
        const done = if (mop.append)
            update(&connection, mop, transaction)
        else
            find(arena, &connection, mop, transaction, &reads[position]);
        done catch |err| {
            abort(&connection, transaction);
            connection.close();
            // A lost connection mid-transaction is transient to drivers; nothing was committed.
            return if (err == error.Transient) .transient else .not_committed;
        };
    }
    var commit_attempt: u32 = 0;
    while (commit_attempt < commit_attempts_max) : (commit_attempt += 1) {
        if (commit_attempt > 0) {
            sdk.sometimes(true, "a commit was retried", .{});
            connection.close();
            connection.open(all[sdk.random_below(all.len)], port, .{ .timeout_ms = timeout_ms }) catch continue;
        }
        var buffer: [command_size_max]u8 = undefined;
        var builder: bson.Builder = .init(&buffer);
        builder.int32("commitTransaction", 1);
        transaction.fields(&builder);
        builder.document("writeConcern");
        builder.string("w", "majority");
        if (commit_attempt > 0) builder.int32("wtimeout", 10_000); // As drivers retry commits.
        builder.close();
        if (transaction.token_size > 0) builder.embedded("recoveryToken", transaction.token[0..transaction.token_size]);
        builder.string("$db", "admin");
        const reply = connection.command(builder.finish() catch unreachable) catch continue;
        if (Mongo.ok(reply)) {
            if (Mongo.write_error(reply).concern) continue; // Committed, perhaps not durably.
            connection.close();
            return .committed;
        }
        if (Mongo.labeled(reply, "UnknownTransactionCommitResult")) continue;
        connection.close();
        if (Mongo.labeled(reply, "TransientTransactionError")) {
            sdk.event("mongo_error", .{ .command = "commitTransaction", .code = Mongo.code(reply), .message = Mongo.message(reply) });
            sdk.sometimes(true, "a commit was reported aborted", .{ .code = Mongo.code(reply) });
            return .transient;
        }
        sdk.event("mongo_error", .{ .command = "commitTransaction", .code = Mongo.code(reply), .message = Mongo.message(reply) });
        return .unknown;
    }
    connection.close();
    return .unknown;
}

const CommandError = error{ Definite, Transient };

fn update(connection: *Mongo, mop: Mop, transaction: *Transaction) CommandError!void {
    var buffer: [command_size_max]u8 = undefined;
    var builder: bson.Builder = .init(&buffer);
    builder.string("update", collection);
    builder.array("updates");
    var index: [10]u8 = undefined;
    builder.document(bson.index(&index, 0));
    builder.document("q");
    builder.int64("_id", @intCast(mop.key));
    builder.close();
    builder.document("u");
    builder.document("$push");
    builder.int64("value", @intCast(mop.value));
    builder.close();
    builder.close();
    builder.boolean("upsert", true);
    builder.close();
    builder.close();
    transaction.fields(&builder);
    builder.string("$db", database);
    const reply = connection.command(builder.finish() catch unreachable) catch return error.Transient;
    transaction.token_keep(reply);
    if (!Mongo.ok(reply)) return command_failed(reply, "update");
    const failed = Mongo.write_error(reply);
    if (failed.code == 0) return;
    sdk.event("mongo_write_error", .{ .code = failed.code, .concern = failed.concern });
    if (Mongo.labeled(reply, "TransientTransactionError")) return error.Transient;
    return error.Definite;
}

fn find(
    arena: std.mem.Allocator,
    connection: *Mongo,
    mop: Mop,
    transaction: *Transaction,
    read: *?[]const u64,
) CommandError!void {
    var buffer: [command_size_max]u8 = undefined;
    var builder: bson.Builder = .init(&buffer);
    builder.string("find", collection);
    builder.document("filter");
    builder.int64("_id", @intCast(mop.key));
    builder.close();
    builder.int32("limit", 1);
    builder.boolean("singleBatch", true);
    transaction.fields(&builder);
    builder.string("$db", database);
    const reply = connection.command(builder.finish() catch unreachable) catch return error.Transient;
    transaction.token_keep(reply);
    if (!Mongo.ok(reply)) return command_failed(reply, "find");
    read.* = list_of(arena, reply) catch return error.Definite;
}

/// Inside a transaction, a failed command aborts it: run again when the server says so.
fn command_failed(reply: []const u8, command: []const u8) CommandError {
    sdk.event("mongo_error", .{ .command = command, .code = Mongo.code(reply), .message = Mongo.message(reply) });
    return if (Mongo.labeled(reply, "TransientTransactionError")) error.Transient else error.Definite;
}

/// The values of the document a find returned (none: an empty list).
fn list_of(arena: std.mem.Allocator, reply: []const u8) ![]const u64 {
    const cursor = (try bson.get(reply, "cursor") orelse return error.BadReply).nested() orelse return error.BadReply;
    const batch = (try bson.get(cursor, "firstBatch") orelse return error.BadReply).nested() orelse return error.BadReply;
    var documents = try bson.Iterator.init(batch);
    const document = ((try documents.next()) orelse return &.{}).nested() orelse return error.BadReply;
    const value = (try bson.get(document, "value") orelse return &.{}).nested() orelse return error.BadReply;
    var entries = try bson.Iterator.init(value);
    var list: std.ArrayList(u64) = .empty;
    while (try entries.next()) |entry| try list.append(arena, @intCast(entry.integer() orelse return error.BadReply));
    return list.items;
}

fn abort(connection: *Mongo, transaction: *Transaction) void {
    if (!transaction.started) return;
    var buffer: [command_size_max]u8 = undefined;
    var builder: bson.Builder = .init(&buffer);
    builder.int32("abortTransaction", 1);
    transaction.fields(&builder);
    if (transaction.token_size > 0) builder.embedded("recoveryToken", transaction.token[0..transaction.token_size]);
    builder.string("$db", "admin");
    _ = connection.command(builder.finish() catch unreachable) catch {};
}

fn elle_mops(arena: std.mem.Allocator, mops: []const Mop, reads: ?*const [mops_max]?[]const u64) ![]const sdk.elle.Mop {
    const out = try arena.alloc(sdk.elle.Mop, mops.len);
    for (mops, out, 0..) |mop, *elle_mop, position| {
        elle_mop.* = if (mop.append)
            .{ .append = .{ .key = mop.key, .value = mop.value } }
        else
            .{ .read = .{ .key = mop.key, .list = if (reads) |known| known[position] orelse &.{} else null } };
    }
    return out;
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

test "a recovery token is kept and sent back as it came" {
    var buffer: [256]u8 = undefined;
    var builder: bson.Builder = .init(&buffer);
    builder.double("ok", 1);
    builder.document("recoveryToken");
    builder.string("recoveryShardId", "rs_shard2");
    builder.close();
    const reply = try builder.finish();
    var transaction: Transaction = .{ .lsid = @splat(0) };
    transaction.begin();
    transaction.token_keep(reply);
    try std.testing.expect(transaction.token_size > 0);
    var commit_buffer: [512]u8 = undefined;
    var commit: bson.Builder = .init(&commit_buffer);
    commit.int32("commitTransaction", 1);
    commit.embedded("recoveryToken", transaction.token[0..transaction.token_size]);
    const document = try commit.finish();
    const token = (try bson.get(document, "recoveryToken")).?.nested().?;
    const shard = (try bson.get(token, "recoveryShardId")).?.text().?;
    try std.testing.expectEqualStrings("rs_shard2", shard);
}
