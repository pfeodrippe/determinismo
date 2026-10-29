// SPDX-License-Identifier: MIT
//! Example test program: nREPL, the protocol every Clojure editor speaks, under concurrent clients
//! and faults: nrepl/nrepl 1.8.0 (server/deps.edn, profile default) and jank 0.1's own server
//! (Dockerfile.jank, profile jank, scenario jank: it has no interrupt). Clients talk bencode
//! over TCP (bencode.zig).
//!
//! Properties:
//!   evaluations return their value   `(+ a b)` answers a + b, whatever else runs
//!   a session's *1 is its own        right after `(+ a b)`, `*1` in that session is a + b,
//!                                    while other sessions evaluate concurrently
//!   requests finish                  every request that gets an answer ends with "done", and
//!                                    nothing answers it after (client.zig)
//!   errors are answered              an evaluation that throws answers its error, and its
//!                                    session evaluates on
//!   definitions are shared           a var defined in one session is that value in another,
//!                                    and completes and looks up there
//!   a session keeps its namespace    after `(in-ns 'x)`, the session's next evaluation is in x
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
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .sessions = sessions, .jank = jank },
    });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.nrepl, .{
        .build = .{ .context = ".", .dockerfile = "examples/nrepl/Dockerfile" },
        .ready = .{ .tcp = port },
    });
    const jank_server = try d.profile("jank");
    jank_server.node(.nrepl, .{
        .build = .{ .context = ".", .dockerfile = "examples/nrepl/Dockerfile.jank" },
        .ready = .{ .tcp = port },
    });
}

fn sessions(s: *System.Scenario) void {
    jank(s);
    s.parallel_driver("interrupt", interrupt_one);
}

/// What every nREPL server does (jank's has no interrupt).
fn jank(s: *System.Scenario) void {
    s.parallel_driver("evaluate", evaluate_many);
    s.parallel_driver("fail", fail_one);
    s.parallel_driver("define", define_one);
    s.parallel_driver("namespace", namespace_one);
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

/// Forms that throw in Clojure, each its own way: unresolved, thrown, out of range, of the wrong
/// type, unread, divided by zero, deep. The last two kill jank 0.1's whole server (README.md):
/// its timelines draw from the others, or every one would end there.
const failing = [_][]const u8{
    "undefined-here",
    "(throw (ex-info \"thrown\" {:n 1}))",
    "(nth [1 2] 5)",
    "(+ 1 :a)",
    "(first 1)",
    "(+ 1 2",
    "(quot 1 0)",
    "(/ 1 0)",
    "((fn deep [n] (if (zero? n) 0 (inc (deep (dec n))))) 10000000)",
};
const failing_jank = failing[0 .. failing.len - 2];

/// An evaluation that throws: its error answered, then its session evaluates on.
fn fail_one(context: *System.Context) !void {
    var client = Client.init();
    client.open(context.nodes.nrepl.address, port) catch |err| return unavailable(err);
    defer client.close();
    const forms: []const []const u8 = if (std.mem.eql(u8, context.profile, "jank")) failing_jank else &failing;
    const form = forms[sdk.random_below_named("fail.form", forms.len)];
    const failed = client.eval(form) catch |err| return unavailable(err);
    sdk.always(failed.done, "requests finish", .{});
    sdk.always(failed.value == null and (failed.eval_error or failed.err.len > 0 or failed.ex != null), "errors are answered", .{
        .form = form,
        .value = failed.value orelse "",
    });
    evaluate_once(&client) catch |err| return unavailable(err);
    sdk.sometimes(true, "a session evaluated on after an error", .{ .form = form });
}

/// A var defined in one session, a value or a function returning it (compiled while other
/// sessions call the ones before: jank's JIT on their threads): another session reads its value,
/// completes and looks it up.
fn define_one(context: *System.Context) !void {
    var definer = Client.init();
    definer.open(context.nodes.nrepl.address, port) catch |err| return unavailable(err);
    defer definer.close();
    var reader = Client.init();
    reader.open(context.nodes.nrepl.address, port) catch |err| return unavailable(err);
    defer reader.close();
    const n = sdk.random_below(1_000_000);
    const function = sdk.random_below_named("define.function", 2) == 1;
    var name_buffer: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "shared-{s}{d}", .{
        if (function) "fn-" else "",
        sdk.random_below(64),
    });
    var code_buffer: [96]u8 = undefined;
    const code = if (function)
        try std.fmt.bufPrint(&code_buffer, "(defn {s} [] {d})", .{ name, n })
    else
        try std.fmt.bufPrint(&code_buffer, "(def {s} {d})", .{ name, n });
    const defined = definer.eval(code) catch |err| return unavailable(err);
    sdk.always(defined.done, "requests finish", .{});
    if (defined.value == null) return; // Defined concurrently with another of its name: either.
    var call_buffer: [48]u8 = undefined;
    const call = if (function) try std.fmt.bufPrint(&call_buffer, "({s})", .{name}) else name;
    const read = reader.eval(call) catch |err| return unavailable(err);
    const value = std.fmt.parseInt(u64, read.value orelse "", 10) catch std.math.maxInt(u64);
    // Another driver may define the same name between the two: then a number all the same.
    sdk.always(value != std.math.maxInt(u64), "definitions are shared", .{
        .name = name,
        .defined = n,
        .read = read.value orelse "",
    });
    sdk.sometimes(value == n, "a definition was read in another session", .{ .function = function });
    // In `user`, as editors name it (jank's server knows no namespace without: README.md).
    const completions = reader.call(&.{ .{ "op", "completions" }, .{ "prefix", name }, .{ "ns", "user" } }) catch |err|
        return unavailable(err);
    sdk.always(completions.done and completions_have(completions.last, name), "a definition completes in another session", .{
        .name = name,
    });
    const lookup = reader.call(&.{ .{ "op", "lookup" }, .{ "sym", name }, .{ "ns", "user" } }) catch |err|
        return unavailable(err);
    const info = lookup.last.get("info");
    sdk.always(lookup.done and info != null and info.?.string("name") != null, "a definition looks up in another session", .{
        .name = name,
    });
}

/// A session that moved to another namespace evaluates there next (nREPL's sessions keep their
/// *ns*, as *1).
fn namespace_one(context: *System.Context) !void {
    var client = Client.init();
    client.open(context.nodes.nrepl.address, port) catch |err| return unavailable(err);
    defer client.close();
    var name_buffer: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "session-{d}", .{sdk.random_below(64)});
    var code_buffer: [64]u8 = undefined;
    const code = try std.fmt.bufPrint(&code_buffer, "(in-ns '{s})", .{name});
    const moved = client.eval(code) catch |err| return unavailable(err);
    sdk.always(moved.done, "requests finish", .{});
    const next = client.eval("1") catch |err| return unavailable(err);
    sdk.always(std.mem.eql(u8, next.ns orelse "", name), "a session keeps its namespace", .{
        .name = name,
        .ns = next.ns orelse "",
    });
}

/// Whether a `completions` reply lists `name` as a candidate.
fn completions_have(reply: nrepl.bencode.Value, name: []const u8) bool {
    const candidates = reply.get("completions") orelse return false;
    if (candidates != .list) return false;
    for (candidates.list) |candidate| {
        const text = candidate.string("candidate") orelse continue;
        if (std.mem.endsWith(u8, text, name)) return true;
    }
    return false;
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
