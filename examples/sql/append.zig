// SPDX-License-Identifier: MIT
//! List-append transactions over SQL (Jepsen's append workload), recorded for Elle (sdk.elle),
//! for anything that speaks PostgreSQL's protocol: PostgreSQL, CockroachDB, YugabyteDB's YSQL.
//!
//! One table, `append (k BIGINT PRIMARY KEY, v TEXT)`: a key's list is its values joined by
//! commas. A transaction reads keys (SELECT) and appends to them (an upsert concatenating the
//! value), between BEGIN and COMMIT at the isolation level asked for. Outcomes, as Elle needs
//! them: `ok` once COMMIT succeeded; `fail` when it certainly did not happen (a statement failed
//! before COMMIT was sent, or COMMIT failed with a serialization failure, SQLSTATE 40001, or a
//! deadlock, 40P01); `info` when COMMIT was sent and no clear answer came. Keys move with virtual
//! time, so that lists stay short.
//!
//!   s.setup("schema", schema);          // sql_append.schema_create(address, port, user)
//!   s.parallel_driver("append", ...);   // sql_append.transactions(arena, addresses, port, ...)
//!   s.finally("elle", ...);             // sdk.elle.check_assert(... .consistency = ...)
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");
const Postgres = @import("pg");

pub const Options = struct {
    port: u16,
    user: []const u8,
    /// Null: the user's name (PostgreSQL's default).
    database: ?[]const u8 = null,
    /// BEGIN's isolation level ("SERIALIZABLE", "REPEATABLE READ", ...); null: the server's
    /// default.
    isolation: ?[]const u8 = "SERIALIZABLE",
    transactions: u32 = 15,
    /// A commit through consensus waits out an election.
    timeout_ms: u32 = 10_000,
};

const mops_max = 4;
const window_s = 10;
const keys_window = 4;
const value_size_max = 64 * 1024;

/// The table, once (any node).
pub fn schema_create(address: [4]u8, options: Options) !void {
    var connection: Postgres = undefined;
    try connection.open_with(address, options.port, options.user, options.database, .{
        .timeout_ms = options.timeout_ms,
    });
    defer connection.close();
    connection.exec("CREATE TABLE IF NOT EXISTS append (k BIGINT PRIMARY KEY, v TEXT NOT NULL)") catch |err| {
        sdk.event("sql_error", .{ .err = connection.last_error(), .sqlstate = connection.sqlstate() });
        return err;
    };
}

const Mop = struct { append: bool, key: u64, value: u64 };

/// A driver: transactions through random nodes, one at a time, each in the history.
pub fn transactions(arena: std.mem.Allocator, addresses: []const [4]u8, options: Options) !void {
    const history: sdk.elle.History = .{};
    var id: u64 = undefined;
    sdk.random_bytes(std.mem.asBytes(&id));
    id &= 0xffff_ffff;
    var process = sdk.elle.process_new();
    var connection: Postgres = undefined;
    var connected = false;
    defer if (connected) connection.close();
    for (0..options.transactions) |sequence| {
        if (!connected) {
            const address = addresses[sdk.random_below(addresses.len)];
            connection.open_with(address, options.port, options.user, options.database, .{
                .timeout_ms = options.timeout_ms,
            }) catch |err| {
                if (!Postgres.is_unavailable(err) and err != error.ServerError) return err;
                sdk.sometimes(true, "a node refused a connection", .{ .err = @errorName(err) });
                continue;
            };
            connected = true;
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

const Outcome = enum { committed, not_committed, unknown };

fn run(
    arena: std.mem.Allocator,
    connection: *Postgres,
    mops: []const Mop,
    reads: *[mops_max]?[]const u64,
    options: Options,
) Outcome {
    var statement: [512]u8 = undefined;
    const begin = if (options.isolation) |level|
        std.fmt.bufPrint(&statement, "BEGIN ISOLATION LEVEL {s}", .{level}) catch unreachable
    else
        "BEGIN";
    connection.exec(begin) catch return .not_committed;
    for (mops, 0..) |mop, index| {
        if (mop.append) {
            const sql = std.fmt.bufPrint(&statement, "INSERT INTO append (k, v) VALUES ({d}, '{d}') " ++
                "ON CONFLICT (k) DO UPDATE SET v = append.v || ',' || '{d}'", .{ mop.key, mop.value, mop.value }) catch unreachable;
            connection.exec(sql) catch return not_committed(connection);
            continue;
        }
        const sql = std.fmt.bufPrint(&statement, "SELECT v FROM append WHERE k = {d}", .{mop.key}) catch
            unreachable;
        const cell = arena.alloc(u8, value_size_max) catch return not_committed(connection);
        const text = connection.query_text(sql, cell) catch return not_committed(connection);
        reads[index] = list_parse(arena, text orelse "") catch return not_committed(connection);
    }
    connection.exec("COMMIT") catch |err| {
        if (err != error.ServerError) return .unknown; // Sent, no answer: it may have happened.
        const code = connection.sqlstate();
        if (std.mem.eql(u8, code, "40001") or std.mem.eql(u8, code, "40P01")) return .not_committed;
        sdk.event("sql_commit_error", .{ .err = connection.last_error(), .sqlstate = code });
        return .unknown;
    };
    return .committed;
}

/// A statement failed: the transaction is aborted (COMMIT never sent). The ROLLBACK is a
/// courtesy: the connection is closed after anyway.
fn not_committed(connection: *Postgres) Outcome {
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

test list_parse {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualSlices(u64, &.{ 1, 22, 333 }, try list_parse(arena.allocator(), "1,22,333"));
    try std.testing.expectEqualSlices(u64, &.{}, try list_parse(arena.allocator(), ""));
}
