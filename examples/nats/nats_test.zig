// SPDX-License-Identifier: MIT
//! Example test program: NATS JetStream (github.com/nats-io/nats-server, v2.15.2), three servers
//! and one stream replicated on all three, following Jepsen's NATS 2.12.1 analysis (2025): it
//! lost acknowledged messages and split into diverging replicas after power failures, flushing
//! to disk every two minutes by default.
//!
//! Producers publish unique messages ("<producer>-<n>") through random servers and note every
//! one JetStream acknowledged, with its stream sequence, in the runner
//! (/tmp/nats-acked.log, one write per line). Properties:
//!   acknowledged publishes survive   after faults, a consumer reads every acknowledged message
//!   sequences are unique             two acknowledgements never give one sequence to two messages
//!   reads are in order, nothing made up
//!                                    a consumer reads in sequence order, each sequence once, and
//!                                    only messages that were published
//!   replicas converge                after faults, every server's copy of the stream (its /jsz)
//!                                    has the same messages and last sequence
//! Profiles: `default` (NATS's defaults: acknowledged before flushed, so a power loss on enough
//! servers loses acknowledged messages, as NATS now documents) and `sync` (flushed before every
//! acknowledgement: any lost acknowledged message is a bug). Faults: the default ones, restarts,
//! graceful stops and power losses (each server's data on its own disk), and stalls and power
//! losses at the servers' syncs.
//!
//!   determinismo explore ... --program zig-out/bin/nats-test --profile sync --scenario queue
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");
const Client = @import("client.zig").Client;
const ack_stream_sequence = @import("client.zig").ack_stream_sequence;

const Nodes = struct { @"nats-1": sdk.Node, @"nats-2": sdk.Node, @"nats-3": sdk.Node };
const System = sdk.System(Nodes);
const server_names = [_][]const u8{ "nats-1", "nats-2", "nats-3" };
const servers_count = server_names.len;

const client_port = 4222;
const monitor_port = 8222;
const routes = "nats://nats-1:6222,nats://nats-2:6222,nats://nats-3:6222";
const stream = "jepsen";
const subject = "jepsen.queue";
/// A publish waits out a leader election.
const timeout_ms = 5000;
const acked_path = "/tmp/nats-acked.log";
const publishes_per_driver = 50;
const fetch_batch = 256;
const setup_attempts_max = 300;
const recovery_attempts_max = 120;
const reply_size_max = 64 * 1024;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{ .queue = queue } });
}

fn describe(d: *System.Describe) !void {
    inline for (.{ "default", "sync" }) |profile_name| {
        const profile = try d.profile(profile_name);
        inline for (server_names) |name| {
            profile.node(@field(System.Name, name), .{
                .build = .{ .context = ".", .dockerfile = "examples/nats/Dockerfile" },
                .command = &.{
                    "-c",                  "/etc/nats/" ++ profile_name ++ ".conf",
                    "-n",                  name,
                    "-js",                 "--cluster_name",
                    "determinismo",        "--cluster",
                    "nats://0.0.0.0:6222", "--routes",
                    routes,                "-m",
                    "8222",
                },
                .ready = .{ .tcp = client_port },
                // A wipe is left out: a server that lost its data rejoins as a new one.
                .faults = .{ .restart = true, .crash = true, .stop = true },
            });
        }
    }
}

fn queue(s: *System.Scenario) void {
    s.setup("stream", stream_created);
    s.parallel_driver("publish", publish_many);
    s.eventually("read", messages_survive);
    s.eventually("converge", replicas_converge);
}

fn addresses(context: *System.Context) [servers_count][4]u8 {
    return .{
        context.nodes.@"nats-1".address,
        context.nodes.@"nats-2".address,
        context.nodes.@"nats-3".address,
    };
}

fn no_answer(err: anyerror) bool {
    return switch (err) {
        error.NoResponders, error.Refused, error.JetStreamError => true,
        else => sdk.tcp.unavailable(err),
    };
}

// Setup --------------------------------------------------------------------------------------

/// The stream, replicated on every server: created once the cluster has a meta leader.
fn stream_created(context: *System.Context) !void {
    const all = addresses(context);
    _ = try sdk.retry(setup_attempts_max, 200, stream_create, .{&all});
}

fn stream_create(all: *const [servers_count][4]u8) !void {
    var client: Client = undefined;
    try client.open(all[sdk.random_below(servers_count)], client_port, .{ .timeout_ms = timeout_ms });
    defer client.close();
    const config = "{\"name\":\"" ++ stream ++ "\",\"subjects\":[\"" ++ subject ++ "\"]," ++
        "\"num_replicas\":3,\"storage\":\"file\",\"allow_direct\":true}";
    var buffer: [4096]u8 = undefined;
    const reply = try client.request("$JS.API.STREAM.CREATE." ++ stream, config, &buffer);
    if (reply.status != 0) return error.NoResponders;
    if (std.mem.indexOf(u8, reply.payload, "\"error\"") != null) {
        // Created already by an earlier attempt whose answer was lost: fine.
        if (std.mem.indexOf(u8, reply.payload, "already in use") != null) return;
        return error.JetStreamError;
    }
}

// Producers ----------------------------------------------------------------------------------

/// Unique messages through random servers, one at a time; each acknowledged one is noted with
/// the sequence JetStream gave it.
fn publish_many(context: *System.Context) !void {
    const all = addresses(context);
    var id: [4]u8 = undefined;
    sdk.random_bytes(&id);
    var client: Client = undefined;
    var connected = false;
    defer if (connected) client.close();
    for (0..publishes_per_driver) |sequence| {
        if (!connected) {
            client.open(all[sdk.random_below(servers_count)], client_port, .{ .timeout_ms = timeout_ms }) catch |err| {
                if (!no_answer(err)) return err;
                continue;
            };
            connected = true;
        }
        var message_buffer: [32]u8 = undefined;
        const message = try std.fmt.bufPrint(&message_buffer, "{x}-{d}", .{ id, sequence });
        const stream_sequence = publish(&client, message) catch |err| {
            if (!no_answer(err)) return err;
            sdk.sometimes(true, "a publish got no acknowledgement", .{ .err = @errorName(err) });
            // A broken connection: the next publish opens another, to a random server.
            client.close();
            connected = false;
            continue;
        };
        acked_note(message, stream_sequence);
        sdk.sometimes(true, "a publish was acknowledged", .{});
    }
}

fn publish(client: *Client, message: []const u8) !u64 {
    var buffer: [4096]u8 = undefined;
    const reply = try client.request(subject, message, &buffer);
    if (reply.status == 503) return error.NoResponders;
    const Ack = struct { stream: []const u8 = "", seq: u64 = 0, @"error": ?std.json.Value = null };
    var parse_buffer: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&parse_buffer);
    const ack = std.json.parseFromSliceLeaky(Ack, fixed.allocator(), reply.payload, .{
        .ignore_unknown_fields = true,
    }) catch return error.BadReply;
    if (ack.@"error" != null or ack.seq == 0) return error.JetStreamError;
    return ack.seq;
}

/// "<message> <sequence>", appended in one write.
fn acked_note(message: []const u8, stream_sequence: u64) void {
    var line_buffer: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buffer, "{s} {d}\n", .{ message, stream_sequence }) catch
        unreachable;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
    const fd = linux.open(acked_path, flags, 0o644);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.write(@intCast(fd), line.ptr, line.len);
}

// Checks -------------------------------------------------------------------------------------

/// Faults are over: a consumer reads the whole stream, in order, and finds every acknowledged
/// message; no sequence was given to two messages.
fn messages_survive(context: *System.Context) !void {
    const all = addresses(context);
    const arena = context.init.arena.allocator();
    const log = std.Io.Dir.cwd().readFileAlloc(context.init.io, acked_path, arena, .limited(1 << 26)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    // What each acknowledgement said: message to sequence, and sequence to message.
    var acked: std.StringHashMapUnmanaged(u64) = .empty;
    var by_sequence: std.AutoHashMapUnmanaged(u64, []const u8) = .empty;
    var shared: u64 = 0;
    var lines = std.mem.tokenizeScalar(u8, log, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const message = fields.next() orelse continue;
        const sequence = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;
        try acked.put(arena, message, sequence);
        const entry = try by_sequence.getOrPut(arena, sequence);
        if (entry.found_existing and !std.mem.eql(u8, entry.value_ptr.*, message)) shared += 1;
        entry.value_ptr.* = message;
    }
    sdk.always(shared == 0, "no two acknowledged messages share a stream sequence", .{
        .shared = shared,
    });
    const read = sdk.retry(recovery_attempts_max, 250, stream_read, .{ &all, arena }) catch |err| {
        sdk.assert_unreachable("the stream cannot be read once faults stop", .{
            .err = @errorName(err),
        });
        return err;
    };
    var lost: u64 = 0;
    var moved: u64 = 0;
    var iterator = acked.iterator();
    while (iterator.next()) |entry| {
        const sequence = read.get(entry.key_ptr.*) orelse {
            lost += 1;
            continue;
        };
        if (sequence != entry.value_ptr.*) moved += 1;
    }
    sdk.always(lost == 0, "every acknowledged publish is read back", .{
        .acknowledged = acked.count(),
        .lost = lost,
        .read = read.count(),
    });
    sdk.always(moved == 0, "an acknowledged message is read at the sequence its " ++
        "acknowledgement gave", .{ .moved = moved });
}

/// The whole stream through a consumer (on a random server): message to sequence. Checks as it
/// reads that sequences come in order, once each, and messages are ones published.
fn stream_read(all: *const [servers_count][4]u8, arena: std.mem.Allocator) !std.StringHashMapUnmanaged(u64) {
    var client: Client = undefined;
    try client.open(all[sdk.random_below(servers_count)], client_port, .{ .timeout_ms = timeout_ms });
    defer client.close();
    var buffer: [reply_size_max]u8 = undefined;
    const config = "{\"stream_name\":\"" ++ stream ++ "\",\"config\":{\"ack_policy\":\"none\"," ++
        "\"deliver_policy\":\"all\",\"mem_storage\":true,\"num_replicas\":1," ++
        "\"inactive_threshold\":60000000000}}";
    const created = try client.request("$JS.API.CONSUMER.CREATE." ++ stream, config, &buffer);
    if (created.status != 0) return error.NoResponders;
    const Created = struct { name: []const u8 = "", @"error": ?std.json.Value = null };
    const consumer = std.json.parseFromSliceLeaky(Created, arena, created.payload, .{
        .ignore_unknown_fields = true,
    }) catch return error.BadReply;
    if (consumer.@"error" != null or consumer.name.len == 0) return error.JetStreamError;
    const next_subject = try std.fmt.allocPrint(arena, "$JS.API.CONSUMER.MSG.NEXT." ++ stream ++ ".{s}", .{consumer.name});
    var read: std.StringHashMapUnmanaged(u64) = .empty;
    var last: u64 = 0;
    var repeated: u64 = 0;
    var unknown: u64 = 0;
    while (true) {
        const pull = std.fmt.comptimePrint("{{\"batch\":{d},\"expires\":2000000000,\"no_wait\":true}}", .{fetch_batch});
        const reply_subject = try client.publish(next_subject, pull);
        var delivered: u32 = 0;
        while (delivered < fetch_batch) : (delivered += 1) {
            const message = try client.next(reply_subject, .delivery, &buffer);
            if (message.status != 0) break; // 404 no messages, 408 expired: this batch is done.
            const sequence = ack_stream_sequence(message.reply_to) orelse return error.BadReply;
            if (sequence <= last) repeated += 1;
            last = @max(last, sequence);
            if (!message_shaped(message.payload)) unknown += 1;
            try read.put(arena, try arena.dupe(u8, message.payload), sequence);
        }
        if (delivered < fetch_batch) break;
    }
    sdk.always(repeated == 0 and unknown == 0, "a consumer reads in sequence order, each " ++
        "once, only messages that were published", .{ .repeated = repeated, .unknown = unknown });
    return read;
}

/// "<8 hex digits>-<number>": what producers publish.
fn message_shaped(payload: []const u8) bool {
    const dash = std.mem.indexOfScalar(u8, payload, '-') orelse return false;
    if (dash != 8) return false;
    _ = std.fmt.parseInt(u32, payload[0..dash], 16) catch return false;
    _ = std.fmt.parseInt(u32, payload[dash + 1 ..], 10) catch return false;
    return true;
}

/// Faults are over: every server's copy of the stream reaches the same messages and last
/// sequence (each server's /jsz reports its own copy).
fn replicas_converge(context: *System.Context) !void {
    const all = addresses(context);
    sdk.retry(recovery_attempts_max, 250, converged, .{&all}) catch |err| {
        sdk.assert_unreachable("the stream's replicas never converge once faults stop", .{
            .err = @errorName(err),
        });
        return err;
    };
}

const Copy = struct { messages: u64, last_seq: u64 };

fn converged(all: *const [servers_count][4]u8) !void {
    var first: ?Copy = null;
    for (all) |address| {
        const copy = try copy_of(address);
        if (first) |known| {
            if (known.messages != copy.messages or known.last_seq != copy.last_seq) {
                return error.NotConverged;
            }
        } else first = copy;
    }
}

fn copy_of(address: [4]u8) !Copy {
    var buffer: [reply_size_max]u8 = undefined;
    const response = try sdk.tcp.http_with(address, monitor_port, "GET", "/jsz?streams=true", "", &buffer, .{ .timeout_ms = timeout_ms });
    if (response.status != 200) return error.NoAnswer;
    const State = struct { messages: u64 = 0, last_seq: u64 = 0 };
    const Detail = struct { name: []const u8 = "", state: State = .{} };
    const Account = struct { stream_detail: []const Detail = &.{} };
    const Jsz = struct { account_details: []const Account = &.{} };
    var parse_buffer: [reply_size_max]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&parse_buffer);
    const jsz = std.json.parseFromSliceLeaky(Jsz, fixed.allocator(), response.body, .{
        .ignore_unknown_fields = true,
    }) catch return error.BadReply;
    for (jsz.account_details) |account| for (account.stream_detail) |detail| {
        if (std.mem.eql(u8, detail.name, stream)) {
            return .{ .messages = detail.state.messages, .last_seq = detail.state.last_seq };
        }
    };
    return error.NoCopy;
}
