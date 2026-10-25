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
//!   GET  /runs/<id>/notebook  {source}; PUT {source}: the run's notebook (JavaScript cells)
//!   GET  /runs/<id>/findings {previous, findings: [{message, kind, finding, rare}]}: what changed
//!                             since the previous finished run of the same system and scenario
//!                             (new, ongoing, resolved, or unseen: maybe missed by chance)
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
    /// Babashka, which evaluates notebooks (Clojure cells; notebook.clj).
    bb: []const u8 = "bb",
};

const runs_max = 4096;
const jobs_max = 256;
// A notebook with its actions' results, an uploaded strategy.
const request_size_max = 64 << 20;
/// Responses (and the run files they are made of) grow as needed up to this: a query over a
/// long run's every timeline is large.
const response_size_max = 256 << 20;
const arguments_max = 64;

const Run = struct {
    id: u32,
    pid: linux.pid_t,
    /// Exit status once finished: 0 all properties passed, 3 some failed, others errors.
    status: ?u32 = null,
    /// Its babashka nREPL server, once started (notebook.clj's names, over this API).
    nrepl_port: ?u16 = null,
    /// Stopped on request (POST /runs/<id>/stop).
    stopped: bool = false,
    /// Started by an earlier server and still running: not its child, so watched with kill(0)
    /// and judged by its record once gone.
    adopted: bool = false,
};

const nrepl_port_base = 17000;

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
};

pub fn serve(arena: std.mem.Allocator, io: std.Io, options: Options) !void {
    const server = try arena.create(Server);
    server.* = .{
        .options = options,
        .io = io,
        .arena = arena,
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
    var response: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer response.deinit();
    const writer = &response.writer;
    const status = route(server, request, writer) catch |err| blk: {
        response.clearRetainingCapacity();
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
    if (eql(u8, first, "strategies")) return strategies_route(server, parts.next(), request, out);
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
    return run_route(server, run, action, &parts, request, out);
}

/// /runs/<id>/<action>[/...]: what one run offers.
fn run_route(
    server: *Server,
    run: *const Run,
    action: []const u8,
    parts: *std.mem.TokenIterator(u8, .scalar),
    request: Request,
    out: *std.Io.Writer,
) !u16 {
    const eql = std.mem.eql;
    if (eql(u8, action, "output") and eql(u8, request.method, "GET")) {
        try out.writeAll(try run_file(server, run.id, "output.log"));
        return 200;
    }
    if (eql(u8, action, "replay") and eql(u8, request.method, "POST")) {
        return run_replay(server, run, request.body, out);
    }
    if (eql(u8, action, "stop") and eql(u8, request.method, "POST")) {
        return run_stop(server, @constCast(run), out);
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
    if (eql(u8, action, "notebook")) {
        const what = parts.next() orelse return notebook(server, run, request, out);
        if (!eql(u8, what, "evaluate") or !eql(u8, request.method, "POST")) return error.NotFound;
        return notebook_evaluate(server, run, request.body, out);
    }
    if (eql(u8, action, "nrepl") and eql(u8, request.method, "POST")) {
        return nrepl_start(server, @constCast(run), out);
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
    /// Timelines (at most, with a time budget).
    branches: ?u32 = null,
    /// Explore until then: "90s", "10m", "2h".
    time_budget: ?[]const u8 = null,
    /// "flat" or "tree" (explore's --branching).
    branching: ?[]const u8 = null,
    /// Fault kinds every node also allows, nodes that allow none (explore's --faults,
    /// --no-faults).
    faults: ?[]const u8 = null,
    no_faults: ?[]const u8 = null,
    /// How long each timeline's drivers run, in virtual time (explore's --timeline).
    timeline: ?[]const u8 = null,
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
    if (asked.time_budget) |budget| {
        try argv.appendSlice(server.arena, &.{ "--time-budget", budget });
    }
    if (asked.branching) |branching| {
        try argv.appendSlice(server.arena, &.{ "--branching", branching });
    }

    if (asked.branches != null or asked.time_budget == null) {
        const branches = try print(server, "{d}", .{asked.branches orelse 16});
        try argv.appendSlice(server.arena, &.{ "--branches", branches });
    }
    try argv.appendSlice(server.arena, &.{
        "--events-dir", try std.fs.path.join(server.arena, &.{ directory, "events" }),
    });
    try argv.appendSlice(server.arena, &.{
        "--record",   try std.fs.path.join(server.arena, &.{ directory, "record.jsonl" }),
        "--tape-dir", try std.fs.path.join(server.arena, &.{ directory, "tapes" }),
    });
    if (asked.scenario) |scenario| try argv.appendSlice(server.arena, &.{ "--scenario", scenario });
    if (asked.profile) |profile| try argv.appendSlice(server.arena, &.{ "--profile", profile });
    if (asked.strategy) |strategy| {
        const command = try strategy_resolve(server, strategy);
        try argv.appendSlice(server.arena, &.{ "--strategy", command });
    }
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
    const pid = try spawn(server.arena, argv.items, output, &.{});
    // For a restarted server to find it still running (runs_load).
    const pid_path = try std.fs.path.join(server.arena, &.{ directory, "pid" });
    const pid_text = try print(server, "{d}\n", .{pid});
    try std.Io.Dir.cwd().writeFile(server.io, .{ .sub_path = pid_path, .data = pid_text });
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
        } else if (std.mem.startsWith(u8, line, "{\"snapshot\":")) {
            try out.print(",\"snapshot\":{s}", .{line["{\"snapshot\":".len .. line.len - 1]});
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
    }
    if (asked.until) |condition| {
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
    const pid = try spawn(server.arena, argv.items, output, &.{});
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
const Summary = struct { branches: u32, properties: []const SummaryProperty };
const SummaryLine = struct { summary: Summary };

fn summary_read(server: *Server, id: u32) ?Summary {
    const record = run_file(server, id, "record.jsonl") catch return null;
    var lines = std.mem.tokenizeScalar(u8, record, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "{\"summary\":")) continue;
        const parsed = std.json.parseFromSliceLeaky(SummaryLine, server.arena, line, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        return parsed.summary;
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
/// passes now, and that is unlikely to be luck) or unseen (passes now, but as rare a failure
/// could have been missed); rare when only one timeline showed it.
fn findings_show(server: *Server, run: *const Run, out: *std.Io.Writer) !u16 {
    const summary_now = summary_read(server, run.id) orelse return error.NotFinished;
    const now = summary_now.properties;
    const previous_id = try run_previous(server, run);
    const summary_before: Summary = if (previous_id) |id| summary_read(server, id) orelse
        .{ .branches = 0, .properties = &.{} } else .{ .branches = 0, .properties = &.{} };
    const before = summary_before.properties;
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
        else if (failed_before)
            resolution(earlier.?, summary_before.branches, summary_now.branches)
        else
            null;
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

/// Whether a failure that is gone is gone for sure. A failure of a property judged per timeline
/// (always, unreachable) that showed in k of n timelines is missed by m new timelines with
/// probability (1 - k/n)^m: below 5% it is resolved, else only unseen. A property judged over
/// the multiverse (sometimes, reachable) that now holds is resolved.
fn resolution(before: SummaryProperty, branches_before: u32, branches_now: u32) []const u8 {
    const per_timeline = std.mem.startsWith(u8, before.kind, "always") or
        std.mem.eql(u8, before.kind, "unreachable");
    if (!per_timeline or branches_before == 0 or before.branches_failing == 0) return "resolved";
    const rate = @as(f64, @floatFromInt(@min(before.branches_failing, branches_before))) /
        @as(f64, @floatFromInt(branches_before));
    const missed = std.math.pow(f64, 1 - rate, @floatFromInt(branches_now));
    return if (missed < 0.05) "resolved" else "unseen";
}

test resolution {
    const always = SummaryProperty{ .kind = "always", .message = "m", .branches_failing = 1 };
    // Seen in 1 of 100: 16 clean timelines could easily have missed it.
    try std.testing.expectEqualStrings("unseen", resolution(always, 100, 16));
    // Seen in 50 of 100: 16 clean timelines would almost surely have shown it.
    var common = always;
    common.branches_failing = 50;
    try std.testing.expectEqualStrings("resolved", resolution(common, 100, 16));
    const sometimes = SummaryProperty{ .kind = "sometimes", .message = "m", .failing = true };
    try std.testing.expectEqualStrings("resolved", resolution(sometimes, 100, 1));
}

/// The run's notebook (the UI's, or an agent's): JavaScript cells, kept in the run's directory
/// so that whoever opens the run sees it. GET answers {source} (null before any save); PUT
/// takes {source}.
fn notebook(server: *Server, run: *const Run, request: Request, out: *std.Io.Writer) !u16 {
    const path = try std.fs.path.join(server.arena, &.{
        try run_directory(server, run.id), "notebook.js",
    });
    if (std.mem.eql(u8, request.method, "PUT")) {
        const Saved = struct { source: []const u8 };
        const saved = try std.json.parseFromSliceLeaky(Saved, server.arena, request.body, .{
            .ignore_unknown_fields = true,
        });
        try std.Io.Dir.cwd().writeFile(server.io, .{ .sub_path = path, .data = saved.source });
        try out.writeAll("{\"saved\":true}\n");
        return 200;
    }
    if (!std.mem.eql(u8, request.method, "GET")) return error.NotFound;
    const limit: std.Io.Limit = .limited(request_size_max);
    const source = std.Io.Dir.cwd().readFileAlloc(server.io, path, server.arena, limit) catch
        |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    try out.print("{{\"source\":{f}}}\n", .{std.json.fmt(source, .{})});
    return 200;
}

/// Strategies uploaded to this server (`PUT /strategies/<name>`, the executable as the body;
/// `GET /strategies` lists them). A run names one as `@<name> [arguments]`. They run on this
/// host as any `--strategy` command does, so serve should listen where only trusted users reach.
fn strategies_route(
    server: *Server,
    name: ?[]const u8,
    request: Request,
    out: *std.Io.Writer,
) !u16 {
    const eql = std.mem.eql;
    const directory = try std.fs.path.join(server.arena, &.{
        server.options.data_directory, "strategies",
    });
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(server.io, directory);
    const given = name orelse {
        if (!eql(u8, request.method, "GET")) return error.NotFound;
        var dir = try cwd.openDir(server.io, directory, .{ .iterate = true });
        defer dir.close(server.io);
        var iterator = dir.iterate();
        try out.writeAll("[");
        var count: u32 = 0;
        while (try iterator.next(server.io)) |entry| {
            if (count > 0) try out.writeAll(",");
            try out.print("{f}", .{std.json.fmt(entry.name, .{})});
            count += 1;
        }
        try out.writeAll("]\n");
        return 200;
    };
    if (!eql(u8, request.method, "PUT")) return error.NotFound;
    if (!strategy_name_valid(given) or request.body.len == 0) return error.BadRequest;
    const path = try std.fs.path.join(server.arena, &.{ directory, given });
    try cwd.writeFile(server.io, .{
        .sub_path = path,
        .data = request.body,
        .flags = .{ .permissions = .executable_file },
    });
    try out.print("{{\"strategy\":\"@{s}\",\"bytes\":{d}}}\n", .{ given, request.body.len });
    return 201;
}

fn strategy_name_valid(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '.') return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    }
    return true;
}

/// `@<name> args` names an uploaded strategy: its path, with the arguments.
fn strategy_resolve(server: *Server, strategy: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, strategy, "@")) return strategy;
    const end = std.mem.indexOfScalar(u8, strategy, ' ') orelse strategy.len;
    const name = strategy[1..end];
    if (!strategy_name_valid(name)) return error.BadRequest;
    return print(server, "{s}/strategies/{s}{s}", .{
        server.options.data_directory, name, strategy[end..],
    });
}

test strategy_name_valid {
    try std.testing.expect(strategy_name_valid("llm.py"));
    try std.testing.expect(!strategy_name_valid("../x"));
    try std.testing.expect(!strategy_name_valid(".hidden"));
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
    // They change the system (what its nodes allow): runs and their replays both.
    if (asked.faults) |kinds| try argv.appendSlice(arena, &.{ "--faults", kinds });
    if (asked.no_faults) |names| try argv.appendSlice(arena, &.{ "--no-faults", names });
    // Part of the inputs (the guest's command line): replays need it too.
    if (asked.timeline) |length| try argv.appendSlice(arena, &.{ "--timeline", length });
}

fn run_find(server: *Server, id: u32) ?*Run {
    for (server.runs[0..server.run_count]) |*run| {
        if (run.id == id) return run;
    }
    return null;
}

/// Stops a running run: SIGTERM to its process group (the explorer and its workers; each run
/// leads its own session). Marked stopped, on disk too.
fn run_stop(server: *Server, run: *Run, out: *std.Io.Writer) !u16 {
    if (run.status != null) return error.NotRunning;
    if (linux.errno(linux.kill(-run.pid, .TERM)) != .SUCCESS) return error.NotRunning;
    run.stopped = true;
    const directory = try run_directory(server, run.id);
    const path = try std.fs.path.join(server.arena, &.{ directory, "stopped" });
    try std.Io.Dir.cwd().writeFile(server.io, .{ .sub_path = path, .data = "" });
    try out.print("{{\"id\":{d},\"state\":\"stopped\"}}\n", .{run.id});
    return 200;
}

/// Runs of an earlier server (before a restart). A run whose record has its summary finished:
/// it passed or failed by that summary. One without whose explorer still runs (its pid file
/// names a live process that writes this run's events) is adopted: running. Others were
/// interrupted (an error), or stopped on request.
fn runs_load(server: *Server) !void {
    var id: u32 = 1;
    while (id < runs_max) : (id += 1) {
        const directory = try run_directory(server, id);
        std.Io.Dir.cwd().access(server.io, directory, .{}) catch break;
        const record = run_file(server, id, "record.jsonl") catch "";
        const stopped = if (run_file(server, id, "stopped")) |_| true else |_| false;
        var run = Run{ .id = id, .pid = 0, .status = recorded_status(record), .stopped = stopped };
        if (run.status == status_interrupted and !stopped) {
            if (run_alive(server, id)) |pid| {
                run.pid = pid;
                run.status = null;
                run.adopted = true;
            }
        }
        server.runs[server.run_count] = run;
        server.run_count += 1;
    }
}

const status_interrupted = 255;

/// The run's explorer, if its pid file names a live process working for this run.
fn run_alive(server: *Server, id: u32) ?linux.pid_t {
    const text = run_file(server, id, "pid") catch return null;
    const pid = std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, text, " \n"), 10) catch return null;
    const arena = server.arena;
    const cmdline_path = std.fmt.allocPrintSentinel(arena, "/proc/{d}/cmdline", .{pid}, 0) catch
        return null;
    // Read until the end: procfs files report no size.
    const fd = linux.open(cmdline_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var cmdline_buffer: [1 << 16]u8 = undefined;
    var size: usize = 0;
    while (size < cmdline_buffer.len) {
        const free = cmdline_buffer[size..];
        const result = linux.read(@intCast(fd), free.ptr, free.len);
        if (linux.errno(result) != .SUCCESS or result == 0) break;
        size += result;
    }
    const cmdline = cmdline_buffer[0..size];
    const directory = run_directory(server, id) catch return null;
    const events = print(server, "{s}/events", .{directory}) catch return null;
    return if (std.mem.indexOf(u8, cmdline, events) != null) pid else null;
}

fn recorded_status(record: []const u8) u32 {
    const key = "{\"summary\":";
    const start = std.mem.lastIndexOf(u8, record, key) orelse return status_interrupted;
    const failing_key = "\"failing_branches\":";
    const failing = std.mem.indexOfPos(u8, record, start, failing_key) orelse
        return status_interrupted;
    const digit = failing + failing_key.len;
    if (digit >= record.len) return status_interrupted;
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
        if (run.adopted) {
            if (linux.errno(linux.kill(run.pid, @enumFromInt(0))) != .SRCH) continue;
            const record = run_file(server, run.id, "record.jsonl") catch "";
            run.status = recorded_status(record);
            continue;
        }
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
    _ = try spawn(server.arena, &.{ "/bin/sh", "-c", command }, log, &.{});
}

fn state(run: *const Run) []const u8 {
    if (run.stopped) return "stopped";
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

const notebook_clj = @embedFile("notebook.clj");

fn notebook_script(server: *Server) ![]const u8 {
    const script = try std.fs.path.join(server.arena, &.{
        server.options.data_directory, "notebook.clj",
    });
    try std.Io.Dir.cwd().writeFile(server.io, .{ .sub_path = script, .data = notebook_clj });
    return script;
}

/// A babashka nREPL server for the run (started once, on loopback): the notebook's names in
/// `user`, over the run's events and record, with actions that run at once through this API.
/// Editors connect through a tunnel to its port.
fn nrepl_start(server: *Server, run: *Run, out: *std.Io.Writer) !u16 {
    if (run.nrepl_port == null) {
        const arena = server.arena;
        const port: u16 = nrepl_port_base + @as(u16, @intCast(run.id % 1000));
        const directory = try run_directory(server, run.id);
        const address = try print(server, "127.0.0.1:{d}", .{port});
        const argv = [_][]const u8{
            server.options.bb, "--init", try notebook_script(server), "nrepl-server", address,
        };
        const environment = [_][]const u8{
            try print(server, "DETERMINISMO={s}", .{server.options.self}),
            try print(server, "DETERMINISMO_EVENTS={s}/events", .{directory}),
            try print(server, "DETERMINISMO_RECORD={s}/record.jsonl", .{directory}),
            try print(server, "DETERMINISMO_API=http://{s}", .{server.options.listen}),
            try print(server, "DETERMINISMO_RUN={d}", .{run.id}),
        };
        const log = try std.fs.path.join(arena, &.{ directory, "nrepl.log" });
        _ = try spawn(arena, &argv, log, &environment);
        run.nrepl_port = port;
    }
    try out.print("{{\"port\":{d}}}\n", .{run.nrepl_port.?});
    return 200;
}

/// Evaluates a notebook's cells (Clojure, with babashka: notebook.clj), the request's body as
/// its input: {"cells": [...], "results": {...}}; answers each cell's outputs.
fn notebook_evaluate(
    server: *Server,
    run: *const Run,
    body: []const u8,
    out: *std.Io.Writer,
) !u16 {
    const arena = server.arena;
    const directory = try run_directory(server, run.id);
    const cwd = std.Io.Dir.cwd();
    const script = try notebook_script(server);
    const input = try std.fs.path.join(server.arena, &.{ directory, "notebook-input.json" });
    try cwd.writeFile(server.io, .{ .sub_path = input, .data = body });
    var environment = std.process.Environ.Map.init(server.arena);
    try environment.put("DETERMINISMO", server.options.self);
    const events = try std.fs.path.join(arena, &.{ directory, "events" });
    const record = try std.fs.path.join(arena, &.{ directory, "record.jsonl" });
    try environment.put("DETERMINISMO_EVENTS", events);
    try environment.put("DETERMINISMO_RECORD", record);
    try environment.put("PATH", "/usr/local/bin:/usr/bin:/bin");
    const result = try std.process.run(server.arena, server.io, .{
        .argv = &.{ server.options.bb, script, input },
        .environ_map = &environment,
    });
    if (result.stdout.len == 0) {
        try out.print("{{\"error\":{f}}}\n", .{std.json.fmt(result.stderr, .{})});
        return 500;
    }
    try out.writeAll(result.stdout);
    return 200;
}

fn run_file(server: *Server, id: u32, name: []const u8) ![]const u8 {
    const path = try std.fs.path.join(server.arena, &.{ try run_directory(server, id), name });
    const limit: std.Io.Limit = .limited(response_size_max);
    return std.Io.Dir.cwd().readFileAlloc(server.io, path, server.arena, limit);
}

fn print(server: *Server, comptime format: []const u8, arguments: anytype) ![]const u8 {
    return std.fmt.allocPrint(server.arena, format, arguments);
}

/// Starts `argv` in the background with its output (both streams) in `output_path`.
/// Starts `argv` in the background, its output to `output_path`; `extra` adds "NAME=value"
/// to its environment.
fn spawn(
    arena: std.mem.Allocator,
    argv: []const []const u8,
    output_path: []const u8,
    extra: []const []const u8,
) !linux.pid_t {
    assert(argv.len > 0 and argv.len < arguments_max);
    const argv_z = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, argv_z) |argument, *slot| slot.* = try arena.dupeSentinel(u8, argument, 0);
    const output_z = try arena.dupeSentinel(u8, output_path, 0);
    const environment = try arena.allocSentinel(?[*:0]const u8, extra.len + 1, null);
    environment[0] = "PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    for (extra, environment[1..]) |entry, *slot| slot.* = try arena.dupeSentinel(u8, entry, 0);
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
        _ = linux.execve(argv_z[0].?, argv_z.ptr, environment.ptr);
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
