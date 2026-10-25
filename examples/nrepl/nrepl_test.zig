// SPDX-License-Identifier: MIT
//! Example test program: nREPL (nrepl/nrepl 1.8.0, server/deps.edn), the protocol every Clojure
//! editor speaks, under concurrent clients and faults. Clients talk bencode over TCP
//! (bencode.zig).
//!
//! Properties:
//!   evaluations return their value   `(+ a b)` answers a + b, whatever else runs
//!   a session's *1 is its own        right after `(+ a b)`, `*1` in that session is a + b,
//!                                    while other sessions evaluate concurrently
//!   requests finish                  every request that gets an answer ends with "done"
//!   interrupts land                  an interrupted long evaluation ends interrupted (or done)
//!   the server recovers              after faults, a new session evaluates again
const std = @import("std");
const assert = std.debug.assert;
const sdk = @import("determinismo");
const bencode = @import("bencode.zig");

const Nodes = struct { nrepl: sdk.Node };
const System = sdk.System(Nodes);

const port = 7888;
const evaluations_per_driver = 12;
const recovery_attempts_max = 120;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{ .sessions = sessions } });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.nrepl, .{
        .build = .{ .context = ".", .dockerfile = "examples/nrepl/Dockerfile" },
        .ready = .{ .tcp = port },
    });
}

fn sessions(s: *System.Scenario) void {
    s.parallel_driver("evaluate", evaluate_many);
    s.parallel_driver("interrupt", interrupt_one);
    s.eventually("recovers", recovers);
}

/// One client: a connection, the session it cloned, and an arena for replies.
const Client = struct {
    connection: sdk.tcp.Connection = undefined,
    session: []const u8 = "",
    arena_state: std.heap.ArenaAllocator,
    next_id: u32 = 0,

    fn open(client: *Client, address: [4]u8) !void {
        try client.connection.open(address, port, .{ .timeout_ms = 5000 });
        errdefer client.connection.close();
        const reply = try client.call(&.{.{ "op", "clone" }});
        client.session = reply.string("new-session") orelse return error.NoSession;
    }

    fn close(client: *Client) void {
        client.connection.close();
        client.arena_state.deinit();
    }

    fn send(client: *Client, fields: []const [2][]const u8) ![]const u8 {
        client.next_id += 1;
        const id = try std.fmt.allocPrint(client.arena_state.allocator(), "{d}", .{client.next_id});
        var all: [8][2][]const u8 = undefined;
        @memcpy(all[0..fields.len], fields);
        all[fields.len] = .{ "id", id };
        var count = fields.len + 1;
        if (client.session.len > 0) {
            all[count] = .{ "session", client.session };
            count += 1;
        }
        var buffer: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try bencode.request_write(&writer, all[0..count]);
        try client.connection.write_all(writer.buffered());
        return id;
    }

    /// The replies to request `id` until its "done", merged: the last value, the status seen.
    fn collect(client: *Client, id: []const u8) !Reply {
        var reply = Reply{};
        for (0..64) |_| {
            const message = try bencode.read(client.arena_state.allocator(), &client.connection);
            const for_id = message.string("id") orelse continue;
            if (!std.mem.eql(u8, for_id, id)) continue;
            if (message.string("value")) |value| reply.value = value;
            if (message.string("new-session")) |session| reply.new_session = session;
            if (message.status_has("interrupted")) reply.interrupted = true;
            if (message.status_has("done")) {
                reply.done = true;
                return reply;
            }
        }
        return error.NoDone;
    }

    fn call(client: *Client, fields: []const [2][]const u8) !Reply {
        return client.collect(try client.send(fields));
    }
};

const Reply = struct {
    value: ?[]const u8 = null,
    new_session: ?[]const u8 = null,
    interrupted: bool = false,
    done: bool = false,

    fn string(reply: Reply, key: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, key, "new-session")) return reply.new_session;
        if (std.mem.eql(u8, key, "value")) return reply.value;
        return null;
    }
};

fn evaluate_many(context: *System.Context) !void {
    var client = Client{ .arena_state = .init(std.heap.page_allocator) };
    client.open(context.nodes.nrepl.address) catch |err| return unavailable(err);
    defer client.close();
    for (0..evaluations_per_driver) |_| {
        evaluate_once(&client) catch |err| return unavailable(err);
    }
}

fn evaluate_once(client: *Client) !void {
    const a = sdk.random_below(1_000_000);
    const b = sdk.random_below(1_000_000);
    var code_buffer: [64]u8 = undefined;
    const code = try std.fmt.bufPrint(&code_buffer, "(+ {d} {d})", .{ a, b });
    const sum = try client.call(&.{ .{ "op", "eval" }, .{ "code", code } });
    sdk.always(sum.done, "requests finish", .{});
    const value = std.fmt.parseInt(u64, sum.value orelse "", 10) catch std.math.maxInt(u64);
    sdk.always(value == a + b, "evaluations return their value", .{ .a = a, .b = b });
    const last = try client.call(&.{ .{ "op", "eval" }, .{ "code", "*1" } });
    const remembered = std.fmt.parseInt(u64, last.value orelse "", 10) catch std.math.maxInt(u64);
    sdk.always(remembered == a + b, "a session's *1 is its own", .{
        .expected = a + b,
        .got = last.value orelse "",
    });
    sdk.sometimes(true, "an evaluation completed", .{});
}

/// A long evaluation, interrupted a random moment later.
fn interrupt_one(context: *System.Context) !void {
    var client = Client{ .arena_state = .init(std.heap.page_allocator) };
    client.open(context.nodes.nrepl.address) catch |err| return unavailable(err);
    defer client.close();
    const long = "(do (Thread/sleep 3000) :slept)";
    const id = client.send(&.{ .{ "op", "eval" }, .{ "code", long } }) catch |err|
        return unavailable(err);
    sdk.sleep_ms(sdk.random_below_named("interrupt.after_ms", 2000));
    _ = client.send(&.{ .{ "op", "interrupt" }, .{ "interrupt-id", id } }) catch |err|
        return unavailable(err);
    const reply = client.collect(id) catch |err| return unavailable(err);
    sdk.always(reply.done, "requests finish", .{});
    sdk.sometimes(reply.interrupted, "interrupts land", .{});
    sdk.sometimes(!reply.interrupted, "an evaluation finished before its interrupt", .{});
}

/// Faults are over: a new session evaluates again.
fn recovers(context: *System.Context) !void {
    sdk.retry(recovery_attempts_max, 250, evaluates, .{context.nodes.nrepl.address}) catch |err| {
        sdk.assert_unreachable("the server never evaluates again", .{ .err = @errorName(err) });
        return err;
    };
}

fn evaluates(address: [4]u8) !void {
    var client = Client{ .arena_state = .init(std.heap.page_allocator) };
    try client.open(address);
    defer client.close();
    const reply = try client.call(&.{ .{ "op", "eval" }, .{ "code", "(+ 1 1)" } });
    if (!std.mem.eql(u8, reply.value orelse "", "2")) return error.WrongValue;
}

fn unavailable(err: anyerror) !void {
    if (!sdk.tcp.unavailable(err) and err != error.NoDone) return err;
    sdk.sometimes(true, "the server was unavailable to a client", .{ .err = @errorName(err) });
}
