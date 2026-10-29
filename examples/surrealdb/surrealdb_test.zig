// SPDX-License-Identifier: MIT
//! Example test program: SurrealDB 3.3 on TiKV, three nodes each running PD, TiKV and a
//! SurrealDB server, under list-append transactions checked by Elle for snapshot isolation
//! (SurrealDB's documented isolation, on every backend). Every key a record `lists:k`, its list
//! in `v`. A transaction is one request to the HTTP API (`/sql`): `BEGIN TRANSACTION`, reads
//! (`lists:k.v`) and appends (`UPSERT lists:k SET v = array::append(v ?? [], x)`), `COMMIT
//! TRANSACTION`. Jepsen never analyzed SurrealDB.
//!
//! Drivers talk to the SurrealDB servers directly, through a node drawn each time. Outcomes:
//! `ok` with the reads; `fail` when nothing was applied (no connection, a statement's error
//! before the commit, a transaction conflict at the commit: SurrealDB's word, "can be retried");
//! `info` otherwise (no answer, any other error at the commit). Once faults stop, every
//! committed append must be in its key's list, read through any node (sdk.elle.final_reads).
//!
//!   determinismo explore ... --memory-mib 10240 --program zig-out/bin/surrealdb-test --scenario append
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo");

const Nodes = struct {
    n1: sdk.Node,
    n2: sdk.Node,
    n3: sdk.Node,
};
const System = sdk.System(Nodes);

const node_names = .{ "n1", "n2", "n3" };
const nodes_count = 3;
const pd_port = 2379;
const http_port = 8000;
/// Each node's memory (PD, TiKV, SurrealDB): TiKV 8.5 holds about 2.2 GB from its start.
const node_memory_mib = 3072; // --memory-mib 10240
const transactions_per_driver = 20;
const mops_max = 4;
/// Keys move with virtual time, a few at once, so lists stay short.
const keys_window = 4;
const window_s = 5;
/// SurrealDB serves once PD has a quorum and TiKV its stores: minutes, under faults.
const setup_attempts_max = 1500;
const final_attempts_max = 240;
const timeout_ms = 60_000;
const response_size_max = 1 << 20;
const request_size_max = 4096;
const headers = "surreal-ns: jepsen\r\nsurreal-db: jepsen\r\nAccept: application/json\r\n";

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .append = append_scenario },
        .checks = .{ .elle = sdk.elle.check(.{ .consistency = "snapshot-isolation" }) },
    });
}

fn describe(d: *System.Describe) !void {
    const profile = try d.profile("default");
    inline for (node_names) |name| {
        profile.node(@field(System.Name, name), .{
            .build = .{ .context = ".", .dockerfile = "examples/surrealdb/Dockerfile" },
            .env = &.{
                "SURREAL_NODE=" ++ name,
                // TiKV's gRPC resolves names with c-ares, which asks DNS and skips /etc/hosts
                // (where the nodes' names are): the system resolver instead (examples/tidb).
                "GRPC_DNS_RESOLVER=native",
            },
            // PD's client port: the nodes start together, as PD needs a quorum.
            .ready = .{ .tcp = pd_port },
            .memory_max_mib = node_memory_mib,
            // PD's timestamps come from its leader's clock (examples/tidb).
            .faults = .{ .restart = true, .crash = true, .stop = true, .clock_skew = true },
        });
    }
}

fn append_scenario(s: *System.Scenario) void {
    // Faults in bursts with quiet stretches: PD elections, TiKV leaders and SurrealDB's
    // reconnections need a few quiet seconds.
    s.pacing = .{ .active_ms_max = 10_000, .quiet_ms_max = 30_000 };
    s.setup("database", database_defined);
    s.parallel_driver("append", appends);
    s.finally("final reads", final_reads);
}

fn addresses(context: *System.Context) [nodes_count][4]u8 {
    return .{ context.nodes.n1.address, context.nodes.n2.address, context.nodes.n3.address };
}

fn call(address: [4]u8, body: []const u8, buffer: []u8) !sdk.tcp.Response {
    return sdk.tcp.http_with(address, http_port, "POST", "/sql", body, buffer, .{
        .timeout_ms = timeout_ms,
        .content_type = "text/plain",
        .headers = headers,
    });
}

// Setup -----------------------------------------------------------------------------------------

fn database_defined(context: *System.Context) !void {
    const all = addresses(context);
    const arena = context.init.arena.allocator();
    const buffer = try arena.alloc(u8, response_size_max);
    _ = try sdk.retry(setup_attempts_max, 500, database_define, .{ arena, &all, buffer });
}

fn database_define(arena: std.mem.Allocator, all: *const [nodes_count][4]u8, buffer: []u8) !void {
    const address = all[sdk.random_below(nodes_count)];
    const body = "DEFINE NAMESPACE IF NOT EXISTS jepsen; USE NS jepsen; DEFINE DATABASE IF NOT EXISTS jepsen; " ++
        "USE DB jepsen; DEFINE TABLE IF NOT EXISTS lists SCHEMALESS;";
    const response = try call(address, body, buffer);
    const results = results_parse(arena, response.body) catch {
        sdk.event("surrealdb_reply", .{ .command = "define", .status = response.status, .body = clip(response.body) });
        return error.NotDefined;
    };
    for (results) |result| if (!result.ok()) {
        sdk.event("surrealdb_error", .{ .command = "define", .message = clip(result.message()) });
        return error.NotDefined;
    };
}

// The workload ----------------------------------------------------------------------------------

const Mop = struct { append: bool, key: u64, value: u64 };
const Outcome = enum { committed, not_committed, unknown };

fn appends(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const all = addresses(context);
    const history: sdk.elle.History = .{};
    var id: u64 = undefined;
    sdk.random_bytes(std.mem.asBytes(&id));
    id &= 0xffff_ffff;
    var process = sdk.elle.process_new();
    const buffer = try arena.alloc(u8, response_size_max);
    for (0..transactions_per_driver) |sequence| {
        var mops: [mops_max]Mop = undefined;
        const count = draw(&mops, id, sequence);
        try history.invoke(arena, process, try elle_mops(arena, mops[0..count], null));
        var reads: [mops_max]?[]const u64 = @splat(null);
        const address = all[sdk.random_below(nodes_count)];
        switch (transact(arena, address, mops[0..count], &reads, buffer)) {
            .committed => {
                try history.ok(arena, process, try elle_mops(arena, mops[0..count], &reads));
                sdk.sometimes(true, "a transaction committed", .{});
            },
            .not_committed => {
                try history.fail(arena, process, try elle_mops(arena, mops[0..count], null));
                sdk.sometimes(true, "a transaction was refused", .{});
            },
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

fn transact(
    arena: std.mem.Allocator,
    address: [4]u8,
    mops: []const Mop,
    reads: *[mops_max]?[]const u64,
    buffer: []u8,
) Outcome {
    var body_buffer: [request_size_max]u8 = undefined;
    const body = request_body(&body_buffer, mops) catch unreachable; // Sized for mops_max.
    const response = call(address, body, buffer) catch |err| {
        // Not connected: nothing was sent. Any later error: it may have been.
        return if (err == error.ConnectFailed) .not_committed else .unknown;
    };
    const results = results_parse(arena, response.body) catch {
        sdk.event("surrealdb_reply", .{ .status = response.status, .body = clip(response.body) });
        return .unknown;
    };
    const outcome = classify(results, mops.len);
    if (outcome != .committed) {
        sdk.event("surrealdb_refused", .{
            .outcome = @tagName(outcome),
            .commit = if (results.len == mops.len + 2) clip(results[mops.len + 1].message()) else "",
            .body = clip(response.body),
        });
        return outcome;
    }
    for (mops, results[1 .. mops.len + 1], 0..) |mop, result, index| {
        if (mop.append) continue;
        reads[index] = result_list(arena, result) catch {
            sdk.event("surrealdb_reply", .{ .status = response.status, .body = clip(response.body) });
            return .unknown;
        };
    }
    return .committed;
}

/// A transaction's outcome by its COMMIT's result (BEGIN, a result per mop, COMMIT): committed;
/// not, when the commit says a statement before it failed ("aborted due to a prior error") or it
/// found a conflict ("can be retried": SurrealDB's word that nothing was written); unknown for
/// any other error there, whatever the statements say.
fn classify(results: []const Result, mops: usize) Outcome {
    if (results.len != mops + 2) return .unknown;
    const commit = results[mops + 1];
    if (commit.ok()) {
        for (results[0 .. mops + 1]) |result| if (!result.ok()) return .unknown;
        return .committed;
    }
    const message = commit.message();
    if (std.mem.indexOf(u8, message, "prior error") != null) return .not_committed;
    if (std.mem.indexOf(u8, message, "can be retried") != null) return .not_committed;
    return .unknown;
}

/// One transaction: BEGIN, a statement per mop, COMMIT.
fn request_body(buffer: []u8, mops: []const Mop) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.writeAll("BEGIN TRANSACTION;");
    for (mops) |mop| {
        if (mop.append) {
            try writer.print(" UPSERT lists:{d} SET v = array::append(v ?? [], {d}) RETURN NONE;", .{ mop.key, mop.value });
        } else {
            // An expression, not RETURN: a RETURN ends a transaction there (committing it).
            try writer.print(" lists:{d}.v;", .{mop.key});
        }
    }
    try writer.writeAll(" COMMIT TRANSACTION;");
    return writer.buffered();
}

const Result = struct {
    status: []const u8 = "",
    result: std.json.Value = .null,
    details: ?struct { kind: []const u8 = "" } = null,

    fn ok(result: Result) bool {
        return std.mem.eql(u8, result.status, "OK");
    }

    /// Not run because another statement failed first.
    fn not_executed(result: Result) bool {
        const details = result.details orelse return false;
        return std.mem.eql(u8, details.kind, "NotExecuted") or std.mem.eql(u8, details.kind, "Cancelled");
    }

    fn message(result: Result) []const u8 {
        return switch (result.result) {
            .string => |text| text,
            else => result.status,
        };
    }
};

fn results_parse(arena: std.mem.Allocator, body: []const u8) ![]const Result {
    return std.json.parseFromSliceLeaky([]const Result, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch error.BadReply;
}

/// A read's list: null (no record yet) is the empty list.
fn result_list(arena: std.mem.Allocator, result: Result) ![]const u64 {
    const items = switch (result.result) {
        .null => return &.{},
        .array => |array| array.items,
        else => return error.BadReply,
    };
    const list = try arena.alloc(u64, items.len);
    for (items, list) |item, *value| value.* = switch (item) {
        .integer => |integer| std.math.cast(u64, integer) orelse return error.BadReply,
        else => return error.BadReply,
    };
    return list;
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

// Once faults stop --------------------------------------------------------------------------------

/// Every committed append is in its key's list, read through any node (sdk.elle.final_reads):
/// Elle takes a read missing one for an older state, and the drivers may never read a key again.
fn final_reads(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const history: sdk.elle.History = .{};
    var reader: FinalReader = .{
        .addresses = addresses(context),
        .buffer = try arena.alloc(u8, response_size_max),
    };
    try sdk.elle.final_reads(arena, &history, &reader);
}

const FinalReader = struct {
    addresses: [nodes_count][4]u8,
    buffer: []u8,
    attempts: u32 = 0,

    pub fn read_list(reader: *FinalReader, arena: std.mem.Allocator, key: u64) ?[]const u64 {
        const mops = [_]Mop{.{ .append = false, .key = key, .value = 0 }};
        while (reader.attempts < final_attempts_max) {
            const address = reader.addresses[sdk.random_below(nodes_count)];
            var reads: [mops_max]?[]const u64 = @splat(null);
            if (transact(arena, address, &mops, &reads, reader.buffer) == .committed) return reads[0].?;
            reader.attempts += 1;
            sdk.sleep_ms(500);
        }
        return null;
    }
};

fn clip(text: []const u8) []const u8 {
    return text[0..@min(text.len, 400)];
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

test request_body {
    var buffer: [request_size_max]u8 = undefined;
    const body = try request_body(&buffer, &.{
        .{ .append = true, .key = 3, .value = 17 },
        .{ .append = false, .key = 4, .value = 0 },
    });
    try std.testing.expectEqualStrings("BEGIN TRANSACTION; UPSERT lists:3 SET v = array::append(v ?? [], 17) " ++
        "RETURN NONE; lists:4.v; COMMIT TRANSACTION;", body);
    var largest: [mops_max]Mop = @splat(.{ .append = true, .key = std.math.maxInt(u64), .value = std.math.maxInt(u64) });
    _ = try request_body(&buffer, &largest);
}

test "results as SurrealDB 3.3 answers them" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A committed transaction: BEGIN, an append, two reads (one of no record), COMMIT.
    const ok = try results_parse(arena,
        \\[{"result":null,"status":"OK","time":"0ns","type":null},{"result":[],"status":"OK","time":"285.874µs","type":null},{"result":[7,9,7],"status":"OK","time":"106.438µs","type":null},{"result":null,"status":"OK","time":"23.112µs","type":null},{"result":null,"status":"OK","time":"29.082µs","type":null}]
    );
    try std.testing.expectEqual(5, ok.len);
    for (ok) |result| try std.testing.expect(result.ok());
    try std.testing.expectEqualSlices(u64, &.{ 7, 9, 7 }, try result_list(arena, ok[2]));
    try std.testing.expectEqualSlices(u64, &.{}, try result_list(arena, ok[3]));
    // A statement's error: the others not run, the commit refused.
    const failed = try results_parse(arena,
        \\[{"result":null,"status":"OK","time":"0ns","type":null},{"details":{"kind":"NotExecuted"},"kind":"Query","result":"The query was not executed due to a failed transaction","status":"ERR","time":"120.981µs","type":null},{"kind":"Thrown","result":"An error occurred: x","status":"ERR","time":"91.361µs","type":null},{"details":{"kind":"NotExecuted"},"kind":"Query","result":"Cannot COMMIT: the transaction was aborted due to a prior error","status":"ERR","time":"0ns","type":null}]
    );
    try std.testing.expect(failed[1].not_executed());
    try std.testing.expect(!failed[2].ok() and !failed[2].not_executed());
    try std.testing.expectEqualStrings("An error occurred: x", failed[2].message());
    try std.testing.expectEqual(Outcome.committed, classify(ok, 3));
    try std.testing.expectEqual(Outcome.not_committed, classify(failed, 2));
    // A conflict at the commit; any other error there may have committed.
    const conflict = try results_parse(arena,
        \\[{"result":null,"status":"OK"},{"result":[],"status":"OK"},{"result":"Failed to commit transaction due to a read or write conflict. This transaction can be retried","status":"ERR"}]
    );
    try std.testing.expectEqual(Outcome.not_committed, classify(conflict, 1));
    const lost = try results_parse(arena,
        \\[{"result":null,"status":"OK"},{"result":"There was a problem with the datastore: connection lost","status":"ERR"},{"result":"There was a problem with the datastore: connection lost","status":"ERR"}]
    );
    try std.testing.expectEqual(Outcome.unknown, classify(lost, 1));
    try std.testing.expectEqual(Outcome.unknown, classify(lost, 2));
}
