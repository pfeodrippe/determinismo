// SPDX-License-Identifier: MIT
//! `determinismo mcp`: a Model Context Protocol server over stdio (JSON-RPC 2.0, one message
//! per line), so agents can describe systems, explore them, replay branches and debug them at
//! exact moments. Each tool runs this executable (`explore ... --record`) and returns what it
//! found; the machine options given to `mcp` apply to every run.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const query = @import("query.zig");
const serve_api = @import("serve.zig");
const event_sets = @import("event_sets.zig");
const store = @import("store.zig");
const duckdb = @import("duckdb.zig");

pub const Options = struct {
    machine: []const []const u8,
    self: []const u8,
    scratch_directory: []const u8,
};

const protocol_version = "2025-03-26";
const line_size_max = 1 << 20;
const result_size_max = 4 << 20;

/// The tools, as MCP lists them (name, description, JSON schema of the arguments).
const tools_json = @embedFile("mcp_tools.json");

const Arguments = struct {
    /// The system: a test program or a Compose file.
    program: ?[]const u8 = null,
    compose: ?[]const u8 = null,
    kubernetes: ?[]const u8 = null,
    scenario: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    seed: u64 = 0,
    /// Null: explore's default (on).
    cpu_modulation: ?bool = null,
    branches: ?u32 = null,
    time_budget: ?[]const u8 = null,
    /// How long each timeline's drivers run (virtual time); replays need the same.
    timeline: ?[]const u8 = null,
    /// A tree's timelines per generation (explore's --generation).
    generation: ?u32 = null,
    branch: ?u32 = null,
    /// Replays a timeline from its tape (an exploration's tape_dir/branch-<n>.jsonl): the way
    /// to replay a tree exploration's timeline past its first generation.
    tape: ?[]const u8 = null,
    at_vtime_ms: ?u64 = null,
    exec: ?[]const u8 = null,
    /// replay: a branch grown from the moment step by step (serve's replay steps).
    steps: []const serve_api.ReplayRequest.Step = &.{},
    @"continue": bool = false,
    /// replay: a fresh future from the moment (explore's --fresh-seed).
    fresh_seed: ?u64 = null,
    from_branch: ?u32 = null,
    from_vtime_ms: ?u64 = null,
    until: ?[]const u8 = null,
    rewind_ms: ?u64 = null,
    property: ?[]const u8 = null,
    points: u32 = 8,
    futures: u32 = 16,
    /// explore: a targeted run, aimed at a diff file's or git range's changed lines.
    changed: ?[]const u8 = null,
    /// explore: where the range is (a repository's directory or URL).
    changed_repository: ?[]const u8 = null,
    /// explore: output lines with these texts are left out of its events (replays write them).
    retroactive: []const []const u8 = &.{},
    /// mutate: a JSON lines file of mutants, {"name", "node", "patch"} each.
    mutants: ?[]const u8 = null,
};

pub fn serve(arena_parent: std.mem.Allocator, io: std.Io, options: Options) !void {
    const line = try arena_parent.alloc(u8, line_size_max);
    var reader_buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &reader_buffer);
    try std.Io.Dir.cwd().createDirPath(io, options.scratch_directory);
    while (true) {
        const message = read_line(&reader.interface, line) orelse return;
        var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena_state.deinit();
        handle(arena_state.allocator(), io, options, message) catch |err| {
            std.debug.print("[determinismo mcp] {s}\n", .{@errorName(err)});
        };
    }
}

fn handle(arena: std.mem.Allocator, io: std.Io, options: Options, message: []const u8) !void {
    const request = try std.json.parseFromSliceLeaky(std.json.Value, arena, message, .{});
    if (request != .object) return;
    const method = (request.object.get("method") orelse return).string;
    const id = request.object.get("id") orelse return; // A notification: nothing to answer.
    const eql = std.mem.eql;
    if (eql(u8, method, "initialize")) {
        return respond(arena, id, "{\"protocolVersion\":\"" ++ protocol_version ++ "\"," ++
            "\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"determinismo\"," ++
            "\"version\":\"0.1.0\"}}");
    }
    if (eql(u8, method, "ping")) return respond(arena, id, "{}");
    if (eql(u8, method, "tools/list")) {
        // One message per line: the file's newlines (it is kept readable) become spaces.
        const flat = try std.mem.replaceOwned(u8, arena, tools_json, "\n", " ");
        const tools = try std.fmt.allocPrint(arena, "{{\"tools\":{s}}}", .{flat});
        return respond(arena, id, tools);
    }
    if (eql(u8, method, "tools/call")) {
        const params = (request.object.get("params") orelse return error.BadRequest).object;
        const name = (params.get("name") orelse return error.BadRequest).string;
        const call_arguments = params.get("arguments") orelse return error.BadRequest;
        var detail: ?[]const u8 = null;
        const text = tool_call(arena, io, options, name, call_arguments, &detail) catch |err| {
            const said = detail orelse @errorName(err);
            const failure = try std.fmt.allocPrint(arena, "error: {s}", .{said});
            return respond_text(arena, id, failure, true);
        };
        return respond_text(arena, id, text, false);
    }
    try write_line(try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{f}," ++
        "\"error\":{{\"code\":-32601,\"message\":\"unknown method\"}}}}", .{
        std.json.fmt(id, .{}),
    }));
}

fn events_answer(
    arena: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    value: std.json.Value,
    connection: *duckdb.Connection,
    out: *std.Io.Writer,
) !void {
    const eql = std.mem.eql;
    const options_json: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    if (eql(u8, name, "query")) {
        const asked = try std.json.parseFromValueLeaky(query.Request, arena, value, options_json);
        const search = try query.query_of(arena, asked);
        _ = try query.answer(connection, arena, &search, out, true);
    } else if (eql(u8, name, "events")) {
        const Asked = event_sets.Request;
        const asked = try std.json.parseFromValueLeaky(Asked, arena, value, options_json);
        try event_sets.request_answer(connection, arena, io, asked, out);
    } else {
        const Asked = struct { sql: []const u8 };
        const asked = try std.json.parseFromValueLeaky(Asked, arena, value, options_json);
        const sql = try arena.dupeSentinel(u8, asked.sql, 0);
        const more = try connection.select_json(out, sql, sql_rows_max);
        const cut = "\n(only the first {d} rows: add a LIMIT, or aggregate)";
        if (more) try out.print(cut, .{sql_rows_max});
    }
}

/// Rows the sql tool answers with at most.
const sql_rows_max = 10_000;

fn tool_call(
    arena: std.mem.Allocator,
    io: std.Io,
    options: Options,
    name: []const u8,
    value: std.json.Value,
    failure: *?[]const u8,
) ![]const u8 {
    const eql = std.mem.eql;
    // On an exploration's events database (its events_dir): a search, an event set, or SQL.
    if (eql(u8, name, "query") or eql(u8, name, "events") or eql(u8, name, "sql")) {
        const options_json: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
        const Where = struct { events_dir: []const u8 };
        const where = try std.json.parseFromValueLeaky(Where, arena, value, options_json);
        const opened = try store.open_for_command(arena, io, where.events_dir);
        defer opened.close();
        var out: std.Io.Writer.Allocating = .init(arena);
        events_answer(arena, io, name, value, &opened.connection, &out.writer) catch |err| {
            if (err == error.DuckDB) failure.* = opened.connection.failure.text();
            return err;
        };
        return out.written();
    }
    const arguments = try std.json.parseFromValueLeaky(Arguments, arena, value, .{
        .ignore_unknown_fields = true,
    });
    if (eql(u8, name, "describe")) {
        const program = arguments.program orelse return error.MissingProgram;
        const describe = [_][]const u8{ program, "--describe" };
        const result = try std.process.run(arena, io, .{ .argv = &describe });
        return result.stdout;
    }
    var argv: std.ArrayList([]const u8) = .empty;
    const command = if (eql(u8, name, "causality"))
        "causality"
    else if (eql(u8, name, "mutate")) "mutate" else "explore";
    try argv.appendSlice(arena, &.{ options.self, command });
    try argv.appendSlice(arena, options.machine);
    const sources = @as(u32, @intFromBool(arguments.program != null)) +
        @intFromBool(arguments.compose != null) + @intFromBool(arguments.kubernetes != null);
    if (sources != 1) return error.ProgramOrCompose;
    if (arguments.program) |program| try argv.appendSlice(arena, &.{ "--program", program });
    if (arguments.compose) |compose| try argv.appendSlice(arena, &.{ "--compose", compose });
    if (arguments.kubernetes) |manifests| try argv.appendSlice(arena, &.{ "--kubernetes", manifests });
    try argv.appendSlice(arena, &.{ "--seed", try number(arena, arguments.seed) });
    if (arguments.cpu_modulation) |on| try argv.append(arena, if (on) "--cpu-modulation" else "--no-cpu-modulation");
    if (arguments.scenario) |scenario| try argv.appendSlice(arena, &.{ "--scenario", scenario });
    if (arguments.profile) |profile| try argv.appendSlice(arena, &.{ "--profile", profile });
    if (arguments.timeline) |length| try argv.appendSlice(arena, &.{ "--timeline", length });
    if (eql(u8, name, "replay")) {
        if (arguments.tape) |tape| {
            try argv.appendSlice(arena, &.{ "--tape", tape });
        } else {
            const branch = arguments.branch orelse return error.MissingBranch;
            try argv.appendSlice(arena, &.{ "--branch", try number(arena, branch) });
        }
        if (arguments.at_vtime_ms) |ms| {
            try argv.appendSlice(arena, &.{ "--at-vtime-ms", try number(arena, ms) });
        }
        if (arguments.until) |condition| {
            try argv.appendSlice(arena, &.{ "--until", condition });
            if (arguments.rewind_ms) |ms| {
                try argv.appendSlice(arena, &.{ "--rewind-ms", try number(arena, ms) });
            }
        }
        var script_path: ?[]const u8 = null;
        if (arguments.at_vtime_ms != null or arguments.until != null) {
            if (arguments.exec) |exec| try argv.appendSlice(arena, &.{ "--exec", exec });
            if (arguments.steps.len > 0) {
                if (arguments.exec != null) return error.ExecOrSteps;
                var unique: u64 = 0;
                std.Io.random(io, std.mem.asBytes(&unique));
                const path = try std.fmt.allocPrint(arena, "/tmp/determinismo-steps-{x:0>16}.txt", .{unique});
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try serve_api.steps_script(arena, arguments.steps) });
                try argv.appendSlice(arena, &.{ "--exec-script", path });
                script_path = path;
            }
            if (arguments.@"continue") try argv.append(arena, "--continue");
            if (arguments.fresh_seed) |seed| {
                try argv.appendSlice(arena, &.{ "--fresh-seed", try std.fmt.allocPrint(arena, "{d}", .{seed}) });
            }
        }
        defer if (script_path) |path| std.Io.Dir.cwd().deleteFile(io, path) catch {};
        const result = try std.process.run(arena, io, .{ .argv = argv.items });
        return guest_lines(arena, result.stderr);
    }
    if (eql(u8, name, "causality")) {
        const branch = arguments.branch orelse return error.MissingBranch;
        const property = arguments.property orelse return error.MissingProperty;
        const branch_text = try number(arena, branch);
        const points = try number(arena, arguments.points);
        const futures = try number(arena, arguments.futures);
        try argv.appendSlice(arena, &.{ "--branch", branch_text, "--property", property });
        try argv.appendSlice(arena, &.{ "--points", points, "--futures", futures, "--json" });
        const result = try std.process.run(arena, io, .{ .argv = argv.items });
        return result.stdout;
    }
    const known = eql(u8, name, "explore") or eql(u8, name, "fork") or eql(u8, name, "mutate");
    if (!known) return error.UnknownTool;
    if (arguments.time_budget) |budget| try argv.appendSlice(arena, &.{ "--time-budget", budget });
    if (arguments.generation) |size| {
        try argv.appendSlice(arena, &.{ "--generation", try number(arena, size) });
    }
    if (arguments.changed) |source| try argv.appendSlice(arena, &.{ "--changed", source });
    if (arguments.changed_repository) |where| {
        try argv.appendSlice(arena, &.{ "--changed-repository", where });
    }
    for (arguments.retroactive) |text| try argv.appendSlice(arena, &.{ "--retroactive", text });
    if (arguments.branches != null or arguments.time_budget == null) {
        const branches = try number(arena, arguments.branches orelse 16);
        try argv.appendSlice(arena, &.{ "--branches", branches });
    }
    if (eql(u8, name, "mutate")) {
        const mutants = arguments.mutants orelse return error.MissingMutants;
        explorations += 1;
        const out = try std.fmt.allocPrint(arena, "{s}/mutation-{d}-{d}", .{
            options.scratch_directory, linux.getpid(), explorations,
        });
        try argv.appendSlice(arena, &.{ "--mutants", mutants, "--out", out });
        const result = try std.process.run(arena, io, .{ .argv = argv.items });
        // Each mutant's exploration (events, record) is under out, for the query tool.
        return std.fmt.allocPrint(arena, "{s}{{\"out\":{f}}}\n", .{
            result.stdout, std.json.fmt(out, .{}),
        });
    }
    if (eql(u8, name, "fork")) {
        const branch = arguments.from_branch orelse return error.MissingBranch;
        const vtime_ms = arguments.from_vtime_ms orelse return error.MissingVtime;
        try argv.appendSlice(arena, &.{
            "--from-branch",   try number(arena, branch),
            "--from-vtime-ms", try number(arena, vtime_ms),
        });
        if (arguments.exec) |exec| try argv.appendSlice(arena, &.{ "--from-exec", exec });
    }
    explorations += 1;
    const record = try std.fmt.allocPrint(arena, "{s}/record-{d}-{d}.jsonl", .{
        options.scratch_directory, linux.getpid(), explorations,
    });
    const events = try std.fmt.allocPrint(arena, "{s}/events-{d}-{d}", .{
        options.scratch_directory, linux.getpid(), explorations,
    });
    const tapes = try std.fmt.allocPrint(arena, "{s}/tapes-{d}-{d}", .{
        options.scratch_directory, linux.getpid(), explorations,
    });
    try argv.appendSlice(arena, &.{ "--record", record, "--events-dir", events });
    try argv.appendSlice(arena, &.{ "--tape-dir", tapes });
    _ = try std.process.run(arena, io, .{ .argv = argv.items });
    const cwd = std.Io.Dir.cwd();
    const results = try cwd.readFileAlloc(io, record, arena, .limited(result_size_max));
    // Where every branch's events are, for the query tool, and its tapes, for replay.
    return std.fmt.allocPrint(arena, "{s}{{\"events_dir\":{f},\"tape_dir\":{f}}}\n", .{
        results, std.json.fmt(events, .{}), std.json.fmt(tapes, .{}),
    });
}

/// Explorations this server ran: each records its events in its own directory.
var explorations: u32 = 0;

/// From a replay's output: the determinismo lines and what the guest said at the moment.
fn guest_lines(arena: std.mem.Allocator, output: []const u8) ![]const u8 {
    var kept: std.ArrayList(u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const keep = std.mem.startsWith(u8, line, "[determinismo]") or
            std.mem.startsWith(u8, line, "[branch") or std.mem.startsWith(u8, line, "[guest @") or
            std.mem.startsWith(u8, line, "  FAIL") or std.mem.startsWith(u8, line, "  PASS");
        if (!keep) continue;
        try kept.appendSlice(arena, line);
        try kept.append(arena, '\n');
    }
    return kept.items;
}

fn respond(arena: std.mem.Allocator, id: std.json.Value, result: []const u8) !void {
    try write_line(try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{f}," ++
        "\"result\":{s}}}", .{ std.json.fmt(id, .{}), result }));
}

fn respond_text(
    arena: std.mem.Allocator,
    id: std.json.Value,
    text: []const u8,
    is_error: bool,
) !void {
    try write_line(try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"result\":" ++
        "{{\"content\":[{{\"type\":\"text\",\"text\":{f}}}],\"isError\":{}}}}}", .{
        std.json.fmt(id, .{}), std.json.fmt(text, .{}), is_error,
    }));
}

fn number(arena: std.mem.Allocator, value: u64) ![]const u8 {
    return std.fmt.allocPrint(arena, "{d}", .{value});
}

fn write_line(line: []const u8) !void {
    var done: u64 = 0;
    while (done < line.len) {
        const result = linux.write(1, line[done..].ptr, line.len - done);
        if (linux.errno(result) != .SUCCESS) return error.WriteFailed;
        done += result;
    }
    _ = linux.write(1, "\n", 1);
}

fn read_line(reader: *std.Io.Reader, buffer: []u8) ?[]const u8 {
    var size: usize = 0;
    while (size < buffer.len) {
        const byte = reader.takeByte() catch return if (size > 0) buffer[0..size] else null;
        if (byte == '\n') return buffer[0..size];
        buffer[size] = byte;
        size += 1;
    }
    return buffer[0..size];
}
