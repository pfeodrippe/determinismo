// SPDX-License-Identifier: MIT
//! Example test program: ScyllaDB 4.2.rc3, the build of Jepsen's analysis (2020), five nodes
//! configured as Jepsen's Scylla test (jepsen-io/scylla: its scylla.yaml, replication factor 3),
//! and its list-append workload over lightweight transactions: every key a row of partition 0 in
//! `lists (part, id, lwt_trivial, value list<int>)`; an append is `UPDATE ... SET value = value +
//! [v] ... IF lwt_trivial = null` (a condition always true, for a Paxos round), several appends a
//! conditional BATCH, a read a SELECT at SERIAL. Elle checks every timeline's history for strict
//! serializability, what LWT with SERIAL reads promise.
//!
//! Jepsen found in 4.2-rc3, among others: #7116, rows whose replicas diverged undetected (the
//! row hash stopped at the first null column, `lwt_trivial`), in healthy clusters; #7258, LWT
//! writes reported Unavailable that committed (aborted reads), under partitions and crashes;
//! stale SERIAL reads.
//!
//! Outcomes are the server's, as Jepsen's client takes them: Unavailable, or a condition not
//! applied, means the write did not happen; a timeout, a write failure, a lost connection, may
//! have. No retries.
//!
//!   determinismo explore ... --memory-mib 8192 --program zig-out/bin/scylla-test --scenario append
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo");
const Cql = @import("cql");

const Nodes = struct { n1: sdk.Node, n2: sdk.Node, n3: sdk.Node, n4: sdk.Node, n5: sdk.Node };
const System = sdk.System(Nodes);

const node_names = [_][]const u8{ "n1", "n2", "n3", "n4", "n5" };
const port = 9042;
const table = "jepsen_keyspace.lists";
/// Drivers number themselves here (in the runner, under a lock): values must be unique per key
/// and fit CQL's int.
const numbers_path = "/tmp/scylla-drivers";

const setup_attempts_max = 600;
const serve_attempts_max = 120;
const transactions_per_driver = 20;
/// The Java driver's read timeout, as Jepsen's client had it.
const timeout_ms = 12_000;
/// Jepsen's longest transaction.
const mops_max = 5;
const window_s = 10;
const keys_window = 4;
const values_max = 4096;
const query_size_max = 2048;
const refused_max = 20;
const refused_pause_ms_min = 100;
const refused_pause_ms_max = 1000;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .append = append_scenario },
        .checks = .{ .elle = sdk.elle.check(.{ .consistency = "strict-serializable" }) },
    });
}

/// `default`: Jepsen's nemeses, process kills and restarts, graceful stops (no power loss).
/// `power-loss`: power losses too. Under them a node can stay down for good: after one in the
/// middle of an sstable deletion, its pending_delete log read back as zeros and every start
/// after failed replaying it (an open question: docs/PLAN.md).
fn describe(d: *System.Describe) !void {
    const build: sdk.schema.Build = .{ .context = ".", .dockerfile = "examples/scylla/Dockerfile" };
    inline for (.{ .{ "default", false }, .{ "power-loss", true } }) |entry| {
        const profile = try d.profile(entry[0]);
        inline for (node_names) |name| {
            profile.node(@field(System.Name, name), .{
                .build = build,
                .command = &.{name},
                .ready = .{ .tcp = port },
                // Kills of Scylla only: a kill of start.sh's helpers (an address looked up,
                // under set -e) as a node started ended its start.sh, the node down for good.
                .faults = .{
                    .restart = true,
                    .crash = entry[1],
                    .stop = true,
                    .process_kill = true,
                    .process_kill_names = &.{"scylla"},
                },
            });
        }
    }
}

fn append_scenario(s: *System.Scenario) void {
    s.setup("schema", schema_setup);
    s.parallel_driver("append", append);
    s.finally("final reads", final_reads);
}

fn addresses(context: *System.Context) [node_names.len][4]u8 {
    return .{
        context.nodes.n1.address, context.nodes.n2.address, context.nodes.n3.address,
        context.nodes.n4.address, context.nodes.n5.address,
    };
}

// Setup -----------------------------------------------------------------------------------------

fn schema_setup(context: *System.Context) !void {
    const all = addresses(context);
    _ = try sdk.retry(setup_attempts_max, 500, ring_formed, .{&all});
    _ = try sdk.retry(setup_attempts_max, 500, schema_create, .{all[0]});
    for (all) |address| _ = try sdk.retry(setup_attempts_max, 500, table_known, .{address});
}

/// Every node knows the four others.
fn ring_formed(all: *const [node_names.len][4]u8) !void {
    for (all) |address| {
        var connection: Cql = undefined;
        try connection.open(address, port, .{ .timeout_ms = timeout_ms });
        defer connection.close();
        const reply = try connection.query("SELECT peer FROM system.peers", .{});
        const rows = switch (reply) {
            .rows => |rows| rows,
            .done => return error.BadReply,
            .failure => |failure| return failed("peers", failure),
        };
        if (rows.count != node_names.len - 1) return error.RingForming;
    }
}

fn schema_create(address: [4]u8) !void {
    var connection: Cql = undefined;
    try connection.open(address, port, .{ .timeout_ms = timeout_ms });
    defer connection.close();
    const statements = [_][]const u8{
        "CREATE KEYSPACE IF NOT EXISTS jepsen_keyspace WITH replication = " ++
            "{'class': 'SimpleStrategy', 'replication_factor': 3}",
        // Jepsen's: lwt_trivial stays null, for a condition always true.
        "CREATE TABLE IF NOT EXISTS " ++ table ++ " (part int, id int, lwt_trivial int, " ++
            "value list<int>, PRIMARY KEY (part, id)) " ++
            "WITH compaction = {'class': 'SizeTieredCompactionStrategy'}",
    };
    for (statements) |statement| {
        switch (try connection.query(statement, .{})) {
            .done, .rows => {},
            .failure => |failure| if (failure.code != Cql.code.already_exists) return failed("schema", failure),
        }
    }
}

/// The node has the table (schema changes spread by gossip).
fn table_known(address: [4]u8) !void {
    var connection: Cql = undefined;
    try connection.open(address, port, .{ .timeout_ms = timeout_ms });
    defer connection.close();
    switch (try connection.query("SELECT value FROM " ++ table ++ " WHERE part = 0 AND id = 0", .{})) {
        .rows => {},
        .done => return error.BadReply,
        .failure => |failure| return failed("table", failure),
    }
}

fn failed(what: []const u8, failure: Cql.Failure) error{Failed} {
    note(what, failure);
    return error.Failed;
}

fn note(what: []const u8, failure: Cql.Failure) void {
    sdk.event("cql_error", .{
        .what = what,
        .code = failure.code,
        .message = failure.message,
        .write_type = failure.write_type,
    });
}

// The workload ----------------------------------------------------------------------------------

const Mop = struct { append: bool, key: u32, value: u32 };
const Outcome = enum { committed, not_committed, unknown };

fn append(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const all = addresses(context);
    const history: sdk.elle.History = .{};
    const number = try driver_number();
    var process = sdk.elle.process_new();
    var connection: Cql = undefined;
    var connected = false;
    defer if (connected) connection.close();
    var refused: u32 = 0;
    var sequence: u32 = 0;
    while (sequence < transactions_per_driver) {
        if (!connected) {
            // As Jepsen's clients: each bound to one node, which coordinates its requests.
            connection.open(all[sdk.random_below(all.len)], port, .{ .timeout_ms = timeout_ms }) catch |err| {
                if (!sdk.tcp.unavailable(err)) return err;
                if (refused == 0) sdk.sometimes(true, "a node refused a connection", .{});
                refused += 1;
                if (refused == refused_max) return;
                pause_ms(refused_pause_ms_min + sdk.random_below(refused_pause_ms_max - refused_pause_ms_min));
                continue;
            };
            connected = true;
        }
        var mops: [mops_max]Mop = undefined;
        const count = draw(&mops, number, sequence);
        try history.invoke(arena, process, try elle_mops(arena, mops[0..count], null));
        var read: ?[]const u64 = null;
        const outcome = run(arena, &connection, mops[0..count], &read);
        switch (outcome) {
            .committed => try history.ok(arena, process, try elle_mops(arena, mops[0..count], read)),
            .not_committed => try history.fail(arena, process, try elle_mops(arena, mops[0..count], null)),
            .unknown => {
                try history.info(arena, process, try elle_mops(arena, mops[0..count], null));
                sdk.sometimes(true, "a write's outcome is unknown", .{});
                process = sdk.elle.process_new(); // Elle's rule: one operation at a time.
            },
        }
        if (outcome != .committed) {
            // A late reply must not answer the next request.
            connection.close();
            connected = false;
        }
        sequence += 1;
    }
}

/// Jepsen's transactions: one read, one append, or appends only (Scylla's CQL has no
/// multi-row read in a transaction). Keys move on with time.
fn draw(mops: *[mops_max]Mop, number: u32, sequence: u32) u32 {
    const count: u32 = @intCast(1 + sdk.random_below(mops_max));
    const base: u32 = @intCast(monotonic_ns() / std.time.ns_per_s / window_s);
    const reading = count == 1 and sdk.random_below(2) == 0;
    for (mops[0..count], 0..) |*mop, position| {
        mop.* = .{
            .append = !reading,
            .key = base + @as(u32, @intCast(sdk.random_below(keys_window))),
            // Unique per key: the driver, its transaction, the micro-operation.
            .value = (number << 8) | (sequence << 3) | @as(u32, @intCast(position)),
        };
    }
    return count;
}

fn run(arena: std.mem.Allocator, connection: *Cql, mops: []const Mop, read: *?[]const u64) Outcome {
    var buffer: [query_size_max]u8 = undefined;
    if (!mops[0].append) {
        const text = std.fmt.bufPrint(&buffer, "SELECT value FROM " ++ table ++ " WHERE part = 0 AND id = {d}", .{
            mops[0].key,
        }) catch unreachable;
        const reply = connection.query(text, .{ .consistency = .serial }) catch return .not_committed;
        const rows = switch (reply) {
            .rows => |rows| rows,
            .done => return .not_committed,
            .failure => |failure| {
                note("read", failure);
                return .not_committed; // A read changes nothing.
            },
        };
        read.* = list_of(arena, &rows) catch return .not_committed;
        return .committed;
    }
    var writer: std.Io.Writer = .fixed(&buffer);
    const batch = mops.len > 1;
    if (batch) writer.writeAll("BEGIN BATCH ") catch unreachable;
    for (mops) |mop| {
        writer.print("UPDATE " ++ table ++ " SET value = value + [{d}] WHERE part = 0 AND id = {d} " ++
            "IF lwt_trivial = null", .{ mop.value, mop.key }) catch unreachable;
        if (batch) writer.writeAll("; ") catch unreachable;
    }
    if (batch) writer.writeAll("APPLY BATCH") catch unreachable;
    // The Java driver's defaults, as Jepsen left them: LOCAL_ONE to commit, SERIAL for Paxos.
    const reply = connection.query(writer.buffered(), .{ .consistency = .local_one, .serial = .serial }) catch
        return .unknown;
    switch (reply) {
        .done => return .unknown,
        .failure => |failure| {
            note(if (batch) "batch" else "append", failure);
            // Jepsen's client: Unavailable is definite (the coordinator did not try); timeouts and
            // write failures are not.
            return if (failure.code == Cql.code.unavailable) .not_committed else .unknown;
        },
        .rows => |rows| {
            const applied_column = rows.column("[applied]") orelse return .unknown;
            var applied: u32 = 0;
            for (rows.cells[0..rows.count]) |row| {
                if (Cql.boolean(row[applied_column]) orelse false) applied += 1;
            }
            if (rows.count > 0 and applied == rows.count) return .committed;
            if (applied == 0) {
                sdk.sometimes(true, "a condition always true was not applied", .{});
                return .not_committed;
            }
            sdk.sometimes(true, "a batch was partly applied", .{ .rows = rows.count, .applied = applied });
            return .unknown;
        },
    }
}

fn list_of(arena: std.mem.Allocator, rows: *const Cql.Rows) ![]const u64 {
    if (rows.count == 0) return &.{};
    const column = rows.column("value") orelse return error.BadReply;
    var values: [values_max]i32 = undefined;
    const list = try Cql.int_list(rows.cells[0][column], &values);
    const out = try arena.alloc(u64, list.len);
    for (list, out) |value, *element| element.* = @as(u32, @bitCast(value)); // Whatever was read.
    return out;
}

fn elle_mops(arena: std.mem.Allocator, mops: []const Mop, read: ?[]const u64) ![]const sdk.elle.Mop {
    const out = try arena.alloc(sdk.elle.Mop, mops.len);
    for (mops, out) |mop, *elle_mop| {
        elle_mop.* = if (mop.append)
            .{ .append = .{ .key = mop.key, .value = mop.value } }
        else
            .{ .read = .{ .key = mop.key, .list = read } };
    }
    return out;
}

/// Once faults stop (the drivers done): every node serves a SERIAL read again, and every
/// committed append is in its key's list, read at SERIAL (sdk.elle.final_reads): Elle below
/// takes a read missing one for an older state, and the drivers may never read a key again.
fn final_reads(context: *System.Context) !void {
    serves(context);
    const arena = context.init.arena.allocator();
    const history: sdk.elle.History = .{};
    var reader: FinalReader = .{ .addresses = addresses(context) };
    try sdk.elle.final_reads(arena, &history, &reader);
}

const FinalReader = struct {
    addresses: [node_names.len][4]u8,

    pub fn read_list(reader: *FinalReader, arena: std.mem.Allocator, key: u64) ?[]const u64 {
        for (0..serve_attempts_max) |attempt| {
            const address = reader.addresses[attempt % reader.addresses.len];
            if (serial_list(arena, address, key)) |list| return list else |_| {}
            pause_ms(1000);
        }
        return null;
    }
};

fn serial_list(arena: std.mem.Allocator, address: [4]u8, key: u64) ![]const u64 {
    var connection: Cql = undefined;
    try connection.open(address, port, .{ .timeout_ms = timeout_ms });
    defer connection.close();
    var buffer: [query_size_max]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "SELECT value FROM " ++ table ++ " WHERE part = 0 AND id = {d}", .{key}) catch unreachable;
    const rows = switch (try connection.query(text, .{ .consistency = .serial })) {
        .rows => |rows| rows,
        .done => return error.BadReply,
        .failure => |failure| return failed("final read", failure),
    };
    return list_of(arena, &rows);
}

/// After faults stop, every node serves a SERIAL read again.
fn serves(context: *System.Context) void {
    for (addresses(context)) |address| {
        _ = sdk.retry(serve_attempts_max, 1000, serial_read, .{address}) catch |err| {
            sdk.assert_unreachable("every node serves SERIAL reads once faults stop", .{ .err = @errorName(err) });
            return;
        };
    }
}

fn serial_read(address: [4]u8) !void {
    var connection: Cql = undefined;
    try connection.open(address, port, .{ .timeout_ms = timeout_ms });
    defer connection.close();
    const text = "SELECT value FROM " ++ table ++ " WHERE part = 0 AND id = 0";
    switch (try connection.query(text, .{ .consistency = .serial })) {
        .rows => {},
        .done => return error.BadReply,
        .failure => |failure| return failed("serves", failure),
    }
}

/// A number of its own for this driver: one counter for all, in the runner, under a lock.
fn driver_number() !u32 {
    const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
    const opened = linux.open(numbers_path, flags, 0o644);
    if (linux.errno(opened) != .SUCCESS) return error.NumbersOpen;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    if (linux.errno(linux.flock(fd, std.posix.LOCK.EX)) != .SUCCESS) return error.NumbersLock;
    var bytes: [4]u8 = @splat(0);
    _ = linux.pread(fd, &bytes, bytes.len, 0); // A new file reads short: zero.
    const number = std.mem.readInt(u32, &bytes, .little) + 1;
    if (number >= 1 << 23) return error.TooManyDrivers; // Values must fit CQL's int.
    std.mem.writeInt(u32, &bytes, number, .little);
    if (linux.pwrite(fd, &bytes, bytes.len, 0) != bytes.len) return error.NumbersWrite;
    return number;
}

fn pause_ms(ms: u64) void {
    if (ms == 0) return;
    const duration: linux.timespec = .{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast(ms % std.time.ms_per_s * std.time.ns_per_ms),
    };
    _ = linux.nanosleep(&duration, null);
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}
