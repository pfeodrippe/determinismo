// SPDX-License-Identifier: MIT
//! `determinismo serve`: the controller's HTTP API (ARCHITECTURE.md §9), for people, CI and
//! agents. A run is one `determinismo explore` child process with its own directory:
//!
//!   <data>/runs/<id>/request.json   what was asked
//!   <data>/runs/<id>/output.log     its output
//!   <data>/runs/<id>/record.jsonl   its results (explore --record)
//!   <data>/runs/<id>/tapes/         the tapes of its branches
//!   <data>/runs/<id>/events/        every branch's events (explore --events-dir)
//!
//! Endpoints (JSON in, JSON out):
//!   GET  /                   the web UI (ui/index.html): runs, properties, logs, search, map
//!   POST /runs               {program | compose, scenario?, profile?, seed?, branches?, jobs?,
//!                             strategy?, from_branch?, from_vtime_ms?}  -> {id}
//!   GET  /runs               every run with its state
//!   GET  /runs/<id>          its state and record (run, branches, summary)
//!   GET  /runs/<id>/output   its output, as text
//!   POST /runs/<id>/replay   {branch, at_vtime_ms? | until? rewind_ms?, exec?} -> its output
//!   POST /runs/<id>/causality {branch, property, points?, futures?} -> {id} (in the background)
//!   GET  /runs/<id>/causality/<n>  {done, points: [{vtime_ms, futures, failing, probability}]}
//!   POST /runs/<id>/extract  {branch, at_vtime_ms, node, path} -> the file's bytes at that moment
//!   GET  /runs/<id>/discovery  {points: [[branches, behaviors], ...]}: new behavior discovery
//!   GET  /runs/<id>/findings {previous, findings: [{message, kind, finding, rare}]}: what changed
//!                             since the previous finished run of the same system and scenario
//!   POST /runs/<id>/query    {condition, preceded_by?, followed_by?, not_preceded_by?,
//!                             not_followed_by?, within?, branch?, up_to_vtime?, limit?,
//!                             output?: events|count|branches} -> JSON lines (query.zig)
//!   POST /runs/<id>/events   {pipeline, branch?, limit?, output?} -> JSON lines: an event set
//!                             (event_sets.zig)
//!
//! One request at a time, with fixed buffers; runs proceed in the background meanwhile.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const query = @import("query.zig");
const event_sets = @import("event_sets.zig");
const extract = @import("extract.zig");

pub const Options = struct {
    /// "address:port", e.g. 127.0.0.1:7878. Bind to loopback unless the network is trusted.
    listen: []const u8,
    data_directory: []const u8,
    /// How runs boot: --kernel, --initrd, --memory-mib, --cache, ... passed to every explore.
    machine: []const []const u8,
    /// This executable, to start runs with.
    self: []const u8,
    /// Run when a run finishes, through /bin/sh with {dir} and {id} replaced: long-term
    /// storage (e.g. `rclone copy {dir} s3:bucket/runs/{id}`). Null keeps runs local only.
    archive: ?[]const u8 = null,
};

const runs_max = 4096;
const jobs_max = 256;
const request_size_max = 64 * 1024;
const response_size_max = 4 << 20;
const arguments_max = 64;

const Run = struct {
    id: u32,
    pid: linux.pid_t,
    /// Exit status once finished: 0 all properties passed, 3 some failed, others errors.
    status: ?u32 = null,
};

/// A causality analysis (causality.zig) of a run's branch, in the background.
const Job = struct {
    run: u32,
    index: u32,
    pid: linux.pid_t,
    done: bool = false,
};

const Server = struct {
    jobs: [jobs_max]Job = undefined,
    job_count: u32 = 0,
    options: Options,
    io: std.Io,
    arena: std.mem.Allocator,
    runs: [runs_max]Run = undefined,
    run_count: u32 = 0,
    request: [request_size_max]u8 = undefined,
    response: []u8,
};

pub fn serve(arena: std.mem.Allocator, io: std.Io, options: Options) !void {
    const server = try arena.create(Server);
    server.* = .{
        .options = options,
        .io = io,
        .arena = arena,
        .response = try arena.alloc(u8, response_size_max),
    };
    const runs_directory = try std.fs.path.join(arena, &.{ options.data_directory, "runs" });
    try std.Io.Dir.cwd().createDirPath(io, runs_directory);
    try runs_load(server);
    const listener = try listen(options.listen);
    std.debug.print("[determinismo] serving on http://{s} (data in {s})\n", .{
        options.listen, options.data_directory,
    });
    while (true) {
        const client = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(client) != .SUCCESS) continue;
        runs_reap(server);
        handle(server, @intCast(client));
        _ = linux.close(@intCast(client));
    }
}

fn listen(address_text: []const u8) !linux.fd_t {
    const colon = std.mem.lastIndexOfScalar(u8, address_text, ':') orelse return error.BadListen;
    const port = try std.fmt.parseInt(u16, address_text[colon + 1 ..], 10);
    var address: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, address_text[0..colon], '.');
    for (&address) |*byte| {
        byte.* = try std.fmt.parseInt(u8, parts.next() orelse return error.BadListen, 10);
    }
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket) != .SUCCESS) return error.Socket;
    const fd: linux.fd_t = @intCast(socket);
    const one: u32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&one), 4);
    const target = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(address),
    };
    if (linux.errno(linux.bind(fd, @ptrCast(&target), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
        return error.Bind;
    }
    if (linux.errno(linux.listen(fd, 64)) != .SUCCESS) return error.Listen;
    return fd;
}

const Request = struct { method: []const u8, path: []const u8, body: []const u8 };

/// The web UI: one page, no build step, talking to this API.
const ui_html = @embedFile("ui/index.html");

fn handle(server: *Server, client: linux.fd_t) void {
    const request = request_read(server, client) catch {
        return respond(client, 400, "text/plain", "bad request\n");
    };
    const page = std.mem.eql(u8, request.path, "/") or std.mem.eql(u8, request.path, "/index.html");
    if (page and std.mem.eql(u8, request.method, "GET")) {
        return respond(client, 200, "text/html; charset=utf-8", ui_html);
    }
    var writer: std.Io.Writer = .fixed(server.response);
    const status = route(server, request, &writer) catch |err| blk: {
        writer.end = 0;
        writer.print("{{\"error\":\"{s}\"}}\n", .{@errorName(err)}) catch {};
        break :blk @as(u16, switch (err) {
            error.NotFound => 404,
            error.BadRequest, error.SyntaxError, error.UnexpectedToken => 400,
            else => 500,
        });
    };
    const text = std.mem.startsWith(u8, writer.buffered(), "{") or
        std.mem.startsWith(u8, writer.buffered(), "[");
    respond(client, status, if (text) "application/json" else "text/plain", writer.buffered());
}

fn route(server: *Server, request: Request, out: *std.Io.Writer) !u16 {
    const eql = std.mem.eql;
    var parts = std.mem.tokenizeScalar(u8, request.path, '/');
    const first = parts.next() orelse return error.NotFound;
    if (!eql(u8, first, "runs")) return error.NotFound;
    const id_text = parts.next() orelse {
        if (eql(u8, request.method, "POST")) return run_create(server, request.body, out);
        if (eql(u8, request.method, "GET")) return runs_list(server, out);
        return error.NotFound;
    };
    const id = std.fmt.parseInt(u32, id_text, 10) catch return error.NotFound;
    const run = run_find(server, id) orelse return error.NotFound;
    const action = parts.next() orelse {
        if (!eql(u8, request.method, "GET")) return error.NotFound;
        return run_show(server, run, out);
    };
    if (eql(u8, action, "output") and eql(u8, request.method, "GET")) {
        try out.writeAll(try run_file(server, run.id, "output.log"));
        return 200;
    }
    if (eql(u8, action, "replay") and eql(u8, request.method, "POST")) {
        return run_replay(server, run, request.body, out);
    }
    if (eql(u8, action, "extract") and eql(u8, request.method, "POST")) {
        return run_extract(server, run, request.body, out);
    }
    if (eql(u8, action, "discovery") and eql(u8, request.method, "GET")) {
        const events = try std.fs.path.join(server.arena, &.{
            try run_directory(server, run.id), "events",
        });
        const timelines = try query.timelines_read(server.arena, server.io, events, null);
        const points = try query.discovery(server.arena, timelines);
        try out.print("{{\"points\":{f}}}\n", .{std.json.fmt(points, .{})});
        return 200;
    }
    if (eql(u8, action, "findings") and eql(u8, request.method, "GET")) {
        return findings_show(server, run, out);
    }
    if (eql(u8, action, "causality")) {
        if (eql(u8, request.method, "POST")) return causality_start(server, run, request.body, out);
        const index_text = parts.next() orelse return error.NotFound;
        const index = std.fmt.parseInt(u32, index_text, 10) catch return error.NotFound;
        return causality_show(server, run, index, out);
    }
    if (eql(u8, action, "query") and eql(u8, request.method, "POST")) {
        const asked = try std.json.parseFromSliceLeaky(query.Request, server.arena, request.body, .{
            .ignore_unknown_fields = true,
        });
        const events = try std.fs.path.join(server.arena, &.{
            try run_directory(server, run.id), "events",
        });
        try out.writeAll(try query.answer(server.arena, server.io, events, asked));
        return 200;
    }
    if (eql(u8, action, "events") and eql(u8, request.method, "POST")) {
        const options_json: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
        const asked = try std.json.parseFromSliceLeaky(event_sets.Request, server.arena,
            request.body, options_json);
        const events = try std.fs.path.join(server.arena, &.{
            try run_directory(server, run.id), "events",
        });
        try out.writeAll(try event_sets.answer(server.arena, server.io, events, asked));
        return 200;
    }
    return error.NotFound;
}

/// What a client may ask for; mirrors explore's flags.
const RunRequest = struct {
    /// The system: a test program, or a Compose file (exactly one).
    program: ?[]const u8 = null,
    compose: ?[]const u8 = null,
    scenario: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    seed: u64 = 0,
    branches: u32 = 16,
    jobs: ?u32 = null,
    strategy: ?[]const u8 = null,
    from_branch: ?u32 = null,
    from_vtime_ms: ?u64 = null,
    /// Branches at varying CPU speeds (and so their replays too).
    cpu_modulation: bool = false,
};

fn run_create(server: *Server, body: []const u8, out: *std.Io.Writer) !u16 {
    const asked = try std.json.parseFromSliceLeaky(RunRequest, server.arena, body, .{
        .ignore_unknown_fields = true,
    });
    if (server.run_count == runs_max) return error.TooManyRuns;
    const id = if (server.run_count == 0) 1 else server.runs[server.run_count - 1].id + 1;
    const directory = try run_directory(server, id);
    try std.Io.Dir.cwd().createDirPath(server.io, directory);
    try std.Io.Dir.cwd().writeFile(server.io, .{
        .sub_path = try std.fs.path.join(server.arena, &.{ directory, "request.json" }),
        .data = body,
    });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(server.arena, &.{ server.options.self, "explore" });
    try argv.appendSlice(server.arena, server.options.machine);
    try system_arguments(server.arena, &argv, &asked);
    try argv.appendSlice(server.arena, &.{ "--seed", try print(server, "{d}", .{asked.seed}) });
    const branches = try print(server, "{d}", .{asked.branches});
    try argv.appendSlice(server.arena, &.{ "--branches", branches });
    try argv.appendSlice(server.arena, &.{
        "--events-dir", try std.fs.path.join(server.arena, &.{ directory, "events" }),
    });
    try argv.appendSlice(server.arena, &.{
        "--record",   try std.fs.path.join(server.arena, &.{ directory, "record.jsonl" }),
        "--tape-dir", try std.fs.path.join(server.arena, &.{ directory, "tapes" }),
    });
    if (asked.scenario) |scenario| try argv.appendSlice(server.arena, &.{ "--scenario", scenario });
    if (asked.profile) |profile| try argv.appendSlice(server.arena, &.{ "--profile", profile });
    if (asked.strategy) |strategy| try argv.appendSlice(server.arena, &.{ "--strategy", strategy });
    if (asked.jobs) |jobs| {
        try argv.appendSlice(server.arena, &.{ "--jobs", try print(server, "{d}", .{jobs}) });
    }
    if (asked.from_branch) |branch| {
        try argv.appendSlice(server.arena, &.{
            "--from-branch",   try print(server, "{d}", .{branch}),
            "--from-vtime-ms", try print(server, "{d}", .{
                asked.from_vtime_ms orelse return error.BadRequest,
            }),
        });
    }
    const output = try std.fs.path.join(server.arena, &.{ directory, "output.log" });
    const pid = try spawn(server.arena, argv.items, output);
    server.runs[server.run_count] = .{ .id = id, .pid = pid };
    server.run_count += 1;
    try out.print("{{\"id\":{d}}}\n", .{id});
    return 201;
}

fn runs_list(server: *Server, out: *std.Io.Writer) !u16 {
    try out.writeAll("[");
    for (server.runs[0..server.run_count], 0..) |*run, index| {
        if (index > 0) try out.writeAll(",");
        try out.print("{{\"id\":{d},\"state\":\"{s}\"}}", .{ run.id, state(run) });
    }
    try out.writeAll("]\n");
    return 200;
}

/// The run's state and its record, gathered as {"run":..,"branches":[..],"summary":..}.
fn run_show(server: *Server, run: *const Run, out: *std.Io.Writer) !u16 {
    const record = run_file(server, run.id, "record.jsonl") catch "";
    try out.print("{{\"id\":{d},\"state\":\"{s}\"", .{ run.id, state(run) });
    if (run.status) |status| try out.print(",\"status\":{d}", .{status});
    var branches: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, record, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "{\"run\":")) {
            try out.print(",\"run\":{s}", .{line["{\"run\":".len .. line.len - 1]});
        } else if (std.mem.startsWith(u8, line, "{\"summary\":")) {
            try out.print(",\"summary\":{s}", .{line["{\"summary\":".len .. line.len - 1]});
        }
    }
    try out.writeAll(",\"branches\":[");
    lines = std.mem.tokenizeScalar(u8, record, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "{\"branch\":")) continue;
        if (branches > 0) try out.writeAll(",");
        try out.writeAll(line["{\"branch\":".len .. line.len - 1]);
        branches += 1;
    }
    try out.writeAll("]}\n");
    return 200;
}

const ReplayRequest = struct {
    branch: u32,
    at_vtime_ms: ?u64 = null,
    /// Or the moment is the first event matching this condition (query.zig).
    until: ?[]const u8 = null,
    /// With until: this long (virtual time) before the condition holds.
    rewind_ms: ?u64 = null,
    exec: ?[]const u8 = null,
};

/// Replays one branch of a run (synchronously) and returns its output.
fn run_replay(server: *Server, run: *const Run, body: []const u8, out: *std.Io.Writer) !u16 {
    const asked = try std.json.parseFromSliceLeaky(ReplayRequest, server.arena, body, .{
        .ignore_unknown_fields = true,
    });
    const request_json = try run_file(server, run.id, "request.json");
    const original = try std.json.parseFromSliceLeaky(RunRequest, server.arena, request_json, .{
        .ignore_unknown_fields = true,
    });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(server.arena, &.{ server.options.self, "explore" });
    try argv.appendSlice(server.arena, server.options.machine);
    try system_arguments(server.arena, &argv, &original);
    try argv.appendSlice(server.arena, &.{ "--seed", try print(server, "{d}", .{original.seed}) });
    if (original.scenario) |scenario| {
        try argv.appendSlice(server.arena, &.{ "--scenario", scenario });
    }
    if (original.profile) |profile| {
        try argv.appendSlice(server.arena, &.{ "--profile", profile });
    }
    const tape = try std.fmt.allocPrint(server.arena, "{s}/tapes/branch-{d}.jsonl", .{
        try run_directory(server, run.id), asked.branch,
    });
    try argv.appendSlice(server.arena, &.{ "--tape", tape });
    if (asked.at_vtime_ms) |ms| {
        try argv.appendSlice(server.arena, &.{ "--at-vtime-ms", try print(server, "{d}", .{ms}) });
    } else if (asked.until) |condition| {
        try argv.appendSlice(server.arena, &.{ "--until", condition });
        if (asked.rewind_ms) |ms| {
            const text = try print(server, "{d}", .{ms});
            try argv.appendSlice(server.arena, &.{ "--rewind-ms", text });
        }
    }
    const moment = asked.at_vtime_ms != null or asked.until != null;
    if (asked.exec) |command| {
        if (moment) try argv.appendSlice(server.arena, &.{ "--exec", command });
    }
    const result = try std.process.run(server.arena, server.io, .{ .argv = argv.items });
    try out.writeAll(result.stdout);
    try out.writeAll(result.stderr);
    return 200;
}

const ExtractRequest = struct { branch: u32, at_vtime_ms: u64, node: []const u8, path: []const u8 };

/// A node's file at a moment of a branch (extract.zig), replayed from the branch's tape.
fn run_extract(server: *Server, run: *const Run, body: []const u8, out: *std.Io.Writer) !u16 {
    const asked = try std.json.parseFromSliceLeaky(ExtractRequest, server.arena, body, .{
        .ignore_unknown_fields = true,
    });
    const original = try std.json.parseFromSliceLeaky(
        RunRequest,
        server.arena,
        try run_file(server, run.id, "request.json"),
        .{ .ignore_unknown_fields = true },
    );
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(server.arena, server.options.machine);
    try system_arguments(server.arena, &argv, &original);
    if (original.scenario) |scenario| {
        try argv.appendSlice(server.arena, &.{ "--scenario", scenario });
    }
    if (original.profile) |profile| try argv.appendSlice(server.arena, &.{ "--profile", profile });
    const tape = try std.fmt.allocPrint(server.arena, "{s}/tapes/branch-{d}.jsonl", .{
        try run_directory(server, run.id), asked.branch,
    });
    try argv.appendSlice(server.arena, &.{
        "--tape",        tape,
        "--at-vtime-ms", try print(server, "{d}", .{asked.at_vtime_ms}),
    });
    const file = try print(server, "{s}:{s}", .{ asked.node, asked.path });
    const bytes = try extract.read(server.arena, server.io, server.options.self, argv.items, file);
    try out.writeAll(bytes);
    return 200;
}

const CausalityRequest = struct {
    branch: u32,
    property: []const u8,
    points: u32 = 8,
    futures: u32 = 16,
};

fn causality_start(server: *Server, run: *const Run, body: []const u8, out: *std.Io.Writer) !u16 {
    const asked = try std.json.parseFromSliceLeaky(CausalityRequest, server.arena, body, .{
        .ignore_unknown_fields = true,
    });
    if (server.job_count == jobs_max) return error.TooManyJobs;
    const original = try std.json.parseFromSliceLeaky(
        RunRequest,
        server.arena,
        try run_file(server, run.id, "request.json"),
        .{ .ignore_unknown_fields = true },
    );
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(server.arena, &.{ server.options.self, "causality" });
    try argv.appendSlice(server.arena, server.options.machine);
    try system_arguments(server.arena, &argv, &original);
    try argv.appendSlice(server.arena, &.{ "--seed", try print(server, "{d}", .{original.seed}) });
    if (original.scenario) |scenario| {
        try argv.appendSlice(server.arena, &.{ "--scenario", scenario });
    }
    if (original.profile) |profile| try argv.appendSlice(server.arena, &.{ "--profile", profile });
    try argv.appendSlice(server.arena, &.{
        "--branch",  try print(server, "{d}", .{asked.branch}),
        "--property", asked.property,
        "--points",  try print(server, "{d}", .{asked.points}),
        "--futures", try print(server, "{d}", .{asked.futures}),
        "--json",
    });
    var index: u32 = 0;
    for (server.jobs[0..server.job_count]) |job| {
        if (job.run == run.id) index = @max(index, job.index + 1);
    }
    const name = try print(server, "causality-{d}.jsonl", .{index});
    const directory = try run_directory(server, run.id);
    const output = try std.fs.path.join(server.arena, &.{ directory, name });
    const pid = try spawn(server.arena, argv.items, output);
    server.jobs[server.job_count] = .{ .run = run.id, .index = index, .pid = pid };
    server.job_count += 1;
    try out.print("{{\"id\":{d}}}\n", .{index});
    return 201;
}

fn causality_show(server: *Server, run: *const Run, index: u32, out: *std.Io.Writer) !u16 {
    const job = for (server.jobs[0..server.job_count]) |*job| {
        if (job.run == run.id and job.index == index) break job;
    } else return error.NotFound;
    const name = try print(server, "causality-{d}.jsonl", .{index});
    const output = run_file(server, run.id, name) catch "";
    try out.print("{{\"done\":{},\"points\":[", .{job.done});
    var first = true;
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "{\"vtime_ms\"")) continue;
        if (!first) try out.writeAll(",");
        first = false;
        try out.writeAll(line);
    }
    try out.writeAll("]}\n");
    return 200;
}

/// A property as a finished run's summary has it.
const SummaryProperty = struct {
    kind: []const u8,
    message: []const u8,
    /// Absent from records written before multiverse verdicts: violated in some branch then.
    failing: ?bool = null,
    branches_failing: u32 = 0,

    fn failed(property: SummaryProperty) bool {
        return property.failing orelse (property.branches_failing > 0);
    }
};
const SummaryLine = struct {
    summary: struct { branches: u32, properties: []const SummaryProperty },
};

fn summary_read(server: *Server, id: u32) ?[]const SummaryProperty {
    const record = run_file(server, id, "record.jsonl") catch return null;
    var lines = std.mem.tokenizeScalar(u8, record, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "{\"summary\":")) continue;
        const parsed = std.json.parseFromSliceLeaky(SummaryLine, server.arena, line, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        return parsed.summary.properties;
    }
    return null;
}

/// The previous finished run of the same system and scenario, as Antithesis compares runs.
fn run_previous(server: *Server, run: *const Run) !?u32 {
    const mine = try run_identity(server, run.id);
    var index = server.run_count;
    while (index > 0) {
        index -= 1;
        const other = &server.runs[index];
        if (other.id >= run.id or other.status == null) continue;
        const theirs = run_identity(server, other.id) catch continue;
        if (std.mem.eql(u8, mine, theirs)) return other.id;
    }
    return null;
}

fn run_identity(server: *Server, id: u32) ![]const u8 {
    const asked = try std.json.parseFromSliceLeaky(RunRequest, server.arena, try run_file(
        server,
        id,
        "request.json",
    ), .{ .ignore_unknown_fields = true });
    return print(server, "{s}|{s}|{s}|{s}", .{
        asked.program orelse "", asked.compose orelse "", asked.scenario orelse "",
        asked.profile orelse "",
    });
}

/// New (fails now, not in the previous run), ongoing (fails in both), resolved (failed before,
/// passes now); rare when only one timeline showed it.
fn findings_show(server: *Server, run: *const Run, out: *std.Io.Writer) !u16 {
    const now = summary_read(server, run.id) orelse return error.NotFinished;
    const previous_id = try run_previous(server, run);
    const before: []const SummaryProperty = if (previous_id) |id| summary_read(server, id) orelse
        &.{} else &.{};
    try out.writeAll("{\"previous\":");
    if (previous_id) |id| try out.print("{d}", .{id}) else try out.writeAll("null");
    try out.writeAll(",\"findings\":[");
    var first = true;
    for (now) |property| {
        const earlier = for (before) |other| {
            if (std.mem.eql(u8, other.message, property.message)) break other;
        } else null;
        const failed_before = if (earlier) |other| other.failed() else false;
        const finding: ?[]const u8 = if (property.failed())
            (if (failed_before) "ongoing" else "new")
        else if (failed_before) "resolved" else null;
        const kind = finding orelse continue;
        if (!first) try out.writeAll(",");
        first = false;
        try out.print("{{\"message\":{f},\"kind\":{f},\"finding\":\"{s}\",\"rare\":{}}}", .{
            std.json.fmt(property.message, .{}), std.json.fmt(property.kind, .{}), kind,
            property.failed() and property.branches_failing == 1,
        });
    }
    // Properties that failed before and no longer exist (code removed) are resolved too.
    for (before) |other| {
        if (!other.failed()) continue;
        const still = for (now) |property| {
            if (std.mem.eql(u8, property.message, other.message)) break true;
        } else false;
        if (still) continue;
        if (!first) try out.writeAll(",");
        first = false;
        try out.print("{{\"message\":{f},\"kind\":{f},\"finding\":\"resolved\",\"rare\":false}}", .{
            std.json.fmt(other.message, .{}), std.json.fmt(other.kind, .{}),
        });
    }
    try out.writeAll("]}\n");
    return 200;
}

fn system_arguments(
    arena: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    asked: *const RunRequest,
) !void {
    if ((asked.program == null) == (asked.compose == null)) return error.BadRequest;
    if (asked.program) |program| try argv.appendSlice(arena, &.{ "--program", program });
    if (asked.compose) |compose| try argv.appendSlice(arena, &.{ "--compose", compose });
    if (asked.cpu_modulation) try argv.append(arena, "--cpu-modulation");
}

fn run_find(server: *Server, id: u32) ?*Run {
    for (server.runs[0..server.run_count]) |*run| {
        if (run.id == id) return run;
    }
    return null;
}

/// Runs of an earlier server (before a restart). A run whose record has its summary finished:
/// it passed or failed by that summary; one without was interrupted (an error).
fn runs_load(server: *Server) !void {
    var id: u32 = 1;
    while (id < runs_max) : (id += 1) {
        const directory = try run_directory(server, id);
        std.Io.Dir.cwd().access(server.io, directory, .{}) catch break;
        const record = run_file(server, id, "record.jsonl") catch "";
        server.runs[server.run_count] = .{ .id = id, .pid = 0, .status = recorded_status(record) };
        server.run_count += 1;
    }
}

fn recorded_status(record: []const u8) u32 {
    const key = "{\"summary\":";
    const start = std.mem.lastIndexOf(u8, record, key) orelse return 255;
    const failing_key = "\"failing_branches\":";
    const failing = std.mem.indexOfPos(u8, record, start, failing_key) orelse return 255;
    const digit = failing + failing_key.len;
    if (digit >= record.len) return 255;
    return if (record[digit] == '0') 0 else 3; // As explore exits.
}

fn runs_reap(server: *Server) void {
    for (server.jobs[0..server.job_count]) |*job| {
        if (job.done) continue;
        var status: i32 = 0;
        const result = linux.wait4(job.pid, &status, linux.W.NOHANG, null);
        if (linux.errno(result) == .SUCCESS and result != 0) job.done = true;
    }
    for (server.runs[0..server.run_count]) |*run| {
        if (run.status != null) continue;
        var status: i32 = 0;
        const result = linux.wait4(run.pid, &status, linux.W.NOHANG, null);
        if (linux.errno(result) != .SUCCESS or result == 0) continue;
        const bits: u32 = @bitCast(status);
        run.status = if (bits & 0x7f == 0) (bits >> 8) & 0xff else 128 + (bits & 0x7f);
        archive(server, run) catch |err| {
            std.debug.print("[determinismo] archiving run {d} failed: {s}\n", .{
                run.id, @errorName(err),
            });
        };
    }
}

/// Hands a finished run's directory to the archive command (in the background).
fn archive(server: *Server, run: *const Run) !void {
    const template = server.options.archive orelse return;
    const directory = try run_directory(server, run.id);
    const id = try print(server, "{d}", .{run.id});
    const with_dir = try std.mem.replaceOwned(u8, server.arena, template, "{dir}", directory);
    const command = try std.mem.replaceOwned(u8, server.arena, with_dir, "{id}", id);
    const log = try std.fs.path.join(server.arena, &.{ directory, "archive.log" });
    _ = try spawn(server.arena, &.{ "/bin/sh", "-c", command }, log);
}

fn state(run: *const Run) []const u8 {
    const status = run.status orelse return "running";
    return switch (status) {
        0 => "passed",
        3 => "failed",
        else => "error",
    };
}

fn run_directory(server: *Server, id: u32) ![]const u8 {
    return std.fmt.allocPrint(server.arena, "{s}/runs/{d}", .{ server.options.data_directory, id });
}

fn run_file(server: *Server, id: u32, name: []const u8) ![]const u8 {
    const path = try std.fs.path.join(server.arena, &.{ try run_directory(server, id), name });
    const limit: std.Io.Limit = .limited(response_size_max / 2);
    return std.Io.Dir.cwd().readFileAlloc(server.io, path, server.arena, limit);
}

fn print(server: *Server, comptime format: []const u8, arguments: anytype) ![]const u8 {
    return std.fmt.allocPrint(server.arena, format, arguments);
}

/// Starts `argv` in the background with its output (both streams) in `output_path`.
fn spawn(arena: std.mem.Allocator, argv: []const []const u8, output_path: []const u8) !linux.pid_t {
    assert(argv.len > 0 and argv.len < arguments_max);
    const argv_z = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, argv_z) |argument, *slot| slot.* = try arena.dupeSentinel(u8, argument, 0);
    const output_z = try arena.dupeSentinel(u8, output_path, 0);
    const environment = [_:null]?[*:0]const u8{"PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"};
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.Fork;
    if (pid == 0) {
        const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
        const fd = linux.open(output_z, flags, 0o644);
        if (linux.errno(fd) == .SUCCESS) {
            _ = linux.dup2(@intCast(fd), 1);
            _ = linux.dup2(@intCast(fd), 2);
        }
        _ = linux.setsid(); // Not killed with the server's terminal.
        _ = linux.execve(argv_z[0].?, argv_z.ptr, &environment);
        linux.exit_group(127);
    }
    return @intCast(pid);
}

fn request_read(server: *Server, client: linux.fd_t) !Request {
    var size: u32 = 0;
    while (true) {
        const result = linux.read(client, server.request[size..].ptr, server.request.len - size);
        if (linux.errno(result) != .SUCCESS or result == 0) return error.BadRequest;
        size += @intCast(result);
        const text = server.request[0..size];
        const header_end = std.mem.indexOf(u8, text, "\r\n\r\n") orelse {
            if (size == server.request.len) return error.BadRequest;
            continue;
        };
        const length = content_length(text[0..header_end]);
        const total = header_end + 4 + length;
        if (total > server.request.len) return error.BadRequest;
        if (size < total) continue;
        var line = std.mem.tokenizeScalar(u8, text[0..header_end], ' ');
        return .{
            .method = line.next() orelse return error.BadRequest,
            .path = line.next() orelse return error.BadRequest,
            .body = text[header_end + 4 .. total],
        };
    }
}

fn content_length(headers: []const u8) u32 {
    var lines = std.mem.tokenizeSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) continue;
        return std.fmt.parseInt(u32, std.mem.trim(u8, line[colon + 1 ..], " "), 10) catch 0;
    }
    return 0;
}

fn respond(client: linux.fd_t, status: u16, content_type: []const u8, body: []const u8) void {
    var header: [256]u8 = undefined;
    const reason = switch (status) {
        200 => "OK",
        201 => "Created",
        400 => "Bad Request",
        404 => "Not Found",
        else => "Internal Server Error",
    };
    const head = std.fmt.bufPrint(&header, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\n" ++
        "Content-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{
        status, reason, content_type, body.len,
    }) catch unreachable;
    write_all(client, head);
    write_all(client, body);
}

fn write_all(fd: linux.fd_t, bytes: []const u8) void {
    var done: u64 = 0;
    while (done < bytes.len) {
        const result = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (linux.errno(result) != .SUCCESS) return;
        done += result;
    }
}

test recorded_status {
    try std.testing.expectEqual(@as(u32, 255), recorded_status("{\"run\":{}}\n"));
    const passed = "{\"summary\":{\"branches\":2,\"failing_branches\":0}}\n";
    try std.testing.expectEqual(@as(u32, 0), recorded_status(passed));
    const failed = "{\"summary\":{\"branches\":2,\"failing_branches\":1}}\n";
    try std.testing.expectEqual(@as(u32, 3), recorded_status(failed));
}

test content_length {
    const post = "POST /runs HTTP/1.1\r\nContent-Length: 12";
    try std.testing.expectEqual(@as(u32, 12), content_length(post));
    try std.testing.expectEqual(@as(u32, 0), content_length("GET /runs HTTP/1.1\r\nHost: x"));
}
