// SPDX-License-Identifier: MIT
//! Example test program: Apache Ignite 3.1 (Raft replication, MVCC transactions over
//! primary-replica leases), three server nodes, under list-append transactions checked by Elle
//! for strict serializability. Every key a row of `LISTS (ID BIGINT PRIMARY KEY, VAL VARCHAR)`
//! in a zone of three replicas, its list the text "v1,v2,...". A transaction with an append is a
//! read-write one (Ignite: serializable), each append a get and a put of the key's list; one
//! without is read-only (read as of its start time). Jepsen never analyzed Ignite.
//!
//! Drivers are client processes: each opens a connection to the client node (IClient.java,
//! Ignite's Java client behind a line protocol) and runs its transactions there. Outcomes, as
//! Ignite documents them: `ok` with the reads; `fail` when nothing was applied (an error before
//! the commit, or the commit's TransactionException: rolled back); `info` when the commit got
//! no answer. Once faults stop, every committed append must be in its key's list, read in a
//! transaction of its own (sdk.elle.final_reads).
//!
//! Profiles: `default`, Ignite's own settings (table partitions' Raft logs not synced before an
//! entry is acknowledged: no power losses); `power-loss`, those logs synced (`raft.fsync`), and
//! power losses too.
//!
//!   determinismo explore ... --memory-mib 8192 --program zig-out/bin/ignite-test --scenario append
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo");
const tcp = sdk.tcp;

const Nodes = struct {
    n1: sdk.Node,
    n2: sdk.Node,
    n3: sdk.Node,
    iclient: sdk.Node,
};
const System = sdk.System(Nodes);

const client_port = 7000;
const cluster_port = 3344;
const rest_port = 10300;
const transactions_per_driver = 20;
const mops_max = 4;
/// Keys move with virtual time, a few at once, so lists stay short.
const keys_window = 4;
const window_s = 5;
const setup_attempts_max = 1200;
/// Once faults stop: the cluster serves within two minutes (JVMs restart, leases move), or never.
const final_attempts_max = 240;
/// The client's own timeouts are 30 s an operation (IClient.java).
const timeout_ms = 120_000;
const line_size_max = 64 * 1024;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .append = append_scenario },
        .checks = .{ .elle = sdk.elle.check(.{ .consistency = "strict-serializable" }) },
    });
}

fn describe(d: *System.Describe) !void {
    inline for (.{ .{ "default", false }, .{ "power-loss", true } }) |entry| {
        const profile = try d.profile(entry[0]);
        const build: sdk.schema.Build = .{ .context = ".", .dockerfile = "examples/ignite/Dockerfile" };
        inline for (.{ "n1", "n2", "n3" }, 1..) |name, id| {
            profile.node(@field(System.Name, name), .{
                .build = build,
                .command = &.{ "server", std.fmt.comptimePrint("{d}", .{id}) },
                .env = &.{"IGNITE_RAFT_FSYNC=" ++ (if (entry[1]) "true" else "false")},
                // The cluster port, open at once: clients are served only once the cluster is
                // initialized (setup), which needs all three.
                .ready = .{ .tcp = cluster_port },
                // Clocks skewed within the 500 ms its hybrid clocks assume (schema sync's
                // maximum clock skew).
                .faults = .{ .restart = true, .crash = entry[1], .stop = true, .clock_skew = true, .clock_skew_ms_max = 400 },
            });
        }
        profile.node(.iclient, .{
            .build = build,
            .command = &.{"client"},
            .ready = .{ .tcp = client_port },
            // The client library's node, as Jepsen's clients: its links to the servers faulted,
            // the drivers' calls into it not, and it is never paused or slowed.
            .faults = .{
                .pause = false,
                .runner_links = false,
                .sync_stall = false,
                .throttle = false,
                .process_pause = false,
            },
        });
    }
}

fn append_scenario(s: *System.Scenario) void {
    // Faults in bursts with quiet stretches: JVMs restart in tens of seconds.
    s.pacing = .{ .active_ms_max = 10_000, .quiet_ms_max = 30_000 };
    s.setup("cluster", cluster_setup);
    s.parallel_driver("append", appends);
    s.finally("final reads", final_reads);
}

const Client = struct {
    connection: tcp.Connection,
    line: [line_size_max]u8 = undefined,

    fn open(client: *Client, context: *System.Context) !void {
        try client.connection.open(context.nodes.iclient.address, client_port, .{ .timeout_ms = timeout_ms });
    }

    /// One request line, one reply line (valid until the next request).
    fn request(client: *Client, comptime format: []const u8, arguments: anytype) ![]const u8 {
        const line = try std.fmt.bufPrint(&client.line, format ++ "\n", arguments);
        try client.connection.write_all(line);
        return client.connection.read_line();
    }
};

// Setup -----------------------------------------------------------------------------------------

/// The cluster initialized (all three in its management and metastorage groups), then the zone
/// and the table, through the client node.
fn cluster_setup(context: *System.Context) !void {
    _ = try sdk.retry(setup_attempts_max, 500, cluster_init, .{context.nodes.n1.address});
    var client: Client = undefined;
    try client.open(context);
    defer client.connection.close();
    _ = try sdk.retry(setup_attempts_max, 500, table_create, .{&client});
}

fn cluster_init(address: [4]u8) !void {
    var buffer: [16 * 1024]u8 = undefined;
    const body =
        \\{"metaStorageNodes":["n1","n2","n3"],"cmgNodes":["n1","n2","n3"],"clusterName":"determinismo"}
    ;
    const response = try tcp.http_with(address, rest_port, "POST", "/management/v1/cluster/init", body, &buffer, .{
        .timeout_ms = timeout_ms,
        .content_type = "application/json",
    });
    if (response.status == 200) return;
    // An earlier attempt's answer was lost: initialized already.
    if (std.mem.indexOf(u8, response.body, "already initialized") != null) return;
    sdk.event("ignite_error", .{ .command = "init", .status = response.status, .body = clip(response.body) });
    return error.NotInitialized;
}

fn table_create(client: *Client) !void {
    const reply = try client.request("setup", .{});
    if (std.mem.eql(u8, reply, "ok")) return;
    sdk.event("ignite_error", .{ .command = "setup", .reply = clip(reply) });
    return error.NotCreated;
}

// The workload ----------------------------------------------------------------------------------

const Mop = struct { append: bool, key: u64, value: u64 };
const Outcome = enum { committed, not_committed, unknown };

fn appends(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    var client: Client = undefined;
    try client.open(context);
    defer client.connection.close();
    const history: sdk.elle.History = .{};
    var id: u64 = undefined;
    sdk.random_bytes(std.mem.asBytes(&id));
    id &= 0xffff_ffff;
    var process = sdk.elle.process_new();
    for (0..transactions_per_driver) |sequence| {
        var mops: [mops_max]Mop = undefined;
        const count = draw(&mops, id, sequence);
        try history.invoke(arena, process, try elle_mops(arena, mops[0..count], null));
        var reads: [mops_max]?[]const u64 = @splat(null);
        switch (run(arena, &client, mops[0..count], &reads)) {
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
                // Its client process may be gone with it: a fresh one.
                client.connection.close();
                client.open(context) catch return;
            },
        }
    }
}

fn draw(mops: *[mops_max]Mop, id: u64, sequence: u64) u32 {
    const count: u32 = @intCast(1 + sdk.random_below(mops_max));
    const base = monotonic_ns() / std.time.ns_per_s / window_s;
    for (mops[0..count], 0..) |*mop, position| {
        mop.* = .{
            .append = sdk.random_below(2) == 0,
            .key = base + sdk.random_below(keys_window),
            // Unique per key: the driver, its transaction, the micro-operation.
            .value = (id << 20) | (sequence << 4) | position,
        };
    }
    return count;
}

fn run(arena: std.mem.Allocator, client: *Client, mops: []const Mop, reads: *[mops_max]?[]const u64) Outcome {
    var line: std.ArrayList(u8) = .empty;
    line.appendSlice(arena, "txn") catch return .not_committed;
    for (mops) |mop| {
        if (mop.append) {
            line.print(arena, " a:{d}:{d}", .{ mop.key, mop.value }) catch return .not_committed;
        } else {
            line.print(arena, " r:{d}", .{mop.key}) catch return .not_committed;
        }
    }
    const reply = client.request("{s}", .{line.items}) catch return .unknown;
    if (std.mem.startsWith(u8, reply, "fail")) {
        sdk.event("ignite_fail", .{ .reply = clip(reply) });
        return .not_committed;
    }
    if (!std.mem.startsWith(u8, reply, "ok")) {
        sdk.event("ignite_reply", .{ .reply = clip(reply) });
        return .unknown;
    }
    return if (reads_parse(arena, reply, mops, reads)) .committed else |_| blk: {
        sdk.event("ignite_reply", .{ .reply = clip(reply) });
        break :blk .unknown;
    };
}

/// "ok <field>...": a field per mop, in order, `-` for an append, `[v1,v2,...]` for a read.
fn reads_parse(arena: std.mem.Allocator, reply: []const u8, mops: []const Mop, reads: *[mops_max]?[]const u64) !void {
    var fields = std.mem.tokenizeScalar(u8, reply["ok".len..], ' ');
    for (mops, 0..) |mop, position| {
        const field = fields.next() orelse return error.BadReply;
        if (mop.append) {
            if (!std.mem.eql(u8, field, "-")) return error.BadReply;
            continue;
        }
        reads[position] = try list_parse(arena, field);
    }
    if (fields.next() != null) return error.BadReply;
}

/// "[v1,v2,...]" to its values.
fn list_parse(arena: std.mem.Allocator, field: []const u8) ![]const u64 {
    if (field.len < 2 or field[0] != '[' or field[field.len - 1] != ']') return error.BadReply;
    var values: std.ArrayList(u64) = .empty;
    var items = std.mem.tokenizeScalar(u8, field[1 .. field.len - 1], ',');
    while (items.next()) |item| try values.append(arena, try std.fmt.parseInt(u64, item, 10));
    return values.items;
}

fn elle_mops(arena: std.mem.Allocator, mops: []const Mop, reads: ?*const [mops_max]?[]const u64) ![]const sdk.elle.Mop {
    const out = try arena.alloc(sdk.elle.Mop, mops.len);
    for (mops, out, 0..) |mop, *elle_mop, position| {
        elle_mop.* = if (mop.append)
            .{ .append = .{ .key = mop.key, .value = mop.value } }
        else
            .{ .read = .{ .key = mop.key, .list = if (reads) |known| known[position] orelse &.{} else null } };
    }
    return out;
}

// Once faults stop --------------------------------------------------------------------------------

/// Every committed append is in its key's list, read in a read-write transaction of its own
/// (sdk.elle.final_reads): Elle takes a read missing one for an older state, and the drivers
/// may never read a key again.
fn final_reads(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const history: sdk.elle.History = .{};
    var reader: FinalReader = .{ .context = context };
    defer if (reader.connected) reader.client.connection.close();
    try sdk.elle.final_reads(arena, &history, &reader);
}

const FinalReader = struct {
    context: *System.Context,
    client: Client = undefined,
    connected: bool = false,
    attempts: u32 = 0,

    pub fn read_list(reader: *FinalReader, arena: std.mem.Allocator, key: u64) ?[]const u64 {
        while (reader.attempts < final_attempts_max) {
            if (!reader.connected) {
                reader.client.open(reader.context) catch {
                    reader.attempts += 1;
                    sdk.sleep_ms(500);
                    continue;
                };
                reader.connected = true;
            }
            const reply = reader.client.request("read {d}", .{key}) catch {
                reader.client.connection.close();
                reader.connected = false;
                reader.attempts += 1;
                continue;
            };
            if (std.mem.startsWith(u8, reply, "ok ")) {
                if (list_parse(arena, reply["ok ".len..])) |list| return list else |_| {}
            }
            sdk.event("ignite_final_read", .{ .key = key, .reply = clip(reply) });
            reader.attempts += 1;
            sdk.sleep_ms(500);
        }
        return null;
    }
};

fn clip(text: []const u8) []const u8 {
    return text[0..@min(text.len, 400)];
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

test reads_parse {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const mops = [_]Mop{
        .{ .append = true, .key = 1, .value = 9 },
        .{ .append = false, .key = 1, .value = 0 },
        .{ .append = false, .key = 2, .value = 0 },
    };
    var reads: [mops_max]?[]const u64 = @splat(null);
    try reads_parse(arena, "ok - [7,9] []", &mops, &reads);
    try std.testing.expectEqual(null, reads[0]);
    try std.testing.expectEqualSlices(u64, &.{ 7, 9 }, reads[1].?);
    try std.testing.expectEqualSlices(u64, &.{}, reads[2].?);
    try std.testing.expectError(error.BadReply, reads_parse(arena, "ok - [7,9]", &mops, &reads));
    try std.testing.expectError(error.BadReply, reads_parse(arena, "ok [1] [7,9] []", &mops, &reads));
}
