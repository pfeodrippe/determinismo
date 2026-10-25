// SPDX-License-Identifier: MIT
//! Example test program: clojure-cli.repl (github.com/clojure/clojure-cli.repl 0.2.1), the
//! Clojure CLI's REPL. Its server is nREPL with its own middleware: editor evaluations (those
//! that send `file`) are echoed to every terminal that asked to `watch`, with their output;
//! terminals browse results with the inspector; configured middleware adds data to every
//! evaluation's final response. Plain nREPL at the same version runs beside it as the reference
//! for what its middleware should leave unchanged.
//!
//! Scenarios and properties:
//!   editors          an editor evaluation answers as plain nREPL's does
//!                    a watching terminal sees each editor evaluation, through to its end
//!                    middleware data is on every evaluation's final response
//!   paused-terminal  an editor evaluation finishes while a terminal does not read
//!   inspector        a terminal's inspector navigation stays its own
//!   sessions         closed sessions are released
const std = @import("std");
const sdk = @import("determinismo");
const nrepl = @import("nrepl");
const Client = nrepl.Client;
const integer = nrepl.bencode.integer;

const Nodes = struct { cli: sdk.Node, plain: sdk.Node };
const System = sdk.System(Nodes);

const port = 7888;
const evaluations_per_editor = 10;
/// Where editors say their code is from (only echoed: the file need not exist).
const editor_file = "/app/src/editor.clj";

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{
        .editors = editors,
        .@"paused-terminal" = paused_terminal,
        .inspector = inspector,
        .sessions = sessions,
    } });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.cli, .{
        .build = .{ .context = ".", .dockerfile = "examples/clojure-cli-repl/Dockerfile" },
        .ready = .{ .tcp = port },
    });
    default.node(.plain, .{
        .build = .{ .context = ".", .dockerfile = "examples/clojure-cli-repl/Dockerfile.plain" },
        .ready = .{ .tcp = port },
    });
}

// Editors --------------------------------------------------------------------------------

fn editors(s: *System.Scenario) void {
    s.parallel_driver("edit", edit);
    s.eventually("answers", answers);
}

/// One editor, its own terminal watching, and a session on plain nREPL: each evaluation goes to
/// both servers; the terminal must see it through.
fn edit(context: *System.Context) !void {
    const nodes = context.nodes;
    // Ids distinct from other editors': terminals see every editor's evaluations by id.
    const first_id: u32 = @intCast(1 + sdk.random_below(1_000_000) * 1000);
    var editor = Client.init();
    editor.next_id = first_id;
    editor.open(nodes.cli.address, port) catch |err| return unavailable(err);
    defer editor.close();
    var terminal = Client.init();
    terminal.open(nodes.cli.address, port) catch |err| return unavailable(err);
    defer terminal.close();
    _ = terminal.send(&.{.{ "op", "watch" }}) catch |err| return unavailable(err);
    var reference = Client.init();
    reference.open(nodes.plain.address, port) catch |err| return unavailable(err);
    defer reference.close();
    for (0..evaluations_per_editor) |_| {
        var buffer: [256]u8 = undefined;
        const code = try expression(&buffer, editor.next_id + 1);
        const fields = [_][2][]const u8{
            .{ "op", "eval" }, .{ "code", code }, .{ "file", editor_file },
        };
        const id = editor.send(&fields) catch |err| return unavailable(err);
        const answer = editor.collect(id) catch |err| return unavailable(err);
        sdk.always(answer.last.get("probe/evals") != null, "middleware data is on every " ++
            "evaluation's final response", .{ .code = code });
        const expected = reference.call(&fields) catch |err| return unavailable(err);
        compare(code, answer, expected);
        seen_by_terminal(&terminal, id, answer) catch |err| return unavailable(err);
    }
}

/// The terminal's stream for this evaluation: its code echoed, its output, then its end.
fn seen_by_terminal(terminal: *Client, id: []const u8, answer: nrepl.Reply) !void {
    const arena = terminal.allocator();
    var echoed = false;
    var out: std.ArrayList(u8) = .empty;
    for (0..4096) |_| {
        const message = try terminal.read();
        const for_eval = message.string("eval-id") orelse continue;
        if (!std.mem.eql(u8, for_eval, id)) continue;
        if (message.string("code") != null) echoed = true;
        if (message.string("out")) |text| try out.appendSlice(arena, text);
        if (!message.status_has("eval-done")) continue;
        sdk.always(echoed and std.mem.eql(u8, out.items, answer.out), "a watching terminal " ++
            "sees each editor evaluation, through to its end", .{
            .echoed = echoed,
            .terminal_out = out.items,
            .editor_out = answer.out,
        });
        sdk.reachable("a terminal saw an editor evaluation end", .{});
        return;
    }
    return error.NoDone;
}

/// What clojure-cli.repl's middleware should leave as nREPL makes it: the value, the output,
/// whether it failed (error text names generated classes, so not compared), the namespace.
fn compare(code: []const u8, got: nrepl.Reply, expected: nrepl.Reply) void {
    const same = optional_eql(got.value, expected.value) and
        std.mem.eql(u8, got.out, expected.out) and
        got.eval_error == expected.eval_error and optional_eql(got.ex, expected.ex) and
        (got.err.len == 0) == (expected.err.len == 0) and optional_eql(got.ns, expected.ns);
    sdk.always(same, "an editor evaluation answers as plain nREPL's does", .{
        .code = code,
        .value = got.value orelse "",
        .expected_value = expected.value orelse "",
        .out = got.out,
        .expected_out = expected.out,
        .ex = got.ex orelse "",
        .expected_ex = expected.ex orelse "",
    });
}

fn optional_eql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// A random evaluation an editor might send: arithmetic, output to *out* and *err*, an
/// exception, a short sleep, the REPL's history. Tagged, so each is distinct.
fn expression(buffer: []u8, tag: u32) ![]const u8 {
    const a = sdk.random_below(1000);
    const b = sdk.random_below(5); // Sometimes 0: a division fails.
    const forms = [_][]const u8{
        "(+ {d} {d})",
        "(do (println \"line\" {d}) (* {d} 2))",
        "(quot {d} {d})",
        "(do (binding [*out* *err*] (println \"warning\" {d})) {d})",
        "(do (Thread/sleep (mod {d} 40)) [:slept {d}])",
        "(do (dotimes [i (mod {d} 4)] (print i)) {d})",
        "(vector *1 {d} {d})",
    };
    const names = .{ "add", "println", "quot", "err", "sleep", "print", "history" };
    const choice = sdk.decide("form", &names);
    var form_buffer: [128]u8 = undefined;
    const form = switch (choice) {
        inline 0...forms.len - 1 => |index| try std.fmt.bufPrint(
            &form_buffer,
            forms[index],
            .{ a, if (index == 2) b else a },
        ),
        else => unreachable,
    };
    return std.fmt.bufPrint(buffer, "(do :e{d} {s})", .{ tag, form });
}

// A terminal that does not read --------------------------------------------------------------

fn paused_terminal(s: *System.Scenario) void {
    s.singleton_driver("pause", pause);
}

/// A terminal asks to watch and then stops reading (suspended, or its network stalled), while
/// an editor evaluates something that prints. In a quiet period: no fault explains a timeout.
fn pause(context: *System.Context) !void {
    const address = context.nodes.cli.address;
    sdk.stop_faults(120 * std.time.ns_per_s);
    sdk.sleep_ms(100);
    var terminal = Client.init();
    terminal.open(address, port) catch |err| return unavailable(err);
    defer terminal.close();
    _ = try terminal.send(&.{.{ "op", "watch" }});
    var editor = Client.init();
    editor.timeout_ms = 60_000;
    try editor.open(address, port);
    defer editor.close();
    // Lines printed: from a few (fit any socket buffer) to many (fill them).
    const lines = sdk.random_below_named("lines printed", 4000) + 1;
    var buffer: [160]u8 = undefined;
    const code = try std.fmt.bufPrint(&buffer, "(dotimes [_ {d}] (println (apply str (repeat " ++
        "100 \"x\"))))", .{lines});
    const fields = [_][2][]const u8{
        .{ "op", "eval" }, .{ "code", code }, .{ "file", editor_file },
    };
    const finished = if (editor.call(&fields)) |reply| reply.done else |_| false;
    sdk.always(finished, "an editor evaluation finishes while a terminal does not read", .{
        .lines = lines,
    });
    sdk.stop_faults(0);
}

// Inspector ------------------------------------------------------------------------------

fn inspector(s: *System.Scenario) void {
    s.parallel_driver("browse", browse);
}

/// A terminal evaluates a vector, opens the inspector on it and steps into its first item;
/// other terminals do the same meanwhile. Its next look must still be where it stepped.
fn browse(context: *System.Context) !void {
    var terminal = Client.init();
    terminal.open(context.nodes.cli.address, port) catch |err| return unavailable(err);
    defer terminal.close();
    var buffer: [96]u8 = undefined;
    const tag = sdk.random_below(1_000_000);
    const code = try std.fmt.bufPrint(&buffer, "[{{:mine {d}}} 1 2 3]", .{tag});
    _ = terminal.eval(code) catch |err| return unavailable(err);
    const start = [_][2][]const u8{
        .{ "op", "inspect-start" }, .{ "rows", integer(10) }, .{ "cols", integer(80) },
    };
    _ = terminal.call(&start) catch |err| return unavailable(err);
    const step_in = [_][2][]const u8{ .{ "op", "inspect-in" }, .{ "idx", integer(0) } };
    _ = terminal.call(&step_in) catch |err| return unavailable(err);
    sdk.sleep_ms(sdk.random_below_named("pause before looking again (ms)", 50));
    const look = [_][2][]const u8{ .{ "op", "inspect-page" }, .{ "delta", integer(0) } };
    const view = terminal.call(&look) catch |err| return unavailable(err);
    const shown = view.last.string("view") orelse "";
    // Stepped into the first item: the path is "*1 / 0" (the `0` item's label).
    const own = std.mem.indexOf(u8, shown, ":path \"*1 / 0\"") != null;
    sdk.always(own, "a terminal's inspector navigation stays its own", .{ .view = shown });
}

// Sessions -------------------------------------------------------------------------------

fn sessions(s: *System.Scenario) void {
    s.parallel_driver("reconnect", reconnect);
    s.finally("released", released);
}

/// An editor that reconnects: a session, an evaluation (its *1 is kept with the session), close.
fn reconnect(context: *System.Context) !void {
    for (0..5) |_| {
        var editor = Client.init();
        editor.open(context.nodes.cli.address, port) catch |err| return unavailable(err);
        defer editor.close();
        _ = editor.eval("(vec (range 1000))") catch |err| return unavailable(err);
        _ = editor.call(&.{.{ "op", "close" }}) catch |err| return unavailable(err);
    }
}

/// Once editors are gone, the watch middleware keeps no session nREPL closed (each would keep
/// its last results reachable). One an editor lost to a fault without closing it is still
/// open in nREPL too: not counted.
fn released(context: *System.Context) !void {
    var probe = Client.init();
    try probe.open(context.nodes.cli.address, port);
    defer probe.close();
    const kept = "(let [open (set (keys @@(resolve 'nrepl.middleware.session/sessions)))] " ++
        "(count (remove open (keys @clojure-cli.repl.watch/sessions))))";
    const reply = try probe.eval(kept);
    const closed_kept = std.fmt.parseInt(u32, reply.value orelse "", 10) catch {
        sdk.assert_unreachable("the sessions could not be counted", .{
            .value = reply.value orelse "",
            .err = reply.err,
        });
        return;
    };
    sdk.always(closed_kept == 0, "closed sessions are released", .{
        .closed_but_kept = closed_kept,
    });
}

// Common ---------------------------------------------------------------------------------

/// Once faults stop, a new session evaluates again.
fn answers(context: *System.Context) !void {
    sdk.retry(120, 250, evaluates, .{context.nodes.cli.address}) catch |err| {
        sdk.assert_unreachable("the server never evaluates again", .{ .err = @errorName(err) });
        return err;
    };
}

fn evaluates(address: [4]u8) !void {
    var client = Client.init();
    try client.open(address, port);
    defer client.close();
    const reply = try client.eval("(+ 1 1)");
    if (!std.mem.eql(u8, reply.value orelse "", "2")) return error.WrongValue;
}

fn unavailable(err: anyerror) !void {
    if (!nrepl.unavailable(err)) return err;
    sdk.sometimes(true, "a server was unavailable to a client", .{ .err = @errorName(err) });
}
