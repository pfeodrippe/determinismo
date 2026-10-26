// SPDX-License-Identifier: MIT
//! Example test program: etcd v3.7.3 (github.com/etcd-io/etcd), three members, through its v3
//! JSON gateway (POST /v3/kv/put, /v3/kv/range, /v3/kv/txn, /v3/maintenance/hashkv).
//!
//! Drivers write unique keys and increment a counter with compare-and-swap, against random
//! members, and keep what was acknowledged in the runner (/tmp/etcd-acked.log: every driver
//! appends, one write per line). Properties, which need no model of the history:
//!   acknowledged writes survive      after faults (crashes at a sync among them: etcd syncs its
//!                                    WAL before it acknowledges), every one is there
//!   reads see earlier writes         a linearizable read, on any member, sees a write
//!                                    acknowledged before it, at a revision at least the write's
//!   revisions grow                   each acknowledged write of a driver has a higher revision
//!   the counter counts               its value is at least the acknowledged increments, at most
//!                                    those plus the ones whose outcome is unknown
//!   members agree                    the members' keyspace hashes (hashkv) at a revision they
//!                                    all reached are equal
//!   watches                          a watch on the written keys delivers its events in revision
//!                                    order, and misses no acknowledged write up to the last
//!                                    event it delivered (Jepsen found etcd 3.4.3's watches
//!                                    skipping revisions)
//!   recovery                         after faults, a write commits and the members converge
//!   strict serializability (Elle)    list-append transactions (reads, then one txn guarded by
//!                                    every key's mod revision), every timeline's history checked
//!                                    by Elle on the host (sdk.elle, checkers/elle) for every
//!                                    anomaly: G0, G1, G-single, G2, real-time order
//! Faults: the default ones, restarts, graceful stops and crashes (each member's data on its own
//! disk), and with them stalls and crashes at the members' syncs.
//!
//!   determinismo explore ... --program zig-out/bin/etcd-test --scenario kv --branches 64
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");

const Nodes = struct {
    @"etcd-1": sdk.Node,
    @"etcd-2": sdk.Node,
    @"etcd-3": sdk.Node,
};
const System = sdk.System(Nodes);
const member_names = [_][]const u8{ "etcd-1", "etcd-2", "etcd-3" };
const members_count = member_names.len;

const client_port = 2379;
const initial_cluster = "etcd-1=http://etcd-1:2380,etcd-2=http://etcd-2:2380," ++
    "etcd-3=http://etcd-3:2380";
/// A consensus write waits out an election (etcd's default election timeout: 1 s).
const timeout_ms = 5000;
const acked_path = "/tmp/etcd-acked.log";
const puts_per_driver = 20;
const increments_per_driver = 10;
const counter_key = "counter";
const written_prefix = "w/";
/// The end of the written keys' range: the prefix with its last byte incremented.
const written_end = "w0";
const page_size = 100;
const txns_per_driver = 15;
const mops_max = 4;
/// List-append keys move with virtual time (each window of keys is used for a few windows'
/// time, overlapping the next ones), so that lists stay short.
const append_window_s = 10;
const append_keys_window = 4;
/// A watch is read for 1 s to this long; a read waits this long for the next event.
const watch_seconds_max = 10;
const watch_read_timeout_ms = 2000;
const cluster_attempts_max = 300;
const recovery_attempts_max = 120;
const response_size_max = 64 * 1024;
const request_size_max = 1024;

comptime {
    assert(written_end[1] == written_prefix[1] + 1);
}

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .kv = kv },
        // Elle, on the host, on every timeline's list-append history.
        .checks = .{ .elle = sdk.elle.check(.{}) },
    });
}

/// `default`: etcd v3.7.3. `jepsen`: v3.4.3, the version of Jepsen's analysis (2020), to measure
/// what determinismo finds blind of what Jepsen reported.
fn describe(d: *System.Describe) !void {
    inline for (.{
        .{ "default", "examples/etcd/Dockerfile" },
        .{ "jepsen", "examples/etcd/Dockerfile.3.4.3" },
    }) |entry| {
        try members(try d.profile(entry[0]), entry[1]);
    }
}

fn members(profile: *System.Profile, comptime dockerfile: []const u8) !void {
    inline for (member_names) |name| {
        profile.node(@field(System.Name, name), .{
            .build = .{ .context = ".", .dockerfile = dockerfile },
            .command = &.{
                "--name",                        name,
                "--data-dir",                    "/var/lib/etcd",
                "--listen-client-urls",          "http://0.0.0.0:2379",
                "--advertise-client-urls",       "http://" ++ name ++ ":2379",
                "--listen-peer-urls",            "http://0.0.0.0:2380",
                "--initial-advertise-peer-urls", "http://" ++ name ++ ":2380",
                "--initial-cluster",             initial_cluster,
                "--initial-cluster-state",       "new",
                "--initial-cluster-token",       "determinismo",
                // Snapshots often (the default is every 10,000 entries): followers that fall
                // behind catch up from one, and restarts load one.
                "--snapshot-count",              "100",
            },
            .ready = .{ .tcp = client_port },
            // A wipe is left out: a member that lost its data cannot rejoin as itself, by design.
            .faults = .{ .restart = true, .crash = true, .stop = true },
        });
    }
}

fn kv(s: *System.Scenario) void {
    s.setup("cluster", cluster_ready);
    s.parallel_driver("write", write_many);
    s.parallel_driver("count", count_many);
    s.parallel_driver("append", append_many);
    s.parallel_driver("watch", watch_once);
    s.anytime("agree", members_agree);
    s.eventually("recover", recovers);
    s.eventually("durable", writes_survive);
}

fn addresses(context: *System.Context) [members_count][4]u8 {
    return .{
        context.nodes.@"etcd-1".address,
        context.nodes.@"etcd-2".address,
        context.nodes.@"etcd-3".address,
    };
}

// The gateway --------------------------------------------------------------------------------
// Proto3 JSON: 64-bit integers are strings, bytes are base64, fields left at their zero value are
// left out (hence every field's default).

const Header = struct { revision: []const u8 = "0", member_id: []const u8 = "" };
const KeyValue = struct { key: []const u8 = "", value: []const u8 = "", mod_revision: []const u8 = "0" };
const RangeResponse = struct { header: Header = .{}, kvs: []const KeyValue = &.{}, more: bool = false };
const PutResponse = struct { header: Header = .{} };
const TxnResponse = struct { header: Header = .{}, succeeded: bool = false };
const StatusResponse = struct { header: Header = .{} };
const WatchEvent = struct { type: []const u8 = "PUT", kv: KeyValue = .{} };
const WatchMessage = struct {
    result: struct { events: []const WatchEvent = &.{}, canceled: bool = false } = .{},
};
const HashResponse = struct { header: Header = .{}, hash: u32 = 0, compact_revision: []const u8 = "0" };

/// A gateway call's outcome: its answer, or no answer (the member was unreachable or answered
/// with an error: whether a write took effect is then unknown).
fn call(
    comptime Response: type,
    address: [4]u8,
    path: []const u8,
    body: []const u8,
    buffer: []u8,
) !Response {
    const response = try sdk.tcp.http_with(address, client_port, "POST", path, body, buffer, .{
        .timeout_ms = timeout_ms,
    });
    if (response.status != 200) return error.NoAnswer;
    var fixed: std.heap.FixedBufferAllocator = .init(buffer[response.body.len..]);
    return std.json.parseFromSliceLeaky(Response, fixed.allocator(), response.body, .{
        .ignore_unknown_fields = true,
    }) catch error.BadAnswer;
}

/// Errors that say only that no answer came: under faults, expected.
fn no_answer(err: anyerror) bool {
    return err == error.NoAnswer or sdk.tcp.unavailable(err);
}

fn revision_of(header: Header) !u64 {
    return std.fmt.parseInt(u64, header.revision, 10) catch error.BadAnswer;
}

const Base64 = struct {
    buffer: [256]u8 = undefined,

    fn of(b: *Base64, bytes: []const u8) []const u8 {
        return std.base64.standard.Encoder.encode(&b.buffer, bytes);
    }
};

fn decoded(buffer: []u8, text: []const u8) ![]const u8 {
    const size = std.base64.standard.Decoder.calcSizeForSlice(text) catch return error.BadAnswer;
    if (size > buffer.len) return error.BadAnswer;
    std.base64.standard.Decoder.decode(buffer[0..size], text) catch return error.BadAnswer;
    return buffer[0..size];
}

fn put(address: [4]u8, key: []const u8, value: []const u8) !u64 {
    var keys: Base64 = .{};
    var values: Base64 = .{};
    var body_buffer: [request_size_max]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buffer, "{{\"key\":\"{s}\",\"value\":\"{s}\"}}", .{
        keys.of(key), values.of(value),
    });
    var buffer: [response_size_max]u8 = undefined;
    const response = try call(PutResponse, address, "/v3/kv/put", body, &buffer);
    return revision_of(response.header);
}

/// A linearizable read of one key: its value (null if absent) and the read's revision.
const Read = struct { value: ?[]const u8, mod_revision: u64, revision: u64 };

fn get(address: [4]u8, key: []const u8, value_buffer: []u8) !Read {
    var keys: Base64 = .{};
    var body_buffer: [request_size_max]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buffer, "{{\"key\":\"{s}\"}}", .{keys.of(key)});
    var buffer: [response_size_max]u8 = undefined;
    const response = try call(RangeResponse, address, "/v3/kv/range", body, &buffer);
    const revision = try revision_of(response.header);
    if (response.kvs.len == 0) return .{ .value = null, .mod_revision = 0, .revision = revision };
    const found = response.kvs[0];
    return .{
        .value = try decoded(value_buffer, found.value),
        .mod_revision = std.fmt.parseInt(u64, found.mod_revision, 10) catch return error.BadAnswer,
        .revision = revision,
    };
}

// Setup --------------------------------------------------------------------------------------

/// The cluster elected a leader and takes writes; the counter starts at 0.
fn cluster_ready(context: *System.Context) !void {
    const all = addresses(context);
    _ = try sdk.retry(cluster_attempts_max, 100, put_anywhere, .{ &all, counter_key, "0" });
}

fn put_anywhere(all: *const [members_count][4]u8, key: []const u8, value: []const u8) !u64 {
    for (all) |address| {
        return put(address, key, value) catch continue;
    }
    return error.NoMemberTookIt;
}

// Drivers ------------------------------------------------------------------------------------

/// Unique keys, each written once to a random member; every acknowledged one is noted, read
/// back from a random member, and its revision compared with the driver's earlier ones.
fn write_many(context: *System.Context) !void {
    const all = addresses(context);
    var id: [8]u8 = undefined;
    sdk.random_bytes(&id);
    var revision_last: u64 = 0;
    for (0..puts_per_driver) |sequence| {
        var key_buffer: [64]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, written_prefix ++ "{x}/{d}", .{ id, sequence });
        var value_bytes: [8]u8 = undefined;
        sdk.random_bytes(&value_bytes);
        var value_buffer: [16]u8 = undefined;
        const value = try std.fmt.bufPrint(&value_buffer, "{x}", .{value_bytes});
        const revision = put(all[sdk.random_below(members_count)], key, value) catch |err| {
            if (!no_answer(err)) return err;
            sdk.sometimes(true, "a write got no answer", .{ .err = @errorName(err) });
            continue;
        };
        acked_note("put", key, value, revision);
        sdk.always(revision > revision_last, "each acknowledged write has a higher revision", .{
            .revision = revision,
            .previous = revision_last,
        });
        revision_last = @max(revision_last, revision);
        var read_buffer: [64]u8 = undefined;
        const read = get(all[sdk.random_below(members_count)], key, &read_buffer) catch |err| {
            if (!no_answer(err)) return err;
            continue;
        };
        const seen = if (read.value) |found| std.mem.eql(u8, found, value) else false;
        sdk.always(seen, "a linearizable read sees a write acknowledged before it", .{
            .key = key,
            .found = read.value != null,
        });
        sdk.always(read.revision >= revision, "a read's revision is at least that of a " ++
            "write acknowledged before it", .{ .read = read.revision, .write = revision });
    }
}

/// Compare-and-swap increments of the counter: read it, then write value + 1 if its mod
/// revision is still the one read. Acknowledged increments and unknown outcomes are noted.
fn count_many(context: *System.Context) !void {
    const all = addresses(context);
    for (0..increments_per_driver) |_| {
        increment(all[sdk.random_below(members_count)]) catch |err| {
            if (!no_answer(err)) return err;
        };
    }
}

fn increment(address: [4]u8) !void {
    var value_buffer: [32]u8 = undefined;
    const read = try get(address, counter_key, &value_buffer);
    const current = std.fmt.parseInt(u64, read.value orelse return error.NoCounter, 10) catch
        return error.BadCounter;
    var keys: Base64 = .{};
    var values: Base64 = .{};
    var next_buffer: [24]u8 = undefined;
    const next = try std.fmt.bufPrint(&next_buffer, "{d}", .{current + 1});
    const key = keys.of(counter_key);
    var body_buffer: [request_size_max]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buffer, "{{\"compare\":[{{\"key\":\"{s}\"," ++
        "\"target\":\"MOD\",\"result\":\"EQUAL\",\"mod_revision\":\"{d}\"}}],\"success\":[{{" ++
        "\"request_put\":{{\"key\":\"{s}\",\"value\":\"{s}\"}}}}]}}", .{
        key, read.mod_revision, key, values.of(next),
    });
    var buffer: [response_size_max]u8 = undefined;
    const response = call(TxnResponse, address, "/v3/kv/txn", body, &buffer) catch |err| {
        if (no_answer(err)) acked_note("increment", "unknown", "", 0);
        return err;
    };
    if (response.succeeded) {
        acked_note("increment", "acknowledged", "", 0);
        sdk.sometimes(true, "an increment was acknowledged", .{});
    } else {
        sdk.sometimes(true, "an increment lost its compare", .{});
    }
}

/// One line per acknowledged (or unknown) operation, appended in one write: drivers in parallel
/// never interleave inside a line.
fn acked_note(kind: []const u8, first: []const u8, second: []const u8, revision: u64) void {
    var line_buffer: [160]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buffer, "{s} {s} {s} {d}\n", .{ kind, first, second, revision }) catch
        unreachable;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
    const fd = linux.open(acked_path, flags, 0o644);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    const written = linux.write(@intCast(fd), line.ptr, line.len);
    assert(linux.errno(written) != .SUCCESS or written == line.len);
}

// Watches ------------------------------------------------------------------------------------

/// A watch on the written keys from a member's current revision, read for a while. The gateway
/// streams it as JSON lines on the open connection (HTTP/1.0: no chunks, the body runs until the
/// watch ends).
fn watch_once(context: *System.Context) !void {
    const all = addresses(context);
    const arena = context.init.arena.allocator();
    const address = all[sdk.random_below(members_count)];
    var status_buffer: [4096]u8 = undefined;
    const status = call(StatusResponse, address, "/v3/maintenance/status", "{}", &status_buffer) catch |err| {
        if (no_answer(err)) return;
        return err;
    };
    const start = try revision_of(status.header) + 1;
    var connection: sdk.tcp.Connection = undefined;
    connection.open(address, client_port, .{ .timeout_ms = watch_read_timeout_ms }) catch |err| {
        if (sdk.tcp.unavailable(err)) return;
        return err;
    };
    defer connection.close();
    var keys: Base64 = .{};
    var ends: Base64 = .{};
    var body_buffer: [request_size_max]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buffer, "{{\"create_request\":{{\"key\":\"{s}\"," ++
        "\"range_end\":\"{s}\",\"start_revision\":\"{d}\"}}}}", .{
        keys.of(written_prefix), ends.of(written_end), start,
    });
    var head_buffer: [256]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buffer, "POST /v3/watch HTTP/1.0\r\nHost: node\r\n" ++
        "Content-Length: {d}\r\n\r\n", .{body.len});
    connection.write_all(head) catch return;
    connection.write_all(body) catch return;
    const status_line = connection.read_line() catch return;
    if (status_line.len < 12 or !std.mem.eql(u8, status_line[9..12], "200")) return;
    while (true) {
        const line = connection.read_line() catch return;
        if (line.len == 0) break; // The end of the head.
    }
    const until_ns = monotonic_ns() + (1 + sdk.random_below(watch_seconds_max)) * std.time.ns_per_s;
    var seen: std.StringHashMapUnmanaged(u64) = .empty;
    var last: u64 = 0;
    var events: u64 = 0;
    while (monotonic_ns() < until_ns) {
        // Quiet past the read timeout, the member gone, or a message larger than the buffer: the
        // watch is over for this driver.
        const line = connection.read_line() catch break;
        if (line.len == 0) continue;
        const message = std.json.parseFromSliceLeaky(WatchMessage, arena, line, .{
            .ignore_unknown_fields = true,
        }) catch break;
        for (message.result.events) |event| {
            const revision = std.fmt.parseInt(u64, event.kv.mod_revision, 10) catch
                return error.BadAnswer;
            sdk.always(revision > last and revision >= start, "a watch delivers events in " ++
                "revision order, from its start", .{
                .revision = revision,
                .previous = last,
                .start = start,
            });
            last = @max(last, revision);
            const key = try decoded(try arena.alloc(u8, event.kv.key.len), event.kv.key);
            try seen.put(arena, key, revision);
            events += 1;
        }
        if (message.result.canceled) break;
    }
    if (events == 0) return;
    sdk.sometimes(true, "a watch delivered events", .{ .events = events });
    try watch_missed(context, arena, &seen, start, last);
}

/// Every write acknowledged (and noted) with a revision from the watch's start to its last
/// event was delivered, at that revision.
fn watch_missed(
    context: *System.Context,
    arena: std.mem.Allocator,
    seen: *const std.StringHashMapUnmanaged(u64),
    start: u64,
    last: u64,
) !void {
    const log = std.Io.Dir.cwd().readFileAlloc(context.init.io, acked_path, arena, .limited(1 << 26)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    var checked: u64 = 0;
    var missed: u64 = 0;
    var lines = std.mem.tokenizeScalar(u8, log, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, fields.next() orelse continue, "put")) continue;
        const key = fields.next() orelse continue;
        _ = fields.next() orelse continue; // Its value.
        const revision = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;
        if (revision < start or revision > last) continue;
        checked += 1;
        if (seen.get(key) != revision) missed += 1;
    }
    sdk.always(missed == 0, "a watch misses no acknowledged write up to its last event", .{
        .checked = checked,
        .missed = missed,
        .start = start,
        .last = last,
    });
}

// List-append transactions (Elle's model) -----------------------------------------------------

const Mop = struct { append: bool, key: u64, value: u64 };
const Txn = struct { mops: [mops_max]Mop = undefined, count: u32 = 0 };
/// What a key held when read (its list, as stored: values separated by spaces), and its mod
/// revision for the guard.
const Held = struct { key: u64, list: std.ArrayList(u8), mod_revision: u64 };

/// Transactions of 1 to 4 micro-operations (appends of values unique to this driver, and reads)
/// on keys of the current window, each recorded in the history (invoke, then ok, fail or info).
/// After an unknown outcome the driver goes on as another process (Elle's rule: one operation
/// at a time per process).
fn append_many(context: *System.Context) !void {
    const all = addresses(context);
    const arena = context.init.arena.allocator();
    var id: u64 = undefined;
    sdk.random_bytes(std.mem.asBytes(&id));
    id &= 0xffff_ffff;
    const history: sdk.elle.History = .{};
    var process = sdk.elle.process_new();
    for (0..txns_per_driver) |sequence| {
        const txn = txn_draw(id, sequence);
        try history.invoke(arena, process, try txn_mops(arena, &txn, null));
        var held: [mops_max]Held = undefined;
        const outcome = txn_run(arena, all[sdk.random_below(members_count)], &txn, &held) catch |err| {
            if (!no_answer(err)) return err;
            try history.info(arena, process, try txn_mops(arena, &txn, null));
            sdk.sometimes(true, "a transaction's outcome is unknown", .{ .err = @errorName(err) });
            process = sdk.elle.process_new();
            continue;
        };
        switch (outcome) {
            .committed => |reads| try history.ok(arena, process, try txn_mops(arena, &txn, &reads)),
            .not_committed => try history.fail(arena, process, try txn_mops(arena, &txn, null)),
        }
    }
}

/// The transaction as Elle reads it, with what its reads saw once known (lists as stored:
/// values separated by spaces).
fn txn_mops(arena: std.mem.Allocator, txn: *const Txn, reads: ?*const [mops_max]?[]const u8) ![]const sdk.elle.Mop {
    const mops = try arena.alloc(sdk.elle.Mop, txn.count);
    for (txn.mops[0..txn.count], mops, 0..) |mop, *out, index| {
        if (mop.append) {
            out.* = .{ .append = .{ .key = mop.key, .value = mop.value } };
            continue;
        }
        const text = if (reads) |known| known[index] else null;
        out.* = .{ .read = .{ .key = mop.key, .list = if (text) |list| try list_parse(arena, list) else null } };
    }
    return mops;
}

fn list_parse(arena: std.mem.Allocator, text: []const u8) ![]const u64 {
    var values: std.ArrayList(u64) = .empty;
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    while (words.next()) |word| {
        try values.append(arena, std.fmt.parseInt(u64, word, 10) catch return error.BadList);
    }
    return values.items;
}

fn txn_draw(id: u64, sequence: u64) Txn {
    var txn: Txn = .{ .count = @intCast(1 + sdk.random_below(mops_max)) };
    const base = monotonic_ns() / std.time.ns_per_s / append_window_s;
    for (txn.mops[0..txn.count], 0..) |*mop, index| {
        mop.* = .{
            .append = sdk.random_below(2) == 0,
            .key = base + sdk.random_below(append_keys_window),
            // Unique per key: the driver's id, its transaction and the micro-operation.
            .value = (id << 20) | (sequence << 4) | index,
        };
    }
    return txn;
}

const Outcome = union(enum) {
    /// The lists each read saw, in micro-operation order (null for appends).
    committed: [mops_max]?[]const u8,
    /// The guard failed (a key changed since read), or the reads failed: it did not happen.
    not_committed,
};

fn txn_run(arena: std.mem.Allocator, address: [4]u8, txn: *const Txn, held: *[mops_max]Held) !Outcome {
    // The keys' lists, read linearizably: no txn is sent if a read fails (it did not happen).
    var held_count: u32 = 0;
    for (txn.mops[0..txn.count]) |mop| {
        for (held[0..held_count]) |known| {
            if (known.key == mop.key) break;
        } else {
            var key_buffer: [24]u8 = undefined;
            const key = append_key(&key_buffer, mop.key);
            const value_buffer = try arena.alloc(u8, response_size_max);
            const read = get(address, key, value_buffer) catch |err| {
                if (no_answer(err)) return .not_committed;
                return err;
            };
            var list: std.ArrayList(u8) = .empty;
            try list.appendSlice(arena, read.value orelse "");
            held[held_count] = .{ .key = mop.key, .list = list, .mod_revision = read.mod_revision };
            held_count += 1;
        }
    }
    // The micro-operations in order, over what was read: a read after an append sees it.
    var reads: [mops_max]?[]const u8 = @splat(null);
    for (txn.mops[0..txn.count], reads[0..txn.count]) |mop, *read| {
        const entry = for (held[0..held_count]) |*known| {
            if (known.key == mop.key) break known;
        } else unreachable;
        if (mop.append) {
            if (entry.list.items.len > 0) try entry.list.append(arena, ' ');
            try entry.list.print(arena, "{d}", .{mop.value});
        } else {
            read.* = try arena.dupe(u8, entry.list.items);
        }
    }
    // One txn: every key unchanged since read (its mod revision; 0 for a key not there yet),
    // then the new lists.
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(arena, "{\"compare\":[");
    for (held[0..held_count], 0..) |entry, index| {
        var key_buffer: [24]u8 = undefined;
        var keys: Base64 = .{};
        if (index > 0) try body.append(arena, ',');
        try body.print(arena, "{{\"key\":\"{s}\",\"target\":\"MOD\",\"result\":\"EQUAL\"," ++
            "\"mod_revision\":\"{d}\"}}", .{ keys.of(append_key(&key_buffer, entry.key)), entry.mod_revision });
    }
    try body.appendSlice(arena, "],\"success\":[");
    var puts: u32 = 0;
    for (held[0..held_count]) |entry| {
        const appended = for (txn.mops[0..txn.count]) |mop| {
            if (mop.append and mop.key == entry.key) break true;
        } else false;
        if (!appended) continue;
        var key_buffer: [24]u8 = undefined;
        var keys: Base64 = .{};
        const value = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(entry.list.items.len));
        if (puts > 0) try body.append(arena, ',');
        try body.print(arena, "{{\"request_put\":{{\"key\":\"{s}\",\"value\":\"{s}\"}}}}", .{
            keys.of(append_key(&key_buffer, entry.key)),
            std.base64.standard.Encoder.encode(value, entry.list.items),
        });
        puts += 1;
    }
    try body.appendSlice(arena, "]}");
    const buffer = try arena.alloc(u8, response_size_max);
    const response = try call(TxnResponse, address, "/v3/kv/txn", body.items, buffer);
    if (!response.succeeded) return .not_committed;
    return .{ .committed = reads };
}

fn append_key(buffer: *[24]u8, key: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "a/{d}", .{key}) catch unreachable;
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

// Checks -------------------------------------------------------------------------------------

/// The members that answer agree on the keyspace at the lowest revision they all reached.
fn members_agree(context: *System.Context) !void {
    const all = addresses(context);
    var revision_common: u64 = std.math.maxInt(u64);
    var answered: u32 = 0;
    for (all) |address| {
        var buffer: [response_size_max]u8 = undefined;
        const status = call(StatusResponse, address, "/v3/maintenance/status", "{}", &buffer) catch
            continue;
        revision_common = @min(revision_common, try revision_of(status.header));
        answered += 1;
    }
    if (answered < 2) return;
    var hashes: [members_count]?HashResponse = @splat(null);
    var buffers: [members_count][4096]u8 = undefined;
    for (all, &hashes, &buffers) |address, *hash, *buffer| {
        var body_buffer: [64]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buffer, "{{\"revision\":\"{d}\"}}", .{revision_common});
        hash.* = call(HashResponse, address, "/v3/maintenance/hashkv", body, buffer) catch null;
    }
    for (0..members_count) |a| for (a + 1..members_count) |b| {
        const first = hashes[a] orelse continue;
        const second = hashes[b] orelse continue;
        // Compacted at different revisions, the hashes cover different histories.
        if (!std.mem.eql(u8, first.compact_revision, second.compact_revision)) continue;
        sdk.always(first.hash == second.hash, "members agree on the keyspace at a revision", .{
            .first = member_names[a],
            .second = member_names[b],
            .revision = revision_common,
        });
    };
}

/// Faults are over: a write commits, and every member reaches the same revision and keyspace.
fn recovers(context: *System.Context) !void {
    const all = addresses(context);
    _ = sdk.retry(recovery_attempts_max, 250, put_anywhere, .{ &all, "recovered", "yes" }) catch |err| {
        sdk.assert_unreachable("no write commits once faults stop", .{ .err = @errorName(err) });
        return err;
    };
    sdk.retry(recovery_attempts_max, 250, converged, .{&all}) catch |err| {
        sdk.assert_unreachable("members never converge once faults stop", .{
            .err = @errorName(err),
        });
        return err;
    };
}

/// The same revision on every member, and the same keyspace hash where the gateway serves
/// hashkv (etcd 3.4's, the `jepsen` profile, does not).
fn converged(all: *const [members_count][4]u8) !void {
    var revision_first: ?u64 = null;
    var hash_first: ?u32 = null;
    for (all) |address| {
        var buffer: [4096]u8 = undefined;
        const status = try call(StatusResponse, address, "/v3/maintenance/status", "{}", &buffer);
        const revision = try revision_of(status.header);
        var body_buffer: [64]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buffer, "{{\"revision\":\"{d}\"}}", .{revision});
        const hash: ?u32 = if (call(HashResponse, address, "/v3/maintenance/hashkv", body, &buffer)) |answer|
            answer.hash
        else |err| switch (err) {
            error.NoAnswer => null,
            else => return err,
        };
        if (revision_first) |first| {
            if (first != revision) return error.NotConverged;
            if (hash_first != null and hash != null and hash_first.? != hash.?) return error.NotConverged;
        } else {
            revision_first = revision;
            hash_first = hash;
        }
    }
}

/// Faults are over: every acknowledged write is there with its value, and the counter holds
/// at least the acknowledged increments, at most those and the unknown ones.
fn writes_survive(context: *System.Context) !void {
    const all = addresses(context);
    const arena = context.init.arena.allocator();
    const log = std.Io.Dir.cwd().readFileAlloc(context.init.io, acked_path, arena, .limited(1 << 26)) catch |err| switch (err) {
        error.FileNotFound => return, // Nothing was acknowledged.
        else => return err,
    };
    const stored = sdk.retry(recovery_attempts_max, 250, written_read, .{ &all, arena }) catch |err| {
        sdk.assert_unreachable("the written keys cannot be read once faults stop", .{
            .err = @errorName(err),
        });
        return err;
    };
    var acknowledged: u64 = 0;
    var missing: u64 = 0;
    var changed: u64 = 0;
    var increments: u64 = 0;
    var unknown: u64 = 0;
    var lines = std.mem.tokenizeScalar(u8, log, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const kind = fields.next() orelse continue;
        const first = fields.next() orelse continue;
        if (std.mem.eql(u8, kind, "increment")) {
            if (std.mem.eql(u8, first, "acknowledged")) increments += 1 else unknown += 1;
            continue;
        }
        const value = fields.next() orelse continue;
        acknowledged += 1;
        const found = stored.get(first) orelse {
            missing += 1;
            continue;
        };
        if (!std.mem.eql(u8, found, value)) changed += 1;
    }
    sdk.always(missing == 0 and changed == 0, "every acknowledged write survives", .{
        .acknowledged = acknowledged,
        .missing = missing,
        .changed = changed,
    });
    var value_buffer: [32]u8 = undefined;
    const counter = sdk.retry(recovery_attempts_max, 250, get, .{ all[0], counter_key, &value_buffer }) catch |err| {
        sdk.assert_unreachable("the counter cannot be read once faults stop", .{ .err = @errorName(err) });
        return err;
    };
    const value = std.fmt.parseInt(u64, counter.value orelse "0", 10) catch return error.BadCounter;
    const counted = value >= increments and value <= increments + unknown;
    sdk.always(counted, "the counter counts every acknowledged increment and no more", .{
        .value = value,
        .acknowledged = increments,
        .unknown = unknown,
    });
}

/// Every written key and its value, read a page at a time from one member that answers.
fn written_read(
    all: *const [members_count][4]u8,
    arena: std.mem.Allocator,
) !std.StringHashMapUnmanaged([]const u8) {
    const address = all[sdk.random_below(members_count)];
    var stored: std.StringHashMapUnmanaged([]const u8) = .empty;
    var start: []const u8 = written_prefix;
    while (true) {
        var keys: Base64 = .{};
        var ends: Base64 = .{};
        var body_buffer: [request_size_max]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buffer, "{{\"key\":\"{s}\",\"range_end\":\"{s}\"," ++
            "\"limit\":\"{d}\"}}", .{ keys.of(start), ends.of(written_end), page_size });
        const buffer = try arena.alloc(u8, response_size_max);
        const page = try call(RangeResponse, address, "/v3/kv/range", body, buffer);
        for (page.kvs) |entry| {
            const key = try decoded(try arena.alloc(u8, entry.key.len), entry.key);
            const value = try decoded(try arena.alloc(u8, entry.value.len), entry.value);
            try stored.put(arena, key, value);
        }
        if (!page.more or page.kvs.len == 0) return stored;
        // The next page starts just after this one's last key.
        const last = try decoded(try arena.alloc(u8, page.kvs[page.kvs.len - 1].key.len), page.kvs[page.kvs.len - 1].key);
        start = try std.mem.concat(arena, u8, &.{ last, "\x00" });
    }
}
