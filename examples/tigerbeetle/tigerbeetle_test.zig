// SPDX-License-Identifier: MIT
//! Example test program: TigerBeetle (github.com/tigerbeetle/tigerbeetle), three replicas,
//! following Jepsen's TigerBeetle analysis (2025, from 0.16.11). Its #2767: a replica that lost
//! its disk and was reformatted (the way back before `tigerbeetle recover`, 0.16.43) can make the
//! cluster lose committed transfers. Here the wipe fault takes a replica's disk, and start.sh
//! reformats the replica's data file as it comes back.
//!
//! Drivers create accounts and transfers through `tigerbeetle repl` (in a random replica's node),
//! and note in the runner (/tmp/tb-acked.log, one write per line) every one TigerBeetle
//! acknowledged, and the transfers whose fate is unknown (no answer in time: a client never gives
//! up, Jepsen's #206). Properties, once faults stop:
//!   acknowledged accounts survive    every acknowledged account is there
//!   acknowledged transfers survive   every acknowledged transfer is there, as created
//!   balances add up                  an account's posted debits and credits are the sum of its
//!                                    acknowledged transfers, plus some of the unknown ones
//! Faults: the default ones, restarts, graceful stops, power losses, and wipes of tb-2 alone.
//!
//!   determinismo explore ... --memory-mib 6144 --program zig-out/bin/tigerbeetle-test \
//!       --scenario ledger
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo");

const Nodes = struct { @"tb-0": sdk.Node, @"tb-1": sdk.Node, @"tb-2": sdk.Node };
const System = sdk.System(Nodes);
const replicas_count = 3;

const port = 3000;
const acked_path = "/tmp/tb-acked.log";
/// A request's answer, at most (busybox timeout around the repl, which never gives up).
const request_timeout = "10";
const accounts_per_driver = 3;
const transfers_per_driver = 20;
/// Ids per lookup: a repl command over about 8 KB panics the repl (0.16.13).
const lookup_batch = 100;
const setup_attempts_max = 300;
/// Once faults stop: how long the cluster may take to answer, and how long it is waited for (to
/// measure it: Jepsen's #2739, a single replica down stalling requests for up to about 100 s).
const recovery_s_max = 60;
const recovery_attempts_max = 600;
const output_size_max = 256 * 1024;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{ .ledger = ledger } });
}

fn describe(d: *System.Describe) !void {
    const profile = try d.profile("default");
    // Only tb-2 ever loses its disk: three replicas tolerate one, and losing two at once loses
    // data in any replicated system. Committed data lost with only tb-2's disk gone is a bug
    // (Jepsen's #2767).
    inline for (.{ "tb-0", "tb-1", "tb-2" }, 0..) |name, replica| {
        profile.node(@field(System.Name, name), .{
            .build = .{ .context = ".", .dockerfile = "examples/tigerbeetle/Dockerfile" },
            .command = &.{ std.fmt.comptimePrint("{d}", .{replica}), "tb-0,tb-1,tb-2" },
            .ready = .{ .tcp = port },
            .faults = .{ .restart = true, .crash = true, .stop = true, .wipe = replica == 2 },
        });
    }
}

fn ledger(s: *System.Scenario) void {
    s.setup("cluster", cluster_answers);
    s.parallel_driver("transfer", transfer_many);
    s.eventually("survive", everything_survives);
}

const Repl = struct {
    nodes: [replicas_count]*const sdk.Node,
    addresses: []const u8,
};

fn repl_of(context: *System.Context, arena: std.mem.Allocator) !Repl {
    const nodes = [replicas_count]*const sdk.Node{
        &context.nodes.@"tb-0", &context.nodes.@"tb-1", &context.nodes.@"tb-2",
    };
    var addresses: std.ArrayList(u8) = .empty;
    for (nodes, 0..) |node, index| {
        if (index > 0) try addresses.append(arena, ',');
        const a = node.address;
        try addresses.print(arena, "{d}.{d}.{d}.{d}:{d}", .{ a[0], a[1], a[2], a[3], port });
    }
    return .{ .nodes = nodes, .addresses = addresses.items };
}

/// One repl command in a random replica's node: its output, or an error when no answer came in
/// time (or the node is down).
fn request(repl: *const Repl, arena: std.mem.Allocator, command: []const u8) ![]const u8 {
    const node = repl.nodes[sdk.random_below(replicas_count)];
    const addresses = try std.fmt.allocPrint(arena, "--addresses={s}", .{repl.addresses});
    const text = try std.fmt.allocPrint(arena, "--command={s}", .{command});
    const buffer = try arena.alloc(u8, output_size_max);
    const result = try node.exec_output(&.{
        "timeout", request_timeout, "tigerbeetle", "repl", "--cluster=0", addresses, text,
    }, buffer);
    if (result.status != 0) return error.NoAnswer;
    return result.output;
}

// Setup ---------------------------------------------------------------------------------------

/// The cluster answers: account 1, which every driver's first transfer may use.
fn cluster_answers(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const repl = try repl_of(context, arena);
    _ = try sdk.retry(setup_attempts_max, 200, account_create_once, .{ &repl, arena, 1 });
}

fn account_create_once(repl: *const Repl, arena: std.mem.Allocator, id: u64) !void {
    const command = try std.fmt.allocPrint(arena, "create_accounts id={d} ledger=1 code=1;", .{id});
    const output = try request(repl, arena, command);
    if (failure(output)) |reason| {
        if (std.mem.indexOf(u8, reason, "exists") == null) return error.Refused;
    }
}

/// A create's failure as the repl prints it ("Failed to create ... error.<result>"), if any.
fn failure(output: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, output, "Failed to create") orelse return null;
    const end = std.mem.indexOfScalarPos(u8, output, at, '\n') orelse output.len;
    return output[at..end];
}

// Drivers -------------------------------------------------------------------------------------

/// A few accounts of its own, then transfers between them (and account 1), each noted when
/// acknowledged, or as unknown when no answer came.
fn transfer_many(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const repl = try repl_of(context, arena);
    var prefix_bytes: [4]u8 = undefined;
    sdk.random_bytes(&prefix_bytes);
    const prefix: u64 = (@as(u64, std.mem.readInt(u32, &prefix_bytes, .little)) | 1) << 20;
    var accounts: [accounts_per_driver + 1]u64 = undefined;
    accounts[0] = 1;
    var created: usize = 1;
    for (0..accounts_per_driver) |index| {
        const id = prefix + index;
        account_create_once(&repl, arena, id) catch |err| {
            sdk.sometimes(true, "an account creation got no answer", .{ .err = @errorName(err) });
            continue;
        };
        note("a {d}\n", .{id});
        accounts[created] = id;
        created += 1;
    }
    if (created < 2) return;
    for (0..transfers_per_driver) |index| {
        const id = prefix + accounts_per_driver + index;
        const debit = accounts[sdk.random_below(created)];
        var credit = accounts[sdk.random_below(created)];
        if (credit == debit) credit = accounts[(sdk.random_below(created - 1) + 1 + std.mem.indexOfScalar(u64, accounts[0..created], debit).?) % created];
        const amount = 1 + sdk.random_below(100);
        const command = try std.fmt.allocPrint(arena, "create_transfers id={d} debit_account_id={d} " ++
            "credit_account_id={d} amount={d} ledger=1 code=1;", .{ id, debit, credit, amount });
        const output = request(&repl, arena, command) catch |err| {
            sdk.sometimes(true, "a transfer got no answer", .{ .err = @errorName(err) });
            note("u {d} {d} {d} {d}\n", .{ id, debit, credit, amount });
            continue;
        };
        if (failure(output)) |reason| {
            sdk.always(false, "a transfer between existing accounts is accepted", .{ .reason = reason });
            continue;
        }
        note("t {d} {d} {d} {d}\n", .{ id, debit, credit, amount });
        sdk.sometimes(true, "a transfer was acknowledged", .{});
    }
}

/// One line appended to the runner's log, in one write.
fn note(comptime format: []const u8, arguments: anytype) void {
    var line_buffer: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buffer, format, arguments) catch unreachable;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
    const fd = linux.open(acked_path, flags, 0o644);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.write(@intCast(fd), line.ptr, line.len);
}

// Checks --------------------------------------------------------------------------------------

const Transfer = struct { id: u64, debit: u64, credit: u64, amount: u64 };

/// What TigerBeetle prints of an account or a transfer (all numbers as strings).
const Object = struct {
    id: []const u8 = "",
    debit_account_id: []const u8 = "",
    credit_account_id: []const u8 = "",
    amount: []const u8 = "",
    debits_posted: []const u8 = "",
    credits_posted: []const u8 = "",
};

fn everything_survives(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const repl = try repl_of(context, arena);
    const log = std.Io.Dir.cwd().readFileAlloc(context.init.io, acked_path, arena, .limited(1 << 26)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    var accounts: std.ArrayList(u64) = .empty;
    var acked: std.ArrayList(Transfer) = .empty;
    var unknown: std.ArrayList(Transfer) = .empty;
    var lines = std.mem.tokenizeScalar(u8, log, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const kind = fields.next() orelse continue;
        var numbers: [4]u64 = @splat(0);
        for (&numbers) |*value| value.* = std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0;
        if (std.mem.eql(u8, kind, "a")) try accounts.append(arena, numbers[0]);
        const transfer: Transfer = .{ .id = numbers[0], .debit = numbers[1], .credit = numbers[2], .amount = numbers[3] };
        if (std.mem.eql(u8, kind, "t")) try acked.append(arena, transfer);
        if (std.mem.eql(u8, kind, "u")) try unknown.append(arena, transfer);
    }
    try accounts.append(arena, 1);
    const waited_start_ns = monotonic_ns();
    const found_accounts = sdk.retry(recovery_attempts_max, 500, lookup, .{ &repl, arena, "lookup_accounts", accounts.items }) catch |err| {
        sdk.assert_unreachable("the cluster answers once faults stop", .{ .err = @errorName(err) });
        return err;
    };
    const waited_s = (monotonic_ns() - waited_start_ns) / std.time.ns_per_s;
    sdk.always(waited_s <= recovery_s_max, "the cluster answers within a minute once faults stop", .{
        .waited_s = waited_s,
    });
    const transfer_ids = try arena.alloc(u64, acked.items.len);
    for (acked.items, transfer_ids) |transfer, *id| id.* = transfer.id;
    const found_transfers = sdk.retry(recovery_attempts_max, 500, lookup, .{ &repl, arena, "lookup_transfers", transfer_ids }) catch |err| {
        sdk.assert_unreachable("the cluster answers once faults stop", .{ .err = @errorName(err) });
        return err;
    };
    var lost_accounts: u64 = 0;
    for (accounts.items) |id| {
        if (!found_accounts.contains(id)) lost_accounts += 1;
    }
    sdk.always(lost_accounts == 0, "every acknowledged account survives", .{
        .acknowledged = accounts.items.len,
        .lost = lost_accounts,
    });
    var lost_transfers: u64 = 0;
    var changed: u64 = 0;
    for (acked.items) |transfer| {
        const object = found_transfers.get(transfer.id) orelse {
            lost_transfers += 1;
            continue;
        };
        const same = number(object.debit_account_id) == transfer.debit and
            number(object.credit_account_id) == transfer.credit and number(object.amount) == transfer.amount;
        if (!same) changed += 1;
    }
    sdk.always(lost_transfers == 0, "every acknowledged transfer survives", .{
        .acknowledged = acked.items.len,
        .lost = lost_transfers,
    });
    sdk.always(changed == 0, "a transfer is read back as it was created", .{ .changed = changed });
    // Each account's posted debits and credits: its acknowledged transfers, and some unknown ones.
    var off: u64 = 0;
    for (accounts.items) |id| {
        const object = found_accounts.get(id) orelse continue;
        var debits_min: u64 = 0;
        var credits_min: u64 = 0;
        var debits_max: u64 = 0;
        var credits_max: u64 = 0;
        for (acked.items) |transfer| {
            if (transfer.debit == id) debits_min += transfer.amount;
            if (transfer.credit == id) credits_min += transfer.amount;
        }
        debits_max = debits_min;
        credits_max = credits_min;
        for (unknown.items) |transfer| {
            if (transfer.debit == id) debits_max += transfer.amount;
            if (transfer.credit == id) credits_max += transfer.amount;
        }
        const debits = number(object.debits_posted);
        const credits = number(object.credits_posted);
        if (debits < debits_min or debits > debits_max or credits < credits_min or credits > credits_max) off += 1;
    }
    sdk.always(off == 0, "an account's balances add up to its transfers", .{ .accounts_off = off });
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

fn number(text: []const u8) u64 {
    return std.fmt.parseInt(u64, text, 10) catch std.math.maxInt(u64);
}

/// The objects with these ids (`lookup_accounts` or `lookup_transfers`), by id: an error when
/// a batch got no answer.
fn lookup(repl: *const Repl, arena: std.mem.Allocator, operation: []const u8, ids: []const u64) !std.AutoHashMapUnmanaged(u64, Object) {
    var found: std.AutoHashMapUnmanaged(u64, Object) = .empty;
    var start: usize = 0;
    while (start < ids.len) : (start += lookup_batch) {
        var command: std.ArrayList(u8) = .empty;
        try command.print(arena, "{s} ", .{operation});
        for (ids[start..@min(ids.len, start + lookup_batch)], 0..) |id, index| {
            if (index > 0) try command.appendSlice(arena, ", ");
            try command.print(arena, "id={d}", .{id});
        }
        try command.append(arena, ';');
        const output = try request(repl, arena, command.items);
        for (try objects(arena, output)) |object| try found.put(arena, number(object.id), object);
    }
    return found;
}

/// The JSON objects the repl prints, one after another (each over several lines).
fn objects(arena: std.mem.Allocator, output: []const u8) ![]const Object {
    var list: std.ArrayList(Object) = .empty;
    var start: ?usize = null;
    var lines = std.mem.splitScalar(u8, output, '\n');
    var offset: usize = 0;
    while (lines.next()) |line| : (offset += line.len + 1) {
        if (std.mem.startsWith(u8, line, "{")) start = offset;
        if (std.mem.startsWith(u8, line, "}")) if (start) |first| {
            const text = output[first .. offset + line.len];
            const object = std.json.parseFromSliceLeaky(Object, arena, text, .{
                .ignore_unknown_fields = true,
            }) catch {
                start = null;
                continue;
            };
            try list.append(arena, object);
            start = null;
        };
    }
    return list.items;
}

test objects {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const output = "info(message_bus): connected to replica 0\n{\n  \"id\": \"7\",\n  \"ledger\": \"1\",\n" ++
        "  \"flags\": [],\n  \"debits_posted\": \"12\"\n}\n{\n  \"id\": \"9\"\n}\n";
    const found = try objects(arena_state.allocator(), output);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("12", found[0].debits_posted);
    try std.testing.expectEqualStrings("9", found[1].id);
}
