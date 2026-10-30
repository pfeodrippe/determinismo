// SPDX-License-Identifier: MIT
//! Example test program: CockroachDB v26.3.3, three nodes, following Jepsen's CockroachDB
//! analysis (2016: serializability violations, fixed then): list-append transactions
//! (examples/sql/append.zig, through PostgreSQL's protocol) whose every timeline's history Elle
//! checks on the host for serializability, CockroachDB's claim (with no stale reads of single
//! keys; across keys it allows causal reversal, so not strict serializability).
//!
//! Faults: the default ones, restarts, graceful stops and power losses (each node's store on its
//! own disk), and stalls and power losses at the nodes' syncs. Ranges are test-sized (64 KiB),
//! so they split, merge and move leases during a timeline.
//!
//! Membership changes (Jepsen's member nemesis): a fourth node, a spare, joins (a fresh store: a
//! new node ID), is decommissioned (its replicas moved off), and joins again fresh once it is,
//! one step at a time, while the drivers append.
//!
//!   determinismo explore ... --program zig-out/bin/cockroachdb-test --scenario append
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo");
const sql_append = @import("sql_append");

const Nodes = struct {
    @"crdb-1": sdk.Node,
    @"crdb-2": sdk.Node,
    @"crdb-3": sdk.Node,
    /// The node that joins and is decommissioned (a spare: not started with the others).
    @"crdb-4": sdk.Node,
};
const System = sdk.System(Nodes);
const node_names = [_][]const u8{ "crdb-1", "crdb-2", "crdb-3" };

const port = 26257;
const image = "docker.io/cockroachdb/cockroach:v26.3.3";
const setup_attempts_max = 300;
const options: sql_append.Options = .{
    .port = port,
    .user = "root",
    .database = "defaultdb",
    .isolation = "SERIALIZABLE",
};

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .append = append_scenario },
        .checks = .{ .elle = sdk.elle.check(.{ .consistency = "serializable" }) },
    });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    // Causality's explanation: the transaction and replica code's logs up in every node, at
    // runtime (crdb_internal.set_vmodule; a restart resets it).
    default.explain = "for n in crdb-1 crdb-2 crdb-3; do det-nodes exec $n /cockroach/cockroach sql --insecure " ++
        "--host=$n:26257 -e \"SELECT crdb_internal.set_vmodule('txn*=2,replica*=2,store*=1')\"; done";
    inline for (node_names ++ .{"crdb-4"}) |name| {
        default.node(@field(System.Name, name), .{
            .image = image,
            .command = &.{
                "start",
                "--insecure",
                "--join=crdb-1:26257,crdb-2:26257,crdb-3:26257",
                "--listen-addr=0.0.0.0:26257",
                "--advertise-addr=" ++ name ++ ":26257",
                "--http-addr=0.0.0.0:8080",
                "--store=/cockroach/cockroach-data",
                // Small caches: three nodes share the machine.
                "--cache=64MiB",
                "--max-sql-memory=64MiB",
            },
            // Test-sized ranges allowed (zone_sql): 64 MiB is the smallest range_max_bytes
            // otherwise, as CockroachDB's own roachtests lower it.
            .env = &.{"COCKROACH_MIN_RANGE_MAX_BYTES=65536"},
            .ready = .{ .tcp = port },
            // A wipe is left out: a node that lost its store cannot rejoin as itself. Clocks
            // skewed within its maximum offset (500 ms; a node past 80% of it stops on purpose).
            .faults = .{ .restart = true, .crash = true, .stop = true, .clock_skew = true, .clock_skew_ms_max = 300 },
            .spare = comptime std.mem.eql(u8, name, "crdb-4"),
        });
    }
}

fn addresses(context: *System.Context) [node_names.len][4]u8 {
    return .{
        context.nodes.@"crdb-1".address,
        context.nodes.@"crdb-2".address,
        context.nodes.@"crdb-3".address,
    };
}

fn append_scenario(s: *System.Scenario) void {
    s.setup("cluster", cluster_ready);
    s.parallel_driver("append", append);
    s.parallel_driver("member", member_changes);
    s.finally("final reads", final_reads);
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

/// One membership step, one at a time (a lock file in the runner), from `node status
/// --decommission` through a node drawn: the spare's active node decommissioned one time in two;
/// none active or decommissioning, the spare started fresh (a new node), unless its last start
/// was within the join grace.
fn member_step(context: *System.Context) !void {
    const lock = linux.open("/tmp/crdb-member.lock", .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(lock) != .SUCCESS) return error.MemberLock;
    defer _ = linux.close(@intCast(lock));
    const lock_exclusive = 2; // LOCK_EX
    if (linux.errno(linux.flock(@intCast(lock), lock_exclusive)) != .SUCCESS) return error.MemberLock;
    const all = [_]*const sdk.Node{ &context.nodes.@"crdb-1", &context.nodes.@"crdb-2", &context.nodes.@"crdb-3" };
    const via = all[sdk.random_below(all.len)];
    const spare = &context.nodes.@"crdb-4";
    var buffer: [16 * 1024]u8 = undefined;
    const status = via.exec_said(&.{
        "/cockroach/cockroach", "node", "status", "--insecure", "--host=localhost:26257", "--decommission", "--format=csv",
    }, &buffer) catch return;
    // The node is down: a later step.
    if (status.status != 0) return member_refused("node status", status.status, status.output);
    const member = spare_member(status.output);
    const node = member orelse {
        if (member_started_ns()) |at| if (monotonic_ns() -| at < join_grace_ns) return; // Still joining.
        try spare.wipe(); // A fresh store: a new node, with a new ID.
        member_started_note();
        sdk.sometimes(true, "a node was started to join", .{});
        return;
    };
    if (!node.active) return; // Decommissioning: later.
    sdk.sometimes(true, "a node joined", .{});
    if (sdk.random_below_named("cockroachdb.member_remove", 2) != 0) {
        return; // A member stays (a fault that stopped it starts it again).
    }
    var output: [4096]u8 = undefined;
    const result = via.exec_said(&.{
        "/cockroach/cockroach", "node", "decommission", node.id, "--insecure", "--host=localhost:26257", "--wait=none",
    }, &output) catch return;
    if (result.status != 0) return member_refused("decommission", result.status, result.output);
    sdk.sometimes(true, "a node was decommissioned", .{});
}

/// The spare's node in `node status --decommission --format=csv` ("id,address,...,membership,
/// ..."): its ID and whether it is active, when one is active or decommissioning (a node
/// decommissioned already is an old one).
fn spare_member(csv: []const u8) ?struct { id: []const u8, active: bool } {
    var lines = std.mem.tokenizeScalar(u8, csv, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, ",crdb-4:26257,") == null) continue;
        const id = line[0 .. std.mem.indexOfScalar(u8, line, ',') orelse continue];
        if (std.mem.indexOf(u8, line, ",active,") != null) return .{ .id = id, .active = true };
        if (std.mem.indexOf(u8, line, ",decommissioning,") != null) return .{ .id = id, .active = false };
    }
    return null;
}

test spare_member {
    const csv = "id,address,sql_address,build,started_at,updated_at,locality,is_available,is_live,gossiped_replicas,is_decommissioning,membership,is_draining\n" ++
        "1,crdb-1:26257,crdb-1:26257,v26.3.3,x,y,,true,true,10,false,active,false\n" ++
        "4,crdb-4:26257,crdb-4:26257,v26.3.3,x,y,,false,false,0,true,decommissioned,false\n" ++
        "5,crdb-4:26257,crdb-4:26257,v26.3.3,x,y,,true,true,3,false,active,false\n";
    const member = spare_member(csv).?;
    try std.testing.expectEqualStrings("5", member.id);
    try std.testing.expect(member.active);
    try std.testing.expectEqual(null, spare_member(csv[0..std.mem.indexOf(u8, csv, "5,crdb-4").?]));
}

/// The spare's last fresh start (monotonic, virtual), and how long its join may take before the
/// cluster lists it: until then, not started again.
const member_started_path = "/tmp/crdb-member.started";
const join_grace_ns = 30 * std.time.ns_per_s;

/// A membership call refused or unanswered, said (an event): under faults, refusals are expected,
/// and a step that never succeeds says why.
fn member_refused(what: []const u8, status: u32, body: []const u8) void {
    sdk.event("member_refused", .{ .what = what, .status = status, .body = body[0..@min(body.len, 512)] });
}

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

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

/// Ranges split at 64 KiB (512 MiB by default, which a test's data never reaches; below 64 MiB
/// only with COCKROACH_MIN_RANGE_MAX_BYTES lowered: the first smoke's setup was refused) and
/// merge under 16 KiB: splits, merges and the lease and replica moves after them
/// happen within a timeline, as Jepsen's split nemesis made them. No internal time series (a
/// write every 10 s on every node that nothing reads here).
const zone_sql = "ALTER RANGE default CONFIGURE ZONE USING range_min_bytes = 16384, range_max_bytes = 65536";
/// Its own statement: a cluster setting is refused inside a transaction, and one `-e` with both
/// is one (the second smoke's setup).
const timeseries_sql = "SET CLUSTER SETTING timeseries.storage.enabled = false";

/// The cluster initialized (once: a second init says it already is), its ranges test-sized, then
/// the table.
fn cluster_ready(context: *System.Context) !void {
    var buffer: [4096]u8 = undefined;
    const init_output = try context.nodes.@"crdb-1".exec_output(&.{
        "/cockroach/cockroach", "init", "--insecure", "--host=crdb-1:26257",
    }, &buffer);
    sdk.event("cluster_init", .{ .status = init_output.status, .output = init_output.output });
    _ = try sdk.retry(setup_attempts_max, 200, settings_apply, .{context});
    _ = try sdk.retry(setup_attempts_max, 200, sql_append.schema_create, .{
        context.nodes.@"crdb-1".address, options,
    });
}

fn settings_apply(context: *System.Context) !void {
    var buffer: [4096]u8 = undefined;
    const result = try context.nodes.@"crdb-1".exec_output(&.{
        "/cockroach/cockroach", "sql", "--insecure", "--host=crdb-1:26257", "-e", zone_sql, "-e", timeseries_sql,
    }, &buffer);
    if (result.status != 0) {
        sdk.event("cluster_settings_refused", .{ .status = result.status, .output = result.output });
        return error.SettingsRefused;
    }
}

fn append(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const all = addresses(context);
    try sql_append.transactions(arena, &all, options);
}

/// Every committed append still there once faults stop (examples/sql/append.zig).
fn final_reads(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const all = addresses(context);
    try sql_append.final_reads(arena, &all, options);
}
