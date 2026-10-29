// SPDX-License-Identifier: MIT
//! Example test program: OpenSearch 3, a cluster of three nodes and one index (one shard, two
//! replicas), under list-append operations on documents checked by Elle: each key a document,
//! its list in `v`. A read is a realtime GET (the copy's latest, not the last refresh's); an
//! append reads the document and writes it back conditioned on what it read (`if_seq_no`,
//! `if_primary_term`: OpenSearch's optimistic concurrency control), again on a conflict. One
//! operation a transaction (documents have no transactions across them). Its reads may see a
//! write before it is acknowledged, on one copy before another (Elasticsearch's documented read
//! model): Elle judges the history serializable, and every read must list each append
//! acknowledged before it began (`realtime_reads`). Jepsen's Elasticsearch analyses (1.1.0,
//! 1.5.0, before OpenSearch forked) lost acknowledged writes to partitions; replication has since
//! taken sequence numbers and primary terms.
//!
//! Drivers talk to the nodes' HTTP API directly, through a node drawn each time. Outcomes: `ok`;
//! `fail` when nothing was written (refused, a conflict too many times, or no answer to the read
//! before the write); `info` when the write got no answer. Once faults stop, every document is
//! read again through each node.
//!
//!   determinismo explore ... --memory-mib 4096 --program zig-out/bin/opensearch-test --scenario append
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo");

const Nodes = struct {
    @"os-1": sdk.Node,
    @"os-2": sdk.Node,
    @"os-3": sdk.Node,
};
const System = sdk.System(Nodes);

const http_port = 9200;
const transport_port = 9300;
const nodes_count = 3;
const index = "elle";
const operations_per_driver = 20;
/// Keys move with virtual time, a few at once, so lists stay short.
const keys_window = 4;
const window_s = 5;
const conflict_retries = 5;
const setup_attempts_max = 600;
/// Two minutes: a JVM node restarting on one vCPU took over one (run 98).
const recovery_attempts_max = 240;
/// A write waits for its replicas, or for the cluster to fail a copy that does not answer.
const timeout_ms = 60_000;
const response_size_max = 1 << 20;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .append = append_scenario },
        .checks = .{ .elle = sdk.elle.check(.{ .consistency = "serializable", .realtime_reads = true }) },
    });
}

fn describe(d: *System.Describe) !void {
    const profile = try d.profile("default");
    const build: sdk.schema.Build = .{ .context = ".", .dockerfile = "examples/opensearch/Dockerfile" };
    inline for (.{ "os-1", "os-2", "os-3" }, 1..) |name, id| {
        profile.node(@field(System.Name, name), .{
            .build = build,
            .command = &.{std.fmt.comptimePrint("{d}", .{id})},
            // The transport port: open at once. The HTTP port waits for the cluster, which needs
            // the nodes started after this one.
            .ready = .{ .tcp = transport_port },
            .faults = .{ .restart = true, .crash = true, .stop = true },
            // OpenSearch writes its keystore at its first start without syncing it: with nothing
            // written back unasked, a power loss at any age left it truncated ("read past EOF:
            // ...opensearch.keystore"), and the node exited (70) at every start (run 88). A host's
            // 30 s window.
            .writeback_s = 30,
        });
    }
}

fn append_scenario(s: *System.Scenario) void {
    // Faults in bursts with quiet stretches between them: JVM nodes that take seconds to start
    // never all serve under a fault every few hundred milliseconds.
    s.pacing = .{ .active_ms_max = 10_000, .quiet_ms_max = 30_000 };
    s.setup("index", index_created);
    s.parallel_driver("append", appends);
    s.eventually("read", final_reads);
}

fn addresses(context: *System.Context) [nodes_count][4]u8 {
    return .{ context.nodes.@"os-1".address, context.nodes.@"os-2".address, context.nodes.@"os-3".address };
}

fn call(address: [4]u8, method: []const u8, path: []const u8, body: []const u8, buffer: []u8) !sdk.tcp.Response {
    // JSON, said so: OpenSearch refuses other content types with a body (406: every append of
    // the first smoke, run 88).
    return sdk.tcp.http_with(address, http_port, method, path, body, buffer, .{
        .timeout_ms = timeout_ms,
        .content_type = "application/json",
    });
}

// Setup -----------------------------------------------------------------------------------------

/// The three nodes in one cluster, then the index, every copy started.
fn index_created(context: *System.Context) !void {
    const all = addresses(context);
    _ = try sdk.retry(setup_attempts_max, 500, cluster_formed, .{all[0]});
    _ = try sdk.retry(setup_attempts_max, 500, index_create, .{all[0]});
    _ = try sdk.retry(setup_attempts_max, 500, index_green, .{all[0]});
}

fn cluster_formed(address: [4]u8) !void {
    var buffer: [16 * 1024]u8 = undefined;
    const response = try call(address, "GET", "/_cluster/health?wait_for_nodes=3&timeout=1s", "", &buffer);
    if (response.status != 200) return error.NotFormed;
}

fn index_create(address: [4]u8) !void {
    var buffer: [16 * 1024]u8 = undefined;
    // Not indexed, only kept: documents are read by id.
    const body =
        \\{"settings": {"index": {"number_of_shards": 1, "number_of_replicas": 2}},
        \\ "mappings": {"dynamic": false}}
    ;
    const response = try call(address, "PUT", "/" ++ index, body, &buffer);
    if (response.status == 200) return;
    // An earlier attempt's answer was lost: the index exists.
    if (response.status == 400 and std.mem.indexOf(u8, response.body, "resource_already_exists") != null) return;
    sdk.event("opensearch_error", .{ .command = "create index", .status = response.status, .body = response.body });
    return error.NotCreated;
}

fn index_green(address: [4]u8) !void {
    var buffer: [16 * 1024]u8 = undefined;
    const response = try call(address, "GET", "/_cluster/health/" ++ index ++ "?wait_for_status=green&timeout=1s", "", &buffer);
    if (response.status != 200) return error.NotGreen;
}

// The workload ----------------------------------------------------------------------------------

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
    for (0..operations_per_driver) |sequence| {
        const key = monotonic_ns() / std.time.ns_per_s / window_s + sdk.random_below(keys_window);
        const address = all[sdk.random_below(nodes_count)];
        if (sdk.random_below(2) == 0) {
            // Unique per key: the driver and its operation.
            const value = (id << 16) | sequence;
            const mop: sdk.elle.Mop = .{ .append = .{ .key = key, .value = value } };
            try history.invoke(arena, process, &.{mop});
            switch (append(arena, address, key, value, buffer)) {
                .committed => {
                    try history.ok(arena, process, &.{mop});
                    sdk.sometimes(true, "an append was acknowledged", .{});
                },
                .not_committed => {
                    try history.fail(arena, process, &.{mop});
                    sdk.sometimes(true, "an append was refused", .{});
                },
                .unknown => {
                    try history.info(arena, process, &.{mop});
                    sdk.sometimes(true, "an append's outcome is unknown", .{});
                    process = sdk.elle.process_new(); // Elle's rule: one operation at a time.
                },
            }
        } else {
            try history.invoke(arena, process, &.{.{ .read = .{ .key = key } }});
            if (read(arena, address, key, buffer)) |list| {
                try history.ok(arena, process, &.{.{ .read = .{ .key = key, .list = list } }});
                sdk.sometimes(true, "a read answered", .{});
            } else |_| {
                try history.fail(arena, process, &.{.{ .read = .{ .key = key } }});
            }
        }
    }
}

const Document = struct {
    found: bool = false,
    _seq_no: u64 = 0,
    _primary_term: u64 = 0,
    _source: struct { v: []const u64 = &.{} } = .{},
};

/// The document of `key`, its list empty when there is none yet.
fn document(arena: std.mem.Allocator, address: [4]u8, key: u64, buffer: []u8) !Document {
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/" ++ index ++ "/_doc/{d}", .{key});
    const response = try call(address, "GET", path, "", buffer);
    if (response.status != 200 and response.status != 404) return error.NotAnswered;
    const parsed = std.json.parseFromSliceLeaky(Document, arena, response.body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.BadAnswer;
    if (response.status == 404 and parsed.found) return error.BadAnswer;
    return parsed;
}

fn read(arena: std.mem.Allocator, address: [4]u8, key: u64, buffer: []u8) ![]const u64 {
    const known = try document(arena, address, key, buffer);
    return if (known.found) known._source.v else &.{};
}

fn append(arena: std.mem.Allocator, address: [4]u8, key: u64, value: u64, buffer: []u8) Outcome {
    for (0..conflict_retries) |_| {
        // Nothing written yet: an error here is a definite failure.
        const known = document(arena, address, key, buffer) catch return .not_committed;
        var body: std.ArrayList(u8) = .empty;
        body.appendSlice(arena, "{\"v\":[") catch return .not_committed;
        for (known._source.v) |item| body.print(arena, "{d},", .{item}) catch return .not_committed;
        body.print(arena, "{d}]}}", .{value}) catch return .not_committed;
        var path_buffer: [128]u8 = undefined;
        const path = (if (known.found)
            std.fmt.bufPrint(&path_buffer, "/" ++ index ++ "/_doc/{d}?if_seq_no={d}&if_primary_term={d}", .{
                key, known._seq_no, known._primary_term,
            })
        else
            std.fmt.bufPrint(&path_buffer, "/" ++ index ++ "/_doc/{d}?op_type=create", .{key})) catch return .not_committed;
        const response = call(address, "PUT", path, body.items, buffer) catch return .unknown;
        switch (response.status) {
            200, 201 => return .committed,
            409 => continue, // Another append came between: read again.
            // Refused before any copy took it: a bad request, or no primary to send it to.
            400, 404 => return .not_committed,
            503 => if (std.mem.indexOf(u8, response.body, "unavailable_shards_exception") != null or
                std.mem.indexOf(u8, response.body, "cluster_block_exception") != null)
                return .not_committed,
            else => {},
        }
        sdk.event("opensearch_reply", .{ .status = response.status, .body = response.body[0..@min(response.body.len, 400)] });
        return .unknown;
    }
    return .not_committed;
}

// Once faults stop --------------------------------------------------------------------------------

/// Every document read again through each node, into the history: Elle then sees an
/// acknowledged append that no final read has as lost. The cluster must serve again.
fn final_reads(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const all = addresses(context);
    const buffer = try arena.alloc(u8, response_size_max);
    // Through whichever node answers: one still restarting, or down for good, is not the cluster.
    const keys = sdk.retry(recovery_attempts_max, 500, keys_listed_any, .{ arena, &all, buffer }) catch |err| {
        sdk.assert_unreachable("the cluster serves again once faults stop", .{ .err = @errorName(err) });
        return err;
    };
    // A sometimes, not a reachable: a message is one kind of assertion (the unreachable above).
    sdk.sometimes(true, "the final reads listed the documents", .{ .keys = keys.len });
    const history: sdk.elle.History = .{};
    for (all) |address| {
        // A node that never answered a whole retry budget is down: its other reads fail at once
        // (retried key by key, a dead node would spend the timeline's hour).
        var down = false;
        for (keys) |key| {
            const process = sdk.elle.process_new();
            try history.invoke(arena, process, &.{.{ .read = .{ .key = key } }});
            const answered = if (down) null else sdk.retry(recovery_attempts_max, 500, read, .{ arena, address, key, buffer }) catch null;
            const list = answered orelse {
                if (!down) sdk.event("opensearch_node_down", .{ .address = address });
                down = true;
                try history.fail(arena, process, &.{.{ .read = .{ .key = key } }});
                sdk.sometimes(false, "a final read answered", .{});
                continue;
            };
            try history.ok(arena, process, &.{.{ .read = .{ .key = key, .list = list } }});
            sdk.sometimes(true, "a final read answered", .{});
        }
    }
}

/// Every document's id: the index refreshed, then searched (ids only).
fn keys_listed_any(arena: std.mem.Allocator, all: []const [4]u8, buffer: []u8) ![]const u64 {
    for (all) |address| {
        if (keys_listed(arena, address, buffer)) |keys| return keys else |_| {}
    }
    return error.NotServing;
}

fn keys_listed(arena: std.mem.Allocator, address: [4]u8, buffer: []u8) ![]const u64 {
    const refreshed = try call(address, "POST", "/" ++ index ++ "/_refresh", "", buffer);
    if (refreshed.status != 200) return error.NotServing;
    const response = try call(address, "GET", "/" ++ index ++ "/_search?size=10000&_source=false", "", buffer);
    if (response.status != 200) return error.NotServing;
    const Hits = struct { hits: struct { hits: []const struct { _id: []const u8 } } };
    const parsed = std.json.parseFromSliceLeaky(Hits, arena, response.body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.BadAnswer;
    const keys = try arena.alloc(u64, parsed.hits.hits.len);
    for (parsed.hits.hits, keys) |hit, *key| key.* = std.fmt.parseInt(u64, hit._id, 10) catch return error.BadAnswer;
    return keys;
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

test "a document as OpenSearch answers it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const found = try std.json.parseFromSliceLeaky(Document, arena_state.allocator(),
        \\{"_index":"elle","_id":"5","_version":3,"_seq_no":12,"_primary_term":2,"found":true,"_source":{"v":[4503599627370495,7]}}
    , .{ .ignore_unknown_fields = true });
    try std.testing.expect(found.found);
    try std.testing.expectEqual(12, found._seq_no);
    try std.testing.expectEqual(2, found._primary_term);
    try std.testing.expectEqualSlices(u64, &.{ 4503599627370495, 7 }, found._source.v);
    const missing = try std.json.parseFromSliceLeaky(Document, arena_state.allocator(),
        \\{"_index":"elle","_id":"6","found":false}
    , .{ .ignore_unknown_fields = true });
    try std.testing.expect(!missing.found);
    try std.testing.expectEqual(0, missing._source.v.len);
}
