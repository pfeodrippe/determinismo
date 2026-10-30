// SPDX-License-Identifier: MIT
//! Example test program: MariaDB 13.0.2 with Galera 4, three nodes, as Jepsen's Galera test runs
//! them (jepsen-io/mysql: its configuration, n1 starting the cluster, list-append transactions
//! at Repeatable Read checked for snapshot isolation). Jepsen's analysis of 12.1.2 (the `jepsen`
//! profile) reported committed transactions lost when nodes crash together (the log is not
//! flushed at commit, as MariaDB recommends for Galera), and lost updates and stale reads.
//!
//! Scenario `append`: transactions through random nodes (examples/sql/append.zig, MySQL's
//! protocol), Elle on every timeline's history, and once faults stop, a read of every key that
//! must hold each committed append. Faults: the default ones, restarts, graceful
//! stops and power losses (each node's data on its own disk), and stalls and power losses at its
//! syncs.
//!
//! Membership changes (Jepsen's member nemesis): a fourth node, a spare, joins the cluster (fresh,
//! by a full state transfer, or with its data, by an incremental one: a named decision) and
//! leaves it gracefully (`mariadb-admin shutdown`), one step at a time, while the drivers append.
//!
//!   determinismo explore ... --program zig-out/bin/galera-test --scenario append
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo");
const sql_append = @import("sql_append");

const Nodes = struct {
    n1: sdk.Node,
    n2: sdk.Node,
    n3: sdk.Node,
    /// The node that joins and leaves (a spare: not started with the others).
    n4: sdk.Node,
};
const System = sdk.System(Nodes);

const node_names = .{ "n1", "n2", "n3" };
const port = 3306;
const schema_attempts_max = 600;

const options: sql_append.Options = .{
    .dialect = .mysql,
    .port = port,
    .user = "root",
    .database = "jepsen",
    .isolation = "REPEATABLE READ",
    // Final reads wait until the node applied every commit of the cluster: a lagging node's
    // read is then no excuse for a missing append.
    .final_session = "SET SESSION wsrep_sync_wait = 1",
};

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .append = append_scenario },
        // Jepsen's expectation for Galera at Repeatable Read.
        .checks = .{ .elle = sdk.elle.check(.{ .consistency = "snapshot-isolation" }) },
    });
}

/// `default`: MariaDB 13.0.2, nodes recovering their position before each start as MariaDB's
/// systemd unit does. `jepsen`: 12.1.2, the version of Jepsen's analysis, started as Jepsen's
/// wrapper does (no position recovery), to measure what determinismo finds blind of what Jepsen
/// reported. `jepsen-dirsync`: 12.1.2 with gvwstate.dat's rename made durable (dirsync.c), to
/// tell whether that rename causes the EVS abort (README). `jepsen-recovered`: that, with the
/// systemd unit's position recovery, to tell Galera's own behavior from the wrapper's. `default`
/// and `jepsen-recovered` flush InnoDB's log at every commit: with it once a second (Jepsen's,
/// the `jepsen` profiles) a whole primary failing within that second loses its last commits, as
/// Galera documents (run 202), which hid any other loss.
fn describe(d: *System.Describe) !void {
    inline for (.{
        .{ "default", "examples/galera/Dockerfile", true },
        .{ "jepsen", "examples/galera/Dockerfile.12.1.2", false },
        .{ "jepsen-dirsync", "examples/galera/Dockerfile.12.1.2-dirsync", false },
        .{ "jepsen-recovered", "examples/galera/Dockerfile.12.1.2-dirsync", true },
    }) |entry| {
        const profile = try d.profile(entry[0]);
        inline for (node_names ++ .{"n4"}) |name| {
            const first = comptime std.mem.eql(u8, name, "n1");
            const env = .{
                "GALERA_NODE=" ++ name,
                "MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1",
                "MARIADB_DATABASE=jepsen",
            };
            profile.node(@field(System.Name, name), .{
                .spare = comptime std.mem.eql(u8, name, "n4"),
                .build = .{ .context = ".", .dockerfile = entry[1] },
                .env = &(if (entry[2]) env ++ .{ "GALERA_RECOVER=1", "GALERA_FLUSH_AT_COMMIT=1" } else env),
                .ready = .{ .tcp = port },
                // The others join the cluster n1 started.
                .after = if (first) &.{} else &.{.n1},
                .faults = .{ .restart = true, .crash = true, .stop = true },
                // Galera's own abort when a joiner's state transfer loses its donor: by design
                // (README), and its signal 11 inside abort() looks like any crash. 114 of hunt run
                // 97's 299 timelines failed "no process crashes: mariadbd" on it alone, the EVS
                // aborts hidden among them.
                // And a node that finds no primary component within gcomm's wait (pc.wait_prim)
                // gives up starting, by design; it is started again. One that joins a
                // non-primary component instead aborts its startup the same way ("Wsrep startup
                // was interrupted": the first membership smoke's n2, a fourth node joining).
                .exits_known = &.{
                    "State transfer cannot be completed, need to abort",
                    "failed to reach primary view",
                    "Wsrep startup was interrupted",
                },
            });
        }
    }
}

fn append_scenario(s: *System.Scenario) void {
    s.setup("schema", schema);
    s.parallel_driver("append", append);
    s.parallel_driver("member", member_changes);
    s.finally("final reads", final_reads);
}

// Membership ------------------------------------------------------------------------------------

/// Membership steps for a while (Jepsen's member nemesis acts every few seconds): up to
/// `member_steps_max`, a drawn 1 to 5 s apart.
fn member_changes(context: *System.Context) !void {
    for (0..member_steps_max) |_| {
        try member_step(context);
        sdk.sleep_ms(1000 + sdk.random_below_named("member.pause_ms", 4000));
    }
}

const member_steps_max = 20;

/// One membership step, one at a time (a lock file in the runner), from the cluster's members a
/// node drawn lists (`wsrep_incoming_addresses`): the spare started when it is not among them
/// (fresh, a full state transfer, or with its data, an incremental one), after the join grace;
/// among them, one time in two shut down gracefully (it leaves the cluster).
fn member_step(context: *System.Context) !void {
    const lock = linux.open("/tmp/galera-member.lock", .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(lock) != .SUCCESS) return error.MemberLock;
    defer _ = linux.close(@intCast(lock));
    const lock_exclusive = 2; // LOCK_EX
    if (linux.errno(linux.flock(@intCast(lock), lock_exclusive)) != .SUCCESS) return error.MemberLock;
    const all = [_]*const sdk.Node{ &context.nodes.n1, &context.nodes.n2, &context.nodes.n3 };
    const spare = &context.nodes.n4;
    var buffer: [4096]u8 = undefined;
    // The members, from the first node that answers, starting at one drawn: under faults one is
    // often down (the first smoke's steps mostly asked a node that was), all of them seldom.
    const first = sdk.random_below(all.len);
    const status = for (0..all.len) |offset| {
        const via = all[(first + offset) % all.len];
        const answer = via.exec_said(&.{ "mariadb", "-uroot", "-N", "-e", "SHOW GLOBAL STATUS LIKE 'wsrep_incoming_addresses'" }, &buffer) catch continue;
        if (answer.status == 0) break answer;
        if (offset == all.len - 1) return member_refused("wsrep_incoming_addresses", answer.status, answer.output);
    } else return;
    var address_buffer: [24]u8 = undefined;
    const address = try std.fmt.bufPrint(&address_buffer, "{d}.{d}.{d}.{d}:", .{
        spare.address[0], spare.address[1], spare.address[2], spare.address[3],
    });
    if (std.mem.indexOf(u8, status.output, address) == null) {
        if (member_started_ns()) |at| if (monotonic_ns() -| at < join_grace_ns) return; // Joining.
        const fresh = sdk.random_below_named("galera.member_fresh", 2) == 0;
        if (fresh) try spare.wipe() else spare.start() catch {}; // Running already: as it is.
        member_started_note();
        sdk.sometimes(true, "a node was started to join", .{ .fresh = fresh });
        return;
    }
    sdk.sometimes(true, "a node joined", .{});
    if (sdk.random_below_named("galera.member_remove", 2) != 0) return; // It stays.
    var output: [4096]u8 = undefined;
    const result = spare.exec_said(&.{ "mariadb-admin", "-uroot", "shutdown" }, &output) catch return;
    if (result.status != 0) return member_refused("shutdown", result.status, result.output);
    sdk.sometimes(true, "a node left gracefully", .{});
}

/// A membership call refused or unanswered, said (an event): under faults, refusals are expected,
/// and a step that never succeeds says why.
fn member_refused(what: []const u8, status: u32, body: []const u8) void {
    sdk.event("member_refused", .{ .what = what, .status = status, .body = body[0..@min(body.len, 512)] });
}

/// The spare's last start (monotonic, virtual), and how long a join (its state transfer) may
/// take before the cluster lists it: until then, not started again.
const member_started_path = "/tmp/galera-member.started";
const join_grace_ns = 60 * std.time.ns_per_s;

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

fn addresses(context: *System.Context) [3][4]u8 {
    return .{ context.nodes.n1.address, context.nodes.n2.address, context.nodes.n3.address };
}

fn schema(context: *System.Context) !void {
    _ = try sdk.retry(schema_attempts_max, 200, sql_append.schema_create, .{
        context.nodes.n1.address, options,
    });
}

fn append(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const all = addresses(context);
    try sql_append.transactions(arena, &all, options);
}

/// Every committed append still there once faults stop (run 123 lost one, Elle none the wiser),
/// and no node in a primary component without a history: stateless nodes restoring their
/// component together run under the nil history UUID, and a node that saves it never starts
/// again (README).
fn final_reads(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const all = addresses(context);
    try sql_append.final_reads(arena, &all, options);
    inline for (node_names) |name| history_check(&@field(context.nodes, name), name);
}

const history_query = "SELECT variable_value FROM information_schema.global_status WHERE " ++
    "variable_name IN ('wsrep_cluster_state_uuid', 'wsrep_cluster_status') ORDER BY variable_name";
const nil_history = "00000000-0000-0000-0000-000000000000";

/// The node's cluster history and whether it is in the primary component (a node down or not
/// answering says nothing).
fn history_check(node: *const sdk.Node, comptime name: []const u8) void {
    var buffer: [512]u8 = undefined;
    const result = node.exec_output(&.{ "mariadb", "-N", "-e", history_query }, &buffer) catch return;
    if (result.status != 0) return;
    // The state UUID's line first (ORDER BY its name), then the status's; an empty value is an
    // empty line (a node not connected has no UUID), kept so the two stay apart.
    var lines = std.mem.splitScalar(u8, result.output, '\n');
    const uuid = std.mem.trim(u8, lines.next() orelse return, " \t\r");
    const status = std.mem.trim(u8, lines.next() orelse return, " \t\r");
    const primary = std.mem.eql(u8, status, "Primary");
    sdk.always(!(primary and std.mem.eql(u8, uuid, nil_history)), "no primary component runs under a nil history", .{
        .node = name,
        .uuid = uuid,
        .status = status,
    });
}
