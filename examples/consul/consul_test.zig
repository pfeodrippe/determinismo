// SPDX-License-Identifier: MIT
//! Example test program: Consul 2.1.0, three servers, its KV store under list-append
//! transactions checked by Elle for strict serializability, which Consul promises for writes and
//! for `?consistent` reads (Jepsen's 2014 analysis found stale reads in its default mode, its
//! leader lease, and Consul documents them: hence `?consistent` here).
//!
//! Every key a KV entry `lists/<key, 20 digits>` (fixed width: a key is a prefix of itself
//! alone), its list the text "v1,v2,..." (base64 on the wire). A transaction reads all its keys
//! at once, a read-only transaction (`PUT /v1/txn?consistent`, `get-tree` of each: nothing for
//! a key never written); with appends it then commits one transaction guarding every key with
//! the index it read (`check-index`, or `check-not-exists`) and setting the appended lists, so
//! its reads are still the keys' values when it commits. Outcomes: `ok` (200), `fail` when
//! nothing was applied (no connection, a guard failed: 409, no leader known), `info` when the
//! request got no answer or another error (the entry may still commit). Once faults stop,
//! every committed append must be in its key's list (sdk.elle.final_reads).
//!
//!   determinismo explore ... --memory-mib 3072 --program zig-out/bin/consul-test --scenario append
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo");

const Nodes = struct { c1: sdk.Node, c2: sdk.Node, c3: sdk.Node };
const System = sdk.System(Nodes);

const http_port = 8500;
const nodes_count = 3;
const node_names = [nodes_count][]const u8{ "c1", "c2", "c3" };
const transactions_per_driver = 20;
const mops_max = 4;
/// Keys move with virtual time, a few at once, so lists stay short.
const keys_window = 4;
const window_s = 5;
const setup_attempts_max = 600;
/// Once faults stop: a leader within two minutes, or never.
const final_attempts_max = 240;
/// Consul's own wait for a leader to apply is shorter (Raft's apply timeout).
const timeout_ms = 30_000;
const response_size_max = 1 << 20;
/// A request with a key's whole list (base64): a window's appends, ~20 digits each.
const request_size_max = 64 * 1024;
const key_prefix = "lists/";

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .append = append_scenario },
        .checks = .{ .elle = sdk.elle.check(.{ .consistency = "strict-serializable" }) },
    });
}

fn describe(d: *System.Describe) !void {
    const profile = try d.profile("default");
    const build: sdk.schema.Build = .{ .context = ".", .dockerfile = "examples/consul/Dockerfile" };
    inline for (node_names) |name| {
        profile.node(@field(System.Name, name), .{
            .build = build,
            .command = &.{name},
            // The HTTP API, which a server opens alone: it serves the KV store once the three
            // elected a leader (setup).
            .ready = .{ .tcp = http_port },
            // Consul syncs its Raft log before an entry is committed: power losses too. Its
            // default reads lean on a leader lease (clocks); `?consistent` ones must not.
            .faults = .{ .restart = true, .crash = true, .stop = true, .clock_skew = true },
        });
    }
}

fn append_scenario(s: *System.Scenario) void {
    // Faults in bursts with quiet stretches: elections and rejoins need a few quiet seconds.
    s.pacing = .{ .active_ms_max = 10_000, .quiet_ms_max = 30_000 };
    s.setup("leader", leader_elected);
    s.parallel_driver("append", appends);
    s.finally("final reads", final_reads);
}

fn addresses(context: *System.Context) [nodes_count][4]u8 {
    return .{ context.nodes.c1.address, context.nodes.c2.address, context.nodes.c3.address };
}

// Setup -----------------------------------------------------------------------------------------

/// A write through any server: once one commits, the cluster has a leader.
fn leader_elected(context: *System.Context) !void {
    const all = addresses(context);
    const arena = context.init.arena.allocator();
    const buffer = try arena.alloc(u8, response_size_max);
    _ = try sdk.retry(setup_attempts_max, 500, setup_write, .{ &all, buffer });
}

fn setup_write(all: *const [nodes_count][4]u8, buffer: []u8) !void {
    const address = all[sdk.random_below(nodes_count)];
    const response = try sdk.tcp.http_with(address, http_port, "PUT", "/v1/kv/setup", "1", buffer, .{
        .timeout_ms = timeout_ms,
    });
    if (response.status != 200) {
        sdk.event("consul_reply", .{ .command = "setup", .status = response.status, .body = clip(response.body) });
        return error.NotWritten;
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
    leader_aim(arena, &all, buffer);
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

/// The injector's faults aimed at the leader a server names (`/v1/status/leader`: its Raft
/// address), as Jepsen's nemeses target one; nothing when it names none.
fn leader_aim(arena: std.mem.Allocator, all: *const [nodes_count][4]u8, buffer: []u8) void {
    const response = sdk.tcp.http_with(all[sdk.random_below(nodes_count)], http_port, "GET", "/v1/status/leader", "", buffer, .{
        .timeout_ms = 5_000,
    }) catch return;
    if (response.status != 200) return;
    const leader = std.json.parseFromSliceLeaky([]const u8, arena, response.body, .{}) catch return;
    const host = leader[0 .. std.mem.lastIndexOfScalar(u8, leader, ':') orelse leader.len];
    for (all, node_names) |address, name| {
        var text_buffer: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&text_buffer, "{d}.{d}.{d}.{d}", .{ address[0], address[1], address[2], address[3] }) catch continue;
        if (std.mem.eql(u8, text, host)) return sdk.fault_aim(name);
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

/// A key's entry as a read found it: its list and its modify index (0: never written).
const Entry = struct { list: []const u64 = &.{}, index: u64 = 0 };

fn transact(
    arena: std.mem.Allocator,
    address: [4]u8,
    mops: []const Mop,
    reads: *[mops_max]?[]const u64,
    buffer: []u8,
) Outcome {
    var keys: [mops_max]u64 = undefined;
    const key_count = keys_distinct(mops, &keys);
    var entries: [mops_max]Entry = undefined;
    // The read: one read-only transaction of every key, `?consistent` (a refused read changed
    // nothing).
    read_entries(arena, address, keys[0..key_count], entries[0..key_count], buffer) catch |err| {
        if (err != error.ConnectFailed and err != error.NotAnswered) {
            sdk.event("consul_read_error", .{ .err = @errorName(err) });
        }
        return .not_committed;
    };
    // The transaction's own view: each read sees its earlier appends.
    var lists: [mops_max]std.ArrayList(u64) = undefined;
    for (entries[0..key_count], lists[0..key_count]) |entry, *list| {
        list.* = .empty;
        list.appendSlice(arena, entry.list) catch return .not_committed;
    }
    var writes = false;
    for (mops, 0..) |mop, index| {
        const at = std.mem.indexOfScalar(u64, keys[0..key_count], mop.key).?;
        if (mop.append) {
            writes = true;
            lists[at].append(arena, mop.value) catch return .not_committed;
        } else {
            reads[index] = arena.dupe(u64, lists[at].items) catch return .not_committed;
        }
    }
    if (!writes) return .committed;
    var body_buffer: [request_size_max]u8 = undefined;
    // A list longer than a request holds (a busy window): not sent, so not committed (the first
    // smokes' drivers panicked here, the buffer sized for a few values).
    const body = write_body(&body_buffer, keys[0..key_count], entries[0..key_count], lists[0..key_count], mops) catch {
        sdk.event("consul_request_too_large", .{ .keys = key_count });
        return .not_committed;
    };
    const response = sdk.tcp.http_with(address, http_port, "PUT", "/v1/txn", body, buffer, .{
        .timeout_ms = timeout_ms,
        .content_type = "application/json",
    }) catch |err| {
        // Not connected: nothing was sent. Any later error: it may have been.
        return if (err == error.ConnectFailed) .not_committed else .unknown;
    };
    switch (response.status) {
        200 => return .committed,
        // A guard failed: the transaction rolled back, nothing applied.
        409 => return .not_committed,
        else => {
            // No leader to forward it to: never in the log. Anything else: it may commit.
            sdk.event("consul_reply", .{ .command = "txn", .status = response.status, .body = clip(response.body) });
            return if (std.mem.indexOf(u8, response.body, "No cluster leader") != null) .not_committed else .unknown;
        },
    }
}

fn keys_distinct(mops: []const Mop, keys: *[mops_max]u64) u32 {
    var count: u32 = 0;
    for (mops) |mop| {
        if (std.mem.indexOfScalar(u64, keys[0..count], mop.key) != null) continue;
        keys[count] = mop.key;
        count += 1;
    }
    return count;
}

/// Every key's entry, at once (a read-only transaction, `?consistent`): a key with no entry is
/// the empty list, never written.
fn read_entries(arena: std.mem.Allocator, address: [4]u8, keys: []const u64, entries: []Entry, buffer: []u8) !void {
    var body_buffer: [request_size_max]u8 = undefined;
    const body = try read_body(&body_buffer, keys);
    const response = sdk.tcp.http_with(address, http_port, "PUT", "/v1/txn?consistent", body, buffer, .{
        .timeout_ms = timeout_ms,
        .content_type = "application/json",
    }) catch |err| return if (err == error.ConnectFailed) error.ConnectFailed else error.NotAnswered;
    if (response.status != 200) return error.NotAnswered;
    try entries_parse(arena, response.body, keys, entries);
}

fn key_write(writer: *std.Io.Writer, key: u64) !void {
    try writer.print(key_prefix ++ "{d:0>20}", .{key});
}

/// `[{"KV":{"Verb":"get-tree","Key":"lists/<key>"}}, ...]`.
fn read_body(buffer: []u8, keys: []const u64) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.writeByte('[');
    for (keys, 0..) |key, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"KV\":{\"Verb\":\"get-tree\",\"Key\":\"");
        try key_write(&writer, key);
        try writer.writeAll("\"}}");
    }
    try writer.writeByte(']');
    return writer.buffered();
}

/// Every key's guard (the index read, or that it does not exist), then each appended key's new
/// list.
fn write_body(
    buffer: []u8,
    keys: []const u64,
    entries: []const Entry,
    lists: []const std.ArrayList(u64),
    mops: []const Mop,
) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.writeByte('[');
    for (keys, entries, 0..) |key, entry, index| {
        if (index > 0) try writer.writeByte(',');
        if (entry.index == 0) {
            try writer.writeAll("{\"KV\":{\"Verb\":\"check-not-exists\",\"Key\":\"");
            try key_write(&writer, key);
            try writer.writeAll("\"}}");
        } else {
            try writer.writeAll("{\"KV\":{\"Verb\":\"check-index\",\"Key\":\"");
            try key_write(&writer, key);
            try writer.print("\",\"Index\":{d}}}}}", .{entry.index});
        }
    }
    for (keys, lists) |key, list| {
        var appended = false;
        for (mops) |mop| appended = appended or (mop.append and mop.key == key);
        if (!appended) continue;
        var text_buffer: [request_size_max / 2]u8 = undefined;
        var text: std.Io.Writer = .fixed(&text_buffer);
        for (list.items, 0..) |value, index| {
            if (index > 0) try text.writeByte(',');
            try text.print("{d}", .{value});
        }
        try writer.writeAll(",{\"KV\":{\"Verb\":\"set\",\"Key\":\"");
        try key_write(&writer, key);
        try writer.writeAll("\",\"Value\":\"");
        var encoded: [std.base64.standard.Encoder.calcSize(text_buffer.len)]u8 = undefined;
        try writer.writeAll(std.base64.standard.Encoder.encode(&encoded, text.buffered()));
        try writer.writeAll("\"}}");
    }
    try writer.writeByte(']');
    return writer.buffered();
}

/// A read-only transaction's results: each key's entry, by its name (get-tree returns none for
/// a key never written).
fn entries_parse(arena: std.mem.Allocator, body: []const u8, keys: []const u64, entries: []Entry) !void {
    const Result = struct { KV: ?struct { Key: []const u8 = "", Value: ?[]const u8 = null, ModifyIndex: u64 = 0 } = null };
    const Reply = struct { Results: ?[]const Result = null };
    const reply = std.json.parseFromSliceLeaky(Reply, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.BadReply;
    for (entries) |*entry| entry.* = .{};
    for (reply.Results orelse &.{}) |result| {
        const kv = result.KV orelse continue;
        if (!std.mem.startsWith(u8, kv.Key, key_prefix)) return error.BadReply;
        const key = std.fmt.parseInt(u64, kv.Key[key_prefix.len..], 10) catch return error.BadReply;
        const at = std.mem.indexOfScalar(u64, keys, key) orelse return error.BadReply;
        const value = kv.Value orelse "";
        const decoded = try arena.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(value) catch return error.BadReply);
        std.base64.standard.Decoder.decode(decoded, value) catch return error.BadReply;
        entries[at] = .{ .list = try list_parse(arena, decoded), .index = kv.ModifyIndex };
    }
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

/// Every committed append is in its key's list, read `?consistent` through any server
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
        while (reader.attempts < final_attempts_max) {
            const address = reader.addresses[sdk.random_below(nodes_count)];
            var entries: [1]Entry = undefined;
            if (read_entries(arena, address, &.{key}, &entries, reader.buffer)) |_| return entries[0].list else |_| {}
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

test "a transaction's requests as Consul takes them" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer: [request_size_max]u8 = undefined;
    try std.testing.expectEqualStrings(
        \\[{"KV":{"Verb":"get-tree","Key":"lists/00000000000000000003"}},{"KV":{"Verb":"get-tree","Key":"lists/00000000000000000004"}}]
    , try read_body(&buffer, &.{ 3, 4 }));
    var lists = [_]std.ArrayList(u64){ .empty, .empty };
    try lists[0].appendSlice(arena, &.{ 5, 17 });
    try lists[1].appendSlice(arena, &.{});
    const body = try write_body(&buffer, &.{ 3, 4 }, &.{ .{ .list = &.{5}, .index = 42 }, .{} }, &lists, &.{
        .{ .append = true, .key = 3, .value = 17 },
        .{ .append = false, .key = 4, .value = 0 },
    });
    // "5,17" in base64: NSwxNw==.
    try std.testing.expectEqualStrings(
        \\[{"KV":{"Verb":"check-index","Key":"lists/00000000000000000003","Index":42}},{"KV":{"Verb":"check-not-exists","Key":"lists/00000000000000000004"}},{"KV":{"Verb":"set","Key":"lists/00000000000000000003","Value":"NSwxNw=="}}]
    , body);
    // The largest request fits.
    var largest: [mops_max]Mop = undefined;
    var keys: [mops_max]u64 = undefined;
    var entries: [mops_max]Entry = undefined;
    var long_lists: [mops_max]std.ArrayList(u64) = undefined;
    for (&largest, &keys, &entries, &long_lists, 0..) |*mop, *key, *entry, *list, index| {
        mop.* = .{ .append = true, .key = std.math.maxInt(u64) - index, .value = std.math.maxInt(u64) };
        key.* = mop.key;
        entry.* = .{ .index = std.math.maxInt(u64) };
        list.* = .empty;
        try list.appendNTimes(arena, std.math.maxInt(u64), 8);
    }
    _ = try write_body(&buffer, &keys, &entries, &long_lists, &largest);
}

test "a read-only transaction's results as Consul answers them" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var entries: [2]Entry = undefined;
    try entries_parse(arena,
        \\{"Results":[{"KV":{"LockIndex":0,"Key":"lists/00000000000000000004","Flags":0,"Value":"NSwxNw==","CreateIndex":40,"ModifyIndex":42}}],"Errors":null,"Index":0,"LastContact":0,"KnownLeader":true}
    , &.{ 3, 4 }, &entries);
    try std.testing.expectEqualSlices(u64, &.{}, entries[0].list);
    try std.testing.expectEqual(@as(u64, 0), entries[0].index);
    try std.testing.expectEqualSlices(u64, &.{ 5, 17 }, entries[1].list);
    try std.testing.expectEqual(@as(u64, 42), entries[1].index);
    var none: [1]Entry = undefined;
    try entries_parse(arena, "{\"Results\":null,\"Errors\":null}", &.{9}, &none);
    try std.testing.expectEqualSlices(u64, &.{}, none[0].list);
}
