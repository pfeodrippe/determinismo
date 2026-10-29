// SPDX-License-Identifier: MIT
//! Example test program: Apache Kafka 3.8.0, three KRaft nodes (broker and controller each),
//! following Jepsen's Bufstream analysis (2024), which found KAFKA-17754 in Kafka's transaction
//! protocol itself: an EndTxn delayed in the network, a client that moved on (an abort after its
//! commit timed out, as the Java client's documentation says), and the late commit ends whatever
//! transaction the producer has open, partway. Jepsen saw aborted reads, lost writes and torn
//! transactions on Kafka under process pauses; the issue is open (KIP-890).
//!
//! Drivers are client processes: each opens a connection to the client node (KClient.java, the
//! Java client 3.8.0), which is one long-lived transactional producer, and runs transactions of
//! one to four sends to random partitions of topic `jepsen`, committing most and aborting some
//! on purpose. Each outcome is noted in the runner (/tmp/kafka-txns.log, one write per line).
//! Once faults stop, every partition is read from the beginning (read_committed):
//!   aborted reads     no value of a transaction aborted on purpose is ever read
//!   lost writes       every value of an acknowledged commit is read
//!   torn              each transaction is read all or none
//!   duplicates        no value is read twice
//! Faults: the default ones (pauses, partitions, degraded links, sync stalls, throttling),
//! restarts, power losses and graceful stops of the brokers; none on the client node.
//!
//!   determinismo explore ... --memory-mib 8192 --program zig-out/bin/kafka-test --scenario txn
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo");
const tcp = sdk.tcp;

const Nodes = struct {
    @"kafka-1": sdk.Node,
    @"kafka-2": sdk.Node,
    @"kafka-3": sdk.Node,
    kclient: sdk.Node,
};
const System = sdk.System(Nodes);

const client_port = 7000;
/// SClient's (share groups), in the client node of Kafka 4.2 and later.
const share_port = 7001;
const controller_port = 9093;
const redpanda_rpc_port = 33145;
const redpanda_explain = "for n in kafka-1 kafka-2 kafka-3; do det-nodes exec $n rpk redpanda config set " ++
    "rpk.additional_start_flags \"[--logger-log-level=tx=trace]\"; det-nodes exec $n rpk redpanda admin " ++
    "config log-level set tx --host localhost:9644 --level trace --expiry-seconds 0; done";
const topic = "jepsen";
const partitions = 4;
const replicas = 3;
const txns_path = "/tmp/kafka-txns.log";
const transactions_per_driver = 20;
/// No transaction begins past this much of a command's time (the guest's clock): Redpanda's
/// under faults sat in the client's 10 s timeouts, a command took 80 s, and a timeline's 41 to
/// 63 commands ran past its hour (run 177: "the guest finishes its scenario" failed with the
/// drivers still running, faults with them). Apache Kafka's 20 take a few seconds.
const driver_budget_ns = 20 * std.time.ns_per_s;
const sends_max = 4;
/// One transaction in a few aborted on purpose (its writes must never be read).
const abort_one_in = 5;
const setup_attempts_max = 300;
const read_attempts_max = 120;
/// Waiting for every transaction to complete once faults stop: a minute, 500 ms apart.
const stable_attempts_max = 120;
/// A transaction's answer at most: the producer's own timeouts are 10 s (KClient.java).
const timeout_ms = 30_000;
const line_size_max = 512;
const share_topic = "queue";
const share_partitions = 3;
const share_group = "jepsen";
const share_path = "/tmp/kafka-share.log";
const produces_per_driver = 20;
const consumes_per_driver = 20;
/// A poll answers up to 1 s, a commit 10 s more (SClient.java).
const share_timeout_ms = 30_000;
/// The drain ends after this many empty polls in a row (each up to a second): past the records'
/// acquisition locks (30 s by default), which consumers that went away may still hold.
const drain_empty_max = 45;
const drain_polls_max = 600;
const share_reply_size_max = 64 * 1024;
/// Violations reported one by one; past these, counted.
const share_reported_max = 8;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .txn = txn_scenario, .share = share_scenario },
        // Each partition a list, each send an append to it, each partition read once faults stop
        // (Jepsen's Kafka checker is Elle too): what the checks below cannot see, transactions
        // ordered one way in a partition and the other way in another (G0, G1c).
        // G0 (write cycles) Jepsen saw on Kafka in normal operation, at both isolation levels
        // (the Bufstream analysis, 2024: "either the documentation is wrong or Kafka's
        // transaction isolation is broken"); on its own it fills this property (run 67: 14
        // timelines of 87, G0 alone). Reported apart; anything else fails it.
        .checks = .{ .elle = sdk.elle.check(.{ .consistency = "read-committed", .allowed = &.{"G0"} }) },
    });
}

/// `default`: the format's bootstrap.checkpoint made durable (start.sh), so that a power loss
/// soon after it does not brick a broker (found here, README) and hide the rest, and each write
/// forced to disk before it counts (log.flush.interval.messages=1): Kafka's defaults lose what
/// its replicas acknowledged when they all lose power within the kernel's writeback window, by
/// design (README), which would hide the rest too.
/// `format-unsynced`: formatted as Kafka does it, that finding's profile.
/// `unflushed`: Kafka's flushing as it comes, the lost writes above expected.
/// `coverage`: the default's, on Java 25 with determinismo's coverage agent on the brokers'
/// coordinators, replication and log (Dockerfile.coverage): new broker code is new behavior.
/// `kafka-4.4`: the default's on Kafka 4.4.0, the latest release, brokers and client
/// (Dockerfile.4.4: transactions v2). `kafka-4.4-coverage`: the same with the coverage agent, as
/// `coverage` (Dockerfile.4.4.coverage): run 68, with it, found what run 67, without, did not.
/// `redpanda`: Redpanda's brokers in Kafka's place (Dockerfile.redpanda).
fn describe(d: *System.Describe) !void {
    inline for (.{ "default", "format-unsynced", "unflushed", "coverage", "kafka-4.4", "kafka-4.4-coverage", "redpanda" }) |profile_name| {
        try describe_profile(try d.profile(profile_name), profile_name);
    }
}

fn describe_profile(profile: anytype, comptime profile_name: []const u8) !void {
    const coverage = comptime std.mem.eql(u8, profile_name, "coverage") or
        std.mem.eql(u8, profile_name, "kafka-4.4-coverage");
    // Redpanda speaks Kafka's protocol: its brokers in place of Kafka's, the same client and
    // checks.
    const redpanda = comptime std.mem.eql(u8, profile_name, "redpanda");
    // Causality's explanation: Redpanda's transaction logger at trace, in the running brokers
    // and in their start flags (an outage restarts them), as the one that explained run 177's
    // open transaction.
    if (redpanda) profile.explain = redpanda_explain;
    const build: sdk.schema.Build = .{
        .context = ".",
        .dockerfile = if (comptime std.mem.eql(u8, profile_name, "kafka-4.4-coverage"))
            "examples/kafka/Dockerfile.4.4.coverage"
        else if (coverage)
            "examples/kafka/Dockerfile.coverage"
        else if (comptime std.mem.eql(u8, profile_name, "kafka-4.4"))
            "examples/kafka/Dockerfile.4.4"
        else
            "examples/kafka/Dockerfile",
    };
    const brokers_build: sdk.schema.Build = if (redpanda)
        .{ .context = ".", .dockerfile = "examples/kafka/Dockerfile.redpanda" }
    else
        build;
    const format = if (comptime std.mem.eql(u8, profile_name, "format-unsynced")) profile_name else "synced";
    const flush = if (comptime std.mem.eql(u8, profile_name, "unflushed")) profile_name else "flushed";
    inline for (.{ "kafka-1", "kafka-2", "kafka-3" }, 1..) |name, id| {
        const number = std.fmt.comptimePrint("{d}", .{id});
        profile.node(@field(System.Name, name), .{
            .build = brokers_build,
            .command = if (redpanda)
                &.{ "redpanda", number }
            else if (coverage)
                &.{ "broker", number, format, flush, "coverage" }
            else
                &.{ "broker", number, format, flush },
            // The controller's port (Redpanda's RPC port): open at once. The broker's opens once
            // the quorum formed, which needs the nodes started after this one.
            .ready = .{ .tcp = if (redpanda) redpanda_rpc_port else controller_port },
            .faults = .{ .restart = true, .crash = true, .stop = true },
        });
    }
    profile.node(.kclient, .{
        .build = build,
        .command = &.{"client"},
        .ready = .{ .tcp = client_port },
        // The client library's node, as Jepsen's clients: its links to the brokers are
        // faulted (KAFKA-17754 needs an EndTxn delayed on its way to the coordinator), the
        // drivers' calls into it are not, and it is never paused or slowed.
        .faults = .{
            .pause = false,
            .runner_links = false,
            .sync_stall = false,
            .throttle = false,
            .process_pause = false,
        },
    });
}

fn txn_scenario(s: *System.Scenario) void {
    // Faults in bursts with quiet stretches between them, as Dgraph's and YugabyteDB's: under
    // a fault every 10 to 300 ms for the whole driver phase (restarts, power losses and stops
    // among them), JVM brokers that take seconds to start were never all up again, and 9
    // timelines in 508 committed a transaction (run 56). Quiet stretches of up to 10 s were
    // still shorter than a broker's restart and the quorum's election after a burst's kills.
    s.pacing = .{ .active_ms_max = 10_000, .quiet_ms_max = 30_000 };
    s.setup("topic", topic_created);
    s.parallel_driver("txn", transactions);
    s.eventually("read", everything_read);
}

const Client = struct {
    connection: tcp.Connection,
    line: [line_size_max]u8 = undefined,

    fn open(client: *Client, context: *System.Context) !void {
        try client.connection.open(context.nodes.kclient.address, client_port, .{ .timeout_ms = timeout_ms });
    }

    /// To SClient, the share groups' client.
    fn open_share(client: *Client, context: *System.Context) !void {
        try client.connection.open(context.nodes.kclient.address, share_port, .{ .timeout_ms = share_timeout_ms });
    }

    /// One request line, one reply line (valid until the next request).
    fn request(client: *Client, comptime format: []const u8, arguments: anytype) ![]const u8 {
        const line = try std.fmt.bufPrint(&client.line, format ++ "\n", arguments);
        try client.connection.write_all(line);
        return client.connection.read_line();
    }
};

// Setup -----------------------------------------------------------------------------------------

/// The topic, and the transaction coordinators (Kafka creates their topic at the first producer's
/// start): made before faults begin, which would otherwise keep that topic from ever forming when
/// the brokers start slower (the coverage profile's agent), and no transaction would run.
fn topic_created(context: *System.Context) !void {
    _ = try sdk.retry(setup_attempts_max, 500, topic_create, .{context});
    _ = try sdk.retry(setup_attempts_max, 500, producer_start, .{context});
}

fn producer_start(context: *System.Context) !void {
    var client: Client = undefined;
    try client.open(context);
    defer client.connection.close();
    const reply = try client.request("hello setup", .{});
    if (std.mem.eql(u8, reply, "ok")) return;
    sdk.event("kafka_error", .{ .command = "hello", .reply = reply });
    return error.NotStarted;
}

fn topic_create(context: *System.Context) !void {
    var client: Client = undefined;
    try client.open(context);
    defer client.connection.close();
    const reply = try client.request("create {s} {d} {d}", .{ topic, partitions, replicas });
    if (std.mem.eql(u8, reply, "ok") or std.mem.eql(u8, reply, "exists")) return;
    // Redpanda refused min.insync.replicas: created without it (its Raft majorities instead).
    if (std.mem.startsWith(u8, reply, "ok without ")) {
        sdk.event("kafka_topic", .{ .created = reply });
        return;
    }
    sdk.event("kafka_error", .{ .command = "create", .reply = reply });
    return error.NotCreated;
}

// The workload ----------------------------------------------------------------------------------

fn transactions(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const history: sdk.elle.History = .{};
    var process = sdk.elle.process_new();
    var id: u64 = undefined;
    sdk.random_bytes(std.mem.asBytes(&id));
    id &= 0xff_ffff;
    var client: Client = undefined;
    client.open(context) catch |err| {
        if (tcp.unavailable(err)) return;
        return err;
    };
    defer client.connection.close();
    const hello = client.request("hello t{d}", .{id}) catch |err| {
        if (tcp.unavailable(err)) return;
        return err;
    };
    if (!std.mem.eql(u8, hello, "ok")) {
        // No producer yet (the coordinator unavailable): nothing was sent.
        sdk.sometimes(true, "a producer could not start", .{ .reply = hello });
        return;
    }
    const started_ns = monotonic_ns();
    for (0..transactions_per_driver) |sequence| {
        if (monotonic_ns() - started_ns >= driver_budget_ns) {
            // An event, no target: Apache Kafka's commands never run out.
            sdk.event("kafka_command_budget", .{ .done = sequence });
            break;
        }
        const count = 1 + sdk.random_below(sends_max);
        const commit = sdk.random_below(abort_one_in) != 0;
        var values: [sends_max]u64 = undefined;
        var placed: [sends_max]u8 = undefined;
        var mops: [sends_max]sdk.elle.Mop = undefined;
        var buffer: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        for (0..count) |position| {
            // Unique: the client, its transaction, the send.
            values[position] = (id << 12) | (sequence << 3) | position;
            const partition = sdk.random_below(partitions);
            placed[position] = @intCast(partition);
            mops[position] = .{ .append = .{ .key = partition, .value = values[position] } };
            try writer.print(" {d}:{d}", .{ partition, values[position] });
        }
        try history.invoke(arena, process, mops[0..count]);
        const reply = client.request("txn {s} {s}{s}", .{
            if (commit) "commit" else "abort", topic, writer.buffered(),
        }) catch {
            // No answer: the transaction may have committed, and the connection is done.
            note("u", values[0..count], placed[0..count]);
            try history.info(arena, process, mops[0..count]);
            sdk.sometimes(true, "a transaction got no answer", .{});
            return;
        };
        const kind: []const u8 = if (std.mem.eql(u8, reply, "ok"))
            "c"
        else if (std.mem.eql(u8, reply, "aborted"))
            "a"
        else if (std.mem.startsWith(u8, reply, "fail"))
            "f"
        else
            "u";
        note(kind, values[0..count], placed[0..count]);
        switch (kind[0]) {
            'c' => try history.ok(arena, process, mops[0..count]),
            'a', 'f' => try history.fail(arena, process, mops[0..count]),
            else => {
                try history.info(arena, process, mops[0..count]);
                process = sdk.elle.process_new(); // Elle's rule: one operation at a time.
            },
        }
        if (kind[0] == 'c') sdk.sometimes(true, "a transaction committed", .{});
        if (kind[0] == 'a') sdk.sometimes(true, "a transaction was aborted on purpose", .{});
        if (kind[0] == 'u') sdk.sometimes(true, "a transaction's outcome is unknown", .{ .reply = reply });
    }
}

/// One transaction's outcome and writes, appended to the runner's log in one write:
/// "<c|a|f|u> <partition>:<value> <partition>:<value>...".
fn note(kind: []const u8, values: []const u64, placed: []const u8) void {
    std.debug.assert(values.len == placed.len);
    var buffer: [192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.writeAll(kind) catch return;
    for (values, placed) |value, partition| writer.print(" {d}:{d}", .{ partition, value }) catch return;
    writer.writeByte('\n') catch return;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
    const fd = linux.open(txns_path, flags, 0o644);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.write(@intCast(fd), writer.buffered().ptr, writer.buffered().len);
}

// Share groups --------------------------------------------------------------------------------

/// Queues for Kafka (KIP-932, Kafka 4.2 and later; the `kafka-4.4` profiles): producers send
/// unique values to topic `queue`, share consumers of one group poll it, acknowledge every record
/// (ACCEPT) and commit. Each poll's deliveries are noted with the driver's clock around its
/// request (/tmp/kafka-share.log). Once faults stop, a drain delivers what is left, and:
///   accepted once   a record whose acceptance committed is not delivered again: a poll begun
///                   after that commit returned never hands it out
///   none lost       every acknowledged record is delivered
///   none invented   every delivered record was produced
fn share_scenario(s: *System.Scenario) void {
    s.pacing = .{ .active_ms_max = 10_000, .quiet_ms_max = 30_000 };
    s.setup("queue", queue_created);
    s.parallel_driver("produce", share_produce);
    s.parallel_driver("consume", share_consume);
    s.finally("drain", share_drained);
}

/// The topic, the group reading from the beginning, and its share coordinator (its state topic
/// made at the first poll), before faults begin.
fn queue_created(context: *System.Context) !void {
    _ = try sdk.retry(setup_attempts_max, 500, share_topic_create, .{context});
    _ = try sdk.retry(setup_attempts_max, 500, share_request_ok, .{ context, "group " ++ share_group });
    _ = try sdk.retry(setup_attempts_max, 500, share_request_ok, .{ context, "consume " ++ share_group ++ " " ++ share_topic });
}

fn share_topic_create(context: *System.Context) !void {
    var client: Client = undefined;
    try client.open(context);
    defer client.connection.close();
    const reply = try client.request("create {s} {d} {d}", .{ share_topic, share_partitions, replicas });
    if (std.mem.eql(u8, reply, "ok") or std.mem.eql(u8, reply, "exists")) return;
    sdk.event("kafka_error", .{ .command = "create", .reply = reply });
    return error.NotCreated;
}

fn share_request_ok(context: *System.Context, line: []const u8) !void {
    var client: Client = undefined;
    try client.open_share(context);
    defer client.connection.close();
    const reply = try client.request("{s}", .{line});
    if (std.mem.startsWith(u8, reply, "ok")) return;
    sdk.event("kafka_error", .{ .command = line, .reply = reply });
    return error.NotDone;
}

fn share_produce(context: *System.Context) !void {
    var id: u64 = undefined;
    sdk.random_bytes(std.mem.asBytes(&id));
    id &= 0xff_ffff;
    var client: Client = undefined;
    client.open_share(context) catch |err| {
        if (tcp.unavailable(err)) return;
        return err;
    };
    defer client.connection.close();
    for (0..produces_per_driver) |sequence| {
        // Unique: the producer, its send.
        const value = (id << 12) | sequence;
        // Noted before it is sent: a driver killed mid-send leaves it invoked, not invented.
        share_note("i {d}", .{value});
        const reply = client.request("produce " ++ share_topic ++ " {d}", .{value}) catch return;
        if (std.mem.eql(u8, reply, "ok")) {
            share_note("o {d}", .{value});
            sdk.sometimes(true, "a record was acknowledged", .{});
        } else sdk.sometimes(true, "a record's outcome is unknown", .{ .reply = reply });
    }
}

fn share_consume(context: *System.Context) !void {
    var client: Client = undefined;
    client.open_share(context) catch |err| {
        if (tcp.unavailable(err)) return;
        return err;
    };
    defer client.connection.close();
    for (0..consumes_per_driver) |_| {
        _ = share_poll(&client) catch return;
    }
}

/// One `consume`: its deliveries noted, "d <sent ns> <answered ns> <delivery count> <c|x>
/// <value>", one write each. How many it delivered.
fn share_poll(client: *Client) !usize {
    const sent_ns = monotonic_ns();
    const reply = try client.request("consume " ++ share_group ++ " " ++ share_topic, .{});
    const answered_ns = monotonic_ns();
    if (!std.mem.startsWith(u8, reply, "ok")) {
        sdk.event("kafka_share_reply", .{ .reply = reply[0..@min(reply.len, 300)] });
        return 0;
    }
    var delivered: usize = 0;
    var records = std.mem.tokenizeScalar(u8, reply["ok".len..], ' ');
    while (records.next()) |record| {
        var fields = std.mem.splitScalar(u8, record, ':');
        const value = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;
        const count = std.fmt.parseInt(u16, fields.next() orelse continue, 10) catch continue;
        const committed = fields.next() orelse continue;
        share_note("d {d} {d} {d} {s} {d}", .{ sent_ns, answered_ns, count, committed, value });
        if (std.mem.eql(u8, committed, "c")) sdk.sometimes(true, "a consumer's acceptance committed", .{});
        delivered += 1;
    }
    return delivered;
}

fn share_note(comptime format: []const u8, arguments: anytype) void {
    var buffer: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, format ++ "\n", arguments) catch return;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
    const fd = linux.open(share_path, flags, 0o644);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.write(@intCast(fd), line.ptr, line.len);
}

/// Once faults stop: the queue drained by a consumer of the group, then the log judged.
fn share_drained(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    var client: Client = undefined;
    _ = try sdk.retry(read_attempts_max, 500, Client.open_share, .{ &client, context });
    defer client.connection.close();
    var empty: u32 = 0;
    var polls: u32 = 0;
    while (empty < drain_empty_max and polls < drain_polls_max) : (polls += 1) {
        const delivered = share_poll(&client) catch {
            client.connection.close();
            _ = try sdk.retry(read_attempts_max, 500, Client.open_share, .{ &client, context });
            empty = 0;
            continue;
        };
        empty = if (delivered == 0) empty + 1 else 0;
    }
    sdk.always(empty == drain_empty_max, "the queue drains once faults stop", .{ .polls = polls });
    const log = std.Io.Dir.cwd().readFileAlloc(context.init.io, share_path, arena, .limited(1 << 26)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    const verdict = try share_judge(arena, log);
    sdk.always(verdict.redelivered == 0, "a record whose acceptance committed is not delivered again", verdict);
    sdk.always(verdict.lost == 0, "every acknowledged record is delivered", verdict);
    sdk.always(verdict.invented == 0, "every delivered record was produced", verdict);
    // Delivered more than once before an acceptance committed: at-least-once, by design.
    if (verdict.delivered_again > 0) sdk.event("kafka_share_redelivered", .{ .records = verdict.delivered_again });
}

const ShareVerdict = struct {
    produced: u64 = 0,
    acknowledged: u64 = 0,
    delivered: u64 = 0,
    delivered_again: u64 = 0,
    redelivered: u64 = 0,
    lost: u64 = 0,
    invented: u64 = 0,
    /// The first violation's record, and (redelivered) the moments at stake.
    example_value: u64 = 0,
    example_committed_ns: u64 = 0,
    example_delivered_sent_ns: u64 = 0,
    example_delivery_count: u16 = 0,
};

const Delivery = struct { sent_ns: u64, answered_ns: u64, count: u16, committed: bool };

fn share_judge(arena: std.mem.Allocator, log: []const u8) !ShareVerdict {
    var invoked: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var acknowledged: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var deliveries: std.AutoHashMapUnmanaged(u64, std.ArrayList(Delivery)) = .empty;
    var lines = std.mem.tokenizeScalar(u8, log, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const kind = fields.next() orelse continue;
        switch (kind[0]) {
            'i', 'o' => {
                const value = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;
                try (if (kind[0] == 'i') &invoked else &acknowledged).put(arena, value, {});
            },
            'd' => {
                const sent_ns = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;
                const answered_ns = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;
                const count = std.fmt.parseInt(u16, fields.next() orelse continue, 10) catch continue;
                const committed = std.mem.eql(u8, fields.next() orelse continue, "c");
                const value = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;
                const entry = try deliveries.getOrPut(arena, value);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(arena, .{ .sent_ns = sent_ns, .answered_ns = answered_ns, .count = count, .committed = committed });
            },
            else => {},
        }
    }
    var verdict: ShareVerdict = .{
        .produced = invoked.count(),
        .acknowledged = acknowledged.count(),
        .delivered = deliveries.count(),
    };
    var iterator = deliveries.iterator();
    while (iterator.next()) |entry| {
        const value = entry.key_ptr.*;
        const list = entry.value_ptr.items;
        if (list.len > 1) verdict.delivered_again += 1;
        if (!invoked.contains(value)) {
            if (verdict.invented == 0 and verdict.redelivered == 0) verdict.example_value = value;
            verdict.invented += 1;
        }
        // The earliest moment an acceptance of it had committed, by the driver's clock.
        var committed_ns: ?u64 = null;
        for (list) |delivery| if (delivery.committed) {
            committed_ns = @min(committed_ns orelse delivery.answered_ns, delivery.answered_ns);
        };
        const after = committed_ns orelse continue;
        for (list) |delivery| if (delivery.sent_ns > after) {
            if (verdict.redelivered == 0) {
                verdict.example_value = value;
                verdict.example_committed_ns = after;
                verdict.example_delivered_sent_ns = delivery.sent_ns;
                verdict.example_delivery_count = delivery.count;
            }
            verdict.redelivered += 1;
            break;
        };
    }
    var acknowledged_values = acknowledged.keyIterator();
    while (acknowledged_values.next()) |value| {
        if (deliveries.contains(value.*)) continue;
        if (verdict.lost == 0 and verdict.redelivered == 0 and verdict.invented == 0) verdict.example_value = value.*;
        verdict.lost += 1;
    }
    return verdict;
}

// Checks --------------------------------------------------------------------------------------

const Outcome = enum { committed, aborted, failed, unknown };
const Transaction = struct { outcome: Outcome, values: []const u64, partitions: []const u8 };

/// The known bug that explains a hang of the partition, if one does, from the brokers' output
/// (the guest's node logs): KAFKA-20734 (a coordinator skipped its markers taking the partition
/// for deleted), or Redpanda's transaction left open by a coordinator that crashed between
/// beginning it on the partitions and recording them (found here, run 177: the partition's every
/// expiry refused, "is unknown:tx::errc::invalid_txn_state"; the README's Redpanda finding).
fn hang_known(context: *System.Context, arena: std.mem.Allocator, partition: usize) ?[]const u8 {
    var names: [2][]const u8 = undefined;
    names[0] = std.fmt.allocPrint(arena, "{s}-{d})", .{ topic, partition }) catch return null;
    names[1] = std.fmt.allocPrint(arena, "{s}-{d},", .{ topic, partition }) catch return null;
    const redpanda_name = std.fmt.allocPrint(arena, "[{{kafka/{s}/{d}}}]", .{ topic, partition }) catch return null;
    for ([_][]const u8{ "kafka-1", "kafka-2", "kafka-3" }) |broker| {
        const path = std.fmt.allocPrint(arena, "/run/det/nodes/{s}/output.log", .{broker}) catch return null;
        const text = std.Io.Dir.cwd().readFileAlloc(context.init.io, path, arena, .limited(1 << 28)) catch continue;
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "these partitions are likely deleted already") != null) {
                for (names) |name| if (std.mem.indexOf(u8, line, name) != null) return "KAFKA-20734";
            }
            if (std.mem.indexOf(u8, line, "is unknown:tx::errc::invalid_txn_state") != null and
                std.mem.indexOf(u8, line, redpanda_name) != null) return "redpanda-orphan-begin-tx";
        }
    }
    return null;
}

fn everything_read(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const log = std.Io.Dir.cwd().readFileAlloc(context.init.io, txns_path, arena, .limited(1 << 26)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    const noted = try transactions_parse(arena, log);
    // Every value read, and how often.
    var read: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    // Partitions whose hang a known bug explains, aborted so they could be read: a committed
    // transaction's writes there are that bug's loss (KAFKA-20734 skipped their commit marker
    // after the commit was acknowledged), counted apart (runs 173's timelines 27 and 72).
    var known_aborted: [partitions]bool = @splat(false);
    // Partitions a hang still holds after the abort: their writes past it cannot be read.
    var behind_hang: [partitions]bool = @splat(false);
    const history: sdk.elle.History = .{};
    const process = sdk.elle.process_new();
    // Read once no transaction is open: commit markers still on their way after the faults
    // (a coordinator just back) would otherwise pass for lost writes (srv3, 2026-10-28: a
    // read 11 s after faults stopped, markers landing during it). A transaction still open a
    // minute on (the coordinator aborts those older than 10 s) hangs.
    for (0..partitions) |partition| {
        const stable = if (sdk.retry(stable_attempts_max, 500, partition_stable, .{ context, partition })) |_|
            true
        else |_|
            false;
        // Open: its offsets, and the producers the partition's leader keeps (the one whose
        // transaction started at the last stable offset is the one left open).
        var client: Client = undefined;
        var producers: []const u8 = "";
        const reply = if (stable) "stable" else if (client.open(context)) |_| reply: {
            defer client.connection.close();
            const offsets = try arena.dupe(u8, client.request("stable {s} {d}", .{ topic, partition }) catch "no answer");
            producers = try arena.dupe(u8, client.request("producers {s} {d}", .{ topic, partition }) catch "no answer");
            break :reply offsets;
        } else |_| "no connection";
        // A hang a known bug explains (KAFKA-20734 in 4.3.0 and 4.4.0: a partition without a
        // leader for a moment taken for deleted, its markers skipped, run 89; Redpanda's
        // coordinator crashing between begin_tx and recording, run 177) is that bug's, counted
        // apart, so a hunt sees the hangs they do not explain.
        const known = if (stable) null else hang_known(context, arena, partition);
        const explained = known != null;
        if (known) |issue| sdk.event("kafka_known_hang", .{ .partition = partition, .issue = issue });
        sdk.always(stable or explained, "no transaction stays open once faults stop", .{
            .partition = partition,
            .reply = reply,
            .producers = producers,
            .known = explained,
        });
        // Hanging: aborted as Kafka's operators would (KIP-664), and the partition read past it,
        // so its writes count as aborted, not lost or torn: the rest is judged on its own (run
        // 68's timeline 125 read up to the hanging transaction only, its 30 "lost" and 24
        // "torn" writes past it). The hang is the property above's.
        if (!stable) if (client.open(context)) |_| {
            defer client.connection.close();
            const aborted = client.request("abort-open {s} {d}", .{ topic, partition }) catch "no answer";
            sdk.event("kafka_hanging_aborted", .{ .partition = partition, .reply = aborted });
            known_aborted[partition] = explained;
            // Still open (Redpanda has no KIP-664 abort: "The node does not support
            // WRITE_TXN_MARKERS", run 177's timeline 83): a committed read stops at the hang,
            // what is past it unread and unjudged, not lost.
            const cleared = if (sdk.retry(stable_attempts_max, 500, partition_stable, .{ context, partition })) |_| true else |_| false;
            behind_hang[partition] = !cleared;
        } else |_| {
            behind_hang[partition] = true;
        };
    }
    for (0..partitions) |partition| {
        const unread = [_]sdk.elle.Mop{.{ .read = .{ .key = partition, .list = null } }};
        try history.invoke(arena, process, &unread);
        const values = sdk.retry(read_attempts_max, 500, partition_read, .{ context, arena, partition }) catch |err| {
            try history.fail(arena, process, &unread);
            sdk.assert_unreachable("every partition can be read once faults stop", .{ .err = @errorName(err) });
            return err;
        };
        try history.ok(arena, process, &.{.{ .read = .{ .key = partition, .list = values } }});
        for (values) |value| {
            const entry = try read.getOrPut(arena, value);
            entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
        }
    }
    var aborted_read: u64 = 0;
    var lost: u64 = 0;
    var torn: u64 = 0;
    var duplicated: u64 = 0;
    var known_lost: u64 = 0;
    var unjudged: u64 = 0;
    var example: ?Transaction = null;
    for (noted) |transaction| {
        var seen: usize = 0;
        // Unread writes on partitions whose known hang was aborted: that bug's.
        var unread_known: usize = 0;
        // Unread writes behind a hang still open: not judged.
        var unread_hung: usize = 0;
        for (transaction.values, transaction.partitions) |value, partition| {
            const times = read.get(value) orelse 0;
            if (times > 0) seen += 1;
            if (times > 1) duplicated += 1;
            if (times > 0 or partition >= partitions) continue;
            if (behind_hang[partition]) {
                unread_hung += 1;
            } else if (known_aborted[partition]) unread_known += 1;
        }
        if (unread_hung > 0 and seen + unread_known + unread_hung == transaction.values.len) {
            unjudged += 1;
            continue;
        }
        if (transaction.outcome == .committed and unread_known > 0 and
            seen + unread_known == transaction.values.len)
        {
            known_lost += 1;
            continue;
        }
        const torn_here = seen > 0 and seen < transaction.values.len;
        if (torn_here) torn += 1;
        switch (transaction.outcome) {
            .aborted, .failed => if (seen > 0) {
                aborted_read += 1;
                example = transaction;
            },
            .committed => if (seen < transaction.values.len) {
                lost += 1;
                example = example orelse transaction;
            },
            .unknown => {},
        }
        if (torn_here) example = example orelse transaction;
    }
    const details = .{
        .transactions = noted.len,
        .values_read = read.count(),
        .aborted_read = aborted_read,
        .lost = lost,
        .torn = torn,
        .duplicated = duplicated,
        .example_outcome = if (example) |e| @tagName(e.outcome) else "",
        .example_first_value = if (example) |e| e.values[0] else 0,
    };
    sdk.always(aborted_read == 0, "no write of an aborted transaction is ever read", details);
    sdk.always(lost == 0, "every write of a committed transaction is read", details);
    // An event, as the hang itself (kafka_known_hang): a sometimes would be a target, failing
    // every run where the bug never struck (Redpanda's run 177).
    if (known_lost > 0) sdk.event("kafka_known_loss", .{ .transactions = known_lost });
    if (unjudged > 0) sdk.event("kafka_behind_hang", .{ .transactions = unjudged });
    sdk.always(torn == 0, "a transaction's writes are read all or none", details);
    sdk.always(duplicated == 0, "no write is read twice", details);
}

fn transactions_parse(arena: std.mem.Allocator, log: []const u8) ![]const Transaction {
    var noted: std.ArrayList(Transaction) = .empty;
    var lines = std.mem.tokenizeScalar(u8, log, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const kind = fields.next() orelse continue;
        const outcome: Outcome = switch (kind[0]) {
            'c' => .committed,
            'a' => .aborted,
            'f' => .failed,
            else => .unknown,
        };
        var values: std.ArrayList(u64) = .empty;
        var placed: std.ArrayList(u8) = .empty;
        while (fields.next()) |field| {
            const colon = std.mem.indexOfScalar(u8, field, ':') orelse continue;
            const partition = std.fmt.parseInt(u8, field[0..colon], 10) catch continue;
            const value = std.fmt.parseInt(u64, field[colon + 1 ..], 10) catch continue;
            try values.append(arena, value);
            try placed.append(arena, partition);
        }
        if (values.items.len == 0) continue;
        try noted.append(arena, .{ .outcome = outcome, .values = values.items, .partitions = placed.items });
    }
    return noted.items;
}

fn partition_stable(context: *System.Context, partition: usize) !void {
    var client: Client = undefined;
    try client.open(context);
    defer client.connection.close();
    const reply = try client.request("stable {s} {d}", .{ topic, partition });
    if (!std.mem.eql(u8, reply, "stable")) return error.Open;
}

fn partition_read(context: *System.Context, arena: std.mem.Allocator, partition: usize) ![]const u64 {
    var client: Client = undefined;
    try client.open(context);
    defer client.connection.close();
    const reply = try client.request("read {s} {d}", .{ topic, partition });
    const prefix = "values ";
    if (!std.mem.startsWith(u8, reply, prefix) and !std.mem.eql(u8, reply, "values")) {
        sdk.event("kafka_error", .{ .command = "read", .reply = reply });
        return error.NotRead;
    }
    var values: std.ArrayList(u64) = .empty;
    if (reply.len <= prefix.len) return values.items;
    var items = std.mem.tokenizeScalar(u8, reply[prefix.len..], ',');
    while (items.next()) |item| try values.append(arena, try std.fmt.parseInt(u64, item, 10));
    return values.items;
}

test share_judge {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 1 delivered twice before its acceptance committed (by design); 2 accepted at 200, then
    // handed out by a poll sent at 300; 3 acknowledged, never delivered; 9 never produced.
    const verdict = try share_judge(arena,
        \\i 1
        \\o 1
        \\i 2
        \\o 2
        \\i 3
        \\o 3
        \\d 10 20 1 x 1
        \\d 30 40 2 c 1
        \\d 100 200 1 c 2
        \\d 300 400 2 c 2
        \\d 500 600 1 c 9
    );
    try std.testing.expectEqual(3, verdict.produced);
    try std.testing.expectEqual(2, verdict.delivered_again); // 1 and 2.
    try std.testing.expectEqual(1, verdict.redelivered);
    try std.testing.expectEqual(1, verdict.lost);
    try std.testing.expectEqual(1, verdict.invented);
    try std.testing.expectEqual(2, verdict.example_value);
    try std.testing.expectEqual(200, verdict.example_committed_ns);
    try std.testing.expectEqual(300, verdict.example_delivered_sent_ns);
}

test transactions_parse {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const noted = try transactions_parse(arena.allocator(), "c 0:1 3:2\na 1:3\nu 2:4 2:5 0:6\nf 1:7\n");
    try std.testing.expectEqual(4, noted.len);
    try std.testing.expectEqual(Outcome.committed, noted[0].outcome);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, noted[0].values);
    try std.testing.expectEqualSlices(u8, &.{ 0, 3 }, noted[0].partitions);
    try std.testing.expectEqual(Outcome.aborted, noted[1].outcome);
    try std.testing.expectEqual(Outcome.unknown, noted[2].outcome);
    try std.testing.expectEqual(Outcome.failed, noted[3].outcome);
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}
