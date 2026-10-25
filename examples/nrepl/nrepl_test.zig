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
const nrepl = @import("nrepl");
const Client = nrepl.Client;

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

fn evaluate_many(context: *System.Context) !void {
    var client = Client.init();
    client.open(context.nodes.nrepl.address, port) catch |err| return unavailable(err);
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
    var client = Client.init();
    client.open(context.nodes.nrepl.address, port) catch |err| return unavailable(err);
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
    var client = Client.init();
    try client.open(address, port);
    defer client.close();
    const reply = try client.call(&.{ .{ "op", "eval" }, .{ "code", "(+ 1 1)" } });
    if (!std.mem.eql(u8, reply.value orelse "", "2")) return error.WrongValue;
}

fn unavailable(err: anyerror) !void {
    if (!nrepl.unavailable(err)) return err;
    sdk.sometimes(true, "the server was unavailable to a client", .{ .err = @errorName(err) });
}
