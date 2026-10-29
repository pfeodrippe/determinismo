// SPDX-License-Identifier: MIT
//! Example test program: rqlite 10 (Raft and SQLite), three voting nodes, under list-append
//! transactions checked by Elle for strict serializability. Every key a row of `lists (id
//! INTEGER PRIMARY KEY, value TEXT)`, its list the text "v1,v2,...". A transaction is one
//! request to the unified endpoint, `/db/request?transaction`: reads (`SELECT value ... WHERE
//! id = k`) and appends (an upsert concatenating `,v`) in one SQLite transaction. One with an
//! append goes through the Raft log and runs on every node as it applies; a read-only one runs
//! at `level=linearizable` (the leader checks a quorum still follows it, then reads once it has
//! applied the commit index it saw: rqlite's documented linearizable reads).
//!
//! Drivers talk to the nodes' HTTP API directly, through a node drawn each time (a follower
//! forwards to its leader). Outcomes: `ok` with the reads; `fail` when nothing was applied (no
//! connection, a statement's error rolling the transaction back, no leader known); `info` when
//! the request got no answer or an error otherwise (a leadership lost while committing, a
//! timeout: the entry may still commit). Once faults stop, every committed append must be in
//! its key's list, read at `level=linearizable` through any node (sdk.elle.final_reads).
//!
//! Profiles: `default`, rqlite's own settings; `snapshots`, Raft snapshots every 64 entries (and
//! at 64 KiB of SQLite WAL), checked every second: a timeline's few thousand writes snapshot and
//! truncate the log many times (the default waits for 8,192 entries or a 4 MiB WAL).
//!
//!   determinismo explore ... --memory-mib 3072 --program zig-out/bin/rqlite-test --scenario append
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo");

const Nodes = struct {
    @"rq-1": sdk.Node,
    @"rq-2": sdk.Node,
    @"rq-3": sdk.Node,
};
const System = sdk.System(Nodes);

const http_port = 4001;
const raft_port = 4002;
const nodes_count = 3;
const transactions_per_driver = 20;
const mops_max = 4;
/// Keys move with virtual time, a few at once, so lists stay short.
const keys_window = 4;
const window_s = 5;
const setup_attempts_max = 600;
/// Once faults stop: a leader within two minutes, or never.
const final_attempts_max = 240;
/// rqlite's own waits are shorter: a forward to the leader 10 s (asked below), an apply 10 s.
const timeout_ms = 30_000;
const response_size_max = 1 << 20;
const request_size_max = 4096;
const table = "lists";

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .append = append_scenario },
        .checks = .{ .elle = sdk.elle.check(.{ .consistency = "strict-serializable" }) },
    });
}

fn describe(d: *System.Describe) !void {
    inline for (.{
        .{ "default", "" },
        .{ "snapshots", "RQLITE_FLAGS=-raft-snap 64 -raft-snap-int 1s -raft-snap-wal-size 65536" },
    }) |entry| {
        const profile = try d.profile(entry[0]);
        const build: sdk.schema.Build = .{ .context = ".", .dockerfile = "examples/rqlite/Dockerfile" };
        inline for (.{ "rq-1", "rq-2", "rq-3" }, 1..) |name, id| {
            profile.node(@field(System.Name, name), .{
                .build = build,
                .command = &.{std.fmt.comptimePrint("{d}", .{id})},
                .env = if (entry[1].len == 0) &.{} else &.{entry[1]},
                // The Raft port, which a node opens alone: its HTTP API serves once the three
                // bootstrapped a cluster together.
                .ready = .{ .tcp = raft_port },
                // rqlite syncs its Raft log before acknowledging an entry: power losses too.
                .faults = .{ .restart = true, .crash = true, .stop = true },
            });
        }
    }
}

fn append_scenario(s: *System.Scenario) void {
    // Faults in bursts with quiet stretches: elections and rejoins need a few quiet seconds.
    s.pacing = .{ .active_ms_max = 10_000, .quiet_ms_max = 30_000 };
    s.setup("table", table_created);
    s.parallel_driver("append", appends);
    s.finally("final reads", final_reads);
}

fn addresses(context: *System.Context) [nodes_count][4]u8 {
    return .{ context.nodes.@"rq-1".address, context.nodes.@"rq-2".address, context.nodes.@"rq-3".address };
}

fn call(address: [4]u8, path: []const u8, body: []const u8, buffer: []u8) !sdk.tcp.Response {
    return sdk.tcp.http_with(address, http_port, "POST", path, body, buffer, .{
        .timeout_ms = timeout_ms,
        .content_type = "application/json",
    });
}

// Setup -----------------------------------------------------------------------------------------

/// The table, through any node: once it is created the cluster has a leader and commits.
fn table_created(context: *System.Context) !void {
    const all = addresses(context);
    const arena = context.init.arena.allocator();
    const buffer = try arena.alloc(u8, response_size_max);
    _ = try sdk.retry(setup_attempts_max, 500, table_create, .{ arena, &all, buffer });
}

fn table_create(arena: std.mem.Allocator, all: *const [nodes_count][4]u8, buffer: []u8) !void {
    const address = all[sdk.random_below(nodes_count)];
    const body =
        \\["CREATE TABLE IF NOT EXISTS lists (id INTEGER PRIMARY KEY, value TEXT NOT NULL)"]
    ;
    const response = try call(address, "/db/execute?timeout=10s", body, buffer);
    const reply = reply_parse(arena, response) catch |err| {
        sdk.event("rqlite_error", .{ .command = "create table", .status = response.status, .body = clip(response.body) });
        return err;
    };
    if (reply.failed()) |message| {
        sdk.event("rqlite_error", .{ .command = "create table", .status = response.status, .message = clip(message) });
        return error.NotCreated;
    }
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
    var writes = false;
    for (mops) |mop| writes = writes or mop.append;
    var body_buffer: [request_size_max]u8 = undefined;
    const body = request_body(&body_buffer, mops) catch unreachable; // Sized for mops_max.
    // With an append, the request goes through the Raft log whatever the level.
    const path = if (writes)
        "/db/request?transaction&timeout=10s"
    else
        "/db/request?transaction&level=linearizable&timeout=10s";
    const response = call(address, path, body, buffer) catch |err| {
        // Not connected: nothing was sent. Any later error: it may have been.
        return if (err == error.ConnectFailed) .not_committed else .unknown;
    };
    if (response.status == 503 and std.mem.indexOf(u8, response.body, "leader not found") != null) {
        // The node knew no leader to forward it to: never in a log.
        return .not_committed;
    }
    const reply = reply_parse(arena, response) catch {
        sdk.event("rqlite_reply", .{ .status = response.status, .body = clip(response.body) });
        return .unknown;
    };
    if (reply.message) |message| {
        // A request-level error: a leadership lost while committing, a timeout. The entry may
        // still commit; a read-only request changed nothing either way.
        sdk.event("rqlite_request_error", .{ .writes = writes, .message = clip(message) });
        return if (writes) .unknown else .not_committed;
    }
    if (reply.results.len != mops.len) {
        // A statement failed and the rest did not run: the transaction rolled back.
        if (reply.failed()) |message| {
            sdk.event("rqlite_statement_error", .{ .message = clip(message) });
            return .not_committed;
        }
        sdk.event("rqlite_reply", .{ .status = response.status, .body = clip(response.body) });
        return .unknown;
    }
    if (reply.failed()) |message| {
        sdk.event("rqlite_statement_error", .{ .message = clip(message) });
        return .not_committed;
    }
    for (mops, reply.results, 0..) |mop, result, index| {
        if (mop.append) continue;
        reads[index] = result_list(arena, result) catch {
            sdk.event("rqlite_reply", .{ .status = response.status, .body = clip(response.body) });
            return if (writes) .unknown else .not_committed;
        };
    }
    return .committed;
}

/// The statements as rqlite takes them: `[["SQL", args...], ...]`.
fn request_body(buffer: []u8, mops: []const Mop) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.writeByte('[');
    for (mops, 0..) |mop, index| {
        if (index > 0) try writer.writeByte(',');
        if (mop.append) {
            try writer.print("[\"INSERT INTO " ++ table ++ " (id, value) VALUES (?, ?) ON CONFLICT (id) DO " ++
                "UPDATE SET value = value || ',' || excluded.value\", {d}, \"{d}\"]", .{ mop.key, mop.value });
        } else {
            try writer.print("[\"SELECT value FROM " ++ table ++ " WHERE id = ?\", {d}]", .{mop.key});
        }
    }
    try writer.writeByte(']');
    return writer.buffered();
}

const Reply = struct {
    results: []const Result = &.{},
    /// A request-level error (rqlite answers it with status 200).
    message: ?[]const u8 = null,

    /// The first statement's error, if any.
    fn failed(reply: Reply) ?[]const u8 {
        if (reply.message) |message| return message;
        for (reply.results) |result| {
            if (result.@"error") |message| return message;
            if (result.error_v2) |e| return e.message;
        }
        return null;
    }
};

const Result = struct {
    values: ?[]const []const std.json.Value = null,
    @"error": ?[]const u8 = null,
    error_v2: ?struct { message: []const u8 = "" } = null,
};

fn reply_parse(arena: std.mem.Allocator, response: sdk.tcp.Response) !Reply {
    if (response.status != 200) return error.NotAnswered;
    const Raw = struct { results: []const Result = &.{}, @"error": ?[]const u8 = null };
    const raw = std.json.parseFromSliceLeaky(Raw, arena, response.body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.BadReply;
    return .{ .results = raw.results, .message = raw.@"error" };
}

/// A SELECT's list: no row is the empty list, one row its text split at commas.
fn result_list(arena: std.mem.Allocator, result: Result) ![]const u64 {
    const rows = result.values orelse return &.{};
    if (rows.len == 0) return &.{};
    if (rows.len != 1 or rows[0].len != 1) return error.BadReply;
    const text = switch (rows[0][0]) {
        .string => |text| text,
        else => return error.BadReply,
    };
    return list_parse(arena, text);
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

// Once faults stop --------------------------------------------------------------------------------

/// Every committed append is in its key's list, read at `level=linearizable` through any node
/// (sdk.elle.final_reads): Elle takes a read missing one for an older state, and the drivers
/// may never read a key again.
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
            pause_ms(500);
        }
        return null;
    }
};

fn clip(text: []const u8) []const u8 {
    return text[0..@min(text.len, 400)];
}

fn pause_ms(ms: u64) void {
    const duration = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&duration, null);
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
    try std.testing.expectEqualStrings("[[\"INSERT INTO lists (id, value) VALUES (?, ?) ON CONFLICT (id) DO " ++
        "UPDATE SET value = value || ',' || excluded.value\", 3, \"17\"],[\"SELECT value FROM lists WHERE id = ?\", 4]]", body);
    // The largest request fits.
    var largest: [mops_max]Mop = @splat(.{ .append = true, .key = std.math.maxInt(u64), .value = std.math.maxInt(u64) });
    _ = try request_body(&buffer, &largest);
}

test "a reply as rqlite answers it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ok = try reply_parse(arena, .{ .status = 200, .body =
        \\{"results":[{"last_insert_id":3,"rows_affected":1},{"columns":["value"],"types":["text"],"values":[["5,17"]]},{"columns":["value"],"types":["text"]}],"time":0.01}
    });
    try std.testing.expectEqual(null, ok.failed());
    try std.testing.expectEqual(3, ok.results.len);
    try std.testing.expectEqualSlices(u64, &.{ 5, 17 }, try result_list(arena, ok.results[1]));
    try std.testing.expectEqualSlices(u64, &.{}, try result_list(arena, ok.results[2]));
    const statement = try reply_parse(arena, .{ .status = 200, .body =
        \\{"results":[{"error":"no such table: lists"}]}
    });
    try std.testing.expectEqualStrings("no such table: lists", statement.failed().?);
    const request = try reply_parse(arena, .{ .status = 200, .body =
        \\{"results":[],"error":"leadership lost while committing log"}
    });
    try std.testing.expectEqualStrings("leadership lost while committing log", request.message.?);
    try std.testing.expectError(error.NotAnswered, reply_parse(arena, .{ .status = 503, .body = "leader not found" }));
}
