// SPDX-License-Identifier: MIT
//! `determinismo runs <command>`: the host's runs from a terminal, through serve's HTTP API
//! (serve.zig), as Antithesis's Snouty CLI works with its runs: for people and agents in a shell.
//!
//!   runs list                                         every run: id, state, system, scenario
//!   runs show <id> [--json]                           its state, progress and summary
//!   runs properties <id> [--details]                  each property's verdict; with --details,
//!                                                     failing ones' first examples (timeline, s)
//!   runs logs <id> <timeline> <seconds> [--window <s>] [--limit <n>]   the timeline's events
//!                                                     leading up to that moment (the last 10 s,
//!                                                     its last 200 lines by default), its
//!                                                     ancestors' included (a tree's timeline
//!                                                     begins inside them)
//!   runs search <id> '<condition>' [--limit <n>] [--count]   (query.zig's conditions)
//!   runs exec <id> <timeline> <seconds> --node <node> '<command>'   a command at that moment
//!                                                     of a replay (--node runner: the runner's)
//!   runs start (--program <path> | --compose <path>) [--scenario s] [--seed n] [--branches n]
//!                                    [--time-budget 2h] [--memory-mib n] [--verify-replays n]
//!   runs stop <id>
//!
//! `--url http://host:port` (or DETERMINISMO_URL): serve's address, http://127.0.0.1:7878 by
//! default. Exit status: 0, 1 when nothing matched (search), 2 for a usage or API error.
const std = @import("std");
const linux = std.os.linux;

const url_default = "http://127.0.0.1:7878";
const response_size_max = 256 << 20;

const Client = struct {
    address: [4]u8,
    port: u16,
    arena: std.mem.Allocator,

    fn init(arena: std.mem.Allocator, url: []const u8) !Client {
        const rest = if (std.mem.startsWith(u8, url, "http://")) url["http://".len..] else url;
        const host_end = std.mem.indexOfScalar(u8, rest, ':') orelse return error.BadUrl;
        const host = rest[0..host_end];
        const port_text = std.mem.trimEnd(u8, rest[host_end + 1 ..], "/");
        var address: [4]u8 = .{ 127, 0, 0, 1 };
        if (!std.mem.eql(u8, host, "localhost")) {
            var parts = std.mem.splitScalar(u8, host, '.');
            for (&address) |*byte| byte.* = try std.fmt.parseInt(u8, parts.next() orelse return error.BadUrl, 10);
        }
        return .{ .address = address, .port = try std.fmt.parseInt(u16, port_text, 10), .arena = arena };
    }

    /// One request (HTTP/1.0, the connection closed after): the body of a 2xx answer, or the
    /// error the API gave (printed).
    fn call(client: *const Client, method: []const u8, path: []const u8, body: ?[]const u8) ![]const u8 {
        const fd_result = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(fd_result) != .SUCCESS) return error.Socket;
        const fd: linux.fd_t = @intCast(fd_result);
        defer _ = linux.close(fd);
        var target = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, client.port), .addr = @bitCast(client.address) };
        if (linux.errno(linux.connect(fd, @ptrCast(&target), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
            std.debug.print("determinismo runs: no serve at {d}.{d}.{d}.{d}:{d} (--url, DETERMINISMO_URL)\n", .{
                client.address[0], client.address[1], client.address[2], client.address[3], client.port,
            });
            return error.NoServe;
        }
        const payload = body orelse "";
        const head = try std.fmt.allocPrint(client.arena, "{s} {s} HTTP/1.0\r\nHost: determinismo\r\n" ++
            "Content-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{ method, path, payload.len });
        try write_all(fd, head);
        try write_all(fd, payload);
        var response: std.ArrayList(u8) = .empty;
        while (response.items.len < response_size_max) {
            try response.ensureUnusedCapacity(client.arena, 1 << 16);
            const free = response.unusedCapacitySlice();
            const read = linux.read(fd, free.ptr, free.len);
            if (linux.errno(read) != .SUCCESS) return error.ReadFailed;
            if (read == 0) break;
            response.items.len += read;
        }
        const text = response.items;
        const header_end = std.mem.indexOf(u8, text, "\r\n\r\n") orelse return error.BadResponse;
        const status_start = (std.mem.indexOfScalar(u8, text, ' ') orelse return error.BadResponse) + 1;
        const status = std.fmt.parseInt(u16, text[status_start..][0..3], 10) catch return error.BadResponse;
        const answer = text[header_end + 4 ..];
        if (status / 100 != 2) {
            std.debug.print("determinismo runs: {s} {s}: {d} {s}\n", .{ method, path, status, answer });
            return error.ApiError;
        }
        return answer;
    }
};

fn write_all(fd: linux.fd_t, bytes: []const u8) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const written = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (linux.errno(written) != .SUCCESS) return error.WriteFailed;
        done += written;
    }
}

pub fn run(arena: std.mem.Allocator, io: std.Io, arguments: []const [:0]const u8) !u8 {
    var url: []const u8 = if (std.c.getenv("DETERMINISMO_URL")) |value| std.mem.span(value) else url_default;
    var words: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        if (std.mem.eql(u8, arguments[index], "--url") and index + 1 < arguments.len) {
            url = arguments[index + 1];
            index += 1;
        } else try words.append(arena, arguments[index]);
    }
    if (words.items.len == 0) return error.Usage;
    const client = try Client.init(arena, url);
    var buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};
    const command = words.items[0];
    const rest = words.items[1..];
    const eql = std.mem.eql;
    if (eql(u8, command, "list")) return list(&client, out);
    if (eql(u8, command, "show")) return show(&client, out, rest);
    if (eql(u8, command, "properties")) return properties(&client, out, rest);
    if (eql(u8, command, "logs")) return logs(&client, out, rest);
    if (eql(u8, command, "search")) return search(&client, out, rest);
    if (eql(u8, command, "exec")) return exec(&client, out, rest);
    if (eql(u8, command, "start")) return start(&client, out, rest);
    if (eql(u8, command, "stop")) return stop(&client, out, rest);
    return error.Usage;
}

fn parse(client: *const Client, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, client.arena, text, .{});
}

fn field(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

fn string(value: ?std.json.Value) []const u8 {
    const known = value orelse return "";
    return switch (known) {
        .string => |text| text,
        else => "",
    };
}

fn integer(value: ?std.json.Value) u64 {
    const known = value orelse return 0;
    return switch (known) {
        .integer => |number| @intCast(@max(0, number)),
        .float => |number| @intFromFloat(@max(0, number)),
        // Past i64 (a seed): std.json keeps the digits.
        .number_string => |digits| std.fmt.parseInt(u64, digits, 10) catch 0,
        else => 0,
    };
}

fn run_id(rest: []const []const u8) !u32 {
    if (rest.len == 0) return error.Usage;
    return std.fmt.parseInt(u32, rest[0], 10);
}

/// "12.5" seconds of virtual time, in nanoseconds.
fn seconds_ns(text: []const u8) !u64 {
    const seconds = try std.fmt.parseFloat(f64, text);
    if (seconds < 0) return error.Usage;
    return @intFromFloat(seconds * std.time.ns_per_s);
}

fn list(client: *const Client, out: *std.Io.Writer) !u8 {
    const runs = try parse(client, try client.call("GET", "/runs", null));
    if (runs != .array) return error.BadResponse;
    try out.print("{s:>5}  {s:<12} {s:<40} {s}\n", .{ "id", "state", "system", "scenario" });
    for (runs.array.items) |entry| {
        try out.print("{d:>5}  {s:<12} {s:<40} {s}\n", .{
            integer(field(entry, "id")),    string(field(entry, "state")),
            string(field(entry, "system")), string(field(entry, "scenario")),
        });
    }
    return 0;
}

fn show(client: *const Client, out: *std.Io.Writer, rest: []const []const u8) !u8 {
    const id = try run_id(rest);
    const text = try client.call("GET", try std.fmt.allocPrint(client.arena, "/runs/{d}", .{id}), null);
    if (rest.len > 1 and std.mem.eql(u8, rest[1], "--json")) {
        try out.print("{s}\n", .{text});
        return 0;
    }
    const value = try parse(client, text);
    const asked = field(value, "run") orelse std.json.Value{ .null = {} };
    try out.print("run {d}: {s}", .{ id, string(field(value, "state")) });
    if (field(value, "status")) |status| if (status == .integer) try out.print(" (status {d})", .{status.integer});
    try out.print("\nscenario {s}", .{string(field(asked, "scenario"))});
    // The record's seed: 16 hex digits.
    if (std.fmt.parseInt(u64, string(field(asked, "seed")), 16)) |seed| {
        try out.print(", seed {d}", .{seed});
    } else |_| {}
    try out.writeByte('\n');
    if (field(value, "progress")) |progress| {
        const running = field(progress, "running");
        try out.print("timelines: {d} done, {d} failing, {d} running, generation {d}\n", .{
            integer(field(progress, "done")),
            integer(field(progress, "failing")),
            if (running) |known| (if (known == .array) known.array.items.len else 0) else 0,
            integer(field(progress, "generation")),
        });
    }
    if (field(value, "stats")) |stats| {
        try out.print("stats: {d} timelines, {d} failing, {d} behaviors, {d} events\n", .{
            integer(field(stats, "timelines")), integer(field(stats, "failing_timelines")),
            integer(field(stats, "behaviors")), integer(field(stats, "events")),
        });
    }
    return 0;
}

const Property = struct {
    type: []const u8 = "",
    message: []const u8 = "",
    status: []const u8 = "",
    timelines_hit: u64 = 0,
    timelines_failing: u64 = 0,
    location: ?[]const u8 = null,
};

fn properties(client: *const Client, out: *std.Io.Writer, rest: []const []const u8) !u8 {
    const id = try run_id(rest);
    const details = rest.len > 1 and std.mem.eql(u8, rest[1], "--details");
    const text = try client.call("GET", try std.fmt.allocPrint(client.arena, "/runs/{d}/properties", .{id}), null);
    const all = try std.json.parseFromSliceLeaky([]const Property, client.arena, text, .{ .ignore_unknown_fields = true });
    // The failing first, as the UI lists them.
    for ([_]bool{ true, false }) |failing_pass| for (all) |property| {
        const failing = std.mem.eql(u8, property.status, "failing");
        if (failing != failing_pass) continue;
        const verdict = if (failing) "FAIL" else if (std.mem.eql(u8, property.status, "passing")) "PASS" else "----";
        try out.print("{s} {s:<22} hit {d:>5}, failing {d:>5}  {s}", .{
            verdict, property.type, property.timelines_hit, property.timelines_failing, property.message,
        });
        if (property.location) |location| try out.print("  ({s})", .{location});
        try out.writeByte('\n');
        if (!details or !failing) continue;
        try examples(client, out, id, &property);
    };
    return 0;
}

/// A failing property's first failing evaluations: timeline, moment and details.
fn examples(client: *const Client, out: *std.Io.Writer, id: u32, property: *const Property) !void {
    const quoted = try quote(client.arena, property.message);
    const condition = if (std.mem.eql(u8, property.type, "unreachable"))
        try std.fmt.allocPrint(client.arena, "assert.message={s} assert.condition=true or " ++
            "antithesis_assert.message={s} antithesis_assert.hit=true", .{ quoted, quoted })
    else
        try std.fmt.allocPrint(client.arena, "assert.message={s} assert.condition=false or " ++
            "antithesis_assert.message={s} antithesis_assert.hit=true antithesis_assert.condition=false", .{ quoted, quoted });
    const body = try std.fmt.allocPrint(client.arena, "{f}", .{std.json.fmt(.{ .condition = condition, .limit = 3 }, .{})});
    const text = client.call("POST", try std.fmt.allocPrint(client.arena, "/runs/{d}/query", .{id}), body) catch return;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const event = parse(client, line) catch continue;
        const at_ns = integer(field(event, "vtime_ns"));
        const assertion = field(field(event, "event") orelse continue, "assert") orelse
            field(field(event, "event") orelse continue, "antithesis_assert") orelse continue;
        const shown = if (field(assertion, "details")) |known|
            try std.fmt.allocPrint(client.arena, "{f}", .{std.json.fmt(known, .{})})
        else
            "";
        try out.print("     timeline {d} at {d}.{d:0>3}s  {s}\n", .{
            integer(field(event, "branch")),                at_ns / std.time.ns_per_s,
            at_ns % std.time.ns_per_s / std.time.ns_per_ms, shown[0..@min(shown.len, 300)],
        });
    }
}

/// A query condition's string (query.zig): in double quotes, backslashes and quotes escaped.
fn quote(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var quoted: std.ArrayList(u8) = .empty;
    try quoted.append(arena, '"');
    for (text) |byte| {
        if (byte == '"' or byte == '\\') try quoted.append(arena, '\\');
        try quoted.append(arena, byte);
    }
    try quoted.append(arena, '"');
    return quoted.items;
}

test quote {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("\"a \\\"b\\\" \\\\c\"", try quote(arena_state.allocator(), "a \"b\" \\c"));
}

fn limit_of(rest: []const []const u8, default: u32) !u32 {
    for (rest, 0..) |word, at| {
        if (std.mem.eql(u8, word, "--limit") and at + 1 < rest.len) return std.fmt.parseInt(u32, rest[at + 1], 10);
    }
    return default;
}

fn has(rest: []const []const u8, flag: []const u8) bool {
    for (rest) |word| if (std.mem.eql(u8, word, flag)) return true;
    return false;
}

fn logs(client: *const Client, out: *std.Io.Writer, rest: []const []const u8) !u8 {
    if (rest.len < 3) return error.Usage;
    const id = try run_id(rest);
    const timeline = try std.fmt.parseInt(u32, rest[1], 10);
    const up_to_ns = try seconds_ns(rest[2]);
    const limit = try limit_of(rest[3..], 200);
    const window_ns = if (value_of(rest[3..], "--window")) |text| try seconds_ns(text) else 10 * std.time.ns_per_s;
    const up_to = @as(f64, @floatFromInt(up_to_ns)) / std.time.ns_per_s;
    const from = @as(f64, @floatFromInt(up_to_ns -| window_ns)) / std.time.ns_per_s;
    const body = try std.fmt.allocPrint(client.arena, "{f}", .{std.json.fmt(.{
        .condition = try std.fmt.allocPrint(client.arena, "vtime>={d:.6}", .{from}),
        .branch = timeline,
        .up_to_vtime = up_to,
        .limit = 1_000_000,
    }, .{})});
    const text = try client.call("POST", try std.fmt.allocPrint(client.arena, "/runs/{d}/query", .{id}), body);
    // The window's last `limit` lines: what led up to the moment.
    var starts: std.ArrayList(usize) = .empty;
    var at: usize = 0;
    while (at < text.len) {
        try starts.append(client.arena, at);
        at = (std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len) + 1;
    }
    const first = starts.items.len -| limit;
    try events_print(client, out, if (first < starts.items.len) text[starts.items[first]..] else "");
    return 0;
}

fn value_of(rest: []const []const u8, flag: []const u8) ?[]const u8 {
    for (rest, 0..) |word, at| {
        if (std.mem.eql(u8, word, flag) and at + 1 < rest.len) return rest[at + 1];
    }
    return null;
}

/// Query answers (JSON lines), one event a line: its moment, then output as text, the rest as
/// JSON.
fn events_print(client: *const Client, out: *std.Io.Writer, text: []const u8) !void {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const value = parse(client, line) catch continue;
        const at_ns = integer(field(value, "vtime_ns"));
        try out.print("{d:>5}.{d:0>3}s [{d}] ", .{
            at_ns / std.time.ns_per_s, at_ns % std.time.ns_per_s / std.time.ns_per_ms, integer(field(value, "branch")),
        });
        const event = field(value, "event") orelse {
            try out.print("{s}\n", .{line});
            continue;
        };
        if (field(event, "output")) |output| {
            try out.print("{s} {s}: {s}\n", .{ string(field(output, "source")), string(field(output, "stream")), string(field(output, "text")) });
        } else try out.print("{f}\n", .{std.json.fmt(event, .{})});
    }
}

fn search(client: *const Client, out: *std.Io.Writer, rest: []const []const u8) !u8 {
    if (rest.len < 2) return error.Usage;
    const id = try run_id(rest);
    const count = has(rest[2..], "--count");
    const limit = try limit_of(rest[2..], 50);
    const body = try std.fmt.allocPrint(client.arena, "{f}", .{std.json.fmt(.{
        .condition = rest[1],
        .limit = limit,
        .output = if (count) "count" else "events",
    }, .{})});
    const text = try client.call("POST", try std.fmt.allocPrint(client.arena, "/runs/{d}/query", .{id}), body);
    if (count) {
        try out.print("{s}", .{text});
        return 0;
    }
    try events_print(client, out, text);
    return if (std.mem.trim(u8, text, " \n").len == 0) 1 else 0;
}

fn exec(client: *const Client, out: *std.Io.Writer, rest: []const []const u8) !u8 {
    if (rest.len < 4) return error.Usage;
    const id = try run_id(rest);
    const timeline = try std.fmt.parseInt(u32, rest[1], 10);
    const at_ns = try seconds_ns(rest[2]);
    var node: []const u8 = "runner";
    var command: ?[]const u8 = null;
    var index: usize = 3;
    while (index < rest.len) : (index += 1) {
        if (std.mem.eql(u8, rest[index], "--node") and index + 1 < rest.len) {
            node = rest[index + 1];
            index += 1;
        } else command = rest[index];
    }
    const asked = command orelse return error.Usage;
    // In a node as docker exec runs it; the runner's directly.
    const shell = if (std.mem.eql(u8, node, "runner"))
        asked
    else
        try std.fmt.allocPrint(client.arena, "det-nodes exec {s} sh -c {s}", .{ node, try shell_quote(client.arena, asked) });
    const body = try std.fmt.allocPrint(client.arena, "{f}", .{std.json.fmt(.{
        .branch = timeline,
        .at_vtime_ms = at_ns / std.time.ns_per_ms,
        .exec = shell,
    }, .{})});
    const text = try client.call("POST", try std.fmt.allocPrint(client.arena, "/runs/{d}/replay", .{id}), body);
    // The replay's output: what the command printed (exec_output events), in order.
    var printed = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, "{\"event\":\"exec_output\"") orelse continue;
        const value = parse(client, line[at..]) catch continue;
        try out.print("{s}", .{string(field(field(value, "details") orelse continue, "text"))});
        printed = true;
    }
    if (!printed) try out.print("(no output; the replay said:)\n{s}\n", .{text[text.len -| 4000..]});
    return 0;
}

/// `text` as one shell word, in single quotes.
fn shell_quote(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var quoted: std.ArrayList(u8) = .empty;
    try quoted.append(arena, '\'');
    for (text) |byte| {
        if (byte == '\'') try quoted.appendSlice(arena, "'\\''") else try quoted.append(arena, byte);
    }
    try quoted.append(arena, '\'');
    return quoted.items;
}

test shell_quote {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("'it'\\''s'", try shell_quote(arena_state.allocator(), "it's"));
}

fn start(client: *const Client, out: *std.Io.Writer, rest: []const []const u8) !u8 {
    var request: std.json.ObjectMap = .empty;
    var index: usize = 0;
    while (index + 1 < rest.len) : (index += 2) {
        const flag = rest[index];
        const value = rest[index + 1];
        const eql = std.mem.eql;
        if (eql(u8, flag, "--program")) {
            try request.put(client.arena, "program", .{ .string = value });
        } else if (eql(u8, flag, "--compose")) {
            try request.put(client.arena, "compose", .{ .string = value });
        } else if (eql(u8, flag, "--scenario")) {
            try request.put(client.arena, "scenario", .{ .string = value });
        } else if (eql(u8, flag, "--profile")) {
            try request.put(client.arena, "profile", .{ .string = value });
        } else if (eql(u8, flag, "--time-budget")) {
            try request.put(client.arena, "time_budget", .{ .string = value });
        } else if (eql(u8, flag, "--seed") or eql(u8, flag, "--branches") or eql(u8, flag, "--memory-mib") or
            eql(u8, flag, "--verify-replays"))
        {
            const name = try std.mem.replaceOwned(u8, client.arena, flag[2..], "-", "_");
            try request.put(client.arena, name, .{ .integer = try std.fmt.parseInt(i64, value, 10) });
        } else return error.Usage;
    }
    if (index != rest.len) return error.Usage;
    if (request.get("program") == null and request.get("compose") == null) return error.Usage;
    const body = try std.fmt.allocPrint(client.arena, "{f}", .{std.json.fmt(std.json.Value{ .object = request }, .{})});
    const text = try client.call("POST", "/runs", body);
    try out.print("{s}", .{text});
    return 0;
}

fn stop(client: *const Client, out: *std.Io.Writer, rest: []const []const u8) !u8 {
    const id = try run_id(rest);
    const text = try client.call("POST", try std.fmt.allocPrint(client.arena, "/runs/{d}/stop", .{id}), "");
    try out.print("{s}", .{text});
    return 0;
}
