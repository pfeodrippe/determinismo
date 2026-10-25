// SPDX-License-Identifier: MIT
//! Example test program over two services: prices live in Postgres (the source of truth) and
//! are cached in Redis, cache-aside, with a classic race.
//!
//! Writers update Postgres, then delete the cached price. Readers take the cached price, or on
//! a miss read Postgres and cache what they read. A reader that reads the old price, loses the
//! CPU while a writer updates and invalidates, then caches the old price, leaves the cache stale
//! forever. The final check compares every cached price with the database: a cross-service
//! invariant no single service can assert.
const std = @import("std");
const assert = std.debug.assert;
const sdk = @import("determinismo");
const Postgres = @import("pg.zig");
const Redis = @import("resp");

const Nodes = struct { postgres: sdk.Node, redis: sdk.Node };
const System = sdk.System(Nodes);

const postgres_port = 5432;
const redis_port = 6379;
const item_count = 5;
const price_initial_cents = 100;
const price_max_cents = 1000;
const operations_per_driver = 10;
const check_attempts_max = 200;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{ .prices = prices } });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.postgres, .{
        .image = "docker.io/library/postgres:17-alpine",
        .env = &.{"POSTGRES_HOST_AUTH_METHOD=trust"},
        .ready = .{ .tcp = postgres_port },
    });
    default.node(.redis, .{
        .image = "docker.io/library/redis:7.4-alpine",
        .command = &.{ "redis-server", "--save", "", "--appendonly", "no" },
        .ready = .{ .tcp = redis_port },
    });
}

fn prices(s: *System.Scenario) void {
    s.setup("catalog", catalog);
    s.parallel_driver("reprice", reprice);
    s.parallel_driver("browse", browse);
    s.finally("coherent", coherent);
}

fn catalog(context: *System.Context) !void {
    var database: Postgres = undefined;
    try database.open(context.nodes.postgres.address, postgres_port, "postgres");
    defer database.close();
    try database.exec("CREATE TABLE price (item integer PRIMARY KEY, cents integer NOT NULL)");
    try database.exec(std.fmt.comptimePrint(
        "INSERT INTO price SELECT item, {d} FROM generate_series(0, {d}) AS item",
        .{ price_initial_cents, item_count - 1 },
    ));
}

/// Writers: update the database, then invalidate the cache.
fn reprice(context: *System.Context) !void {
    var clients: Clients = undefined;
    clients.open(context) catch |err| return unavailable(err);
    defer clients.close();
    for (0..operations_per_driver) |_| {
        const item = sdk.random_below(item_count);
        const cents = 1 + sdk.random_below(price_max_cents);
        var sql_buffer: [128]u8 = undefined;
        const update = "UPDATE price SET cents = {d} WHERE item = {d}";
        const sql = try std.fmt.bufPrint(&sql_buffer, update, .{ cents, item });
        clients.database.exec(sql) catch |err| return unavailable(err);
        var key_buffer: [16]u8 = undefined;
        const invalidate = [_][]const u8{ "DEL", key(&key_buffer, item) };
        _ = clients.cache.call(&invalidate) catch |err| return unavailable(err);
    }
}

/// Readers: cache-aside. The bug: what was read may be stale by the time it is cached.
fn browse(context: *System.Context) !void {
    var clients: Clients = undefined;
    clients.open(context) catch |err| return unavailable(err);
    defer clients.close();
    for (0..operations_per_driver) |_| {
        const item = sdk.random_below(item_count);
        var key_buffer: [16]u8 = undefined;
        const item_key = key(&key_buffer, item);
        const lookup = [_][]const u8{ "GET", item_key };
        const cached = clients.cache.call(&lookup) catch |err| return unavailable(err);
        if (cached == .bulk and cached.bulk != null) {
            sdk.reachable("price served from the cache", .{});
            continue;
        }
        const cents = clients.price(item) catch |err| return unavailable(err);
        var value_buffer: [24]u8 = undefined;
        const value = try std.fmt.bufPrint(&value_buffer, "{d}", .{cents});
        _ = clients.cache.call(&.{ "SET", item_key, value }) catch |err| return unavailable(err);
        sdk.reachable("price cached after a miss", .{});
    }
}

/// Faults are over: every cached price must be the database's.
fn coherent(context: *System.Context) !void {
    sdk.retry(check_attempts_max, 50, check, .{context}) catch |err| {
        if (!is_unavailable(err)) return err;
        sdk.assert_unreachable("the services answer once faults stop", .{});
        return error.ServicesUnavailable;
    };
    sdk.sometimes(true, "coherence check ran", .{});
}

fn check(context: *System.Context) !void {
    var clients: Clients = undefined;
    try clients.open(context);
    defer clients.close();
    for (0..item_count) |item| {
        var key_buffer: [16]u8 = undefined;
        const cached = try clients.cache.call(&.{ "GET", key(&key_buffer, item) });
        if (cached != .bulk) return error.BadReply;
        const text = cached.bulk orelse continue; // Not cached: nothing to compare.
        const cached_cents = try std.fmt.parseInt(i64, text, 10);
        const database_cents = try clients.price(item);
        const details = .{ .item = item, .cached = cached_cents, .database = database_cents };
        sdk.always(cached_cents == database_cents, "cached prices match the database", details);
    }
}

const Clients = struct {
    database: Postgres,
    cache: Redis,

    fn open(clients: *Clients, context: *System.Context) !void {
        try clients.database.open(context.nodes.postgres.address, postgres_port, "postgres");
        errdefer clients.database.close();
        try clients.cache.open(context.nodes.redis.address, redis_port);
    }

    fn close(clients: *Clients) void {
        clients.cache.close();
        clients.database.close();
    }

    fn price(clients: *Clients, item: u64) !i64 {
        assert(item < item_count);
        var sql_buffer: [64]u8 = undefined;
        const select = "SELECT cents FROM price WHERE item = {d}";
        const sql = try std.fmt.bufPrint(&sql_buffer, select, .{item});
        return try clients.database.query_integer(sql) orelse error.MissingItem;
    }
};

fn key(buffer: *[16]u8, item: u64) []const u8 {
    assert(item < item_count);
    return std.fmt.bufPrint(buffer, "price:{d}", .{item}) catch unreachable;
}

fn is_unavailable(err: anyerror) bool {
    return Postgres.is_unavailable(err) or Redis.is_unavailable(err);
}

/// Faults make a service unreachable for a while: a driver that meets that gives up.
fn unavailable(err: anyerror) !void {
    if (!is_unavailable(err)) return err;
    sdk.sometimes(true, "a service was unavailable to a test command", .{ .err = @errorName(err) });
}
