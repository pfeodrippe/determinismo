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
    /// The spare broker (started by the `member` driver): Apache Kafka's partitions' replicas
    /// move onto it and back; Redpanda's joins and is decommissioned.
    @"kafka-4": sdk.Node,
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
/// Apache Kafka's: the transaction and share coordinators' loggers, and the share partitions',
/// at TRACE in each running broker (dynamic broker loggers; a restart resets them).
const kafka_explain = "for i in 1 2 3; do det-nodes exec kafka-$i /opt/kafka/bin/kafka-configs.sh " ++
    "--bootstrap-server localhost:9092 --alter --entity-type broker-loggers --entity-name $i --add-config " ++
    "kafka.coordinator.transaction=TRACE,org.apache.kafka.coordinator.transaction=TRACE," ++
    "kafka.server.share=TRACE,org.apache.kafka.coordinator.share=TRACE; done";
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
    inline for (.{ "default", "format-unsynced", "unflushed", "coverage", "kafka-4.4", "kafka-4.4-coverage", "kafka-4.4-dynamic", "redpanda" }) |profile_name| {
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
    // open transaction; Apache Kafka's coordinators' loggers.
    profile.explain = if (redpanda) redpanda_explain else kafka_explain;
    const build: sdk.schema.Build = .{
        .context = ".",
        .dockerfile = if (comptime std.mem.eql(u8, profile_name, "kafka-4.4-coverage"))
            "examples/kafka/Dockerfile.4.4.coverage"
        else if (coverage)
            "examples/kafka/Dockerfile.coverage"
        else if (comptime std.mem.eql(u8, profile_name, "kafka-4.4") or std.mem.eql(u8, profile_name, "kafka-4.4-dynamic"))
            "examples/kafka/Dockerfile.4.4"
        else
            "examples/kafka/Dockerfile",
    };
    const brokers_build: sdk.schema.Build = if (redpanda)
        .{ .context = ".", .dockerfile = "examples/kafka/Dockerfile.redpanda" }
    else
        build;
    const format = if (comptime std.mem.eql(u8, profile_name, "format-unsynced")) profile_name else "synced";
    // A dynamic KRaft quorum (KIP-853): the spare is a controller added to the voters and
    // removed, not a broker partitions move onto.
    const dynamic = comptime std.mem.eql(u8, profile_name, "kafka-4.4-dynamic");
    const quorum_env: []const []const u8 = if (dynamic) &.{"KAFKA_QUORUM=dynamic"} else &.{};
    const flush = if (comptime std.mem.eql(u8, profile_name, "unflushed")) profile_name else "flushed";
    inline for (.{ "kafka-1", "kafka-2", "kafka-3" }, 1..) |name, id| {
        const number = std.fmt.comptimePrint("{d}", .{id});
        profile.node(@field(System.Name, name), .{
            .build = brokers_build,
            .env = quorum_env,
            .command = if (redpanda)
                &.{ "redpanda", number }
            else if (coverage)
                &.{ "broker", number, format, flush, "coverage" }
            else
                &.{ "broker", number, format, flush },
            // The controller's port (Redpanda's RPC port): open at once. The broker's opens once
            // the quorum formed, which needs the nodes started after this one.
            .ready = .{ .tcp = if (redpanda) redpanda_rpc_port else controller_port },
            // Clock skews too: coordinators expire transactions by their wall clocks, and the
            // logs' safety must not depend on the brokers' clocks agreeing.
            .faults = .{ .restart = true, .crash = true, .stop = true, .clock_skew = true },
        });
    }
    profile.node(.@"kafka-4", .{
        .build = brokers_build,
        .env = quorum_env,
        .command = if (redpanda)
            &.{ "redpanda", "4" }
        else if (coverage)
            &.{ "broker", "4", format, flush, "coverage" }
        else
            &.{ "broker", "4", format, flush },
        .ready = .{ .tcp = if (redpanda) redpanda_rpc_port else if (dynamic) controller_port else 9092 },
        .faults = .{ .restart = true, .crash = true, .stop = true, .clock_skew = true },
        .spare = true,
    });
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
    s.parallel_driver("member", member_changes);
    s.eventually("read", everything_read);
}

// Membership ------------------------------------------------------------------------------------

/// Membership steps for a while (Jepsen's member nemesis acts every few seconds): up to
/// `member_steps_max`, a drawn 1 to 5 s apart, so a join, a removal and a join again fit in one
/// driver's run.
fn member_changes(context: *System.Context) !void {
    for (0..member_steps_max) |_| {
        try member_step(context);
        sdk.sleep_ms(1000 + sdk.random_below_named("member.pause_ms", 4000));
    }
}

const member_steps_max = 20;

/// A partition's replicas moved (Jepsen's member nemesis, as Kafka changes membership): one at a
/// time (a lock file in the runner), of the workload's topic or of `__transaction_state` (the
/// coordinators' log), one replica onto the spare broker, or back from it to the broker it
/// lacks, through `kafka-reassign-partitions.sh` run in a broker drawn. The spare starts at the
/// first step; transactions must stay atomic and durable through the moves.
fn member_step(context: *System.Context) !void {
    const spare = &context.nodes.@"kafka-4";
    const lock = linux.open("/tmp/kafka-member.lock", .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(lock) != .SUCCESS) return error.MemberLock;
    defer _ = linux.close(@intCast(lock));
    const lock_exclusive = 2; // LOCK_EX
    if (linux.errno(linux.flock(@intCast(lock), lock_exclusive)) != .SUCCESS) return error.MemberLock;
    if (std.mem.eql(u8, context.profile, "redpanda")) return redpanda_member_step(context, spare);
    if (std.mem.eql(u8, context.profile, "kafka-4.4-dynamic")) return controller_member_step(context, spare);
    spare.start() catch {}; // Running already, or started now (it joins as broker 4).
    const brokers = [_]*const sdk.Node{ &context.nodes.@"kafka-1", &context.nodes.@"kafka-2", &context.nodes.@"kafka-3" };
    const via = brokers[sdk.random_below(brokers.len)];
    const transactions_log = sdk.random_below_named("kafka.member_topic", 2) == 0;
    const moved_topic = if (transactions_log) "__transaction_state" else topic;
    // Kafka's default transaction.state.log.num.partitions; the topic's from num.partitions.
    const partition = sdk.random_below(if (transactions_log) 50 else 4);
    var described: [64 * 1024]u8 = undefined;
    const description = via.exec_said(&.{
        "/opt/kafka/bin/kafka-topics.sh", "--bootstrap-server", "localhost:9092", "--describe", "--topic", moved_topic,
    }, &described) catch return;
    // Its broker is down: a later step.
    if (description.status != 0) return member_refused("describe", description.status, description.output);
    var assigned: [replicas]u32 = undefined;
    const count = replicas_of(description.output, partition, &assigned) orelse return;
    if (count != replicas) return;
    // Onto the spare, or back from it to the broker it lacks.
    const onto_spare = std.mem.indexOfScalar(u32, &assigned, 4) == null;
    if (onto_spare) {
        assigned[sdk.random_below_named("kafka.member_replica", replicas)] = 4;
    } else {
        const missing: u32 = for ([_]u32{ 1, 2, 3 }) |broker| {
            if (std.mem.indexOfScalar(u32, &assigned, broker) == null) break broker;
        } else return;
        assigned[std.mem.indexOfScalar(u32, &assigned, 4).?] = missing;
    }
    var plan_buffer: [256]u8 = undefined;
    const plan = try std.fmt.bufPrint(&plan_buffer, "{{\"version\":1,\"partitions\":[{{\"topic\":\"{s}\",\"partition\":{d},\"replicas\":[{d},{d},{d}]}}]}}", .{
        moved_topic, partition, assigned[0], assigned[1], assigned[2],
    });
    var output: [8 * 1024]u8 = undefined;
    const result = via.exec_said(&.{
        "sh", "-c",
        "printf %s \"$0\" > /tmp/reassign.json && /opt/kafka/bin/kafka-reassign-partitions.sh " ++
            "--bootstrap-server localhost:9092 --reassignment-json-file /tmp/reassign.json --execute",
        plan,
    }, &output) catch return;
    // A move under way, or no controller: a later step.
    if (result.status != 0) return member_refused("reassign", result.status, result.output);
    sdk.sometimes(true, "a partition replica was moved", .{ .topic = moved_topic, .onto_spare = onto_spare });
}

/// The dynamic quorum's membership step (KIP-853), from `kafka-metadata-quorum describe
/// --status` through a controller drawn: the spare, an observer once started, added to the
/// voters (`add-controller`, run on it: its own configuration and directory); a voter, removed
/// one time in two (`remove-controller` with its directory ID). It runs throughout.
fn controller_member_step(context: *System.Context, spare: *const sdk.Node) !void {
    spare.start() catch {}; // Running already, or started now (an observer).
    const controllers = [_]*const sdk.Node{ &context.nodes.@"kafka-1", &context.nodes.@"kafka-2", &context.nodes.@"kafka-3" };
    const via = controllers[sdk.random_below(controllers.len)];
    const quorum_tool = "/opt/kafka/bin/kafka-metadata-quorum.sh";
    var buffer: [16 * 1024]u8 = undefined;
    const status = via.exec_said(&.{ quorum_tool, "--bootstrap-controller", "localhost:9093", "describe", "--status" }, &buffer) catch return;
    // No controller there: a later step.
    if (status.status != 0) return member_refused("quorum status", status.status, status.output);
    var output: [8 * 1024]u8 = undefined;
    if (!voter_listed(status.output, 4)) {
        const added = spare.exec_said(&.{
            quorum_tool, "--command-config", "/tmp/server.properties", "--bootstrap-controller", "localhost:9093", "add-controller",
        }, &output) catch return;
        if (added.status != 0) return member_refused("add-controller", added.status, added.output);
        sdk.sometimes(true, "a controller was added to the voters", .{});
        return;
    }
    sdk.sometimes(true, "a controller joined the voters", .{});
    if (sdk.random_below_named("kafka.controller_remove", 2) != 0) return;
    // Its directory ID is the one its format drew (it is not among the initial controllers).
    const directory = voter_directory(status.output, 4) orelse {
        return member_refused("quorum status unread", status.status, status.output);
    };
    const removed = via.exec_said(&.{
        quorum_tool,       "--bootstrap-controller", "localhost:9093",            "remove-controller",
        "--controller-id", "4",                      "--controller-directory-id", directory,
    }, &output) catch return;
    if (removed.status != 0) return member_refused("remove-controller", removed.status, removed.output);
    sdk.sometimes(true, "a controller was removed from the voters", .{});
}

/// Whether `describe --status` lists node `id` among its CurrentVoters (`"id": 4` in the line's
/// JSON).
fn voter_listed(text: []const u8, id: u32) bool {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "CurrentVoters:")) continue;
        var spaced_buffer: [24]u8 = undefined;
        var tight_buffer: [24]u8 = undefined;
        const spaced = std.fmt.bufPrint(&spaced_buffer, "\"id\": {d},", .{id}) catch return false;
        const tight = std.fmt.bufPrint(&tight_buffer, "\"id\":{d},", .{id}) catch return false;
        return std.mem.indexOf(u8, line, spaced) != null or std.mem.indexOf(u8, line, tight) != null;
    }
    return false;
}

/// The directory ID `describe --status` gives voter `id` (`{"id": 4, "directoryId": "..."`).
fn voter_directory(text: []const u8, id: u32) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "CurrentVoters:")) continue;
        var spaced_buffer: [24]u8 = undefined;
        var tight_buffer: [24]u8 = undefined;
        const spaced = std.fmt.bufPrint(&spaced_buffer, "\"id\": {d},", .{id}) catch return null;
        const tight = std.fmt.bufPrint(&tight_buffer, "\"id\":{d},", .{id}) catch return null;
        const at = std.mem.indexOf(u8, line, spaced) orelse std.mem.indexOf(u8, line, tight) orelse return null;
        const key = "\"directoryId\":";
        const field = std.mem.indexOfPos(u8, line, at, key) orelse return null;
        const open = std.mem.indexOfScalarPos(u8, line, field + key.len, '"') orelse return null;
        const close = std.mem.indexOfScalarPos(u8, line, open + 1, '"') orelse return null;
        return line[open + 1 .. close];
    }
    return null;
}

test voter_directory {
    const text = "ClusterId: MkU3\nLeaderId: 1\n" ++
        "CurrentVoters:          [{\"id\": 1, \"directoryId\": \"x\"}, {\"id\": 4, \"directoryId\": \"Hy0_aa\", \"endpoints\": []}]\n";
    try std.testing.expectEqualStrings("Hy0_aa", voter_directory(text, 4).?);
    try std.testing.expectEqualStrings("x", voter_directory(text, 1).?);
    try std.testing.expect(voter_directory(text, 2) == null);
}

test voter_listed {
    const text = "ClusterId: MkU3\nLeaderId: 1\n" ++
        "CurrentVoters:          [{\"id\": 1, \"directoryId\": \"x\"}, {\"id\": 4, \"directoryId\": \"y\"}]\n" ++
        "CurrentObservers:       [{\"id\": 2, \"directoryId\": \"z\"}]\n";
    try std.testing.expect(voter_listed(text, 4));
    try std.testing.expect(voter_listed(text, 1));
    try std.testing.expect(!voter_listed(text, 2));
}

/// Redpanda's membership step, from its admin API's brokers (`GET /v1/brokers`): the spare (any
/// node but 1 to 3) decommissioned one time in two while active; once it is gone, started again
/// fresh (a new node, a new ID), unless its last start was within the join grace.
fn redpanda_member_step(context: *System.Context, spare: *const sdk.Node) !void {
    const brokers = [_][4]u8{ context.nodes.@"kafka-1".address, context.nodes.@"kafka-2".address, context.nodes.@"kafka-3".address };
    const via = brokers[sdk.random_below(brokers.len)];
    const arena = context.init.arena.allocator();
    const buffer = try arena.alloc(u8, 64 * 1024);
    const listed = tcp.http_with(via, redpanda_admin_port, "GET", "/v1/brokers", "", buffer, .{ .timeout_ms = 5_000 }) catch |err| {
        return member_refused("brokers", 0, @errorName(err));
    };
    if (listed.status != 200) return member_refused("brokers", listed.status, listed.body);
    const Broker = struct { node_id: u32 = 0, membership_status: []const u8 = "" };
    const all = std.json.parseFromSliceLeaky([]const Broker, arena, listed.body, .{ .ignore_unknown_fields = true }) catch {
        return member_refused("brokers unread", listed.status, listed.body);
    };
    const found: ?Broker = for (all) |broker| {
        if (broker.node_id > 3) break broker;
    } else null;
    const broker = found orelse {
        if (member_started_ns()) |at| if (monotonic_ns() -| at < join_grace_ns) return; // Still joining.
        try spare.wipe(); // Fresh: a new node, which the cluster gives a new ID.
        member_started_note();
        sdk.sometimes(true, "a broker was started to join", .{});
        return;
    };
    if (!std.mem.eql(u8, broker.membership_status, "active")) return; // Draining: later.
    sdk.sometimes(true, "a broker joined", .{});
    if (sdk.random_below_named("redpanda.member_remove", 2) != 0) {
        return; // A member stays (a fault that stopped it starts it again).
    }
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/v1/brokers/{d}/decommission", .{broker.node_id});
    const response = tcp.http_with(via, redpanda_admin_port, "PUT", path, "", buffer, .{ .timeout_ms = 10_000 }) catch |err| {
        return member_refused("decommission", 0, @errorName(err));
    };
    if (response.status != 200) return member_refused("decommission", response.status, response.body);
    sdk.sometimes(true, "a broker was decommissioned", .{});
}

/// A membership call refused or unanswered (status 0, the error), said (an event): under faults,
/// refusals are expected, and a step that never succeeds says why.
fn member_refused(what: []const u8, status: u32, body: []const u8) void {
    sdk.event("member_refused", .{ .what = what, .status = status, .body = body[0..@min(body.len, 512)] });
}

const redpanda_admin_port = 9644;
/// The spare's last fresh start (monotonic, virtual), and how long its join may take before the
/// cluster lists it: until then, not started again.
const member_started_path = "/tmp/kafka-member.started";
const join_grace_ns = 30 * std.time.ns_per_s;

fn member_started_ns() ?u64 {
    const fd = linux.open(member_started_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var text: [32]u8 = undefined;
    const size = linux.read(@intCast(fd), &text, text.len);
    if (linux.errno(size) != .SUCCESS) return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, text[0..size], " \n"), 10) catch null;
}

fn member_started_note() void {
    var text: [32]u8 = undefined;
    const line = std.fmt.bufPrint(&text, "{d}\n", .{monotonic_ns()}) catch return;
    const fd = linux.open(member_started_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.write(@intCast(fd), line.ptr, line.len);
}

/// The replicas `kafka-topics.sh --describe` lists for `partition` ("Partition: 2 ... Replicas:
/// 1,3,2 ..."), into `assigned`; how many, or null when the partition is not listed.
fn replicas_of(text: []const u8, partition: u64, assigned: *[replicas]u32) ?usize {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var marker_buffer: [32]u8 = undefined;
        const marker = std.fmt.bufPrint(&marker_buffer, "Partition: {d}\t", .{partition}) catch return null;
        if (std.mem.indexOf(u8, line, marker) == null) continue;
        const at = (std.mem.indexOf(u8, line, "Replicas: ") orelse return null) + "Replicas: ".len;
        const end = std.mem.indexOfAnyPos(u8, line, at, "\t ") orelse line.len;
        var count: usize = 0;
        var ids = std.mem.tokenizeScalar(u8, line[at..end], ',');
        while (ids.next()) |id| {
            if (count == assigned.len) return null;
            assigned[count] = std.fmt.parseInt(u32, id, 10) catch return null;
            count += 1;
        }
        return count;
    }
    return null;
}

test replicas_of {
    const text = "Topic: jepsen\tTopicId: x\tPartitionCount: 4\n" ++
        "\tTopic: jepsen\tPartition: 1\tLeader: 2\tReplicas: 2,4,1\tIsr: 2,1\n" ++
        "\tTopic: jepsen\tPartition: 10\tLeader: 3\tReplicas: 3,1,2\tIsr: 3,1,2\n";
    var assigned: [replicas]u32 = undefined;
    try std.testing.expectEqual(@as(?usize, 3), replicas_of(text, 1, &assigned));
    try std.testing.expectEqualSlices(u32, &.{ 2, 4, 1 }, &assigned);
    try std.testing.expectEqual(@as(?usize, 3), replicas_of(text, 10, &assigned));
    try std.testing.expectEqualSlices(u32, &.{ 3, 1, 2 }, &assigned);
    try std.testing.expectEqual(@as(?usize, null), replicas_of(text, 2, &assigned));
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
    if (std.mem.startsWith(u8, reply, "ok")) return;
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
    if (!std.mem.startsWith(u8, hello, "ok")) {
        // No producer yet (the coordinator unavailable): nothing was sent.
        sdk.sometimes(true, "a producer could not start", .{ .reply = hello });
        return;
    }
    // Faults aimed at its transactions' coordinator, where Kafka's transaction bugs live (a
    // coordinator crashing between beginning a transaction and recording it: Redpanda's run 177).
    if (std.mem.startsWith(u8, hello, "ok ")) {
        var name_buffer: [16]u8 = undefined;
        const coordinator = std.fmt.bufPrint(&name_buffer, "kafka-{s}", .{hello["ok ".len..]}) catch "";
        if (coordinator.len > 0) sdk.fault_aim(coordinator);
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
