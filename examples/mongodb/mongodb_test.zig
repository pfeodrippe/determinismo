// SPDX-License-Identifier: MIT
//! Example test program: MongoDB 9.0.4, a three-node replica set, as Jepsen's MongoDB test runs it
//! (jepsen-io/mongodb: replica set `rs_jepsen` with 1 s heartbeat timeouts and elections,
//! priorities 3, 2, 1, the journal on), and its list-append workload: one document per key in
//! jepsendb.jepsencoll, appended with `$push` (upsert), read by `_id`; one operation alone at
//! majority read and write concern, longer ones in a transaction at snapshot read concern and
//! majority write concern. Jepsen's analysis of 4.2.6 (the `jepsen` profile) reported read skew,
//! cyclic information flow and duplicated effects in such transactions. Elle checks every
//! timeline's history for snapshot isolation, what MongoDB's transactions claim.
//!
//! Outcomes are the server's: a transaction it reports aborted (TransientTransactionError) is a
//! failure, so one that happened anyway shows as a read of an aborted write (G1a); one whose
//! commit has no clear answer (UnknownTransactionCommitResult, a write concern error, a lost
//! connection) may have happened.
//!
//!   determinismo explore ... --program zig-out/bin/mongodb-test --scenario append
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");
const Mongo = @import("client.zig");
const bson = Mongo.bson;

const Nodes = struct { n1: sdk.Node, n2: sdk.Node, n3: sdk.Node };
const System = sdk.System(Nodes);

const node_names = [_][]const u8{ "n1", "n2", "n3" };
const port = 27017;
const replica_set = "rs_jepsen";
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
const refused_max = 20;
const refused_pause_ms_min = 100;
const refused_pause_ms_max = 1000;
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

/// `default`: MongoDB 9.0.4. `jepsen`: 4.2.6, the version of Jepsen's analysis (2020), to measure
/// what determinismo finds blind of what Jepsen reported.
fn describe(d: *System.Describe) !void {
    inline for (.{ .{ "default", image }, .{ "jepsen", image_jepsen } }) |entry| {
        const profile = try d.profile(entry[0]);
        inline for (node_names) |name| {
            profile.node(@field(System.Name, name), .{
                .image = entry[1],
                .command = &.{
                    "mongod",                  "--replSet", replica_set, "--bind_ip_all", "--port", "27017",
                    // Three share the machine: a small cache each (by default half of it).
                    "--wiredTigerCacheSizeGB", "0.25",
                },
                .ready = .{ .tcp = port },
                .faults = .{ .restart = true, .crash = true, .stop = true },
            });
        }
    }
}

fn append_scenario(s: *System.Scenario) void {
    s.setup("replica_set", replica_set_setup);
    s.parallel_driver("append", append);
    s.finally("final reads", final_reads);
}

const Member = struct { name: []const u8, address: [4]u8 };

fn members(context: *System.Context) [3]Member {
    return .{
        .{ .name = "n1", .address = context.nodes.n1.address },
        .{ .name = "n2", .address = context.nodes.n2.address },
        .{ .name = "n3", .address = context.nodes.n3.address },
    };
}

// Setup -----------------------------------------------------------------------------------------

fn replica_set_setup(context: *System.Context) !void {
    const all = members(context);
    _ = try sdk.retry(setup_attempts_max, 200, initiate, .{all[0].address});
    _ = try sdk.retry(setup_attempts_max, 200, collection_create, .{&all});
}

/// Jepsen's replica set: fast heartbeats and elections, priorities 3, 2, 1.
fn initiate(address: [4]u8) !void {
    var connection: Mongo = undefined;
    try connection.open(address, port, .{ .timeout_ms = timeout_ms });
    defer connection.close();
    var buffer: [command_size_max]u8 = undefined;
    var builder: bson.Builder = .init(&buffer);
    builder.document("replSetInitiate");
    builder.string("_id", replica_set);
    builder.document("settings");
    // Below the election timeout: newer versions refuse Jepsen's 1 s elections with the default
    // 2 s heartbeat interval (4.2 did not check).
    builder.int32("heartbeatIntervalMillis", 500);
    builder.int32("heartbeatTimeoutSecs", 1);
    builder.int32("electionTimeoutMillis", 1000);
    builder.int32("catchUpTimeoutMillis", 1000);
    builder.int32("catchUpTakeoverDelayMillis", 3000);
    builder.close();
    builder.array("members");
    for (node_names, 0..) |name, position| {
        var index: [10]u8 = undefined;
        var host: [32]u8 = undefined;
        builder.document(bson.index(&index, position));
        builder.int32("_id", @intCast(position));
        builder.string("host", std.fmt.bufPrint(&host, "{s}:{d}", .{ name, port }) catch unreachable);
        builder.int32("priority", @intCast(node_names.len - position));
        builder.close();
    }
    builder.close();
    builder.close();
    builder.string("$db", "admin");
    const reply = try connection.command(try builder.finish());
    if (Mongo.ok(reply) or Mongo.code(reply) == 23) return; // 23: already initialized.
    sdk.event("mongo_error", .{ .command = "replSetInitiate", .code = Mongo.code(reply), .message = Mongo.message(reply) });
    return error.NotInitiated;
}

/// The collection, on the primary (transactions do not create collections).
fn collection_create(all: *const [3]Member) !void {
    var connection: Mongo = undefined;
    if (!try primary_connect(&connection, all, all[sdk.random_below(all.len)].address)) return error.NoPrimary;
    defer connection.close();
    var buffer: [command_size_max]u8 = undefined;
    var builder: bson.Builder = .init(&buffer);
    builder.string("create", collection);
    builder.document("writeConcern");
    builder.string("w", "majority");
    builder.close();
    builder.string("$db", database);
    const reply = try connection.command(try builder.finish());
    if (Mongo.ok(reply) or Mongo.code(reply) == 48) return; // 48: it exists.
    sdk.event("mongo_error", .{ .command = "create", .code = Mongo.code(reply), .message = Mongo.message(reply) });
    return error.NotCreated;
}

/// Connects to `address`, then to the primary it names if it is not one (as drivers follow the
/// replica set). Whether the connection is to the primary.
fn primary_connect(connection: *Mongo, all: *const [3]Member, address: [4]u8) !bool {
    try connection.open(address, port, .{ .timeout_ms = timeout_ms });
    var buffer: [command_size_max]u8 = undefined;
    var builder: bson.Builder = .init(&buffer);
    builder.int32("isMaster", 1);
    builder.string("$db", "admin");
    const reply = connection.command(try builder.finish()) catch |err| {
        connection.close();
        return err;
    };
    const master = bson.get(reply, "ismaster") catch null;
    if (master) |element| {
        if (element.truth() orelse false) return true;
    }
    const named = (bson.get(reply, "primary") catch null) orelse {
        connection.close();
        return false;
    };
    const primary = named.text() orelse "";
    const name = primary[0 .. std.mem.indexOfScalar(u8, primary, ':') orelse primary.len];
    connection.close();
    for (all) |member| {
        if (!std.mem.eql(u8, member.name, name)) continue;
        try connection.open(member.address, port, .{ .timeout_ms = timeout_ms });
        return true;
    }
    return false;
}

// The workload ----------------------------------------------------------------------------------

const Mop = struct { append: bool, key: u64, value: u64 };
const Outcome = enum { committed, not_committed, unknown };

fn append(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const all = members(context);
    const history: sdk.elle.History = .{};
    var id: u64 = undefined;
    sdk.random_bytes(std.mem.asBytes(&id));
    id &= 0xffff_ffff;
    var process = sdk.elle.process_new();
    var connection: Mongo = undefined;
    var connected = false;
    defer if (connected) connection.close();
    var refused: u32 = 0;
    var sequence: u64 = 0;
    while (sequence < transactions_per_driver) {
        if (!connected) {
            const address = all[sdk.random_below(all.len)].address;
            const primary = primary_connect(&connection, &all, address) catch |err| blk: {
                if (!Mongo.is_unavailable(err)) return err;
                break :blk false;
            };
            if (!primary) {
                // Down, cut off, electing: a while later, without spending a transaction.
                if (refused == 0) sdk.sometimes(true, "no primary answered a connection", .{});
                refused += 1;
                if (refused == refused_max) return;
                pause_ms(refused_pause_ms_min + sdk.random_below(refused_pause_ms_max - refused_pause_ms_min));
                continue;
            }
            connected = true;
        }
        var mops: [mops_max]Mop = undefined;
        const count = draw(&mops, id, sequence);
        try history.invoke(arena, process, try elle_mops(arena, mops[0..count], null));
        var reads: [mops_max]?[]const u64 = @splat(null);
        const outcome = run(arena, &connection, mops[0..count], &reads);
        switch (outcome) {
            .committed => try history.ok(arena, process, try elle_mops(arena, mops[0..count], &reads)),
            .not_committed => try history.fail(arena, process, try elle_mops(arena, mops[0..count], null)),
            .unknown => {
                try history.info(arena, process, try elle_mops(arena, mops[0..count], null));
                sdk.sometimes(true, "a write's outcome is unknown", .{});
                process = sdk.elle.process_new(); // Elle's rule: one operation at a time.
            },
        }
        if (outcome != .committed) {
            connection.close();
            connected = false;
        }
        sequence += 1;
    }
}

/// Once faults stop: every committed append in its key's document (sdk.elle.final_reads), read
/// from the primary at majority read concern.
fn final_reads(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    var reader: FinalReader = .{ .all = members(context) };
    defer reader.close();
    const history: sdk.elle.History = .{};
    try sdk.elle.final_reads(arena, &history, &reader);
}

/// Connections the final reads try (a pause after each that fails) before leaving the rest of
/// the keys unjudged.
const final_attempts_max = 60;
const final_pause_ms = 1000;

/// The final reads' connection: to the primary, found through a member drawn at random, reopened
/// after a read fails, until `final_attempts_max` attempts failed.
const FinalReader = struct {
    all: [3]Member,
    connection: Mongo = undefined,
    connected: bool = false,
    attempts: u32 = 0,

    pub fn read_list(reader: *FinalReader, arena: std.mem.Allocator, key: u64) ?[]const u64 {
        while (reader.attempts < final_attempts_max) {
            if (!reader.connected) {
                const address = reader.all[sdk.random_below(reader.all.len)].address;
                reader.connected = primary_connect(&reader.connection, &reader.all, address) catch false;
                if (!reader.connected) {
                    reader.attempts += 1;
                    pause_ms(final_pause_ms);
                    continue;
                }
            }
            var list: ?[]const u64 = null;
            find(arena, &reader.connection, .{ .append = false, .key = key, .value = 0 }, null, &list) catch {
                reader.close();
                reader.attempts += 1;
                pause_ms(final_pause_ms);
                continue;
            };
            return list orelse &.{};
        }
        return null;
    }

    fn close(reader: *FinalReader) void {
        if (reader.connected) reader.connection.close();
        reader.connected = false;
    }
};

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

/// A session's transaction: its id and number, sent with each of its commands.
const Transaction = struct {
    lsid: [16]u8,
    started: bool = false,

    fn fields(transaction: *Transaction, builder: *bson.Builder) void {
        builder.document("lsid");
        builder.binary("id", bson.binary_uuid, &transaction.lsid);
        builder.close();
        builder.int64("txnNumber", 1);
        builder.boolean("autocommit", false);
        if (transaction.started) return;
        transaction.started = true;
        builder.boolean("startTransaction", true);
        builder.document("readConcern");
        builder.string("level", "snapshot");
        builder.close();
    }
};

fn run(arena: std.mem.Allocator, connection: *Mongo, mops: []const Mop, reads: *[mops_max]?[]const u64) Outcome {
    if (mops.len == 1) return alone(arena, connection, mops[0], &reads[0]);
    var transaction: Transaction = .{ .lsid = undefined };
    sdk.random_bytes(&transaction.lsid);
    for (mops, 0..) |mop, position| {
        const done = if (mop.append)
            update(connection, mop, &transaction)
        else
            find(arena, connection, mop, &transaction, &reads[position]);
        done catch {
            abort(connection, &transaction);
            return .not_committed; // Never committed: no commit was sent.
        };
    }
    var buffer: [command_size_max]u8 = undefined;
    var builder: bson.Builder = .init(&buffer);
    builder.int32("commitTransaction", 1);
    transaction.fields(&builder);
    majority(&builder);
    builder.string("$db", "admin");
    const reply = connection.command(builder.finish() catch unreachable) catch return .unknown;
    if (Mongo.ok(reply)) return if (Mongo.write_error(reply).concern) .unknown else .committed;
    if (Mongo.labeled(reply, "UnknownTransactionCommitResult")) return .unknown;
    if (Mongo.labeled(reply, "TransientTransactionError")) return .not_committed;
    return outcome_of_error(reply, "commitTransaction");
}

/// One operation alone, outside a transaction: majority reads and writes.
fn alone(arena: std.mem.Allocator, connection: *Mongo, mop: Mop, read: *?[]const u64) Outcome {
    if (!mop.append) {
        find(arena, connection, mop, null, read) catch return .not_committed;
        return .committed;
    }
    update(connection, mop, null) catch |err| return switch (err) {
        error.Definite => .not_committed,
        else => .unknown,
    };
    return .committed;
}

const CommandError = error{ Definite, Unknown };

fn update(connection: *Mongo, mop: Mop, transaction: ?*Transaction) CommandError!void {
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
    if (transaction) |t| t.fields(&builder) else majority(&builder);
    builder.string("$db", database);
    const reply = connection.command(builder.finish() catch unreachable) catch return error.Unknown;
    if (!Mongo.ok(reply)) {
        return if (outcome_of_error(reply, "update") == .not_committed) error.Definite else error.Unknown;
    }
    const failed = Mongo.write_error(reply);
    if (failed.code == 0) return;
    sdk.event("mongo_write_error", .{ .code = failed.code, .concern = failed.concern });
    if (failed.concern) return error.Unknown; // Written, perhaps not durably.
    return if (definite(failed.code)) error.Definite else error.Unknown;
}

fn find(
    arena: std.mem.Allocator,
    connection: *Mongo,
    mop: Mop,
    transaction: ?*Transaction,
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
    if (transaction) |t| t.fields(&builder) else {
        builder.document("readConcern");
        builder.string("level", "majority");
        builder.close();
    }
    builder.string("$db", database);
    const reply = connection.command(builder.finish() catch unreachable) catch return error.Unknown;
    if (!Mongo.ok(reply)) {
        _ = outcome_of_error(reply, "find");
        return error.Definite;
    }
    read.* = list_of(arena, reply) catch return error.Definite;
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
    builder.string("$db", "admin");
    _ = connection.command(builder.finish() catch unreachable) catch {};
}

fn majority(builder: *bson.Builder) void {
    builder.document("writeConcern");
    builder.string("w", "majority");
    builder.close();
}

fn outcome_of_error(reply: []const u8, command: []const u8) Outcome {
    const error_code = Mongo.code(reply);
    sdk.event("mongo_error", .{ .command = command, .code = error_code, .message = Mongo.message(reply) });
    return if (definite(error_code)) .not_committed else .unknown;
}

fn definite(error_code: i64) bool {
    return std.mem.indexOfScalar(i64, &definite_codes, error_code) != null;
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

fn pause_ms(ms: u64) void {
    if (ms == 0) return;
    const duration: linux.timespec = .{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast(ms % std.time.ms_per_s * std.time.ns_per_ms),
    };
    _ = linux.nanosleep(&duration, null);
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

test list_of {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [512]u8 = undefined;
    var builder: bson.Builder = .init(&buffer);
    builder.document("cursor");
    builder.array("firstBatch");
    var index: [10]u8 = undefined;
    builder.document(bson.index(&index, 0));
    builder.int64("_id", 3);
    builder.array("value");
    builder.int64(bson.index(&index, 0), 11);
    builder.int64(bson.index(&index, 1), 12);
    builder.close();
    builder.close();
    builder.close();
    builder.close();
    builder.double("ok", 1);
    const reply = try builder.finish();
    try std.testing.expectEqualSlices(u64, &.{ 11, 12 }, try list_of(arena.allocator(), reply));
}
