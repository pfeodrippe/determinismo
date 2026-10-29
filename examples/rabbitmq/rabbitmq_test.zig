// SPDX-License-Identifier: MIT
//! Example test program: RabbitMQ 4.1, a cluster of three nodes and a quorum queue (Raft, three
//! replicas), checked as Jepsen's queue tests check one (total-queue): every message the cluster
//! confirmed is dequeued in the end, nothing is dequeued that was never enqueued, and nothing it
//! refused. Redeliveries are RabbitMQ's at-least-once (a message got and not acknowledged comes
//! back): counted, not failed.
//!
//! Drivers are client processes: each opens a connection to the client node (rclient.py, pika
//! behind a line protocol) and enqueues persistent messages with publisher confirms, or dequeues
//! (basic.get, then an acknowledgement), through a node drawn each time. Each outcome is noted in
//! the runner (/tmp/rabbitmq-ops.log, one write per line). Once faults stop, the queue is drained
//! through every node, then judged.
//! Faults: the default ones (pauses, partitions, degraded links, sync stalls, throttling) in
//! bursts, restarts, power losses and graceful stops of the brokers; the client node's links to
//! the brokers faulted, the drivers' calls into it not.
//!
//!   determinismo explore ... --memory-mib 4096 --program zig-out/bin/rabbitmq-test --scenario queue
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo");
const tcp = sdk.tcp;

const Nodes = struct {
    @"rabbit-1": sdk.Node,
    @"rabbit-2": sdk.Node,
    @"rabbit-3": sdk.Node,
    rclient: sdk.Node,
};
const System = sdk.System(Nodes);

const client_port = 7000;
const amqp_port = 5672;
const queue = "jepsen";
const brokers = 3;
const ops_path = "/tmp/rabbitmq-ops.log";
const operations_per_driver = 20;
const setup_attempts_max = 300;
/// Draining once faults stop: the queue read until every node answered empty this many times
/// in a row (a node just back may not serve yet), with a minute of attempts for errors.
const empty_streak = 3;
const drain_attempts_max = 120;
/// A node failing every dequeue for this long (virtual time) is left out of the drain: a dead
/// one costs a connection timeout each time.
const node_down_ns = 60 * std.time.ns_per_s;
const drain_dequeues_max = 100_000;
/// An operation's answer at most: the client's own timeouts are 5 to 10 s (rclient.py).
const timeout_ms = 30_000;
const line_size_max = 512;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .queue = queue_scenario },
    });
}

/// `default`: the brokers' disks with a host's 30 s writeback window (schema.Node.writeback_s):
/// RabbitMQ leaves its feature flags file and Mnesia's tables to writeback, and the guest's
/// strict model (nothing written back unasked) bricked nodes after power losses at any age
/// (README). `flags-unsynced`: strict, the feature flags finding's profile.
fn describe(d: *System.Describe) !void {
    inline for (.{ "default", "flags-unsynced" }) |profile_name| {
        try describe_profile(try d.profile(profile_name), profile_name);
    }
}

fn describe_profile(profile: anytype, comptime profile_name: []const u8) !void {
    const strict = comptime std.mem.eql(u8, profile_name, "flags-unsynced");
    const build: sdk.schema.Build = .{ .context = ".", .dockerfile = "examples/rabbitmq/Dockerfile" };
    inline for (.{ "rabbit-1", "rabbit-2", "rabbit-3" }, 1..) |name, id| {
        profile.node(@field(System.Name, name), .{
            .build = build,
            .command = &.{ "broker", std.fmt.comptimePrint("{d}", .{id}) },
            .ready = .{ .tcp = amqp_port },
            .faults = .{ .restart = true, .crash = true, .stop = true },
            .writeback_s = if (strict) null else 30,
        });
    }
    profile.node(.rclient, .{
        .build = build,
        .command = &.{"client"},
        .ready = .{ .tcp = client_port },
        // The client library's node, as Jepsen's clients: its links to the brokers faulted, the
        // drivers' calls into it not, and it is never paused or slowed.
        .faults = .{
            .pause = false,
            .runner_links = false,
            .sync_stall = false,
            .throttle = false,
            .process_pause = false,
        },
    });
}

fn queue_scenario(s: *System.Scenario) void {
    // Faults in bursts with quiet stretches between them (Kafka's: brokers restarted every two
    // seconds or so never came back).
    s.pacing = .{ .active_ms_max = 10_000, .quiet_ms_max = 30_000 };
    s.setup("queue", queue_declared);
    s.parallel_driver("enqueue", enqueues);
    s.parallel_driver("dequeue", dequeues);
    s.eventually("drain", drained);
}

const Client = struct {
    connection: tcp.Connection,
    line: [line_size_max]u8 = undefined,

    fn open(client: *Client, context: *System.Context) !void {
        try client.connection.open(context.nodes.rclient.address, client_port, .{ .timeout_ms = timeout_ms });
    }

    /// One request line, one reply line (valid until the next request).
    fn request(client: *Client, comptime format: []const u8, arguments: anytype) ![]const u8 {
        const line = try std.fmt.bufPrint(&client.line, format ++ "\n", arguments);
        try client.connection.write_all(line);
        return client.connection.read_line();
    }
};

// Setup -----------------------------------------------------------------------------------------

/// The cluster of three formed, then the queue declared on it (a quorum queue takes its members
/// from the cluster as it is: declared earlier, it would have fewer replicas).
fn queue_declared(context: *System.Context) !void {
    _ = try sdk.retry(setup_attempts_max, 500, cluster_formed, .{context});
    _ = try sdk.retry(setup_attempts_max, 500, queue_declare, .{context});
}

fn cluster_formed(context: *System.Context) !void {
    var buffer: [16 * 1024]u8 = undefined;
    const node = &context.nodes.@"rabbit-1";
    const result = try node.exec_output(&.{ "rabbitmqctl", "-q", "cluster_status", "--formatter", "json" }, &buffer);
    if (result.status != 0) return error.NotFormed;
    const Status = struct { running_nodes: []const []const u8 = &.{} };
    const status = std.json.parseFromSliceLeaky(Status, context.init.arena.allocator(), result.output, .{
        .ignore_unknown_fields = true,
    }) catch return error.NotFormed;
    if (status.running_nodes.len < brokers) return error.NotFormed;
}

fn queue_declare(context: *System.Context) !void {
    var client: Client = undefined;
    try client.open(context);
    defer client.connection.close();
    const reply = try client.request("declare 1 {s}", .{queue});
    if (std.mem.eql(u8, reply, "ok")) return;
    sdk.event("rabbitmq_error", .{ .command = "declare", .reply = reply });
    return error.NotDeclared;
}

// The workload ----------------------------------------------------------------------------------

fn enqueues(context: *System.Context) !void {
    var id: u64 = undefined;
    sdk.random_bytes(std.mem.asBytes(&id));
    id &= 0xff_ffff;
    var client: Client = undefined;
    client.open(context) catch |err| {
        if (tcp.unavailable(err)) return;
        return err;
    };
    defer client.connection.close();
    for (0..operations_per_driver) |sequence| {
        const value = (id << 12) | sequence;
        const node = 1 + sdk.random_below(brokers);
        // Noted before it is sent, as Jepsen's invocations: a driver killed as its phase ends,
        // during the publish, leaves a message that may be in the queue (its dequeue is no
        // phantom). Invoked alone, its outcome is unknown.
        note("e", value);
        const reply = client.request("enqueue {d} {s} {d}", .{ node, queue, value }) catch {
            // No answer: it may have been confirmed, and the connection is done.
            note("e?", value);
            sdk.sometimes(true, "an enqueue got no answer", .{});
            return;
        };
        if (std.mem.eql(u8, reply, "ok")) {
            note("e+", value);
            sdk.sometimes(true, "a message was confirmed", .{});
        } else if (std.mem.eql(u8, reply, "nack")) {
            note("e-", value);
            sdk.sometimes(true, "a message was refused", .{});
        } else {
            note("e?", value);
            sdk.sometimes(true, "an enqueue's outcome is unknown", .{ .reply = reply });
        }
    }
}

fn dequeues(context: *System.Context) !void {
    var client: Client = undefined;
    client.open(context) catch |err| {
        if (tcp.unavailable(err)) return;
        return err;
    };
    defer client.connection.close();
    for (0..operations_per_driver) |_| {
        const node = 1 + sdk.random_below(brokers);
        const reply = client.request("dequeue {d} {s}", .{ node, queue }) catch return;
        _ = dequeue_noted(reply);
    }
}

/// A dequeue's reply noted ("d <value>" acknowledged, "d? <value>" got and maybe not): whether
/// the queue answered empty.
fn dequeue_noted(reply: []const u8) enum { value, empty, other } {
    if (std.mem.startsWith(u8, reply, "value ")) {
        const value = std.fmt.parseInt(u64, reply["value ".len..], 10) catch return .other;
        note("d", value);
        sdk.sometimes(true, "a message was dequeued", .{});
        return .value;
    }
    if (std.mem.eql(u8, reply, "empty")) {
        sdk.sometimes(true, "a dequeue found the queue empty", .{});
        return .empty;
    }
    if (std.mem.startsWith(u8, reply, "unknown ")) {
        var words = std.mem.tokenizeScalar(u8, reply["unknown ".len..], ' ');
        if (std.fmt.parseInt(u64, words.next() orelse "", 10)) |value| note("d?", value) else |_| {}
    }
    return .other;
}

/// One operation, appended to the runner's log in one write: "<kind> <value>".
fn note(kind: []const u8, value: u64) void {
    var buffer: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{s} {d}\n", .{ kind, value }) catch return;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
    const fd = linux.open(ops_path, flags, 0o644);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.write(@intCast(fd), line.ptr, line.len);
}

// Once faults stop --------------------------------------------------------------------------------

fn drained(context: *System.Context) !void {
    // Every node in turn, until each that answers said empty `empty_streak` times running; a
    // node failing every dequeue for `node_down_ns` is left out (down for good: a quorum queue
    // serves from a majority).
    var client: Client = undefined;
    _ = try sdk.retry(drain_attempts_max, 500, client_opened, .{ context, &client });
    defer client.connection.close();
    var streaks: [brokers]u32 = @splat(0);
    // When each node's current run of failures began (null: it answered last).
    var failing_since: [brokers]?u64 = @splat(null);
    var left: [brokers]bool = @splat(false);
    var dequeued: u64 = 0;
    var at: usize = 0;
    const done = while (dequeued < drain_dequeues_max) {
        var serving: u32 = 0;
        var empty: u32 = 0;
        for (streaks, left) |streak, out| {
            if (out) continue;
            serving += 1;
            empty += @intFromBool(streak >= empty_streak);
        }
        if (serving == 0) break false;
        if (empty == serving) break true;
        while (left[at]) at = (at + 1) % brokers;
        const answered = if (client.request("dequeue {d} {s}", .{ at + 1, queue })) |reply| switch (dequeue_noted(reply)) {
            .value => value: {
                dequeued += 1;
                streaks = @splat(0);
                break :value true;
            },
            .empty => empty: {
                streaks[at] += 1;
                break :empty true;
            },
            .other => false,
        } else |_| reopened: {
            client.connection.close();
            _ = try sdk.retry(drain_attempts_max, 500, client_opened, .{ context, &client });
            break :reopened false;
        };
        if (answered) {
            failing_since[at] = null;
        } else {
            const now = monotonic_ns();
            const since = failing_since[at] orelse now;
            failing_since[at] = since;
            left[at] = now - since >= node_down_ns;
            sdk.sleep_ms(500);
        }
        at = (at + 1) % brokers;
    } else false;
    var left_out: u32 = 0;
    for (left) |out| left_out += @intFromBool(out);
    sdk.always(done, "the queue can be drained once faults stop", .{
        .dequeued = dequeued,
        .nodes_left_out = left_out,
    });
    try judge(context);
}

fn client_opened(context: *System.Context, client: *Client) !void {
    try client.open(context);
}

/// What the log says: each value's enqueue outcome and how often it was dequeued.
fn judge(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const log = std.Io.Dir.cwd().readFileAlloc(context.init.io, ops_path, arena, .limited(1 << 26)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    const counts = try tally(arena, log);
    sdk.always(counts.lost == 0, "every confirmed message is dequeued", counts);
    sdk.always(counts.unexpected == 0, "nothing is dequeued that was never enqueued", counts);
    sdk.always(counts.refused_dequeued == 0, "no refused message is dequeued", counts);
    sdk.sometimes(counts.redelivered > 0, "a message is dequeued twice (redelivered)", counts);
}

const Tally = struct {
    confirmed: u64 = 0,
    /// Confirmed, and never dequeued (nor maybe).
    lost: u64 = 0,
    /// Dequeued, never enqueued.
    unexpected: u64 = 0,
    /// Refused (nack), and dequeued.
    refused_dequeued: u64 = 0,
    /// Dequeued more than once.
    redelivered: u64 = 0,
    example_lost: u64 = 0,
};

fn tally(arena: std.mem.Allocator, log: []const u8) !Tally {
    const Seen = struct { invoked: bool = false, enqueued: u8 = 0, dequeued: u32 = 0, maybe_dequeued: u32 = 0 };
    var values: std.AutoHashMapUnmanaged(u64, Seen) = .empty;
    var lines = std.mem.tokenizeScalar(u8, log, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const kind = words.next() orelse continue;
        const value = std.fmt.parseInt(u64, words.next() orelse continue, 10) catch continue;
        const entry = try values.getOrPut(arena, value);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        if (std.mem.eql(u8, kind, "e")) entry.value_ptr.invoked = true;
        if (std.mem.eql(u8, kind, "e+")) entry.value_ptr.enqueued = '+';
        if (std.mem.eql(u8, kind, "e-")) entry.value_ptr.enqueued = '-';
        if (std.mem.eql(u8, kind, "e?")) entry.value_ptr.enqueued = '?';
        if (std.mem.eql(u8, kind, "d")) entry.value_ptr.dequeued += 1;
        if (std.mem.eql(u8, kind, "d?")) entry.value_ptr.maybe_dequeued += 1;
    }
    var counts: Tally = .{};
    var example_lost: ?u64 = null;
    var iterator = values.iterator();
    while (iterator.next()) |entry| {
        const seen = entry.value_ptr.*;
        if (seen.enqueued == '+') counts.confirmed += 1;
        if (seen.enqueued == '+' and seen.dequeued + seen.maybe_dequeued == 0) {
            counts.lost += 1;
            example_lost = @min(example_lost orelse entry.key_ptr.*, entry.key_ptr.*);
        }
        if (!seen.invoked and seen.enqueued == 0 and seen.dequeued > 0) counts.unexpected += 1;
        if (seen.enqueued == '-' and seen.dequeued > 0) counts.refused_dequeued += 1;
        if (seen.dequeued > 1) counts.redelivered += 1;
    }
    counts.example_lost = example_lost orelse 0;
    return counts;
}

test tally {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const log =
        \\e 1
        \\e+ 1
        \\e 2
        \\e+ 2
        \\e 3
        \\e- 3
        \\e 4
        \\e? 4
        \\e 5
        \\e+ 5
        \\e 6
        \\d 6
        \\d 1
        \\d 1
        \\d 3
        \\d 9
        \\d? 5
        \\
    ;
    const counts = try tally(arena.allocator(), log);
    try std.testing.expectEqual(3, counts.confirmed);
    try std.testing.expectEqual(1, counts.lost); // 2: confirmed, never dequeued.
    try std.testing.expectEqual(2, counts.example_lost);
    try std.testing.expectEqual(1, counts.unexpected); // 9.
    try std.testing.expectEqual(1, counts.refused_dequeued); // 3.
    try std.testing.expectEqual(1, counts.redelivered); // 1, twice.
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}
