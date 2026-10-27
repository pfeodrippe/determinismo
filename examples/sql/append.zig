// SPDX-License-Identifier: MIT
//! List-append transactions over SQL, recorded for Elle (sdk.elle), for anything that speaks
//! PostgreSQL's protocol (PostgreSQL, CockroachDB, YugabyteDB's YSQL) or MySQL's (MySQL,
//! MariaDB and Galera, Percona, TiDB): `Options.dialect`.
//!
//! As Jepsen's append workload (jepsen-io/stolon's, which found PostgreSQL 12.3's G2-item, and
//! jepsen-io/sql's): keys spread over tables `txn0`, `txn1`, ... `(id INT PRIMARY KEY, sk INT,
//! val TEXT)`, a key's row holding its values joined by commas in `val`, with `sk` = `id`. A read
//! selects a key's row by `id` or by `sk` (unindexed: a scan); an append updates it (`UPDATE ...
//! SET val = CONCAT(...)`), inserts it when no row matched (under a savepoint in a transaction)
//! and updates again when that insert lost a race; or upserts it at once (`INSERT ... ON
//! CONFLICT DO UPDATE`, MySQL's `ON DUPLICATE KEY UPDATE`). A transaction of one micro-operation runs alone (autocommit, at the
//! session's isolation level), longer ones between BEGIN and COMMIT, with a pause of up to 10 ms
//! before each micro-operation. Keys move with virtual time, so that lists stay short.
//!
//! Outcomes, as Elle needs them: `ok` once it committed; `fail` when it certainly did not happen
//! (a statement failed before COMMIT was sent, or failed with a definite error: a serialization
//! failure, SQLSTATE 40001, a deadlock, 40P01, ...); `info` when it may have (COMMIT, or a
//! statement on its own, sent with no clear answer).
//!
//!   s.setup("schema", schema);          // sql_append.schema_create(address, options)
//!   s.parallel_driver("append", ...);   // sql_append.transactions(arena, addresses, options)
//!   .checks = .{ .elle = sdk.elle.check(.{ .consistency = ... }) }
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");
const Postgres = @import("pg");
const Mysql = @import("mysql");

pub const Options = struct {
    dialect: Dialect = .postgres,
    port: u16,
    user: []const u8,
    /// Null: the user's name in PostgreSQL, none in MySQL.
    database: ?[]const u8 = null,
    /// BEGIN's isolation level ("SERIALIZABLE", "REPEATABLE READ", ...); null: the server's
    /// default.
    isolation: ?[]const u8 = "SERIALIZABLE",
    transactions: u32 = 15,
    /// A commit through consensus waits out an election.
    timeout_ms: u32 = 10_000,
    /// Tables keys spread over (Jepsen's stolon test: 3).
    tables: u32 = 3,
    /// How appends write, drawn for each.
    upserts: []const Upsert = &.{ .update_insert_update, .on_conflict },
    /// Which column reads and updates find a key by, drawn for each statement.
    keys: []const Key = &.{ .primary, .secondary },
    /// A pause before each micro-operation, drawn up to this (Jepsen's: 10 ms).
    pause_ms_max: u32 = 10,
};

pub const Dialect = enum { postgres, mysql };
pub const Upsert = enum { update_insert_update, on_conflict };
pub const Key = enum { primary, secondary };

const tables_max = 16;
/// Connections refused before a driver gives up (the next one tries again), and the pause
/// between them.
const refused_max = 20;
const refused_pause_ms_min = 100;
const refused_pause_ms_max = 1000;
const mops_max = 4;
const window_s = 10;
const keys_window = 4;
const value_size_max = 64 * 1024;

/// The tables, once (any node).
pub fn schema_create(address: [4]u8, options: Options) !void {
    assert(options.tables > 0 and options.tables <= tables_max);
    var connection: Client = undefined;
    try connection.open(address, options);
    defer connection.close();
    for (0..options.tables) |table| {
        var statement: [256]u8 = undefined;
        const sql = std.fmt.bufPrint(&statement, "CREATE TABLE IF NOT EXISTS txn{d} " ++
            "(id INT NOT NULL PRIMARY KEY, sk INT NOT NULL, val TEXT)", .{table}) catch unreachable;
        connection.exec(sql) catch |err| {
            sdk.event("sql_error", .{ .err = connection.last_error(), .sqlstate = connection.sqlstate() });
            return err;
        };
    }
}

const Mop = struct { append: bool, key: u64, value: u64 };

/// A driver: transactions through random nodes, one at a time, each in the history.
pub fn transactions(arena: std.mem.Allocator, addresses: []const [4]u8, options: Options) !void {
    const history: sdk.elle.History = .{};
    var id: u64 = undefined;
    sdk.random_bytes(std.mem.asBytes(&id));
    id &= 0xffff_ffff;
    var process = sdk.elle.process_new();
    var connection: Client = undefined;
    var connected = false;
    defer if (connected) connection.close();
    var refused: u32 = 0;
    var sequence: u64 = 0;
    while (sequence < options.transactions) {
        if (!connected) {
            const address = addresses[sdk.random_below(addresses.len)];
            connection.open(address, options) catch |err| {
                if (!sdk.tcp.unavailable(err) and err != error.ServerError) return err;
                // Down, cut off or starting: a while later, without spending a transaction.
                if (refused == 0) sdk.sometimes(true, "a node refused a connection", .{ .err = @errorName(err) });
                if (err == error.ServerError) sdk.event("sql_connect_refused", .{
                    .err = connection.last_error(),
                    .sqlstate = connection.sqlstate(),
                });
                refused += 1;
                if (refused == refused_max) return;
                pause_ms(refused_pause_ms_min + sdk.random_below(refused_pause_ms_max - refused_pause_ms_min));
                continue;
            };
            connected = true;
            // Transactions of one micro-operation run alone, at this level too.
            if (options.isolation) |level| {
                var statement: [128]u8 = undefined;
                const sql = switch (options.dialect) {
                    .postgres => std.fmt.bufPrint(&statement, "SET SESSION CHARACTERISTICS AS " ++
                        "TRANSACTION ISOLATION LEVEL {s}", .{level}),
                    .mysql => std.fmt.bufPrint(&statement, "SET SESSION TRANSACTION " ++
                        "ISOLATION LEVEL {s}", .{level}),
                } catch unreachable;
                connection.exec(sql) catch |err| {
                    if (err == error.ServerError) sdk.event("sql_error", .{
                        .err = connection.last_error(),
                        .sqlstate = connection.sqlstate(),
                    });
                    connection.close();
                    connected = false;
                    refused += 1;
                    if (refused == refused_max) return;
                    continue;
                };
            }
        }
        var mops: [mops_max]Mop = undefined;
        const count = draw(&mops, id, sequence);
        try history.invoke(arena, process, try elle_mops(arena, mops[0..count], null));
        var reads: [mops_max]?[]const u64 = @splat(null);
        const outcome = run(arena, &connection, mops[0..count], &reads, options);
        switch (outcome) {
            .committed => try history.ok(arena, process, try elle_mops(arena, mops[0..count], &reads)),
            .not_committed => try history.fail(arena, process, try elle_mops(arena, mops[0..count], null)),
            .unknown => {
                try history.info(arena, process, try elle_mops(arena, mops[0..count], null));
                sdk.sometimes(true, "a commit's outcome is unknown", .{});
                process = sdk.elle.process_new(); // Elle's rule: one operation at a time.
            },
        }
        if (outcome != .committed) {
            // The connection may be gone, or inside an aborted transaction: a fresh one.
            connection.close();
            connected = false;
        }
        sequence += 1;
    }
}

fn draw(mops: *[mops_max]Mop, id: u64, sequence: u64) u32 {
    const count: u32 = @intCast(1 + sdk.random_below(mops_max));
    const base = monotonic_ns() / std.time.ns_per_s / window_s;
    for (mops[0..count], 0..) |*mop, index| {
        mop.* = .{
            .append = sdk.random_below(2) == 0,
            .key = base + sdk.random_below(keys_window),
            // Unique per key: the driver, its transaction, the micro-operation.
            .value = (id << 20) | (sequence << 4) | index,
        };
    }
    return count;
}

/// A connection in either protocol.
const Client = union(Dialect) {
    postgres: Postgres,
    mysql: Mysql,

    fn open(client: *Client, address: [4]u8, options: Options) !void {
        const tcp_options: sdk.tcp.Options = .{ .timeout_ms = options.timeout_ms };
        switch (options.dialect) {
            .postgres => {
                client.* = .{ .postgres = undefined };
                try client.postgres.open_with(address, options.port, options.user, options.database, tcp_options);
            },
            .mysql => {
                client.* = .{ .mysql = undefined };
                try client.mysql.open_with(address, options.port, options.user, options.database, tcp_options);
            },
        }
    }

    fn close(client: *Client) void {
        switch (client.*) {
            inline else => |*connection| connection.close(),
        }
    }

    fn exec(client: *Client, sql: []const u8) !void {
        switch (client.*) {
            inline else => |*connection| return connection.exec(sql),
        }
    }

    fn exec_rows(client: *Client, sql: []const u8) !u64 {
        switch (client.*) {
            inline else => |*connection| return connection.exec_rows(sql),
        }
    }

    fn query_text(client: *Client, sql: []const u8, cell: []u8) !?[]const u8 {
        switch (client.*) {
            inline else => |*connection| return connection.query_text(sql, cell),
        }
    }

    fn sqlstate(client: *const Client) []const u8 {
        switch (client.*) {
            inline else => |*connection| return connection.sqlstate(),
        }
    }

    fn last_error(client: *const Client) []const u8 {
        switch (client.*) {
            inline else => |*connection| return connection.last_error(),
        }
    }

    /// Whether the last error says the statement (or transaction) certainly did not happen.
    fn definite(client: *const Client) bool {
        return switch (client.*) {
            .postgres => |*connection| sqlstate_definite(connection.sqlstate()),
            .mysql => |*connection| sqlstate_definite(connection.sqlstate()) or
                mysql_definite(connection.error_number),
        };
    }
};

const Outcome = enum { committed, not_committed, unknown };

fn run(
    arena: std.mem.Allocator,
    connection: *Client,
    mops: []const Mop,
    reads: *[mops_max]?[]const u64,
    options: Options,
) Outcome {
    // One micro-operation runs alone: its statements commit as they run.
    const alone = mops.len == 1;
    var statement: [128]u8 = undefined;
    if (!alone) {
        // MySQL's level is the session's (set as the connection opened).
        const begin = if (options.isolation != null and options.dialect == .postgres)
            std.fmt.bufPrint(&statement, "BEGIN ISOLATION LEVEL {s}", .{options.isolation.?}) catch
                unreachable
        else
            "BEGIN";
        connection.exec(begin) catch return .not_committed;
    }
    for (mops, 0..) |mop, index| {
        pause(options);
        const done = if (mop.append)
            append(connection, mop, alone, options)
        else
            read(arena, connection, mop, &reads[index], options);
        done catch |err| {
            if (!alone) return not_committed(connection);
            return switch (err) {
                error.Definite => .not_committed,
                error.Unknown => if (mop.append) .unknown else .not_committed,
            };
        };
    }
    if (alone) return .committed;
    connection.exec("COMMIT") catch |err| {
        if (err != error.ServerError) return .unknown; // Sent, no answer: it may have happened.
        if (connection.definite()) return .not_committed;
        sdk.event("sql_commit_error", .{ .err = connection.last_error(), .sqlstate = connection.sqlstate() });
        return .unknown;
    };
    return .committed;
}

const StatementError = error{ Definite, Unknown };

fn read(
    arena: std.mem.Allocator,
    connection: *Client,
    mop: Mop,
    list: *?[]const u64,
    options: Options,
) StatementError!void {
    var statement: [256]u8 = undefined;
    const sql = std.fmt.bufPrint(&statement, "SELECT val FROM txn{d} WHERE {s} = {d}", .{
        mop.key % options.tables, column(options), mop.key,
    }) catch unreachable;
    const cell = arena.alloc(u8, value_size_max) catch return error.Definite;
    const text = connection.query_text(sql, cell) catch |err| return failure(connection, err);
    list.* = list_parse(arena, text orelse "") catch return error.Definite;
}

/// Appends as Jepsen's clients do: update, else insert, else (the insert lost a race) update;
/// or at once with an upsert.
fn append(connection: *Client, mop: Mop, alone: bool, options: Options) StatementError!void {
    const table = mop.key % options.tables;
    var statement: [512]u8 = undefined;
    switch (options.upserts[sdk.random_below(options.upserts.len)]) {
        .on_conflict => {
            const sql = switch (options.dialect) {
                .postgres => std.fmt.bufPrint(&statement, "INSERT INTO txn{d} AS t (id, sk, val) " ++
                    "VALUES ({d}, {d}, '{d}') ON CONFLICT (id) DO UPDATE SET " ++
                    "val = CONCAT(t.val, ',', '{d}') WHERE t.{s} = {d}", .{
                    table, mop.key, mop.key, mop.value, mop.value, column(options), mop.key,
                }),
                .mysql => std.fmt.bufPrint(&statement, "INSERT INTO txn{d} (id, sk, val) " ++
                    "VALUES ({d}, {d}, '{d}') ON DUPLICATE KEY UPDATE " ++
                    "val = CONCAT(val, ',', '{d}')", .{ table, mop.key, mop.key, mop.value, mop.value }),
            } catch unreachable;
            connection.exec(sql) catch |err| return failure(connection, err);
        },
        .update_insert_update => {
            if (try update(connection, mop, options)) return;
            if (!alone) connection.exec("SAVEPOINT upsert") catch |err| return failure(connection, err);
            const sql = std.fmt.bufPrint(&statement, "INSERT INTO txn{d} (id, sk, val) " ++
                "VALUES ({d}, {d}, '{d}')", .{ table, mop.key, mop.key, mop.value }) catch unreachable;
            if (connection.exec(sql)) |_| {
                if (!alone) connection.exec("RELEASE SAVEPOINT upsert") catch |err| return failure(connection, err);
                return;
            } else |err| {
                // A duplicate key (integrity class 23: PostgreSQL's 23505, MySQL's 23000).
                const raced = err == error.ServerError and std.mem.startsWith(u8, connection.sqlstate(), "23");
                if (!raced) return failure(connection, err);
            }
            if (!alone) connection.exec("ROLLBACK TO SAVEPOINT upsert") catch |err| return failure(connection, err);
            if (try update(connection, mop, options)) return;
            sdk.event("sql_append_no_row", .{ .key = mop.key }); // Rare: not something a run must reach.
            return error.Definite; // Neither its insert nor its updates wrote.
        },
    }
}

/// Whether the update matched the key's row.
fn update(connection: *Client, mop: Mop, options: Options) StatementError!bool {
    var statement: [256]u8 = undefined;
    const sql = std.fmt.bufPrint(&statement, "UPDATE txn{d} SET val = CONCAT(val, ',', '{d}') " ++
        "WHERE {s} = {d}", .{ mop.key % options.tables, mop.value, column(options), mop.key }) catch
        unreachable;
    const rows = connection.exec_rows(sql) catch |err| return failure(connection, err);
    return rows > 0;
}

fn column(options: Options) []const u8 {
    return switch (options.keys[sdk.random_below(options.keys.len)]) {
        .primary => "id",
        .secondary => "sk",
    };
}

fn pause(options: Options) void {
    pause_ms(sdk.random_below(options.pause_ms_max + 1));
}

fn pause_ms(ms: u64) void {
    if (ms == 0) return;
    const duration: linux.timespec = .{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast(ms % std.time.ms_per_s * std.time.ns_per_ms),
    };
    _ = linux.nanosleep(&duration, null);
}

/// A statement failed: definitely (the server refused it), or with no clear answer.
fn failure(connection: *Client, err: anyerror) StatementError {
    if (err != error.ServerError) return error.Unknown;
    if (connection.definite()) return error.Definite;
    sdk.event("sql_error", .{ .err = connection.last_error(), .sqlstate = connection.sqlstate() });
    return error.Unknown;
}

/// An error after which the statement (or transaction) certainly did not happen: transaction
/// rollbacks but 40003 (completion unknown), integrity, syntax and data errors, an aborted
/// transaction.
fn sqlstate_definite(sqlstate: []const u8) bool {
    if (std.mem.eql(u8, sqlstate, "40003")) return false;
    const class = sqlstate[0..2];
    for ([_][]const u8{ "40", "23", "42", "22", "25" }) |known| {
        if (std.mem.eql(u8, class, known)) return true;
    }
    return false;
}

/// MySQL errors that roll the statement or its transaction back, under a generic SQLSTATE: a
/// lock wait timeout (1205), a snapshot conflict (MariaDB's 1020, "record has changed since last
/// read"), a node not in the cluster yet (Galera's 1047).
fn mysql_definite(number: u16) bool {
    return switch (number) {
        1205, 1020, 1047 => true,
        else => false,
    };
}

/// A statement failed: the transaction is aborted (COMMIT never sent). The ROLLBACK is a
/// courtesy: the connection is closed after anyway.
fn not_committed(connection: *Client) Outcome {
    connection.exec("ROLLBACK") catch {};
    return .not_committed;
}

fn list_parse(arena: std.mem.Allocator, text: []const u8) ![]const u64 {
    var values: std.ArrayList(u64) = .empty;
    var words = std.mem.tokenizeScalar(u8, text, ',');
    while (words.next()) |word| {
        try values.append(arena, std.fmt.parseInt(u64, word, 10) catch return error.BadList);
    }
    return values.items;
}

fn elle_mops(arena: std.mem.Allocator, mops: []const Mop, reads: ?*const [mops_max]?[]const u64) ![]const sdk.elle.Mop {
    const out = try arena.alloc(sdk.elle.Mop, mops.len);
    for (mops, out, 0..) |mop, *elle_mop, index| {
        elle_mop.* = if (mop.append)
            .{ .append = .{ .key = mop.key, .value = mop.value } }
        else
            .{ .read = .{ .key = mop.key, .list = if (reads) |known| known[index] orelse &.{} else null } };
    }
    return out;
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

test sqlstate_definite {
    try std.testing.expect(sqlstate_definite("40001"));
    try std.testing.expect(sqlstate_definite("23505"));
    try std.testing.expect(!sqlstate_definite("40003"));
    try std.testing.expect(!sqlstate_definite("08006"));
    try std.testing.expect(!sqlstate_definite("57P01"));
    try std.testing.expect(mysql_definite(1205) and !mysql_definite(2013));
}

test list_parse {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualSlices(u64, &.{ 1, 22, 333 }, try list_parse(arena.allocator(), "1,22,333"));
    try std.testing.expectEqualSlices(u64, &.{}, try list_parse(arena.allocator(), ""));
}
