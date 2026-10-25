// SPDX-License-Identifier: MIT
//! End-to-end checks on the Linux host: the whole system, through the command line, as a user
//! runs it. `zig build e2e` (after building the guest kernel and initramfs, see README.md).
//!
//! Each check boots real VMs: exploration finds the examples' known bugs without overshoots,
//! branches replay from fresh boots with identical event hashes, tapes replay without their
//! strategy, and a tape refuses to replay on different inputs.
//!
//! Usage: e2e [--bin <dir>] [--guest <dir>] [--cache <dir>] [--only <name>]
//!   --bin    built programs (zig-out/bin)       --guest  vmlinuz and base.cpio ($HOME/guest)
//!   --cache  determinismo's cache ($HOME/cache) --only   the checks whose names contain <name>
const std = @import("std");
const assert = std.debug.assert;

const Context = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    determinismo: []const u8,
    machine: []const []const u8,
    bin: []const u8,
    scratch: []const u8,
    /// Babashka, for notebooks ($DETERMINISMO_BB); without it their evaluation is skipped.
    bb: ?[]const u8 = null,
    failures: u32 = 0,
};

/// One branch line of a report: `[branch N] seed=... events_hash=H failing=F ...`.
const Branch = struct { index: u32, events_hash: []const u8, failing: bool };

const branches_max = 64;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    const home = init.environ_map.get("HOME") orelse "/root";
    var bin: []const u8 = "zig-out/bin";
    var guest: []const u8 = try std.fs.path.join(arena, &.{ home, "guest" });
    var cache: []const u8 = try std.fs.path.join(arena, &.{ home, "cache" });
    var only: []const u8 = "";
    var index: usize = 1;
    while (index + 1 < arguments.len) : (index += 2) {
        const flag = arguments[index];
        const value = arguments[index + 1];
        if (std.mem.eql(u8, flag, "--bin")) bin = value else if (std.mem.eql(u8, flag, "--guest")) {
            guest = value;
        } else if (std.mem.eql(u8, flag, "--cache")) {
            cache = value;
        } else if (std.mem.eql(u8, flag, "--only")) {
            only = value;
        } else return error.Usage;
    }
    var context = Context{
        .arena = arena,
        .io = init.io,
        .bb = init.environ_map.get("DETERMINISMO_BB"),
        .determinismo = try std.fs.path.join(arena, &.{ bin, "determinismo" }),
        .machine = &.{
            "--kernel",     try std.fs.path.join(arena, &.{ guest, "vmlinuz" }),
            "--initrd",     try std.fs.path.join(arena, &.{ guest, "base.cpio" }),
            "--memory-mib", "2048",
            "--append",     "quiet",
            "--cache",      cache,
        },
        .bin = bin,
        .scratch = "/tmp/determinismo-e2e",
    };
    std.Io.Dir.cwd().deleteTree(init.io, context.scratch) catch {};
    try std.Io.Dir.cwd().createDirPath(init.io, context.scratch);

    const jar = try std.fs.path.join(arena, &.{ home, "opt", "tla", "tla2tools.jar" });
    const ran = try checks_run(&context, only, jar);
    if (ran == 0) {
        std.debug.print("e2e: no check is named like '{s}'\n", .{only});
        std.process.exit(2);
    }
    if (context.failures > 0) {
        std.debug.print("e2e: {d} checks failed\n", .{context.failures});
        std.process.exit(1);
    }
    std.debug.print("e2e: all checks passed\n", .{});
}

/// Runs the checks whose names contain `only` (all when empty) and counts them.
fn checks_run(context: *Context, only: []const u8, jar: []const u8) !u32 {
    const checks = .{
        .{ "bank", check_bank },                     .{ "shop", check_shop },
        .{ "tapes", check_tapes },                   .{ "python", check_python_strategy },
        .{ "properties", check_builtin_properties }, .{ "entropy", check_kernel_entropy },
        .{ "quiet", check_quiet_period },            .{ "query", check_query },
        .{ "network", check_network_faults },        .{ "serve", check_serve },
        .{ "until", check_until_and_causality },     .{ "coverage", check_coverage },
        .{ "parallel", check_parallel },             .{ "fork", check_fork },
        .{ "tree", check_tree },                     .{ "disk", check_disk },
        .{ "mutate", check_mutate },                 .{ "compose", check_compose },
        .{ "shards", check_shards },                 .{ "stress", check_stress },
        .{ "controller", check_controller },         .{ "clojure", check_clojure },
        .{ "k3s", check_k3s },                       .{ "script", check_script },
        .{ "modulation", check_cpu_modulation },     .{ "profile", check_profile },
        .{ "catalog", check_catalog },               .{ "guidance", check_guidance },
    };
    var ran: u32 = 0;
    inline for (checks) |check| {
        if (std.mem.indexOf(u8, check[0], only) != null) {
            try check[1](context);
            ran += 1;
        }
    }
    if (std.mem.indexOf(u8, "tla", only) != null) {
        try check_tla(context, jar);
        ran += 1;
    }
    return ran;
}

const Example = struct { program: []const u8, scenario: []const u8, branches: u32 };

fn check_bank(context: *Context) !void {
    try check_example(context, .{ .program = "bank-test", .scenario = "bank", .branches = 12 });
}

fn check_shop(context: *Context) !void {
    try check_example(context, .{ .program = "shop-test", .scenario = "prices", .branches = 4 });
}

/// Explores, then replays the first failing branch (if any) and the first passing one alone.
fn check_example(context: *Context, example: Example) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, example.program });
    const branches_text = try std.fmt.allocPrint(context.arena, "{d}", .{example.branches});
    const report = try explore(context, &.{
        "--program",  program,       "--scenario", example.scenario, "--seed", "7",
        "--branches", branches_text,
    });
    var branches: [branches_max]Branch = undefined;
    const count = parse_branches(report, &branches);
    expect(context, count == example.branches, "{s}: explored {d} branches", .{
        example.program, count,
    });
    expect(context, std.mem.indexOf(u8, report, ", 0 overshoots") != null, "{s}: no overshoots", .{
        example.program,
    });
    for ([_]bool{ true, false }) |failing| {
        const branch = for (branches[0..count]) |branch| {
            if (branch.failing == failing) break branch;
        } else continue;
        const index_text = try std.fmt.allocPrint(context.arena, "{d}", .{branch.index});
        const replay = try explore(context, &.{
            "--program", program,    "--scenario", example.scenario, "--seed", "7",
            "--branch",  index_text,
        });
        var replayed: [1]Branch = undefined;
        const same = parse_branches(replay, &replayed) == 1 and
            std.mem.eql(u8, replayed[0].events_hash, branch.events_hash);
        expect(context, same, "{s}: branch {d} ({s}) replays from a fresh boot", .{
            example.program, branch.index, if (failing) "failing" else "passing",
        });
    }
    if (std.mem.eql(u8, example.program, "bank-test")) {
        const found = for (branches[0..count]) |branch| {
            if (branch.failing) break true;
        } else false;
        expect(context, found, "{s}: exploration finds the lost update", .{example.program});
    }
}

/// A strategy's branch replays from its tape alone, and not on different inputs.
fn check_tapes(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "bank-test" });
    const strategy = try std.fs.path.join(context.arena, &.{ context.bin, "det-strategy-mutate" });
    const tapes = try std.fs.path.join(context.arena, &.{ context.scratch, "tapes" });
    const report = try explore(context, &.{
        "--program",  program,  "--scenario", "bank", "--seed", "11", "--branches", "4",
        "--strategy", strategy, "--tape-dir", tapes,
    });
    var branches: [branches_max]Branch = undefined;
    const count = parse_branches(report, &branches);
    expect(context, count == 4, "tapes: explored {d} branches with a strategy", .{count});
    if (count == 0) return;
    const last = branches[count - 1];
    const tape_name = try std.fmt.allocPrint(context.arena, "branch-{d}.jsonl", .{last.index});
    const tape = try std.fs.path.join(context.arena, &.{ tapes, tape_name });
    const replay = try explore(context, &.{
        "--program", program, "--scenario", "bank", "--tape", tape,
    });
    var replayed: [1]Branch = undefined;
    const same = parse_branches(replay, &replayed) == 1 and
        std.mem.eql(u8, replayed[0].events_hash, last.events_hash);
    expect(context, same, "tapes: branch {d} replays from its tape without the strategy", .{
        last.index,
    });
    const elsewhere = try explore(context, &.{
        "--program", program, "--scenario", "bank", "--tape", tape, "--timer-slack-us", "101",
    });
    const refused = std.mem.indexOf(u8, elsewhere, "the tape was recorded with inputs") != null;
    expect(context, refused, "tapes: a replay on different inputs is refused", .{});
}

/// Coverage-guided exploration solves the maze (1 in 10000 timelines by chance): with coverage
/// from the C, Zig, Python and JVM SDKs, one worker or several sharing one corpus, and in
/// Python and Java under faults (decisions and events of other processes interleaved). The
/// solving branch replays from its tape.
fn check_coverage(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const c = [_][]const u8{ "--program", program, "--profile", "maze", "--scenario", "maze" };
    const zig = [_][]const u8{
        "--program", program, "--profile", "maze-zig", "--scenario", "maze",
    };
    const python = [_][]const u8{
        "--compose", "tests/antithesis-compat/python/compose.yaml", "--scenario", "maze",
    };
    const java = [_][]const u8{
        "--compose", "tests/antithesis-compat/java/compose.yaml", "--scenario", "maze",
    };
    const mazes = [_]Maze{
        .{ .label = "C, one worker", .system = &c, .jobs = 1, .branches = 300 },
        .{ .label = "Zig, one worker", .system = &zig, .jobs = 1, .branches = 300 },
        .{ .label = "C, 4 synced workers", .system = &c, .jobs = 4, .branches = 300 },
        .{ .label = "Python, 8 synced workers", .system = &python, .jobs = 8, .branches = 1000 },
        .{ .label = "Java, 8 synced workers", .system = &java, .jobs = 8, .branches = 1000 },
    };
    for (mazes, 0..) |maze, index| try check_maze(context, maze, index);
}

const Maze = struct { label: []const u8, system: []const []const u8, jobs: u32, branches: u32 };

fn check_maze(context: *Context, maze: Maze, index: usize) !void {
    const arena = context.arena;
    const mutate = try std.fs.path.join(arena, &.{ context.bin, "det-strategy-mutate" });
    const tapes = try std.fmt.allocPrint(arena, "{s}/maze-{d}-tapes", .{ context.scratch, index });
    const sync = try std.fmt.allocPrint(arena, "{s}/maze-{d}-sync", .{ context.scratch, index });
    const strategy = if (maze.jobs == 1)
        mutate
    else
        try std.fmt.allocPrint(arena, "{s} --sync-dir {s}", .{ mutate, sync });
    var arguments: std.ArrayList([]const u8) = .empty;
    try arguments.appendSlice(arena, maze.system);
    try arguments.appendSlice(arena, &.{
        "--seed",     "1",
        "--branches", try std.fmt.allocPrint(arena, "{d}", .{maze.branches}),
        "--jobs",     try std.fmt.allocPrint(arena, "{d}", .{maze.jobs}),
        "--strategy", strategy,
        "--tape-dir", tapes,
    });
    const report = try explore(context, arguments.items);
    const branches = try arena.alloc(Branch, maze.branches); // One line per branch.
    const count = parse_branches(report, branches);
    const solved = for (branches[0..count]) |branch| {
        if (branch.failing) break branch;
    } else null;
    expect(context, solved != null, "coverage ({s}): guided exploration solves the maze", .{
        maze.label,
    });
    const branch = solved orelse return;
    const tape_name = try std.fmt.allocPrint(arena, "branch-{d}.jsonl", .{branch.index});
    const tape = try std.fs.path.join(arena, &.{ tapes, tape_name });
    var replay_arguments: std.ArrayList([]const u8) = .empty;
    try replay_arguments.appendSlice(arena, maze.system);
    try replay_arguments.appendSlice(arena, &.{ "--tape", tape });
    const replay = try explore(context, replay_arguments.items);
    var replayed: [1]Branch = undefined;
    const same = parse_branches(replay, &replayed) == 1 and replayed[0].failing and
        std.mem.eql(u8, replayed[0].events_hash, branch.events_hash);
    expect(context, same, "coverage ({s}): the solving branch {d} replays from its tape", .{
        maze.label, branch.index,
    });
}

/// A strategy written in Python (found through PATH, as a shell would) steers decisions, and a
/// branch it steered replays from its tape without it.
fn check_python_strategy(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "bank-test" });
    const tapes = try std.fs.path.join(context.arena, &.{ context.scratch, "python-tapes" });
    const common = [_][]const u8{ "--program", program, "--scenario", "bank", "--seed", "3" };
    const report = try explore(context, &(common ++ [_][]const u8{
        "--branches", "12",  "--jobs", "1", "--strategy", "python3 plugins/python/extremes.py",
        "--tape-dir", tapes,
    }));
    var branches: [12]Branch = undefined;
    const count = parse_branches(report, &branches);
    expect(context, count == 12, "python strategy: explored {d} branches", .{count});
    if (count == 0) return;
    // The bandit tries its rates in order: branch 1 overrides 5% of the decisions.
    const tape = try std.fs.path.join(context.arena, &.{ tapes, "branch-1.jsonl" });
    const cwd = std.Io.Dir.cwd();
    const recorded = cwd.readFileAlloc(context.io, tape, context.arena, .limited(1 << 24)) catch "";
    const steered = std.mem.indexOf(u8, recorded, "\"pull\"") != null;
    expect(context, steered, "python strategy: it overrides decisions", .{});
    const replay = try explore(context, &(common ++ [_][]const u8{ "--tape", tape }));
    var replayed: [1]Branch = undefined;
    const same = parse_branches(replay, &replayed) == 1 and
        std.mem.eql(u8, replayed[0].events_hash, branches[1].events_hash);
    expect(context, same, "python strategy: its branch replays from the tape without it", .{});
}

/// Kubernetes (K3s) as the system under test, on one node and as a three-node cluster (pods
/// spread over them): the workload survives faults, and a branch replays exactly.
fn check_k3s(context: *Context) !void {
    try check_k3s_profile(context, "single", "4096", "one node");
    try check_k3s_profile(context, "cluster", "8192", "three nodes");
}

fn check_k3s_profile(
    context: *Context,
    profile: []const u8,
    memory_mib: []const u8,
    label: []const u8,
) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "k3s-test" });
    const common = [_][]const u8{
        "--program",    program,    "--profile", profile, "--scenario", "cluster", "--seed", "1",
        "--memory-mib", memory_mib,
    };
    const arena = context.arena;
    const explored = try std.fmt.allocPrint(arena, "{s}/k3s-{s}", .{ context.scratch, profile });
    const report = try explore(context, &(common ++ [_][]const u8{
        "--branches", "4", "--events-dir", explored,
    }));
    const passes = std.mem.indexOf(u8, report, "4 branches, 0 with failing properties") != null;
    expect(context, passes, "k3s ({s}): the workload survives faults in 4 branches", .{label});
    var branches: [4]Branch = undefined;
    const count = parse_branches(report, &branches);
    if (count == 0) return;
    const index = try std.fmt.allocPrint(arena, "{d}", .{branches[0].index});
    const replayed_events = try std.fmt.allocPrint(arena, "{s}-replay.jsonl", .{explored});
    const replay = try explore(context, &(common ++ [_][]const u8{
        "--branch", index, "--events", replayed_events,
    }));
    var replayed: [1]Branch = undefined;
    const same = parse_branches(replay, &replayed) == 1 and
        std.mem.eql(u8, replayed[0].events_hash, branches[0].events_hash);
    expect(context, same, "k3s ({s}): branch {d} replays exactly", .{ label, branches[0].index });
    if (!same) {
        const original = try std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{
            explored, branches[0].index,
        });
        first_difference(context, original, replayed_events);
    }
}

/// Prints where two event logs part: what a replay did differently.
fn first_difference(context: *Context, a_path: []const u8, b_path: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    const limit: std.Io.Limit = .limited(1 << 28);
    const a = cwd.readFileAlloc(context.io, a_path, context.arena, limit) catch return;
    const b = cwd.readFileAlloc(context.io, b_path, context.arena, limit) catch return;
    var a_lines = std.mem.splitScalar(u8, a, '\n');
    var b_lines = std.mem.splitScalar(u8, b, '\n');
    var line: u32 = 1;
    while (true) : (line += 1) {
        const left = a_lines.next() orelse "<end>";
        const right = b_lines.next() orelse "<end>";
        if (std.mem.eql(u8, left, "<end>") and std.mem.eql(u8, right, "<end>")) return;
        if (std.mem.eql(u8, left, right)) continue;
        std.debug.print("  first difference, line {d}:\n    explored: {s}\n    replayed: {s}\n", .{
            line, left[0..@min(left.len, 400)], right[0..@min(right.len, 400)],
        });
        return;
    }
}

/// Every branch's events, queried as Antithesis's Logs Explorer does: the failing timelines are
/// found, node output is searchable, and a temporal condition splits the violations exactly
/// (those preceded by a fault and those not add up to all).
fn check_query(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "bank-test" });
    const events = try std.fs.path.join(context.arena, &.{ context.scratch, "query-events" });
    const report = try explore(context, &.{
        "--program",    program, "--scenario", "bank", "--seed", "3", "--branches", "16",
        "--events-dir", events,
    });
    const failing_report = std.mem.indexOf(u8, report, "with failing properties") != null;
    const violation = "assert.message=\"total balance is conserved\" assert.condition=false";
    const all = try query_count(context, &.{ events, violation });
    const fault = "event=fault";
    const after_fault = try query_count(context, &.{ events, violation, "--preceded-by", fault });
    const no_fault = try query_count(context, &.{ events, violation, "--not-preceded-by", fault });
    const output = try query_count(context, &.{ events, "output.source=redis" });
    // A regular expression finds the same lines.
    const matched = try query_count(context, &.{ events, "output.source=~^re(d|x)i[s]$" });
    const found = failing_report and all > 0 and output > 0 and after_fault + no_fault == all and
        matched == output;
    expect(context, found, "query: {d} violations ({d} after a fault, {d} without), {d} redis " ++
        "output lines ({d} by a regex)", .{ all, after_fault, no_fault, output, matched });
    // Event sets: the same answers through a pipeline (with_last), and through a program.
    const arena = context.arena;
    const annotated = try std.fmt.allocPrint(arena, "[{{\"filter\": {f}}}, " ++
        "{{\"with_last\": {{\"fault\": \"event=fault\"}}}}, {{\"filter\": \"last_fault?\"}}]", .{
        std.json.fmt(violation, .{}),
    });
    const with_last = try events_count(context, &.{ events, annotated });
    const piped = try std.fmt.allocPrint(arena, "[{{\"filter\": {f}}}, " ++
        "{{\"through\": \"cat\"}}]", .{std.json.fmt(violation, .{})});
    const through = try events_count(context, &.{ events, piped });
    expect(context, with_last == after_fault and through == all, "event sets: with_last finds " ++
        "{d} violations after a fault, a program passes {d} through", .{ with_last, through });
}

/// How many events `determinismo events` gives (its --count line).
fn events_count(context: *Context, arguments: []const []const u8) !u64 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(context.arena, &.{ context.determinismo, "events" });
    try argv.appendSlice(context.arena, arguments);
    try argv.append(context.arena, "--count");
    const result = try std.process.run(context.arena, context.io, .{ .argv = argv.items });
    const end = std.mem.indexOfScalar(u8, result.stdout, ' ') orelse return 0;
    return std.fmt.parseInt(u64, result.stdout[0..end], 10) catch 0;
}

/// The HTTP API and its web UI: `serve` answers with the page, starts a run, records every
/// branch's events, and answers queries about them.
fn check_serve(context: *Context) !void {
    const arena = context.arena;
    const address = "127.0.0.1:7891";
    const data = try std.fs.path.join(arena, &.{ context.scratch, "serve" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "serve", "--listen", address });
    try argv.appendSlice(arena, &.{ "--data", data });
    if (context.bb) |bb| try argv.appendSlice(arena, &.{ "--bb", bb });
    try argv.appendSlice(arena, context.machine);
    var server = try std.process.spawn(context.io, .{
        .argv = argv.items,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer server.kill(context.io);
    const url = "http://" ++ address;
    var page: []const u8 = "";
    for (0..50) |_| {
        page = curl(context, &.{url ++ "/"}) catch "";
        if (page.len > 0) break;
        sleep_ms(100);
    }
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const body = try std.fmt.allocPrint(arena, "{{\"program\":{f},\"scenario\":\"bank\"," ++
        "\"seed\":3,\"branches\":8}}", .{std.json.fmt(program, .{})});
    _ = try curl(context, &.{ "-X", "POST", "-d", body, url ++ "/runs" });
    var run: []const u8 = "";
    for (0..600) |_| {
        run = try curl(context, &.{url ++ "/runs/1"});
        if (std.mem.indexOf(u8, run, "\"state\":\"running\"") == null) break;
        sleep_ms(200);
    }
    const asked = "{\"condition\":\"output.source=redis\",\"output\":\"count\"}";
    const answer = try curl(context, &.{ "-X", "POST", "-d", asked, url ++ "/runs/1/query" });
    const discovery = try curl(context, &.{url ++ "/runs/1/discovery"});
    const curve = std.mem.indexOf(u8, discovery, "[8,") != null; // A point after 8 branches.
    const ui = std.mem.indexOf(u8, page, "<title>determinismo</title>") != null and curve;
    const finished = std.mem.indexOf(u8, run, "\"summary\"") != null;
    const queried = std.mem.indexOf(u8, answer, "\"events\":") != null and
        std.mem.indexOf(u8, answer, "\"events\":0,") == null;
    expect(context, ui and finished and queried, "serve: the UI, a run over HTTP, and a query " ++
        "of its events ({s})", .{std.mem.trim(u8, answer, "\n")});
    // The run's notebook: none at first, then what was saved.
    const empty = try curl(context, &.{url ++ "/runs/1/notebook"});
    const cells = "{\"source\":\"print(1)\\n// %%\\nprint(2)\"}";
    _ = try curl(context, &.{ "-X", "PUT", "-d", cells, url ++ "/runs/1/notebook" });
    const saved = try curl(context, &.{url ++ "/runs/1/notebook"});
    const notebook = std.mem.indexOf(u8, empty, "\"source\":null") != null and
        std.mem.indexOf(u8, saved, "print(1)\\n// %%\\nprint(2)") != null;
    const in_page = std.mem.indexOf(u8, page, "notebookEvaluate") != null;
    expect(context, notebook and in_page, "serve: the notebook is kept with the run", .{});
    // Clojure cells, evaluated with babashka: a query of the run's events, and a value.
    if (context.bb == null) {
        std.debug.print("SKIP serve: notebook evaluation ($DETERMINISMO_BB is not set)\n", .{});
        return;
    }
    const evaluate = "{\"cells\":[\"(def failing (query \\\"assert.condition=false\\\"))\"," ++
        "\"(pos? (count failing))\"],\"results\":{}}";
    const evaluated = try curl(context, &.{
        "-X", "POST", "-d", evaluate, url ++ "/runs/1/notebook/evaluate",
    });
    const found = std.mem.indexOf(u8, evaluated, "\"type\":\"edn\",\"text\":\"true\"") != null;
    expect(context, found, "serve: a Clojure notebook queries the run ({s})", .{
        evaluated[0..@min(evaluated.len, 300)],
    });
}

fn curl(context: *Context, arguments: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    const json = "Content-Type: application/json";
    try argv.appendSlice(context.arena, &.{ "curl", "-s", "--fail", "-H", json });
    try argv.appendSlice(context.arena, arguments);
    const result = try std.process.run(context.arena, context.io, .{ .argv = argv.items });
    if (!result.term.success()) return error.RequestFailed;
    return result.stdout;
}

fn sleep_ms(duration_ms: u64) void {
    const request = std.os.linux.timespec{
        .sec = @intCast(duration_ms / 1000),
        .nsec = @intCast((duration_ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.os.linux.nanosleep(&request, null);
}

/// `--until` (Antithesis's wait_until) stops a branch at its first violation and runs a command
/// there, the same on every replay; causality analysis measures the failure's probability at
/// moments before it (certain at the failure itself).
fn check_until_and_causality(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const system = [_][]const u8{ "--program", program, "--scenario", "bank", "--seed", "3" };
    const violation = "assert.message=\"total balance is conserved\" assert.condition=false";
    var outputs: [2][]const u8 = undefined;
    for (&outputs) |*output| {
        const read = "det-nodes exec redis redis-cli mget account:0 account:1";
        const report = try explore(context, &(system ++ [_][]const u8{
            "--branch", "4", "--until", violation, "--exec", read,
        }));
        output.* = try lines_with(arena, report, &.{ "at moment", "exec_output" });
    }
    const stopped = std.mem.indexOf(u8, outputs[0], "exec_output") != null and
        std.mem.eql(u8, outputs[0], outputs[1]);
    expect(context, stopped, "until: branch 4 stops at its first violation, the same twice", .{});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "causality" });
    try argv.appendSlice(arena, context.machine);
    try argv.appendSlice(arena, &system);
    try argv.appendSlice(arena, &.{
        "--branch",  "4", "--property", "total balance is conserved", "--points", "4",
        "--futures", "8", "--json",
    });
    const result = try std.process.run(arena, context.io, .{ .argv = argv.items });
    const Point = struct { vtime_ms: u64, probability: f64 };
    var points: u32 = 0;
    var last: f64 = 0;
    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const point = std.json.parseFromSliceLeaky(Point, arena, line, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        if (point.probability < 0 or point.probability > 1) break;
        points += 1;
        last = point.probability;
    }
    expect(context, points == 4 and last == 1, "causality: {d} moments, certain at the " ++
        "failure ({d:.2})", .{ points, last });
    try check_files(context, &system, violation);
    try check_rewind(context, &system, violation);
}

/// The profiler at a moment of the self-test's echo node (a static Zig binary, with symbols):
/// samples, named functions, and the same profile twice.
fn check_profile(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest" });
    const system = [_][]const u8{ "--program", program, "--scenario", "steady", "--seed", "1" };
    var folded: [2][]const u8 = undefined;
    for (&folded, 0..) |*text, run| {
        const name = try std.fmt.allocPrint(arena, "profile-{d}.folded", .{run});
        const path = try std.fs.path.join(arena, &.{ context.scratch, name });
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ context.determinismo, "profile" });
        try argv.appendSlice(arena, context.machine);
        try argv.appendSlice(arena, &system);
        try argv.appendSlice(arena, &.{ "--branch", "0", "--at-vtime-ms", "1050" });
        try argv.appendSlice(arena, &.{ "--node", "echo", "--ms", "100", "--all" });
        try argv.appendSlice(arena, &.{ "--folded", path });
        _ = try std.process.run(arena, context.io, .{ .argv = argv.items });
        const cwd = std.Io.Dir.cwd();
        text.* = cwd.readFileAlloc(context.io, path, arena, .limited(1 << 22)) catch "";
    }
    const samples = number_after(folded[0], "# det-profile: ") orelse 0;
    // Some stack ends in a named function, not an address.
    var named = false;
    var lines = std.mem.tokenizeScalar(u8, folded[0], '\n');
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        const end = std.mem.lastIndexOfScalar(u8, line, ' ') orelse continue;
        const start = (std.mem.lastIndexOfScalar(u8, line[0..end], ';') orelse continue) + 1;
        named = named or std.mem.indexOf(u8, line[start..end], "0x") == null;
    }
    const same = std.mem.eql(u8, folded[0], folded[1]);
    expect(context, samples > 0 and named and same, "profile: {d} samples of a node at a " ++
        "moment, functions named, the same twice", .{samples});
    // Every thread's stack at the same moment.
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "stacks" });
    try argv.appendSlice(arena, context.machine);
    try argv.appendSlice(arena, &system);
    try argv.appendSlice(arena, &.{ "--branch", "0", "--at-vtime-ms", "1050", "--node", "echo" });
    const result = try std.process.run(arena, context.io, .{ .argv = argv.items });
    const stacks = std.mem.indexOf(u8, result.stderr, " thread ") != null and
        std.mem.indexOf(u8, result.stderr, "#0  ") != null and
        std.mem.indexOf(u8, result.stderr, "_start") != null;
    expect(context, stacks, "stacks: every thread of a node at a moment, named", .{});
}

/// Rewind: 5 ms of virtual time before the first violation, where it has not happened yet.
fn check_rewind(context: *Context, system: []const []const u8, violation: []const u8) !void {
    var extra: std.ArrayList([]const u8) = .empty;
    try extra.appendSlice(context.arena, system);
    try extra.appendSlice(context.arena, &.{
        "--branch", "4", "--until", violation, "--rewind-ms", "5", "--exec", "echo rewound",
    });
    const report = try explore(context, extra.items);
    const holds: u64 = @intFromFloat(number_after(report, "the condition holds at ") orelse 0);
    const target: u64 = @intFromFloat(number_after(report, "; the moment is ") orelse 0);
    const last = std.mem.lastIndexOf(u8, report, "at moment vtime=") orelse 0;
    const reached: u64 = @intFromFloat(number_after(report[last..], "at moment vtime=") orelse 0);
    const exact = holds > target and holds - target == 5 * std.time.ns_per_ms and
        reached >= target and reached - target < std.time.ns_per_ms;
    const ran = std.mem.indexOf(u8, report, "\"text\":\"rewound\\n\"") != null;
    const before = std.mem.indexOf(u8, report, "failing=0") != null;
    expect(context, exact and ran and before, "rewind: 5 ms before the violation " ++
        "({d}ns, then {d}ns), not failing yet", .{ holds, reached });
    // wait_until's timeout: the condition, or this time at the latest (here, before it holds:
    // just after the setup snapshot, wherever the guest's setup put it).
    const snapshot_ms = snapshot_vtime_ms(report) orelse 0;
    const deadline = try std.fmt.allocPrint(context.arena, "{d}", .{snapshot_ms + 20});
    var timeout: std.ArrayList([]const u8) = .empty;
    try timeout.appendSlice(context.arena, system);
    try timeout.appendSlice(context.arena, &.{
        "--branch", "4", "--until", violation, "--at-vtime-ms", deadline, "--exec", "echo late",
    });
    const timed = try explore(context, timeout.items);
    const expected = try std.fmt.allocPrint(context.arena, "at moment vtime={d}", .{
        snapshot_ms + 20,
    });
    const late = std.mem.indexOf(u8, timed, "until: timed out") != null and
        std.mem.indexOf(u8, timed, expected) != null;
    expect(context, late, "until: with a timeout, the moment is the timeout when the " ++
        "condition has not held", .{});
}

/// extract_file and inject_file at the first violation of branch 4.
fn check_files(context: *Context, system: []const []const u8, violation: []const u8) !void {
    const arena = context.arena;
    // extract_file: a node's file at that moment, byte for byte (Redis's own config here).
    const extracted = try std.fs.path.join(arena, &.{ context.scratch, "extracted" });
    var extract_argv: std.ArrayList([]const u8) = .empty;
    try extract_argv.appendSlice(arena, &.{ context.determinismo, "extract" });
    try extract_argv.appendSlice(arena, context.machine);
    try extract_argv.appendSlice(arena, system);
    try extract_argv.appendSlice(arena, &.{
        "--branch", "4",       "--until", violation, "--file", "redis:/etc/hostname",
        "--to",     extracted,
    });
    _ = try std.process.run(arena, context.io, .{ .argv = extract_argv.items });
    const cwd = std.Io.Dir.cwd();
    const hostname = cwd.readFileAlloc(context.io, extracted, arena, .limited(64)) catch "";
    expect(context, std.mem.eql(u8, hostname, "redis\n"), "extract: a node's file at a moment " ++
        "({d} bytes)", .{hostname.len});
    // inject_file: 10000 arbitrary bytes into the node at that moment (three moment commands
    // of base64 and more), then a command there sees them, byte for byte.
    var bytes: [10_000]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(index *% 2654435761 >> 7);
    const local = try std.fs.path.join(arena, &.{ context.scratch, "to-inject" });
    try cwd.writeFile(context.io, .{ .sub_path = local, .data = &bytes });
    var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(&bytes, &digest, .{});
    var inject_argv: std.ArrayList([]const u8) = .empty;
    try inject_argv.appendSlice(arena, &.{ context.determinismo, "inject" });
    try inject_argv.appendSlice(arena, context.machine);
    try inject_argv.appendSlice(arena, system);
    try inject_argv.appendSlice(arena, &.{
        "--branch", "4", "--until", violation, "--file", "redis:/tmp/injected", "--from", local,
    });
    try inject_argv.appendSlice(arena, &.{
        "--then", "md5sum /proc/$(cat /run/det/nodes/redis/pid)/root/tmp/injected",
    });
    const injected = try std.process.run(arena, context.io, .{ .argv = inject_argv.items });
    const hex = std.fmt.bytesToHex(digest, .lower);
    const seen = std.mem.indexOf(u8, injected.stderr, &hex) != null;
    expect(context, seen, "inject: {d} bytes into a node at a moment, the same there", .{
        bytes.len,
    });
}

/// The lines of `text` containing any of `keys`, joined.
fn lines_with(arena: std.mem.Allocator, text: []const u8, keys: []const []const u8) ![]const u8 {
    var kept: std.ArrayList(u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        for (keys) |key| {
            if (std.mem.indexOf(u8, line, key) == null) continue;
            try kept.appendSlice(arena, line);
            try kept.append(arena, '\n');
            break;
        }
    }
    return kept.items;
}

/// Antithesis's network faults: partitions into groups and clogs, with their disruption forms,
/// recorded in full; a branch with one replays exactly.
fn check_network_faults(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "shop-test" });
    const events = try std.fs.path.join(arena, &.{ context.scratch, "fault-events" });
    const system = [_][]const u8{ "--program", program, "--scenario", "prices", "--seed", "2" };
    // Flat: one baseline per timeline, and any of them replays by its index.
    _ = try explore(context, &(system ++ [_][]const u8{
        "--branches", "64", "--events-dir", events, "--branching", "flat",
    }));
    const partition = "event=fault details.kind=partition_groups";
    const groups = try query_count(context, &.{ events, partition });
    const clogs = try query_count(context, &.{ events, "event=fault details.kind=clog" });
    const threads = try query_count(context, &.{ events, "event=fault details.kind=thread_pause" });
    const baselines = try query_count(context, &.{ events, "event=network_baseline" });
    // A restore is logged only while network faults are under way: they overlap the next fault.
    const restores = try query_count(context, &.{ events, "event=fault details.kind=restore" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        context.determinismo, "query",  events, "event=fault details.kind=partition_groups",
        "--branches",         "--json",
    });
    const found = try std.process.run(arena, context.io, .{ .argv = argv.items });
    const First = struct { branch: u32 };
    const line_end = std.mem.indexOfScalar(u8, found.stdout, '\n') orelse found.stdout.len;
    const first = std.json.parseFromSliceLeaky(First, arena, found.stdout[0..line_end], .{
        .ignore_unknown_fields = true,
    }) catch null;
    var same = false;
    if (first) |branch_found| {
        const index = try std.fmt.allocPrint(arena, "{d}", .{branch_found.branch});
        var hashes: [2]Branch = undefined;
        for (&hashes) |*hash| {
            const report = try explore(context, &(system ++ [_][]const u8{
                "--branch", index, "--branching", "flat",
            }));
            var one: [1]Branch = undefined;
            if (parse_branches(report, &one) == 1) hash.* = one[0];
        }
        same = std.mem.eql(u8, hashes[0].events_hash, hashes[1].events_hash);
    }
    const all = groups > 0 and clogs > 0 and threads > 0 and baselines == 64 and
        restores > 0 and same;
    expect(context, all, "faults: {d} partitions into groups, {d} clogs, {d} thread pauses, " ++
        "{d} network baselines, {d} restores of overlapping network faults; a branch with a " ++
        "partition replays exactly", .{ groups, clogs, threads, baselines, restores });
}

/// How many events `determinismo query` finds (its --count line).
fn query_count(context: *Context, arguments: []const []const u8) !u64 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(context.arena, &.{ context.determinismo, "query" });
    try argv.appendSlice(context.arena, arguments);
    try argv.append(context.arena, "--count");
    const result = try std.process.run(context.arena, context.io, .{ .argv = argv.items });
    const end = std.mem.indexOfScalar(u8, result.stdout, ' ') orelse return 0;
    return std.fmt.parseInt(u64, result.stdout[0..end], 10) catch 0;
}

/// Antithesis's pausing faults: a driver asks for a quiet period from inside a node, and no
/// fault (but clock skips) starts during it, while faults happen before it.
fn check_quiet_period(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const events = try std.fs.path.join(context.arena, &.{ context.scratch, "quiet-events" });
    _ = try explore(context, &.{
        "--program",  program, "--profile",    "workers", "--scenario", "quiet", "--seed", "1",
        "--branches", "4",     "--events-dir", events,
    });
    const quiet = try query_count(context, &.{ events, "event=faults_quiet" });
    // Custom faults ran in the node, which finds det-stop-faults in its environment.
    const custom = try query_count(context, &.{
        events, "event=custom_fault_ran details.stop_faults=/opt/determinismo/bin/det-stop-faults",
    });
    const faults = try query_count(context, &.{ events, "event=fault" });
    const during = try query_count(context, &.{
        events,               "event=fault details.kind!=clock_skip", "--preceded-by",
        "event=faults_quiet", "--within",                             "1.9",
    });
    const counts = .{ quiet, faults, during, custom };
    expect(context, quiet == 4 and faults > 0 and during == 0 and custom > 0, "quiet periods: " ++
        "requested from a node in {d} of 4 timelines; {d} faults, {d} during them; {d} custom " ++
        "faults", counts);
}

/// The guest kernel's random generator after the snapshot: different in every branch, the same
/// when a branch replays.
fn check_kernel_entropy(context: *Context) !void {
    var values: [3][]const u8 = undefined;
    for ([_][]const u8{ "0", "1", "0" }, &values, 0..) |branch, *value, run| {
        const name = try std.fmt.allocPrint(context.arena, "entropy-{d}.jsonl", .{run});
        const events = try std.fs.path.join(context.arena, &.{ context.scratch, name });
        const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
        _ = try explore(context, &.{
            "--program", program, "--scenario", "steady", "--seed", "1", "--branch", branch,
            "--events",  events,
        });
        const cwd = std.Io.Dir.cwd();
        const log = cwd.readFileAlloc(
            context.io,
            events,
            context.arena,
            .limited(1 << 24),
        ) catch "";
        const key = "\"kernel_entropy\",\"details\":{\"value\":";
        const at = std.mem.indexOf(u8, log, key) orelse {
            value.* = "";
            continue;
        };
        const start = at + key.len;
        const end = std.mem.indexOfScalarPos(u8, log, start, '}') orelse start;
        value.* = log[start..end];
    }
    const found = values[0].len > 0 and values[1].len > 0;
    const differs = found and !std.mem.eql(u8, values[0], values[1]);
    const replays = found and std.mem.eql(u8, values[0], values[2]);
    expect(context, differs and replays, "kernel randomness: {s} and {s} in two branches, " ++
        "{s} on replay", .{ values[0], values[1], values[2] });
}

/// The built-in properties pass on a steady system and catch a node that exits by itself and an
/// OOM kill.
fn check_builtin_properties(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const steady = try explore(context, &.{
        "--program", program, "--scenario", "steady", "--seed", "1", "--branches", "2",
    });
    const passes = std.mem.indexOf(u8, steady, "2 branches, 0 with failing properties") != null;
    expect(context, passes, "built-in properties pass on a steady system", .{});
    const both = try explore(context, &.{
        "--program", program, "--profile",  "default,mutant", "--scenario", "steady",
        "--seed",    "1",     "--branches", "2",
    });
    const killed = std.mem.indexOf(u8, both, "PASS default") != null and
        std.mem.indexOf(u8, both, "FAIL mutant") != null;
    expect(context, killed, "mutation: the tests pass on the system and catch its mutant", .{});
    const crash = try explore(context, &.{
        "--program", program, "--scenario", "node_exit", "--seed", "1", "--branches", "1",
    });
    const caught = std.mem.indexOf(u8, crash, "FAIL \"nodes do not exit unexpectedly\"") != null;
    expect(context, caught, "built-in properties catch a node that exits", .{});
    const hog = try explore(context, &.{
        "--program",  program, "--profile", "memory", "--scenario", "oom", "--seed", "1",
        "--branches", "1",
    });
    const workers = try explore(context, &.{
        "--program",  program, "--profile", "workers", "--scenario", "steady", "--seed", "1",
        "--branches", "8",
    });
    const all_pass = "8 branches, 0 with failing properties";
    const replaced = std.mem.indexOf(u8, workers, all_pass) != null and
        std.mem.indexOf(u8, workers, "PASS reachable") != null;
    expect(context, replaced, "process kills hit workers, never a node's main process", .{});
    const oom = "FAIL \"the kernel kills no process for lack of memory\"";
    const oom_caught = std.mem.indexOf(u8, hog, oom) != null and
        std.mem.indexOf(u8, hog, "FAIL \"the hog is killed\"") == null;
    expect(context, oom_caught, "built-in properties catch an OOM kill in a node", .{});
    const crashed = try explore(context, &.{
        "--program", program, "--scenario", "crash", "--seed", "1", "--branches", "1",
    });
    const crash_caught = std.mem.indexOf(u8, crashed, "FAIL \"no process crashes") != null;
    expect(context, crash_caught, "built-in properties catch a crash (SIGSEGV) in a node", .{});
    try check_core_dump(context, program);
}

/// The crash leaves a core dump, which `extract` takes out of the runner at a later moment.
fn check_core_dump(context: *Context, program: []const u8) !void {
    const arena = context.arena;
    const events = try std.fs.path.join(arena, &.{ context.scratch, "crash.jsonl" });
    const system = [_][]const u8{ "--program", program, "--scenario", "crash", "--seed", "1" };
    _ = try explore(context, &(system ++ [_][]const u8{ "--branch", "0", "--events", events }));
    const cwd = std.Io.Dir.cwd();
    const log = cwd.readFileAlloc(context.io, events, arena, .limited(1 << 24)) catch "";
    const key = "\"event\":\"core_dump\"";
    const at = std.mem.indexOf(u8, log, key) orelse {
        expect(context, false, "core dump: a crash leaves one", .{});
        return;
    };
    const path_key = "\"path\":\"";
    const path_start = (std.mem.indexOfPos(u8, log, at, path_key) orelse at) + path_key.len;
    const path_end = std.mem.indexOfScalarPos(u8, log, path_start, '"') orelse path_start;
    const core_path = log[path_start..path_end];
    const local = try std.fs.path.join(arena, &.{ context.scratch, "core" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "extract" });
    try argv.appendSlice(arena, context.machine);
    try argv.appendSlice(arena, &system);
    const file = try std.fmt.allocPrint(arena, "runner:{s}", .{core_path});
    try argv.appendSlice(arena, &.{ "--branch", "0", "--until", "event=core_dump" });
    try argv.appendSlice(arena, &.{ "--file", file, "--to", local });
    _ = try std.process.run(arena, context.io, .{ .argv = argv.items });
    const core = cwd.readFileAlloc(context.io, local, arena, .limited(1 << 28)) catch "";
    const elf = core.len > 4 and std.mem.eql(u8, core[0..4], "\x7fELF");
    expect(context, elf, "core dump: {s}, {d} bytes, an ELF core, extracted at a moment", .{
        core_path, core.len,
    });
}

/// CPU modulation: the same seed's timelines change (preemption lands elsewhere), the bug is
/// still found, and a modulated branch replays exactly.
fn check_cpu_modulation(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "bank-test" });
    const system = [_][]const u8{ "--program", program, "--scenario", "bank", "--seed", "7" };
    const plain = try explore(context, &(system ++ [_][]const u8{ "--branches", "8" }));
    const modulated = try explore(context, &(system ++ [_][]const u8{
        "--branches", "8", "--cpu-modulation",
    }));
    var before: [8]Branch = undefined;
    var after: [8]Branch = undefined;
    const count = parse_branches(plain, &before);
    const count_modulated = parse_branches(modulated, &after);
    // Workers finish in any order: branches pair by index.
    var changed: u32 = 0;
    var third: []const u8 = "";
    for (after[0..count_modulated]) |b| {
        if (b.index == 3) third = b.events_hash;
        for (before[0..count]) |a| {
            if (a.index != b.index) continue;
            changed += @intFromBool(!std.mem.eql(u8, a.events_hash, b.events_hash));
        }
    }
    const failing = std.mem.indexOf(u8, modulated, "failing=1") != null;
    var replays: [2]Branch = undefined;
    for (&replays) |*replay| {
        const report = try explore(context, &(system ++ [_][]const u8{
            "--branch", "3", "--cpu-modulation",
        }));
        var one: [1]Branch = undefined;
        replay.* = if (parse_branches(report, &one) == 1) one[0] else .{
            .index = 0,
            .events_hash = "",
            .failing = false,
        };
    }
    const exact = count_modulated == 8 and third.len > 0 and
        std.mem.eql(u8, replays[0].events_hash, third) and
        std.mem.eql(u8, replays[1].events_hash, third);
    expect(context, changed > 0 and failing and exact, "cpu modulation: {d} of {d} timelines " ++
        "change, the bug is found, branch 3 replays exactly", .{ changed, count });
}

/// The assertion catalog: an assertion no timeline evaluates fails, known from the catalog the
/// test program announced as it started; the C node announced its own.
fn check_catalog(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest-catalog" });
    const events = try std.fs.path.join(arena, &.{ context.scratch, "catalog.jsonl" });
    const report = try explore(context, &.{
        "--program", program, "--scenario", "catalog", "--seed", "1", "--branch", "0",
        "--events",  events,
    });
    // The catalog's verdict comes last: the line after its header names the assertion.
    const verdict = std.mem.indexOf(u8, report, "not reached in any scenario") orelse report.len;
    const failed = std.mem.indexOf(u8, report[verdict..], "FAIL sometimes") != null and
        std.mem.indexOf(u8, report[verdict..], "catalog: a branch no timeline takes") != null;
    const cwd = std.Io.Dir.cwd();
    const log = cwd.readFileAlloc(context.io, events, arena, .limited(1 << 24)) catch "";
    const declared_c = std.mem.indexOf(u8, log, "\"message\":\"the C SDK's randomness stays " ++
        "below its bound\",\"hit\":false") != null;
    expect(context, failed and declared_c, "catalog: an assertion no timeline evaluates fails " ++
        "from the catalog alone; the C node announces its own", .{});
    // Zig assertions carry their place in the code, from the program's debug info.
    const place = "catalog_test.zig\",\"line\":26,\"function\":";
    const located = std.mem.indexOf(u8, log, place) != null;
    expect(context, located, "catalog: a Zig assertion's event says where it is (file, line)", .{});
    if (!located or !failed or !declared_c) std.debug.print("{s}\n", .{report});
}

/// Guidance: four digits must add up to 35 (5 timelines in 10000), one comparison that coverage
/// cannot see into. 300 timelines miss it by chance; with the guidance assertion's distance,
/// det-strategy-mutate climbs to it.
fn check_guidance(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest" });
    const common = [_][]const u8{
        "--program",  program, "--profile", "maze-sum", "--scenario", "maze", "--seed", "3",
        "--branches", "300",
    };
    const property = "PASS sometimes             hit in  300/300 branches, failing in    0  " ++
        "maze sum";
    const random = try explore(context, &common);
    const sync = try std.fmt.allocPrint(arena, "{s}/guidance-sync", .{context.scratch});
    try std.Io.Dir.cwd().createDirPath(context.io, sync);
    const strategy = try std.fmt.allocPrint(arena, "{s}/det-strategy-mutate --sync-dir {s}", .{
        context.bin, sync,
    });
    const guided = try explore(context, &(common ++ [_][]const u8{ "--strategy", strategy }));
    const missed = std.mem.indexOf(u8, random, property) == null;
    const found = std.mem.indexOf(u8, guided, property) != null;
    expect(context, missed and found, "guidance: 300 random timelines miss the sum maze; " ++
        "guided by its distance, the strategy solves it", .{});
}

/// The tree explorer: timelines return to moments of earlier ones (a path at least one deep);
/// the tree is the same with one worker or four; and a timeline of the greatest depth replays
/// alone, exactly, from its tape (which holds its path).
fn check_tree(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const tapes = try std.fmt.allocPrint(arena, "{s}/tree-tapes", .{context.scratch});
    const record = try std.fmt.allocPrint(arena, "{s}/tree.jsonl", .{context.scratch});
    const common = [_][]const u8{
        "--program",   program, "--scenario", "bank", "--seed", "5", "--branches", "40",
        "--branching", "tree",
    };
    const one = try explore(context, &(common ++ [_][]const u8{
        "--jobs", "1", "--tape-dir", tapes, "--record", record,
    }));
    const many = try explore(context, &(common ++ [_][]const u8{ "--jobs", "4" }));
    var sequential: [branches_max]Branch = undefined;
    var parallel: [branches_max]Branch = undefined;
    const count = parse_branches(one, &sequential);
    const same = count == 40 and parse_branches(many, &parallel) == count and
        same_timelines(sequential[0..count], parallel[0..count]);
    const deep = try deepest_replays(context, program, record, tapes, sequential[0..count]);
    expect(context, same and deep.depth >= 1 and deep.replays, "tree: {d} timelines, up to " ++
        "{d} deep, the same with one worker or four; #{?d} replays alone from its tape", .{
        count, deep.depth, deep.index,
    });
    // With a strategy (overriding decisions): nodes replay their parents with their tapes, and
    // a deep timeline still replays alone, without the strategy.
    const strategy_tapes = try std.fmt.allocPrint(arena, "{s}/tree-strategy-tapes", .{
        context.scratch,
    });
    const strategy_record = try std.fmt.allocPrint(arena, "{s}/tree-strategy.jsonl", .{
        context.scratch,
    });
    const steered = try explore(context, &(common ++ [_][]const u8{
        "--jobs",     "2",            "--strategy", "python3 plugins/python/extremes.py",
        "--tape-dir", strategy_tapes, "--record",   strategy_record,
    }));
    var steered_branches: [branches_max]Branch = undefined;
    const steered_count = parse_branches(steered, &steered_branches);
    const steered_deep = try deepest_replays(
        context,
        program,
        strategy_record,
        strategy_tapes,
        steered_branches[0..steered_count],
    );
    const steered_ok = steered_count == 40 and steered_deep.depth >= 1 and steered_deep.replays;
    expect(context, steered_ok, "tree with a strategy: {d} timelines, up to {d} deep; #{?d} " ++
        "replays from its tape (its ancestors' decisions from theirs)", .{
        steered_count, steered_deep.depth, steered_deep.index,
    });
}

/// The deepest timeline of a tree exploration (from its record), and whether it replays alone
/// from its tape with the events it had.
fn deepest_replays(
    context: *Context,
    program: []const u8,
    record: []const u8,
    tapes: []const u8,
    explored: []const Branch,
) !struct { index: ?u32, depth: usize, replays: bool } {
    const arena = context.arena;
    const cwd = std.Io.Dir.cwd();
    const lines = cwd.readFileAlloc(context.io, record, arena, .limited(1 << 24)) catch "";
    var deepest: ?u32 = null;
    var depth_max: usize = 0;
    var records = std.mem.tokenizeScalar(u8, lines, '\n');
    while (records.next()) |line| {
        if (!std.mem.startsWith(u8, line, "{\"branch\":")) continue;
        const Step = struct { branch: u32 };
        const Line = struct { branch: struct { index: u32, path: []const Step } };
        const parsed = std.json.parseFromSliceLeaky(Line, arena, line, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        if (parsed.branch.path.len <= depth_max) continue;
        depth_max = parsed.branch.path.len;
        deepest = parsed.branch.index;
    }
    const index = deepest orelse return .{ .index = null, .depth = 0, .replays = false };
    const tape = try std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ tapes, index });
    const replay = try explore(context, &.{
        "--program", program, "--scenario", "bank", "--tape", tape,
    });
    var replayed: [1]Branch = undefined;
    const original = for (explored) |branch| {
        if (branch.index == index) break branch;
    } else null;
    const replays = original != null and parse_branches(replay, &replayed) == 1 and
        std.mem.eql(u8, replayed[0].events_hash, original.?.events_hash);
    return .{ .index = index, .depth = depth_max, .replays = replays };
}

/// A mutation campaign (determinismo mutate): of two mutants, the one that breaks the sums is
/// caught, the one in code nothing runs is not (shell has no line coverage: unnoticed).
fn check_mutate(context: *Context) !void {
    const arena = context.arena;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "mutate" });
    try argv.appendSlice(arena, context.machine);
    const program = try std.fs.path.join(arena, &.{ context.bin, "det-selftest-sum" });
    const out = try std.fmt.allocPrint(arena, "{s}/mutate", .{context.scratch});
    try argv.appendSlice(arena, &.{
        "--program",  program, "--scenario", "sum",                        "--seed", "1",
        "--branches", "4",     "--mutants",  "tests/mutate/mutants.jsonl", "--out",  out,
    });
    const result = try std.process.run(arena, context.io, .{ .argv = argv.items });
    const caught = std.mem.indexOf(u8, result.stdout, "caught     sum subtracts") != null;
    const unnoticed = std.mem.indexOf(u8, result.stdout, "unnoticed  an unused function") != null;
    const counted = std.mem.indexOf(u8, result.stdout, "1 of 2 mutants caught") != null;
    expect(context, caught and unnoticed and counted, "mutate: the mutant that breaks the " ++
        "sums is caught, the one in unused code is not", .{});
    if (!(caught and unnoticed and counted)) {
        std.debug.print("{s}\n{s}\n", .{ result.stdout, result.stderr });
    }
}

/// Disk faults (Antithesis's restarts that keep synced changes, or lose all): a node writes
/// one file synced and one not; a crash keeps the first and loses the second, a wipe loses
/// both, in every timeline (and the timeline replays exactly).
fn check_disk(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const common = [_][]const u8{
        "--program", program, "--profile", "durable", "--scenario", "disk", "--seed", "1",
    };
    const report = try explore(context, &(common ++ [_][]const u8{ "--branches", "3" }));
    const passes = std.mem.indexOf(u8, report, "3 branches, 0 with failing properties") != null and
        std.mem.indexOf(u8, report, "PASS always                hit in    3/3 branches, " ++
            "failing in    0  a crash keeps what was synced and loses the rest") != null;
    var branches: [3]Branch = undefined;
    const count = parse_branches(report, &branches);
    var same = false;
    if (count > 0) {
        const replay = try explore(context, &(common ++ [_][]const u8{ "--branch", "0" }));
        var replayed: [1]Branch = undefined;
        same = parse_branches(replay, &replayed) == 1 and
            same_timelines(&replayed, branches[0..count]);
    }
    expect(context, passes and same, "disk: a crash keeps what was synced and loses the " ++
        "rest, a wipe loses both; a timeline replays exactly", .{});
    if (!passes) std.debug.print("{s}\n", .{lines_with(context.arena, report, &.{
        "FAIL", "fault_failed", "det-nodes",
    }) catch ""});
}

/// Branches give the same timelines whether one worker runs them or one per CPU does.
fn check_parallel(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "bank-test" });
    const common = [_][]const u8{
        "--program", program, "--scenario", "bank", "--seed", "21", "--branches", "8",
    };
    const one = try explore(context, &(common ++ [_][]const u8{ "--jobs", "1" }));
    const many = try explore(context, &(common ++ [_][]const u8{ "--jobs", "4" }));
    var sequential: [branches_max]Branch = undefined;
    var parallel: [branches_max]Branch = undefined;
    const count = parse_branches(one, &sequential);
    const counts_match = count == 8 and parse_branches(many, &parallel) == count;
    const same = counts_match and same_timelines(sequential[0..count], parallel[0..count]);
    expect(context, same, "parallel workers give the timelines of one worker", .{});
}

/// TLA+ trace validation: the buggy service's trace is not a behavior of the spec; once its
/// transfer is patched through the REPL, it is. Needs Java and tla2tools.jar.
fn check_tla(context: *Context, jar: []const u8) !void {
    std.Io.Dir.cwd().access(context.io, jar, .{}) catch {
        std.debug.print("SKIP tla: no {s}\n", .{jar});
        return;
    };
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "clojure-bank-test" });
    const common = [_][]const u8{ "--program", program, "--scenario", "bank", "--seed", "5" };
    const spec = "examples/clojure-bank/tla/Bank.tla";
    const scratch = context.scratch;
    const buggy_events = try std.fs.path.join(context.arena, &.{ scratch, "tla-buggy.jsonl" });
    const buggy = [_][]const u8{ "--branch", "1", "--events", buggy_events };
    _ = try explore(context, &(common ++ buggy));
    const fixed_events = try std.fs.path.join(context.arena, &.{ scratch, "tla-fixed.jsonl" });
    _ = try explore(context, &(common ++ [_][]const u8{
        "--from-branch", "1",                                 "--from-vtime-ms", "3700",
        "--from-exec",   "det-nodes exec bank /app/patch.sh", "--branch",        "2",
        "--events",      fixed_events,
    }));
    var statuses: [2]u8 = undefined;
    for ([_][]const u8{ buggy_events, fixed_events }, &statuses) |events, *status| {
        const result = try std.process.run(context.arena, context.io, .{ .argv = &.{
            context.determinismo, "tla", "--spec", spec, "--events", events, "--tla2tools", jar,
        } });
        status.* = switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
    }
    const message = "tla: the buggy trace is rejected, the patched one is a behavior of the spec";
    expect(context, statuses[0] == 3 and statuses[1] == 0, message, .{});
}

/// A failing branch's script (its commands and faults) makes other seeds fail too.
fn check_script(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "bank-test" });
    const common = [_][]const u8{ "--program", program, "--scenario", "bank" };
    const exploration = [_][]const u8{ "--seed", "7", "--branches", "8" };
    const found = try explore(context, &(common ++ exploration));
    var branches: [branches_max]Branch = undefined;
    const count = parse_branches(found, &branches);
    const failing = for (branches[0..count]) |branch| {
        if (branch.failing) break branch;
    } else return expect(context, false, "script: a failing branch to start from", .{});
    const index = try std.fmt.allocPrint(context.arena, "{d}", .{failing.index});
    const events_name = "script-events.jsonl";
    const events = try std.fs.path.join(context.arena, &.{ context.scratch, events_name });
    _ = try explore(context, &(common ++ [_][]const u8{
        "--seed", "7", "--branch", index, "--events", events,
    }));
    const extracted = try std.process.run(context.arena, context.io, .{
        .argv = &.{ context.determinismo, "script", events },
    });
    const script_path = try std.fs.path.join(context.arena, &.{ context.scratch, "script.json" });
    const script_file: std.Io.Dir.WriteFileOptions = .{
        .sub_path = script_path,
        .data = extracted.stdout,
    };
    try std.Io.Dir.cwd().writeFile(context.io, script_file);
    const others = common ++ [_][]const u8{ "--seed", "99", "--branches", "8" };
    const without = failing_count(try explore(context, &others));
    const scripted = others ++ [_][]const u8{ "--script", script_path };
    const with = failing_count(try explore(context, &scripted));
    expect(context, with > 0 and with >= without, "script: other seeds fail with it ({d} of 8, " ++
        "{d} without)", .{ with, without });
}

fn failing_count(report: []const u8) u32 {
    var branches: [branches_max]Branch = undefined;
    const count = parse_branches(report, &branches);
    var failing: u32 = 0;
    for (branches[0..count]) |branch| failing += @intFromBool(branch.failing);
    return failing;
}

/// A JVM service, patched through its REPL at a moment: its futures stop losing money; and a
/// moment before the snapshot is refused.
fn check_clojure(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "clojure-bank-test" });
    const common = [_][]const u8{ "--program", program, "--scenario", "bank", "--seed", "5" };
    // Fork just after the setup snapshot (where it is depends on the guest's work so far): the
    // patch lands before the futures run.
    const probe = try explore(context, &(common ++ [_][]const u8{ "--branch", "0" }));
    const snapshot_ms = snapshot_vtime_ms(probe) orelse {
        expect(context, false, "clojure: the setup snapshot's moment is reported", .{});
        return;
    };
    const moment = try std.fmt.allocPrint(context.arena, "{d}", .{snapshot_ms + 200});
    const fork = common ++ [_][]const u8{
        "--from-branch", "0", "--from-vtime-ms", moment, "--branches", "4",
    };
    const plain = try explore(context, &fork);
    const patched = try explore(context, &(fork ++ [_][]const u8{
        "--from-exec", "det-nodes exec bank /app/patch.sh",
    }));
    const fails = std.mem.indexOf(u8, plain, "4 branches, 0 with failing") == null;
    const fixed = std.mem.indexOf(u8, patched, "4 branches, 0 with failing properties") != null;
    const message = "clojure: futures fail, and pass once patched via the REPL";
    expect(context, fails and fixed, message, .{});
    const early = try explore(context, &(common ++ [_][]const u8{
        "--branch", "0", "--at-vtime-ms", "100", "--exec", "true",
    }));
    const refused = std.mem.indexOf(u8, early, "is not after the snapshot") != null;
    expect(context, refused, "moments before the snapshot are refused", .{});
}

/// The setup snapshot's virtual time from explore's report ("snapshot at setup_complete:
/// vtime=3.512s").
fn snapshot_vtime_ms(report: []const u8) ?u64 {
    const key = "snapshot at setup_complete: vtime=";
    const start = (std.mem.indexOf(u8, report, key) orelse return null) + key.len;
    const end = std.mem.indexOfScalarPos(u8, report, start, 's') orelse return null;
    const seconds = std.fmt.parseFloat(f64, report[start..end]) catch return null;
    return @intFromFloat(seconds * std.time.ms_per_s);
}

/// Self-test level 1 (§14): the HTTP API under faults keeps every run and its result.
fn check_controller(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const report = try explore(context, &.{
        "--program", program, "--profile",  "controller", "--scenario", "controller",
        "--seed",    "2",     "--branches", "16",
    });
    const passes = std.mem.indexOf(u8, report, "16 branches, 0 with failing properties") != null;
    expect(context, passes, "controller: runs survive pauses, partitions and restarts", .{});
}

/// Adversarial guest (§14 level 2): clocks, sleeps, page faults and forks at once replay.
fn check_stress(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const common = [_][]const u8{ "--program", program, "--scenario", "stress", "--seed", "4" };
    const report = try explore(context, &(common ++ [_][]const u8{ "--branches", "6" }));
    var branches: [branches_max]Branch = undefined;
    const count = parse_branches(report, &branches);
    expect(context, count == 6, "stress: explored {d} branches", .{count});
    if (count == 0) return;
    var all_same = true;
    for ([_][]const u8{ "1", "4" }) |index| {
        const replay = try explore(context, &(common ++ [_][]const u8{ "--branch", index }));
        var replayed: [1]Branch = undefined;
        const ok = parse_branches(replay, &replayed) == 1 and
            same_timelines(&replayed, branches[0..count]);
        all_same = all_same and ok;
    }
    expect(context, all_same, "stress: branches replay from fresh boots", .{});
}

/// Two shards, merged, give the timelines of one exploration.
fn check_shards(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "bank-test" });
    const common = [_][]const u8{
        "--program", program, "--scenario", "bank", "--seed", "21", "--branches", "6",
    };
    const whole = try explore(context, &common);
    var records: [2][]const u8 = undefined;
    for (&records, 0..) |*record, shard| {
        record.* = try std.fmt.allocPrint(context.arena, "{s}/shard-{d}.jsonl", .{
            context.scratch, shard,
        });
        const flag = try std.fmt.allocPrint(context.arena, "{d}/2", .{shard});
        const shard_flags = [_][]const u8{ "--shard", flag, "--record", record.* };
        _ = try explore(context, &(common ++ shard_flags));
    }
    const result = try std.process.run(context.arena, context.io, .{
        .argv = &.{ context.determinismo, "merge", records[0], records[1] },
    });
    var unsharded: [branches_max]Branch = undefined;
    const count = parse_branches(whole, &unsharded);
    var merged: [branches_max]Branch = undefined;
    const merged_count = merged_branches(result.stdout, &merged);
    const same = count == 6 and merged_count == count and
        same_timelines(unsharded[0..count], merged[0..merged_count]);
    expect(context, same, "shards: two shards merged give the timelines of one run", .{});
}

/// The branches of a merged record (JSON lines).
fn merged_branches(record: []const u8, branches: []Branch) u32 {
    var count: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, record, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "{\"branch\":")) continue;
        if (count == branches.len) break;
        const index_text = field_json(line, "\"index\":") orelse continue;
        const hash = field_json(line, "\"events_hash\":\"") orelse continue;
        branches[count] = .{
            .index = std.fmt.parseInt(u32, index_text, 10) catch continue,
            .events_hash = hash,
            .failing = false,
        };
        count += 1;
    }
    return count;
}

fn field_json(line: []const u8, comptime key: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, line, key) orelse return null) + key.len;
    var end = start;
    while (end < line.len and line[end] != ',' and line[end] != '"') end += 1;
    return line[start..end];
}

/// An Antithesis-style project (Compose file, test templates in an image, SDK-format
/// assertions) explores, finds its bug, and replays.
fn check_compose(context: *Context) !void {
    const compose = "tests/antithesis-compat/bank/compose.yaml";
    const common = [_][]const u8{ "--compose", compose, "--scenario", "bank", "--seed", "3" };
    const report = try explore(context, &(common ++ [_][]const u8{ "--branches", "8" }));
    var branches: [branches_max]Branch = undefined;
    const count = parse_branches(report, &branches);
    expect(context, count == 8, "compose: explored {d} branches", .{count});
    const failing = for (branches[0..count]) |branch| {
        if (branch.failing) break branch;
    } else null;
    const found = failing != null;
    expect(context, found, "compose: finds the lost update via SDK-format assertions", .{});
    const branch = failing orelse return;
    const index = try std.fmt.allocPrint(context.arena, "{d}", .{branch.index});
    const replay = try explore(context, &(common ++ [_][]const u8{ "--branch", index }));
    var replayed: [1]Branch = undefined;
    const same = parse_branches(replay, &replayed) == 1 and
        same_timelines(&replayed, branches[0..count]);
    expect(context, same, "compose: branch {d} replays", .{branch.index});
}

/// Branches from a moment of another branch (a nested snapshot) replay alone.
fn check_fork(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "bank-test" });
    const common = [_][]const u8{ "--program", program, "--scenario", "bank", "--seed", "21" };
    const parent = try explore(context, &(common ++ [_][]const u8{ "--branch", "0" }));
    const setup_s = number_after(parent, "snapshot at setup_complete: vtime=") orelse 0;
    const branch_end_s = branch_vtime(parent) orelse 0;
    const ok_times = setup_s > 0 and branch_end_s > setup_s;
    expect(context, ok_times, "fork: the parent branch runs past its snapshot", .{});
    if (!ok_times) return;
    const middle_ms: u64 = @intFromFloat((setup_s + branch_end_s) / 2 * 1000);
    const middle = try std.fmt.allocPrint(context.arena, "{d}", .{middle_ms});
    const fork = common ++ [_][]const u8{ "--from-branch", "0", "--from-vtime-ms", middle };
    const children = try explore(context, &(fork ++ [_][]const u8{ "--branches", "4" }));
    var branches: [branches_max]Branch = undefined;
    const count = parse_branches(children, &branches);
    expect(context, count == 4, "fork: explored {d} branches from {d} ms of branch 0", .{
        count, middle_ms,
    });
    if (count == 0) return;
    const replay = try explore(context, &(fork ++ [_][]const u8{ "--branch", "2" }));
    var replayed: [1]Branch = undefined;
    const same = parse_branches(replay, &replayed) == 1 and
        same_timelines(&replayed, branches[0..count]);
    expect(context, same, "fork: a branch from the fork point replays alone", .{});
}

/// The end vtime (seconds) of the first branch line.
fn branch_vtime(report: []const u8) ?f64 {
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "[branch ")) continue;
        return number_after(line, "vtime=");
    }
    return null;
}

/// The number (seconds, as printed with an `s`) right after `key` in `text`.
fn number_after(text: []const u8, key: []const u8) ?f64 {
    const start = (std.mem.indexOf(u8, text, key) orelse return null) + key.len;
    var end = start;
    while (end < text.len and (std.ascii.isDigit(text[end]) or text[end] == '.')) end += 1;
    return std.fmt.parseFloat(f64, text[start..end]) catch null;
}

/// Whether every branch of `a` has a twin in `b` (same index) with the same event hash.
fn same_timelines(a: []const Branch, b: []const Branch) bool {
    for (a) |branch| {
        const twin = for (b) |other| {
            if (other.index == branch.index) break other;
        } else return false;
        if (!std.mem.eql(u8, twin.events_hash, branch.events_hash)) return false;
    }
    return true;
}

/// Runs `determinismo explore` with the machine options; returns its whole output.
fn explore(context: *Context, extra: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(context.arena, &.{ context.determinismo, "explore" });
    try argv.appendSlice(context.arena, context.machine);
    try argv.appendSlice(context.arena, extra);
    const result = try std.process.run(context.arena, context.io, .{ .argv = argv.items });
    // Exit status 3 means "properties failed", which the checks expect; others are errors.
    const status: u8 = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };
    // Refusals some checks expect (a tape on other inputs, a moment before the snapshot).
    const refusal = std.mem.indexOf(u8, result.stderr, "recorded with") != null or
        std.mem.indexOf(u8, result.stderr, "is not after the snapshot") != null;
    if (status != 0 and status != 3 and !refusal) {
        std.debug.print("e2e: determinismo exited with {d}:\n{s}\n", .{ status, result.stderr });
    }
    return std.mem.concat(context.arena, u8, &.{ result.stdout, result.stderr });
}

fn parse_branches(report: []const u8, branches: []Branch) u32 {
    var count: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "[branch ")) continue;
        if (count == branches.len) break;
        const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
        const index_text = std.mem.trim(u8, line["[branch ".len..close], " ");
        const hash = field(line, "events_hash=") orelse continue;
        const failing = field(line, "failing=") orelse continue;
        branches[count] = .{
            .index = std.fmt.parseInt(u32, index_text, 10) catch continue,
            .events_hash = hash,
            .failing = !std.mem.eql(u8, failing, "0"),
        };
        count += 1;
    }
    return count;
}

fn field(line: []const u8, comptime key: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, line, key) orelse return null) + key.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, ' ') orelse line.len;
    return line[start..end];
}

fn expect(context: *Context, ok: bool, comptime format: []const u8, arguments: anytype) void {
    const status = if (ok) "PASS" else "FAIL";
    std.debug.print("{s} " ++ format ++ "\n", .{status} ++ arguments);
    if (!ok) context.failures += 1;
}

test parse_branches {
    const report = "[determinismo] inputs 1\n" ++
        "[branch    3] seed=ab shutdown vtime=2.9s wall=0.4s events=488 events_hash=5167 " ++
        "failing=1  FAIL \"total\"\n" ++
        "[branch   10] seed=cd shutdown vtime=2.1s wall=0.1s events=99 events_hash=c66e " ++
        "failing=0\n";
    var branches: [branches_max]Branch = undefined;
    try std.testing.expectEqual(@as(u32, 2), parse_branches(report, &branches));
    try std.testing.expectEqual(@as(u32, 3), branches[0].index);
    try std.testing.expect(branches[0].failing);
    try std.testing.expectEqualStrings("c66e", branches[1].events_hash);
}
