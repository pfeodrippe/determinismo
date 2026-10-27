// SPDX-License-Identifier: MIT
//! Example test program: Dgraph v1.1.1, the release of Jepsen's analysis (2020), five nodes each
//! a zero and an alpha (Jepsen's: three replicas of each group, so two groups, of three alphas
//! and of two), and Jepsen's bank workload: eight accounts holding 100 in all, each account's
//! key, type and amount on one of seven predicates (its key modulo seven), so that its data lies
//! in several tablets, which a driver moves between the groups as Jepsen's nemesis did.
//!
//! Jepsen found in 1.1.1, every one with tablet moves: #4534 (and #4540), reads missing values
//! (an account with no amount); #4575, the same, rarely; #4543, read skew corrupting the total
//! for good (98 or 102); #4538, acknowledged inserts lost; #4601, a list read back as a number.
//!
//!   transfers  read two accounts, write both (an account at zero deleted), commit
//!   reads      every account, through each type predicate, in one transaction
//! Properties: every read sees the total (100); every account read has its amount; no amount is
//! negative; reads see only the bank's accounts, once each; once faults stop, the accounts read
//! and still hold 100.
//!
//! Faults: the default ones, process kills (a zero or an alpha, started again by its node),
//! restarts, graceful stops and power losses.
//!
//!   determinismo explore ... --memory-mib 12288 --program zig-out/bin/dgraph-test --scenario bank
const std = @import("std");
const sdk = @import("determinismo");

const Nodes = struct { dg1: sdk.Node, dg2: sdk.Node, dg3: sdk.Node, dg4: sdk.Node, dg5: sdk.Node };
const System = sdk.System(Nodes);
const node_names = [_][]const u8{ "dg1", "dg2", "dg3", "dg4", "dg5" };

const alpha_port = 8080;
const zero_port = 6080;
/// Jepsen's bank: eight accounts, 100 in all, transfers of 1 to 5, seven predicate stripes.
const accounts = 8;
const total = 100;
const transfer_max = 5;
const stripes = 7;
const operations_per_driver = 30;
const setup_attempts_max = 600;
const recover_attempts_max = 120;
const timeout_ms = 10_000;
/// A tablet move waits for the data to copy (Jepsen's: 20 s).
const move_timeout_ms = 20_000;
/// A reply's size at most (a zero's state, the largest, is a few kilobytes).
const reply_size_max = 256 * 1024;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .bank = bank_scenario },
    });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    const build: sdk.schema.Build = .{ .context = ".", .dockerfile = "examples/dgraph/Dockerfile" };
    inline for (node_names, 1..) |name, index| {
        default.node(@field(System.Name, name), .{
            .build = build,
            .command = &.{std.fmt.comptimePrint("{d}", .{index})},
            // The zero's HTTP port: open at once (an alpha waits for a quorum of zeros).
            .ready = .{ .tcp = zero_port },
            // Kills of the zero and the alpha (as Jepsen's): start.sh's supervising shells are
            // not Dgraph, and one killed left its alpha down for good.
            .faults = .{
                .restart = true,
                .crash = true,
                .stop = true,
                .process_kill = true,
                .process_kill_names = &.{"dgraph"},
            },
        });
    }
}

fn bank_scenario(s: *System.Scenario) void {
    // Faults in stretches of up to 10 s, quiet ones between: an alpha out of its group takes
    // seconds to serve again, and under a fault every 0.3 s nothing committed (Jepsen's nemesis
    // acted every 10 s).
    s.pacing = .{ .active_ms_max = 10_000, .quiet_ms_max = 10_000 };
    s.setup("accounts", bank_setup);
    s.parallel_driver("bank", bank_operations);
    s.singleton_driver("tablets", tablets_move);
    s.eventually("conserved", conserved);
}

fn addresses(context: *System.Context) [node_names.len][4]u8 {
    return .{
        context.nodes.dg1.address, context.nodes.dg2.address, context.nodes.dg3.address,
        context.nodes.dg4.address, context.nodes.dg5.address,
    };
}

fn address_of(context: *System.Context, name: []const u8) ?[4]u8 {
    const all = addresses(context);
    for (node_names, all) |node_name, address| {
        if (std.mem.eql(u8, node_name, name)) return address;
    }
    return null;
}

// Dgraph's HTTP API ------------------------------------------------------------------------------

/// Replies land here: a driver is a process of its own, its requests one at a time.
var reply_buffer: [reply_size_max]u8 = undefined;

/// A request's JSON answer, or why there is none: Conflict (aborted, definitely), Refused (an
/// error Dgraph reported), or the connection's errors (no answer).
fn request(
    arena: std.mem.Allocator,
    address: [4]u8,
    port: u16,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    wait_ms: u32,
) !std.json.Value {
    const response = try sdk.tcp.http_with(address, port, method, path, body, &reply_buffer, .{
        .timeout_ms = wait_ms,
        .content_type = "application/json",
    });
    // Copied out of the buffer, which the next request reuses.
    const options: std.json.ParseOptions = .{ .allocate = .alloc_always };
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, response.body, options) catch
        return if (response.status == 200) error.BadAnswer else error.NoAnswer;
    if (value != .object) return error.BadAnswer;
    if (value.object.get("errors")) |errors| {
        const message = error_message(errors);
        if (std.mem.indexOf(u8, message, "aborted") != null or
            std.mem.indexOf(u8, message, "onflict") != null) return error.Conflict;
        sdk.sometimes(true, "Dgraph refused a request", .{ .path = path, .message = message });
        return error.Refused;
    }
    return value;
}

fn error_message(errors: std.json.Value) []const u8 {
    if (errors != .array or errors.array.items.len == 0) return "";
    const first = errors.array.items[0];
    if (first != .object) return "";
    const message = first.object.get("message") orelse return "";
    return if (message == .string) message.string else "";
}

fn field(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

/// A transaction through one alpha: its start timestamp from its first request, and the keys
/// and predicates its mutations touched, which its commit sends back.
const Txn = struct {
    arena: std.mem.Allocator,
    address: [4]u8,
    start_ts: u64 = 0,
    keys: std.ArrayList(std.json.Value) = .empty,
    preds: std.ArrayList(std.json.Value) = .empty,

    fn path(txn: *const Txn, base: []const u8) ![]const u8 {
        if (txn.start_ts == 0) return base;
        const separator: []const u8 = if (std.mem.indexOfScalar(u8, base, '?') == null) "?" else "&";
        return std.fmt.allocPrint(txn.arena, "{s}{s}startTs={d}", .{ base, separator, txn.start_ts });
    }

    fn context_take(txn: *Txn, answer: std.json.Value) !void {
        const context = field(field(answer, "extensions") orelse return error.BadAnswer, "txn") orelse
            return error.BadAnswer;
        const start = field(context, "start_ts") orelse return error.BadAnswer;
        if (start != .integer) return error.BadAnswer;
        if (txn.start_ts == 0) txn.start_ts = @intCast(start.integer);
        if (field(context, "keys")) |keys| if (keys == .array) try txn.keys.appendSlice(txn.arena, keys.array.items);
        if (field(context, "preds")) |preds| if (preds == .array) try txn.preds.appendSlice(txn.arena, preds.array.items);
    }

    /// The query's `q` block.
    fn query(txn: *Txn, text: []const u8) ![]const std.json.Value {
        const body = try std.json.Stringify.valueAlloc(txn.arena, .{ .query = text }, .{});
        const answer = try request(txn.arena, txn.address, alpha_port, "POST", try txn.path("/query"), body, timeout_ms);
        try txn.context_take(answer);
        const q = field(field(answer, "data") orelse return error.BadAnswer, "q") orelse return &.{};
        return if (q == .array) q.array.items else error.BadAnswer;
    }

    fn mutate(txn: *Txn, body: []const u8) !void {
        const answer = try request(txn.arena, txn.address, alpha_port, "POST", try txn.path("/mutate"), body, timeout_ms);
        try txn.context_take(answer);
    }

    fn commit(txn: *Txn) !void {
        if (txn.start_ts == 0) return;
        const body = try std.json.Stringify.valueAlloc(txn.arena, .{
            .keys = txn.keys.items,
            .preds = txn.preds.items,
        }, .{});
        _ = try request(txn.arena, txn.address, alpha_port, "POST", try txn.path("/commit"), body, timeout_ms);
    }

    /// Best effort: a transaction left open is aborted by Dgraph in time anyway.
    fn abort(txn: *Txn) void {
        if (txn.start_ts == 0) return;
        const path_abort = txn.path("/commit?abort=true") catch return;
        _ = request(txn.arena, txn.address, alpha_port, "POST", path_abort, "", timeout_ms) catch {};
    }
};

// Accounts ---------------------------------------------------------------------------------------

const Account = struct { uid: ?[]const u8, amount: i64 };

fn integer(value: ?std.json.Value) ?i64 {
    const known = value orelse return null;
    return switch (known) {
        .integer => |number| number,
        .float => |number| @intFromFloat(number),
        else => null,
    };
}

/// The account `key`, or none (no node holds it: its amount is 0).
fn account_find(txn: *Txn, key: u32) !?Account {
    const stripe = key % stripes;
    const text = try std.fmt.allocPrint(txn.arena, "{{ q(func: eq(key_{d}, {d})) {{ uid key_{d} amount_{d} }} }}", .{ stripe, key, stripe, stripe });
    const found = try txn.query(text);
    if (found.len == 0) return null;
    sdk.always(found.len == 1, "an account is one node", .{ .key = key, .nodes = found.len });
    const node = found[0];
    const uid = field(node, "uid") orelse return error.BadAnswer;
    if (uid != .string) return error.BadAnswer;
    const amount_name = try std.fmt.allocPrint(txn.arena, "amount_{d}", .{stripe});
    const amount = integer(field(node, amount_name));
    sdk.always(amount != null, "every account read has its amount", .{ .key = key, .read = "transfer" });
    return .{ .uid = uid.string, .amount = amount orelse return error.MissingAmount };
}

/// The account written back: deleted at zero (as Jepsen's), else its key and amount set (and
/// its type, new).
fn account_write(txn: *Txn, key: u32, account: Account) !void {
    const stripe = key % stripes;
    const body = if (account.amount == 0)
        try std.fmt.allocPrint(txn.arena, "{{\"delete\":[{{\"uid\":\"{s}\",\"key_{d}\":null,\"amount_{d}\":null,\"type_{d}\":null}}]}}", .{ account.uid.?, stripe, stripe, stripe })
    else if (account.uid) |uid|
        try std.fmt.allocPrint(txn.arena, "{{\"set\":[{{\"uid\":\"{s}\",\"key_{d}\":{d},\"amount_{d}\":{d}}}]}}", .{ uid, stripe, key, stripe, account.amount })
    else
        try std.fmt.allocPrint(txn.arena, "{{\"set\":[{{\"key_{d}\":{d},\"type_{d}\":\"account\",\"amount_{d}\":{d}}}]}}", .{ stripe, key, stripe, stripe, account.amount });
    try txn.mutate(body);
}

const Read = struct { total: i64, accounts: u32, missing: u32, negative: u32, strangers: u32, twice: u32 };

/// Every account, through each type predicate, in one transaction (one snapshot), as Jepsen's
/// bank read.
fn accounts_read(arena: std.mem.Allocator, address: [4]u8) !Read {
    var txn: Txn = .{ .arena = arena, .address = address };
    var read: Read = .{ .total = 0, .accounts = 0, .missing = 0, .negative = 0, .strangers = 0, .twice = 0 };
    var seen: [accounts]bool = @splat(false);
    var fields: std.Io.Writer.Allocating = .init(arena);
    for (0..stripes) |stripe| try fields.writer.print(" key_{d} amount_{d}", .{ stripe, stripe });
    for (0..stripes) |stripe| {
        const text = try std.fmt.allocPrint(arena, "{{ q(func: eq(type_{d}, \"account\")) {{ uid{s} }} }}", .{
            stripe, fields.written(),
        });
        for (try txn.query(text)) |node| {
            var key: ?i64 = null;
            var amount: ?i64 = null;
            for (0..stripes) |other| {
                key = key orelse integer(field(node, try std.fmt.allocPrint(arena, "key_{d}", .{other})));
                amount = amount orelse integer(field(node, try std.fmt.allocPrint(arena, "amount_{d}", .{other})));
            }
            read.accounts += 1;
            const known_key = key orelse {
                read.strangers += 1;
                continue;
            };
            if (known_key < 0 or known_key >= accounts) {
                read.strangers += 1;
                continue;
            }
            const index: usize = @intCast(known_key);
            if (seen[index]) read.twice += 1;
            seen[index] = true;
            const known_amount = amount orelse {
                read.missing += 1;
                continue;
            };
            if (known_amount < 0) read.negative += 1;
            read.total += known_amount;
        }
    }
    return read;
}

fn read_judge(read: Read, phase: []const u8) void {
    const details = .{ .read = read, .phase = phase };
    sdk.always(read.missing == 0, "every account read has its amount", details);
    sdk.always(read.total == total or read.missing > 0, "every read sees the bank's total", details);
    sdk.always(read.negative == 0, "no account's amount is negative", details);
    sdk.always(read.strangers == 0 and read.twice == 0, "reads see only the bank's accounts, once each", details);
}

// Setup ------------------------------------------------------------------------------------------

fn bank_setup(context: *System.Context) !void {
    const arena = context.init.arena.allocator();
    const all = addresses(context);
    _ = try sdk.retry(setup_attempts_max, 500, cluster_formed, .{ arena, &all });
    _ = try sdk.retry(setup_attempts_max, 500, schema_alter, .{ arena, all[0] });
    _ = try sdk.retry(setup_attempts_max, 500, first_account, .{ arena, all[0] });
}

/// Every alpha in a group, each group with a leader: two groups, of three and two.
fn cluster_formed(arena: std.mem.Allocator, all: *const [node_names.len][4]u8) !void {
    const state = try request(arena, all[0], zero_port, "GET", "/state", "", timeout_ms);
    const groups = field(state, "groups") orelse return error.Forming;
    if (groups != .object) return error.Forming;
    var members: usize = 0;
    var iterator = groups.object.iterator();
    while (iterator.next()) |group| {
        const group_members = field(group.value_ptr.*, "members") orelse return error.Forming;
        if (group_members != .object) return error.Forming;
        var led = false;
        var member_iterator = group_members.object.iterator();
        while (member_iterator.next()) |member| {
            members += 1;
            const leader = field(member.value_ptr.*, "leader") orelse continue;
            led = led or (leader == .bool and leader.bool);
        }
        if (!led) return error.Forming;
    }
    if (members != node_names.len) return error.Forming;
}

fn schema_alter(arena: std.mem.Allocator, address: [4]u8) !void {
    var schema: std.Io.Writer.Allocating = .init(arena);
    for (0..stripes) |stripe| {
        try schema.writer.print("key_{d}: int @index(int) @upsert .\ntype_{d}: string @index(exact) .\n" ++
            "amount_{d}: int .\n", .{ stripe, stripe, stripe });
    }
    _ = try request(arena, address, alpha_port, "POST", "/alter", schema.written(), timeout_ms);
}

/// Account 0 holds the total.
fn first_account(arena: std.mem.Allocator, address: [4]u8) !void {
    var txn: Txn = .{ .arena = arena, .address = address };
    errdefer txn.abort();
    if (try account_find(&txn, 0) != null) return;
    try account_write(&txn, 0, .{ .uid = null, .amount = total });
    try txn.commit();
}

// Drivers ----------------------------------------------------------------------------------------

fn bank_operations(context: *System.Context) !void {
    const all = addresses(context);
    for (0..operations_per_driver) |_| {
        // Each operation's replies, freed after it.
        var operation: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer operation.deinit();
        const arena = operation.allocator();
        const address = all[sdk.random_below(all.len)];
        if (sdk.random_below(4) == 0) {
            const read = accounts_read(arena, address) catch |err| {
                sdk.sometimes(true, "a read failed", .{ .err = @errorName(err) });
                continue;
            };
            read_judge(read, "faults");
            sdk.sometimes(true, "a read saw every account", .{ .accounts = read.accounts });
        } else {
            transfer(arena, address) catch |err| switch (err) {
                error.Conflict => sdk.sometimes(true, "a transfer conflicted", .{}),
                error.Insufficient => sdk.sometimes(true, "a transfer lacked funds", .{}),
                else => sdk.sometimes(true, "a transfer failed", .{ .err = @errorName(err) }),
            };
        }
    }
}

fn transfer(arena: std.mem.Allocator, address: [4]u8) !void {
    const from: u32 = @intCast(sdk.random_below(accounts));
    const to: u32 = @intCast((from + 1 + sdk.random_below(accounts - 1)) % accounts);
    const amount: i64 = @intCast(1 + sdk.random_below(transfer_max));
    var txn: Txn = .{ .arena = arena, .address = address };
    errdefer txn.abort();
    const source = try account_find(&txn, from) orelse return error.Insufficient;
    if (source.amount < amount) return error.Insufficient;
    const target = try account_find(&txn, to);
    try account_write(&txn, from, .{ .uid = source.uid, .amount = source.amount - amount });
    try account_write(&txn, to, .{
        .uid = if (target) |known| known.uid else null,
        .amount = (if (target) |known| known.amount else 0) + amount,
    });
    try txn.commit();
    sdk.sometimes(true, "a transfer committed", .{ .from = from, .to = to, .amount = amount });
}

/// Jepsen's tablet mover: every tablet of the bank's predicates to a group drawn among them all,
/// through the zeros' leader.
fn tablets_move(context: *System.Context) !void {
    const all = addresses(context);
    for (0..operations_per_driver) |_| {
        var operation: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer operation.deinit();
        const arena = operation.allocator();
        sdk.sleep_ms(1000 + sdk.random_below(9000));
        const state = request(arena, all[sdk.random_below(all.len)], zero_port, "GET", "/state", "", timeout_ms) catch continue;
        const leader = zero_leader(context, state) orelse continue;
        const groups = field(state, "groups") orelse continue;
        if (groups != .object) continue;
        const group_ids = groups.object.keys();
        var iterator = groups.object.iterator();
        while (iterator.next()) |group| {
            const tablets = field(group.value_ptr.*, "tablets") orelse continue;
            if (tablets != .object) continue;
            var tablet_iterator = tablets.object.iterator();
            while (tablet_iterator.next()) |tablet| {
                const predicate = tablet.key_ptr.*;
                const ours = std.mem.startsWith(u8, predicate, "key_") or
                    std.mem.startsWith(u8, predicate, "amount_") or
                    std.mem.startsWith(u8, predicate, "type_");
                if (!ours) continue;
                const target = group_ids[sdk.random_below(group_ids.len)];
                if (std.mem.eql(u8, target, group.key_ptr.*)) continue;
                const path = try std.fmt.allocPrint(arena, "/moveTablet?tablet={s}&group={s}", .{ predicate, target });
                tablet_move(arena, leader, path) catch |err| {
                    sdk.sometimes(true, "a tablet move failed", .{ .err = @errorName(err) });
                    continue;
                };
                sdk.sometimes(true, "a tablet moved", .{ .predicate = predicate, .from = group.key_ptr.*, .to = target });
            }
        }
    }
}

/// One tablet moved through the zeros' leader. A move answers in plain text ("Predicate: [key_3]
/// moved from group [1] to [2]"), a refusal in JSON (its errors): every move once read as a
/// failure, as no JSON came back.
fn tablet_move(arena: std.mem.Allocator, leader: [4]u8, path: []const u8) !void {
    const response = try sdk.tcp.http_with(leader, zero_port, "GET", path, "", &reply_buffer, .{
        .timeout_ms = move_timeout_ms,
        .content_type = "application/json",
    });
    if (response.status == 200 and std.mem.startsWith(u8, response.body, "Predicate: [")) return;
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, response.body, .{}) catch return error.BadAnswer;
    const message = if (field(value, "errors")) |errors| error_message(errors) else "";
    sdk.sometimes(true, "Dgraph refused a request", .{ .path = path, .message = message });
    return error.Refused;
}

/// The zeros' leader's node ("addr": "dg3:5080").
fn zero_leader(context: *System.Context, state: std.json.Value) ?[4]u8 {
    const zeros = field(state, "zeros") orelse return null;
    if (zeros != .object) return null;
    var iterator = zeros.object.iterator();
    while (iterator.next()) |zero| {
        const leader = field(zero.value_ptr.*, "leader") orelse continue;
        if (leader != .bool or !leader.bool) continue;
        const addr = field(zero.value_ptr.*, "addr") orelse continue;
        if (addr != .string) continue;
        const name = addr.string[0 .. std.mem.indexOfScalar(u8, addr.string, ':') orelse addr.string.len];
        return address_of(context, name);
    }
    return null;
}

/// Once faults stop: the accounts read, from every alpha, still holding the total.
fn conserved(context: *System.Context) !void {
    for (addresses(context)) |address| {
        var operation: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer operation.deinit();
        const arena = operation.allocator();
        const read = sdk.retry(recover_attempts_max, 1000, accounts_read, .{ arena, address }) catch |err| {
            sdk.assert_unreachable("every alpha reads the accounts once faults stop", .{ .err = @errorName(err) });
            return;
        };
        read_judge(read, "recovered");
    }
}
