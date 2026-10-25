// SPDX-License-Identifier: MIT
//! `determinismo mcp`: a Model Context Protocol server over stdio (JSON-RPC 2.0, one message
//! per line), so agents can describe systems, explore them, replay branches and debug them at
//! exact moments. Each tool runs this executable (`explore ... --record`) and returns what it
//! found; the machine options given to `mcp` apply to every run.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const query = @import("query.zig");

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
    scenario: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    seed: u64 = 0,
    branches: u32 = 16,
    branch: ?u32 = null,
    at_vtime_ms: ?u64 = null,
    exec: ?[]const u8 = null,
    @"continue": bool = false,
    from_branch: ?u32 = null,
    from_vtime_ms: ?u64 = null,
    until: ?[]const u8 = null,
    property: ?[]const u8 = null,
    points: u32 = 8,
    futures: u32 = 16,
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
        const text = tool_call(arena, io, options, name, call_arguments) catch |err| {
            const failure = try std.fmt.allocPrint(arena, "error: {s}", .{@errorName(err)});
            return respond_text(arena, id, failure, true);
        };
        return respond_text(arena, id, text, false);
    }
    try write_line(try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{f}," ++
        "\"error\":{{\"code\":-32601,\"message\":\"unknown method\"}}}}", .{
        std.json.fmt(id, .{}),
    }));
}

fn tool_call(
    arena: std.mem.Allocator,
    io: std.Io,
    options: Options,
    name: []const u8,
    value: std.json.Value,
) ![]const u8 {
    const eql = std.mem.eql;
    if (eql(u8, name, "query")) {
        // An exploration's events directory, and the query (query.Request's fields).
        const options_json: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
        const Where = struct { events_dir: []const u8 };
        const where = try std.json.parseFromValueLeaky(Where, arena, value, options_json);
        const asked = try std.json.parseFromValueLeaky(query.Request, arena, value, options_json);
        return query.answer(arena, io, where.events_dir, asked);
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
    const command = if (eql(u8, name, "causality")) "causality" else "explore";
    try argv.appendSlice(arena, &.{ options.self, command });
    try argv.appendSlice(arena, options.machine);
    if ((arguments.program == null) == (arguments.compose == null)) return error.ProgramOrCompose;
    if (arguments.program) |program| try argv.appendSlice(arena, &.{ "--program", program });
    if (arguments.compose) |compose| try argv.appendSlice(arena, &.{ "--compose", compose });
    try argv.appendSlice(arena, &.{ "--seed", try number(arena, arguments.seed) });
    if (arguments.scenario) |scenario| try argv.appendSlice(arena, &.{ "--scenario", scenario });
    if (arguments.profile) |profile| try argv.appendSlice(arena, &.{ "--profile", profile });
    if (eql(u8, name, "replay")) {
        const branch = arguments.branch orelse return error.MissingBranch;
        try argv.appendSlice(arena, &.{ "--branch", try number(arena, branch) });
        if (arguments.at_vtime_ms) |ms| {
            try argv.appendSlice(arena, &.{ "--at-vtime-ms", try number(arena, ms) });
        } else if (arguments.until) |condition| {
            try argv.appendSlice(arena, &.{ "--until", condition });
        }
        if (arguments.at_vtime_ms != null or arguments.until != null) {
            if (arguments.exec) |exec| try argv.appendSlice(arena, &.{ "--exec", exec });
            if (arguments.@"continue") try argv.append(arena, "--continue");
        }
        const result = try std.process.run(arena, io, .{ .argv = argv.items });
        return guest_lines(arena, result.stderr);
    }
    if (eql(u8, name, "causality")) {
        const branch = arguments.branch orelse return error.MissingBranch;
        const property = arguments.property orelse return error.MissingProperty;
        try argv.appendSlice(arena, &.{
            "--branch",  try number(arena, branch), "--property", property,
            "--points",  try number(arena, arguments.points),
            "--futures", try number(arena, arguments.futures),
            "--json",
        });
        const result = try std.process.run(arena, io, .{ .argv = argv.items });
        return result.stdout;
    }
    if (!eql(u8, name, "explore") and !eql(u8, name, "fork")) return error.UnknownTool;
    try argv.appendSlice(arena, &.{ "--branches", try number(arena, arguments.branches) });
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
    try argv.appendSlice(arena, &.{ "--record", record, "--events-dir", events });
    _ = try std.process.run(arena, io, .{ .argv = argv.items });
    const cwd = std.Io.Dir.cwd();
    const results = try cwd.readFileAlloc(io, record, arena, .limited(result_size_max));
    // Where every branch's events are, for the query tool.
    return std.fmt.allocPrint(arena, "{s}{{\"events_dir\":{f}}}\n", .{
        results, std.json.fmt(events, .{}),
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
