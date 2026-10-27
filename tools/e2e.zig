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
        // Its own: suites run at once (a full one and a single check) do not share files.
        .scratch = try std.fmt.allocPrint(arena, "/tmp/determinismo-e2e-{d}", .{
            std.os.linux.getpid(),
        }),
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
        std.debug.print("e2e: {d} checks failed (their files: {s})\n", .{
            context.failures, context.scratch,
        });
        std.process.exit(1);
    }
    std.Io.Dir.cwd().deleteTree(init.io, context.scratch) catch {};
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
        .{ "durability", check_durability },         .{ "mutate", check_mutate },
        .{ "checks", check_host_checks },            .{ "inject", check_inject },
        .{ "compose", check_compose },               .{ "shards", check_shards },
        .{ "stress", check_stress },                 .{ "controller", check_controller },
        .{ "clojure", check_clojure },               .{ "k3s", check_k3s },
        .{ "script", check_script },                 .{ "modulation", check_cpu_modulation },
        .{ "profile", check_profile },               .{ "catalog", check_catalog },
        .{ "guidance", check_guidance },             .{ "voidstar", check_voidstar },
        .{ "changed", check_changed },               .{ "readdress", check_readdress },
        .{ "retroactive", check_retroactive },       .{ "hang", check_hang },
        .{ "pinned", check_pinned },                 .{ "saved", check_saved },
        .{ "concurrent", check_concurrent },         .{ "resume", check_resume },
        .{ "ui", check_ui },                         .{ "runs", check_runs },
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
    // A command at a moment of a replay (looking inside a timeline) makes a new timeline from
    // there: the replay goes on to the end, not stopping at the tape it no longer follows.
    const inside = try explore(context, &.{
        "--program",     program, "--scenario", "bank",               "--tape",     tape,
        "--at-vtime-ms", "1500",  "--exec",     "echo looked inside", "--continue",
    });
    var looked: [1]Branch = undefined;
    const goes_on = std.mem.indexOf(u8, inside, "looked inside") != null and
        std.mem.indexOf(u8, inside, "diverged") == null and parse_branches(inside, &looked) == 1;
    expect(context, goes_on, "tapes: a command at a moment of a replay runs, and the replay " ++
        "goes on to the end", .{});
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
    // Its own initramfs: replaced below, as a deploy replaces the host's.
    const initrd = try std.fs.path.join(arena, &.{ context.scratch, "serve-initrd.cpio" });
    const machine = try arena.dupe([]const u8, context.machine);
    for (machine[0 .. machine.len - 1], 0..) |flag, index| {
        if (!std.mem.eql(u8, flag, "--initrd")) continue;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(context.io, machine[index + 1], arena, .unlimited);
        try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = initrd, .data = bytes });
        machine[index + 1] = initrd;
    }
    try argv.appendSlice(arena, machine);
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
    // A deploy replaces the initramfs: the run's replays still boot what it booted (kept by
    // content), to the same events.
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = initrd, .data = "not the run's" });
    const replayed = try curl(context, &.{ "-X", "POST", "-d", "{\"branch\":0}", url ++ "/runs/1/replay" });
    const hash_at = std.mem.indexOf(u8, replayed, "events_hash=");
    const hash = if (hash_at) |at| replayed[at + "events_hash=".len ..][0..16] else "";
    const record_path = try std.fs.path.join(arena, &.{ data, "runs", "1", "record.jsonl" });
    const record = try std.Io.Dir.cwd().readFileAlloc(context.io, record_path, arena, .limited(1 << 24));
    const same = hash.len == 16 and std.mem.indexOf(u8, record, hash) != null;
    expect(context, same, "serve: a run replays after a deploy replaced its initramfs " ++
        "(events hash {s})", .{hash});
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

/// The web UI in a browser (tests/ui, Playwright), against a serve with three runs of the bank
/// example: one finished with a failing property (its causality analysis, run from the page to
/// its end), another finished, and one running while the tests look at it.
fn check_ui(context: *Context) !void {
    const arena = context.arena;
    const cwd = std.Io.Dir.cwd();
    cwd.access(context.io, "tests/ui/node_modules/@playwright/test", .{}) catch {
        std.debug.print("SKIP ui: tests/ui has no Playwright (npm ci && npx playwright install " ++
            "--with-deps chromium there)\n", .{});
        return;
    };
    const address = "127.0.0.1:7892";
    const url = "http://" ++ address;
    const data = try std.fs.path.join(arena, &.{ context.scratch, "ui-serve" });
    cwd.deleteTree(context.io, data) catch {};
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "serve", "--listen", address, "--data", data });
    try argv.appendSlice(arena, context.machine);
    var server = try std.process.spawn(context.io, .{ .argv = argv.items, .stdout = .ignore, .stderr = .ignore });
    defer server.kill(context.io);
    for (0..50) |_| {
        const listed = curl(context, &.{url ++ "/runs"}) catch "";
        if (listed.len > 0) break;
        sleep_ms(100);
    }
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    for ([_][]const u8{
        "\"seed\":3,\"branches\":16",
        "\"seed\":4,\"branches\":8",
    }) |runs| {
        const body = try std.fmt.allocPrint(arena, "{{\"program\":{f},\"scenario\":\"bank\",{s}}}", .{
            std.json.fmt(program, .{}), runs,
        });
        _ = try curl(context, &.{ "-X", "POST", "-d", body, url ++ "/runs" });
    }
    for ([_][]const u8{ url ++ "/runs/1", url ++ "/runs/2" }) |run_url| {
        for (0..3000) |_| {
            const run = try curl(context, &.{run_url});
            if (std.mem.indexOf(u8, run, "\"state\":\"running\"") == null) break;
            sleep_ms(200);
        }
    }
    // serve saved run 1's first failure to disk on its own, as soon as it found it.
    const snapshots = try std.fs.path.join(arena, &.{ data, "runs", "1", "snapshots" });
    var saved_log: []const u8 = "";
    for (0..600) |_| {
        var dir = cwd.openDir(context.io, snapshots, .{ .iterate = true }) catch {
            sleep_ms(500);
            continue;
        };
        defer dir.close(context.io);
        var iterator = dir.iterate();
        while (try iterator.next(context.io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "failure-")) continue;
            const path = try std.fs.path.join(arena, &.{ snapshots, entry.name });
            const text = cwd.readFileAlloc(context.io, path, arena, .limited(1 << 20)) catch "";
            if (std.mem.indexOf(u8, text, "{\"saved\":") != null) saved_log = text;
        }
        if (saved_log.len > 0) break;
        sleep_ms(500);
    }
    expect(context, saved_log.len > 0, "ui: serve saved run 1's first failure to disk as soon " ++
        "as it found it", .{});
    // The third runs while the tests look at it (on one CPU: the analysis needs the rest).
    const running = try std.fmt.allocPrint(arena, "{{\"program\":{f},\"scenario\":\"bank\"," ++
        "\"seed\":5,\"branches\":100000,\"jobs\":1,\"time_budget\":\"30m\"}}", .{std.json.fmt(program, .{})});
    _ = try curl(context, &.{ "-X", "POST", "-d", running, url ++ "/runs" });
    defer _ = curl(context, &.{ "-X", "POST", url ++ "/runs/3/stop" }) catch "";
    // The fourth, flat, for the page to stop and resume.
    const resumable = try std.fmt.allocPrint(arena, "{{\"program\":{f},\"scenario\":\"bank\"," ++
        "\"seed\":6,\"branches\":100000,\"jobs\":1,\"branching\":\"flat\",\"time_budget\":\"30m\"}}", .{std.json.fmt(program, .{})});
    _ = try curl(context, &.{ "-X", "POST", "-d", resumable, url ++ "/runs" });
    defer _ = curl(context, &.{ "-X", "POST", url ++ "/runs/4/stop" }) catch "";
    const command = try std.fmt.allocPrint(arena, "cd tests/ui && DETERMINISMO_URL={s} npx playwright test", .{url});
    const result = try std.process.run(arena, context.io, .{
        .argv = &.{ "/bin/sh", "-c", command },
        .stdout_limit = .limited(16 << 20),
        .stderr_limit = .limited(16 << 20),
    });
    const passed = result.term.success();
    expect(context, passed, "ui: the run page in a browser (Playwright): runs by URL, a " ++
        "causality analysis from the page to its end, the map's failures, a running run's " ++
        "refreshes, a run stopped and resumed from its page", .{});
    if (!passed) std.debug.print("{s}\n{s}\n", .{ result.stdout, result.stderr });
}

/// Every exploration is a run of the host's (src/runs.zig): one started at a terminal shows in
/// serve as serve's own do, running, then judged; serve stops it.
fn check_runs(context: *Context) !void {
    const arena = context.arena;
    const cwd = std.Io.Dir.cwd();
    const address = "127.0.0.1:7893";
    const url = "http://" ++ address;
    const data = try std.fs.path.join(arena, &.{ context.scratch, "runs-store" });
    cwd.deleteTree(context.io, data) catch {};
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ context.determinismo, "serve", "--listen", address, "--data", data });
    try argv.appendSlice(arena, context.machine);
    var server = try std.process.spawn(context.io, .{ .argv = argv.items, .stdout = .ignore, .stderr = .ignore });
    defer server.kill(context.io);
    for (0..50) |_| {
        const listed = curl(context, &.{url ++ "/runs"}) catch "";
        if (listed.len > 0) break;
        sleep_ms(100);
    }
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const system = [_][]const u8{ "--data", data, "--program", program, "--scenario", "bank", "--branching", "flat", "--jobs", "2" };
    // One to its end, as at a terminal.
    const output = try explore(context, &(system ++ [_][]const u8{ "--seed", "3", "--branches", "8" }));
    const claimed = std.mem.indexOf(u8, output, "[determinismo] run 1: ") != null;
    var listed: []const u8 = "";
    for (0..100) |_| {
        listed = curl(context, &.{url ++ "/runs/1"}) catch "";
        if (std.mem.indexOf(u8, listed, "\"state\":\"failed\"") != null) break;
        sleep_ms(200);
    }
    const timelines = curl(context, &.{url ++ "/runs/1/timelines"}) catch "";
    const logged = cwd.readFileAlloc(context.io, try std.fs.path.join(arena, &.{ data, "runs", "1", "output.log" }), arena, .limited(1 << 24)) catch "";
    expect(context, claimed and std.mem.indexOf(u8, listed, "\"state\":\"failed\"") != null and
        std.mem.count(u8, timelines, "\"index\"") == 8 and std.mem.indexOf(u8, logged, "[branch") != null, "runs: an exploration at a terminal is run 1 of the host's, in serve with its 8 timelines " ++
        "and its output, failed as it ended", .{});
    // Another, long, which serve stops.
    var command: std.ArrayList(u8) = .empty;
    try command.print(arena, "exec '{s}' explore", .{context.determinismo});
    for (context.machine) |part| try command.print(arena, " '{s}'", .{part});
    for (system) |part| try command.print(arena, " '{s}'", .{part});
    try command.print(arena, " --seed 4 --branches 100000 --time-budget 30m > /dev/null 2>&1", .{});
    var child = try std.process.spawn(context.io, .{ .argv = &.{ "sh", "-c", command.items }, .stdout = .ignore, .stderr = .ignore });
    var running = false;
    for (0..600) |_| {
        const run = curl(context, &.{url ++ "/runs/2"}) catch "";
        running = std.mem.indexOf(u8, run, "\"state\":\"running\"") != null;
        if (running) break;
        sleep_ms(100);
    }
    _ = curl(context, &.{ "-X", "POST", url ++ "/runs/2/stop" }) catch "";
    const term = try child.wait(context.io);
    var stopped = false;
    for (0..100) |_| {
        const run = curl(context, &.{url ++ "/runs/2"}) catch "";
        stopped = std.mem.indexOf(u8, run, "\"state\":\"stopped\"") != null;
        if (stopped) break;
        sleep_ms(200);
    }
    _ = term;
    expect(context, running and stopped, "runs: another, running at a terminal, shows " ++
        "running in serve, and serve stops it", .{});
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
    // Points come as their futures finish, and refinement adds moments inside jumps.
    const Point = struct { vtime_ms: u64, probability: f64, low: f64, high: f64 };
    var points: u32 = 0;
    var latest: Point = .{ .vtime_ms = 0, .probability = 0, .low = 0, .high = 0 };
    var bounded = true;
    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const point = std.json.parseFromSliceLeaky(Point, arena, line, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        bounded = bounded and point.low <= point.probability and point.probability <= point.high;
        points += 1;
        if (point.vtime_ms >= latest.vtime_ms) latest = point;
    }
    expect(context, points >= 4 and latest.probability == 1 and bounded, "causality: {d} " ++
        "moments (4, and refinements inside jumps), certain at the failure ({d:.2}), each " ++
        "within its 90% interval", .{ points, latest.probability });
    // The bug as an event condition (a verdict) instead of a property: the same analysis.
    var verdict_argv: std.ArrayList([]const u8) = .empty;
    try verdict_argv.appendSlice(arena, &.{ context.determinismo, "causality" });
    try verdict_argv.appendSlice(arena, context.machine);
    try verdict_argv.appendSlice(arena, &system);
    try verdict_argv.appendSlice(arena, &.{
        "--branch", "4", "--verdict", violation, "--points", "4", "--futures", "8", "--refine", "0", "--json",
    });
    const verdict_result = try std.process.run(arena, context.io, .{ .argv = verdict_argv.items });
    var verdict_points: u32 = 0;
    var verdict_latest: Point = .{ .vtime_ms = 0, .probability = 0, .low = 0, .high = 0 };
    var verdict_lines = std.mem.tokenizeScalar(u8, verdict_result.stdout, '\n');
    while (verdict_lines.next()) |line| {
        const point = std.json.parseFromSliceLeaky(Point, arena, line, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        verdict_points += 1;
        if (point.vtime_ms >= verdict_latest.vtime_ms) verdict_latest = point;
    }
    expect(context, verdict_points == 5 and verdict_latest.probability == 1, "causality with a " ++
        "verdict (an event condition, no property): {d} moments, certain at the failure ({d:.2})", .{
        verdict_points, verdict_latest.probability,
    });
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
        "--branch", "4", "--until", violation, "--rewind-ms", "50", "--exec", "echo rewound",
    });
    const report = try explore(context, extra.items);
    const holds: u64 = @trunc(number_after(report, "the condition holds at ") orelse 0);
    const target: u64 = @trunc(number_after(report, "; the moment is ") orelse 0);
    const last = std.mem.lastIndexOf(u8, report, "at moment vtime=") orelse 0;
    const reached: u64 = @trunc(number_after(report[last..], "at moment vtime=") orelse 0);
    // The guest runs on while the command does: the rewind leaves it room to end first.
    const exact = holds > target and holds - target == 50 * std.time.ns_per_ms and
        reached >= target and reached - target < std.time.ns_per_ms;
    const ran = std.mem.indexOf(u8, report, "\"text\":\"rewound\\n\"") != null;
    const before = std.mem.indexOf(u8, report, "failing=0") != null;
    expect(context, exact and ran and before, "rewind: 50 ms before the violation " ++
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

/// One timeline run at once by more processes than the host has cores (they queue for the CPU
/// pool's cores): the same history in each. VMs on a core's sibling hyperthreads perturbed each
/// other's retired-branch counters, and VMs outside the pool ran anywhere (2026-10-27).
fn check_concurrent(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const runs = 8;
    var children: [runs]std.process.Child = undefined;
    var logs: [runs][]const u8 = undefined;
    for (&children, &logs, 0..) |*child, *log, index| {
        log.* = try std.fmt.allocPrint(arena, "{s}/concurrent-{d}.log", .{ context.scratch, index });
        var command: std.ArrayList(u8) = .empty;
        try command.print(arena, "exec '{s}' explore", .{context.determinismo});
        for (context.machine) |part| try command.print(arena, " '{s}'", .{part});
        try command.print(arena, " --program '{s}' --scenario bank --seed 9 --branch 3 " ++
            "--branching flat 2> '{s}'", .{ program, log.* });
        child.* = try std.process.spawn(context.io, .{
            .argv = &.{ "sh", "-c", command.items },
            .stdout = .ignore,
            .stderr = .ignore,
        });
    }
    for (&children) |*child| _ = try child.wait(context.io);
    var first: ?[]const u8 = null;
    var same: u32 = 0;
    for (logs) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(context.io, path, arena, .limited(1 << 24)) catch "";
        var branches: [1]Branch = undefined;
        if (parse_branches(text, &branches) != 1) continue;
        const hash = branches[0].events_hash;
        if (first == null) first = hash;
        if (std.mem.eql(u8, first.?, hash)) same += 1;
    }
    expect(context, same == runs, "concurrent: one timeline run by {d} processes at once, " ++
        "the same history in {d}", .{ runs, same });
}

/// A run killed partway and resumed (--resume) explores what it would have whole: the same
/// timelines (index, events hash), once each; flat, and a tree (from its recorded summaries).
fn check_resume(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    for ([_][]const u8{ "flat", "tree" }) |branching| {
        const system = [_][]const u8{
            "--program",  program, "--scenario",   "bank", "--seed", "7", "--branching", branching,
            "--branches", "48",    "--generation", "16",   "--jobs", "3",
        };
        const whole = try std.fmt.allocPrint(arena, "{s}/resume-{s}-whole.jsonl", .{ context.scratch, branching });
        const parts = try std.fmt.allocPrint(arena, "{s}/resume-{s}-parts.jsonl", .{ context.scratch, branching });
        _ = try explore(context, &(system ++ [_][]const u8{ "--record", whole }));
        // Killed once a dozen timelines are recorded (its workers go with it).
        var command: std.ArrayList(u8) = .empty;
        try command.print(arena, "exec '{s}' explore", .{context.determinismo});
        for (context.machine) |part| try command.print(arena, " '{s}'", .{part});
        for (system) |part| try command.print(arena, " '{s}'", .{part});
        try command.print(arena, " --record '{s}' 2> /dev/null", .{parts});
        var child = try std.process.spawn(context.io, .{
            .argv = &.{ "sh", "-c", command.items },
            .stdout = .ignore,
            .stderr = .ignore,
        });
        for (0..6000) |_| {
            const text = std.Io.Dir.cwd().readFileAlloc(context.io, parts, arena, .limited(1 << 24)) catch "";
            if (std.mem.count(u8, text, "{\"branch\":") >= 12) break;
            sleep_ms(50);
        }
        _ = std.os.linux.kill(child.id.?, .TERM);
        _ = try child.wait(context.io);
        const interrupted = try record_timelines(context, parts);
        _ = try explore(context, &(system ++ [_][]const u8{ "--record", parts, "--resume" }));
        const expected = try record_timelines(context, whole);
        const resumed = try record_timelines(context, parts);
        const same = expected.len == 48 and expected.len == resumed.len and for (expected, resumed) |a, b| {
            if (!std.mem.eql(u8, a, b)) break false;
        } else true;
        expect(context, same, "resume ({s}): killed at {d} timelines, resumed: the {d} timelines " ++
            "of the whole run, once each ({d} recorded)", .{ branching, interrupted.len, expected.len, resumed.len });
    }
}

/// A record's timelines as "index events_hash", sorted (duplicates kept: they would differ).
fn record_timelines(context: *Context, path: []const u8) ![]const []const u8 {
    const arena = context.arena;
    const text = std.Io.Dir.cwd().readFileAlloc(context.io, path, arena, .limited(1 << 26)) catch "";
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "{\"branch\":")) continue;
        const index = field_json(line, "\"index\":") orelse continue;
        const hash = field_json(line, "\"events_hash\":\"") orelse continue;
        try out.append(arena, try std.fmt.allocPrint(arena, "{s:0>8} {s}", .{ index, hash }));
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return out.items;
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
        "--program",   program, "--scenario", "bank", "--seed", "5", "--branches", "64",
        "--branching", "tree",
    };
    const one = try explore(context, &(common ++ [_][]const u8{
        "--jobs", "1", "--tape-dir", tapes, "--record", record, "--verify-holders",
    }));
    const many = try explore(context, &(common ++ [_][]const u8{ "--jobs", "4" }));
    var sequential: [branches_max]Branch = undefined;
    var parallel: [branches_max]Branch = undefined;
    const count = parse_branches(one, &sequential);
    // Past the first generations in flight (all from the setup snapshot), the tree deepens.
    const same = count == 64 and parse_branches(many, &parallel) == count and
        same_timelines(sequential[0..count], parallel[0..count]);
    const deep = try deepest_replays(context, program, record, tapes, sequential[0..count], &.{});
    // In-run snapshots (holders) made nodes without replays, in both: the same tree as replays
    // from their parents' start would make, which the deepest timeline's lone replay checks.
    const held = held_nodes(one) > 0 and held_nodes(many) > 0;
    // Each the node a replay makes, in what the guest can see (--verify-holders remade them).
    const verified = std.mem.indexOf(u8, one, "ns: the same") != null and
        std.mem.indexOf(u8, one, "DIFFERENT") == null;
    const passes = same and deep.depth >= 1 and deep.replays and held and verified;
    expect(context, passes, "tree: {d} timelines, up to {d} deep, the same with one worker or " ++
        "four; #{?d} replays alone from its tape; {d} nodes from in-run snapshots, each the " ++
        "one a replay makes", .{
        count, deep.depth, deep.index, held_nodes(one),
    });
    if (!verified) std.debug.print("{s}\n", .{lines_with(context.arena, one, &.{
        "verify",
    }) catch ""});
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
        &.{},
    );
    const steered_ok = steered_count == 64 and steered_deep.depth >= 1 and steered_deep.replays;
    expect(context, steered_ok, "tree with a strategy: {d} timelines, up to {d} deep; #{?d} " ++
        "replays from its tape (its ancestors' decisions from theirs)", .{
        steered_count, steered_deep.depth, steered_deep.index,
    });
    // With CPU modulation: holders keep the modulated timelines as they were, their nodes are
    // the ones a replay makes, and a deep timeline replays alone.
    const modulated_tapes = try std.fmt.allocPrint(arena, "{s}/tree-modulated-tapes", .{
        context.scratch,
    });
    const modulated_record = try std.fmt.allocPrint(arena, "{s}/tree-modulated.jsonl", .{
        context.scratch,
    });
    const modulated = try explore(context, &(common ++ [_][]const u8{
        "--jobs",     "2",             "--cpu-modulation", "--verify-holders",
        "--tape-dir", modulated_tapes, "--record",         modulated_record,
    }));
    var modulated_branches: [branches_max]Branch = undefined;
    const modulated_count = parse_branches(modulated, &modulated_branches);
    const modulated_deep = try deepest_replays(
        context,
        program,
        modulated_record,
        modulated_tapes,
        modulated_branches[0..modulated_count],
        &.{"--cpu-modulation"},
    );
    const modulated_verified = std.mem.indexOf(u8, modulated, "ns: the same") != null and
        std.mem.indexOf(u8, modulated, "DIFFERENT") == null;
    const modulated_ok = modulated_count == 64 and modulated_deep.depth >= 1 and
        modulated_deep.replays and held_nodes(modulated) > 0 and modulated_verified;
    expect(context, modulated_ok, "tree with cpu modulation: {d} timelines, up to {d} deep; " ++
        "#{?d} replays alone from its tape; {d} nodes from in-run snapshots, each the one a " ++
        "replay makes", .{
        modulated_count, modulated_deep.depth, modulated_deep.index, held_nodes(modulated),
    });
    if (!modulated_verified) std.debug.print("{s}\n", .{lines_with(arena, modulated, &.{
        "verify",
    }) catch ""});
}

/// The tree's nodes made from in-run snapshots, over its generations ("(n from in-run
/// snapshots)" in each generation's line).
fn held_nodes(report: []const u8) u64 {
    var total: u64 = 0;
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    while (lines.next()) |line| {
        const end = std.mem.indexOf(u8, line, " from in-run snapshots)") orelse continue;
        const start = (std.mem.lastIndexOfScalar(u8, line[0..end], '(') orelse continue) + 1;
        total += std.fmt.parseInt(u64, line[start..end], 10) catch 0;
    }
    return total;
}

/// The deepest timeline of a tree exploration (from its record), and whether it replays alone
/// from its tape with the events it had.
fn deepest_replays(
    context: *Context,
    program: []const u8,
    record: []const u8,
    tapes: []const u8,
    explored: []const Branch,
    /// The exploration's options a replay needs too (they are in its inputs).
    options: []const []const u8,
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
    const system = [_][]const u8{ "--program", program, "--scenario", "bank", "--tape", tape };
    const argv = try std.mem.concat(arena, []const u8, &.{ &system, options });
    const replay = try explore(context, argv);
    var replayed: [1]Branch = undefined;
    const original = for (explored) |branch| {
        if (branch.index == index) break branch;
    } else null;
    const replays = original != null and parse_branches(replay, &replayed) == 1 and
        std.mem.eql(u8, replayed[0].events_hash, original.?.events_hash);
    return .{ .index = index, .depth = depth_max, .replays = replays };
}

/// Faults a scenario asks for (sdk.fault, det-faults inject): a pause, a graceful stop and a
/// one-way partition each take the node away and give it back, in every timeline.
fn check_inject(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const report = try explore(context, &.{
        "--program",  program, "--profile", "injectable", "--scenario", "inject", "--seed", "1",
        "--branches", "2",
    });
    const passes = std.mem.indexOf(u8, report, "2 branches, 0 with failing properties") != null and
        std.mem.indexOf(u8, report, "injected faults came and went") != null;
    expect(context, passes, "inject: a pause, a stop and a one-way partition asked for by " ++
        "the scenario take the node away and give it back", .{});
    if (!passes) std.debug.print("{s}\n", .{lines_with(context.arena, report, &.{
        "FAIL", "fault_inject_refused", "fault_failed",
    }) catch ""});
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
            "failing in    0  a crash keeps what was synced and loses the rest") != null and
        std.mem.indexOf(u8, report, "PASS always                hit in    3/3 branches, " ++
            "failing in    0  writes a disk drops are synced, then gone after a crash") != null and
        std.mem.indexOf(u8, report, "PASS always                hit in    3/3 branches, " ++
            "failing in    0  a disk works again after its faults") != null;
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
        "rest, a wipe loses both; dropped writes vanish, refused ones fail, a slow disk is " ++
        "slow, and it works again; a timeline replays exactly", .{});
    if (!passes) std.debug.print("{s}\n", .{lines_with(context.arena, report, &.{
        "FAIL", "fault_failed", "fault_heal_failed", "det-nodes",
    }) catch ""});
}

/// Host checks (System.main's `.checks`): records a timeline's command made reach the program's
/// check on the host, in order and typed, as properties of the timeline; a replay agrees.
fn check_host_checks(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const common = [_][]const u8{ "--program", program, "--scenario", "records", "--seed", "1" };
    const report = try explore(context, &(common ++ [_][]const u8{ "--branches", "2" }));
    const properties = [_][]const u8{
        "a host check knows its scenario",
        "a host check gets every record",
        "a host check gets the records in order, as made",
        "host checks run to completion",
    };
    var passes = std.mem.indexOf(u8, report, "2 branches, 0 with failing properties") != null;
    for (properties) |property| {
        const line = try std.fmt.allocPrint(context.arena, "hit in    2/2 branches, failing in    0  {s}", .{property});
        passes = passes and std.mem.indexOf(u8, report, line) != null;
    }
    var branches: [2]Branch = undefined;
    const count = parse_branches(report, &branches);
    var same = false;
    if (count > 0) {
        const replay = try explore(context, &(common ++ [_][]const u8{ "--branch", "0" }));
        var replayed: [1]Branch = undefined;
        same = parse_branches(replay, &replayed) == 1 and
            same_timelines(&replayed, branches[0..count]);
    }
    expect(context, passes and same, "host checks: a timeline's records reach the program's " ++
        "check on the host, in order and typed, as properties; a replay agrees", .{});
    if (!passes) std.debug.print("{s}\n", .{lines_with(context.arena, report, &.{
        "FAIL", "check", "always",
    }) catch ""});
}

/// Faults at durability points (the guest module's): a stall holds a node's syncs; a crash at
/// a sync loses the write before it and keeps it just after; a timeline replays exactly.
fn check_durability(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const common = [_][]const u8{
        "--program", program, "--profile", "durable", "--scenario", "durability", "--seed", "1",
    };
    const report = try explore(context, &(common ++ [_][]const u8{ "--branches", "2" }));
    const properties = [_][]const u8{
        "a sync stall holds a node's syncs, and they complete",
        "a crash just before a sync loses the write",
        "a crash just after a sync keeps the write",
        "a write crashed at its sync never returns",
    };
    var passes = std.mem.indexOf(u8, report, "2 branches, 0 with failing properties") != null;
    for (properties) |property| {
        const line = try std.fmt.allocPrint(context.arena, "hit in    2/2 branches, failing in    0  {s}", .{property});
        passes = passes and std.mem.indexOf(u8, report, line) != null;
    }
    var branches: [2]Branch = undefined;
    const count = parse_branches(report, &branches);
    var same = false;
    if (count > 0) {
        const replay = try explore(context, &(common ++ [_][]const u8{ "--branch", "0" }));
        var replayed: [1]Branch = undefined;
        same = parse_branches(replay, &replayed) == 1 and
            same_timelines(&replayed, branches[0..count]);
    }
    expect(context, passes and same, "durability points: a stall holds a node's syncs; a " ++
        "crash just before a sync loses the write, just after keeps it; a timeline replays " ++
        "exactly", .{});
    if (!passes) std.debug.print("{s}\n", .{lines_with(context.arena, report, &.{
        "FAIL", "fault_failed", "fault_inject_refused", "det-nodes", "always",
    }) catch ""});
}

/// A timeline that never finishes ends at its ceiling of virtual time, as hung (the finish
/// property fails), at the same point in a replay.
fn check_hang(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const common = [_][]const u8{
        "--program", program, "--scenario", "hang", "--seed", "1", "--timeline-limit", "20s",
    };
    const report = try explore(context, &(common ++ [_][]const u8{ "--branches", "2" }));
    const hung = std.mem.count(u8, report, " hung ") == 2 and std.mem.indexOf(u8, report, "FAIL always                hit in    2/2 branches, failing in    2  the guest " ++
        "finishes its scenario") != null;
    var branches: [2]Branch = undefined;
    const count = parse_branches(report, &branches);
    const replay = try explore(context, &(common ++ [_][]const u8{ "--branch", "0" }));
    var replayed: [1]Branch = undefined;
    const same = count == 2 and parse_branches(replay, &replayed) == 1 and
        same_timelines(&replayed, branches[0..count]);
    expect(context, hung and same, "hang: a timeline that never finishes ends at its " ++
        "ceiling, hung, the same in a replay", .{});
    if (!(hung and same)) std.debug.print("{s}\n", .{lines_with(context.arena, report, &.{
        "[branch", "FAIL",
    }) catch ""});
}

/// Retroactive logging: output lines with a hidden text are not written while exploring (the
/// timelines are the same: events hash), and a replay of a timeline writes them.
fn check_retroactive(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const system = [_][]const u8{ "--program", program, "--scenario", "bank", "--seed", "21" };
    const text = "Ready to accept";
    var hidden_dirs: [2][]const u8 = undefined;
    var reports: [2][]const u8 = undefined;
    for (&hidden_dirs, &reports, 0..) |*dir, *report, index| {
        dir.* = try std.fmt.allocPrint(arena, "{s}/retroactive-{d}", .{ context.scratch, index });
        const extra: []const []const u8 = if (index == 0) &.{ "--retroactive", text } else &.{};
        report.* = try explore(context, try std.mem.concat(arena, []const u8, &.{
            &system, &.{ "--branches", "2", "--branching", "flat", "--events-dir", dir.* }, extra,
        }));
    }
    const replay_dir = try std.fmt.allocPrint(arena, "{s}/retroactive-replay", .{context.scratch});
    _ = try explore(context, &(system ++ [_][]const u8{
        "--branch", "0", "--retroactive", text, "--events-dir", replay_dir,
    }));
    const hidden = try directory_has(context, hidden_dirs[0], text);
    const shown = try directory_has(context, hidden_dirs[1], text);
    const replayed = try directory_has(context, replay_dir, text);
    var with: [2]Branch = undefined;
    var without: [2]Branch = undefined;
    const same = parse_branches(reports[0], &with) == 2 and
        parse_branches(reports[1], &without) == 2 and same_timelines(&with, &without);
    const passes = !hidden and shown and replayed and same;
    expect(context, passes, "retroactive: hidden output stays out of an exploration's events, " ++
        "the timelines unchanged, and a replay writes it", .{});
    if (!passes) std.debug.print("hidden {} shown {} replayed {} same {}\n", .{
        hidden, shown, replayed, same,
    });
}

/// A pinned system replays on another host: a kit (the run's pin, with its node disks beside it
/// by name) replays a timeline from an empty cache, with nothing pulled or built, to the same
/// events.
fn check_pinned(context: *Context) !void {
    const arena = context.arena;
    const io = context.io;
    const cwd = std.Io.Dir.cwd();
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const system = [_][]const u8{ "--program", program, "--scenario", "bank", "--seed", "5", "--branch", "0" };
    const events = try std.fs.path.join(arena, &.{ context.scratch, "pinned-events" });
    const report = try explore(context, &(system ++ [_][]const u8{ "--events-dir", events }));
    const Pin = struct { system_json: []const u8, disks: []const []const u8 };
    const pin_path = try std.fs.path.join(arena, &.{ events, "system.pin.json" });
    const pin_json = try cwd.readFileAlloc(io, pin_path, arena, .limited(1 << 20));
    const pin = try std.json.parseFromSliceLeaky(Pin, arena, pin_json, .{});
    const kit = try std.fs.path.join(arena, &.{ context.scratch, "pinned-kit" });
    try cwd.createDirPath(io, kit);
    const names = try arena.alloc([]const u8, pin.disks.len);
    for (pin.disks, names) |disk, *name| {
        name.* = std.fs.path.basename(disk);
        const copy = try std.fs.path.join(arena, &.{ kit, name.* });
        cwd.access(io, copy, .{}) catch try cwd.copyFile(disk, cwd, copy, io, .{});
    }
    const kit_pin = try std.fs.path.join(arena, &.{ kit, "system.pin.json" });
    try cwd.writeFile(io, .{ .sub_path = kit_pin, .data = try std.fmt.allocPrint(arena, "{f}", .{
        std.json.fmt(Pin{ .system_json = pin.system_json, .disks = names }, .{}),
    }) });
    const fresh = try std.fs.path.join(arena, &.{ context.scratch, "pinned-cache" });
    const replayed = try explore(context, &(system ++ [_][]const u8{ "--system", kit_pin, "--cache", fresh }));
    var original: [1]Branch = undefined;
    var again: [1]Branch = undefined;
    const same = parse_branches(report, &original) == 1 and parse_branches(replayed, &again) == 1 and
        std.mem.eql(u8, original[0].events_hash, again[0].events_hash);
    const built = std.mem.indexOf(u8, replayed, "] building ") != null or
        std.mem.indexOf(u8, replayed, "] pulling ") != null or
        std.mem.indexOf(u8, replayed, "] flattening ") != null;
    expect(context, same and !built, "pinned: a kit replays a timeline from an empty cache, " ++
        "nothing pulled or built ({s})", .{if (same) original[0].events_hash else "differs"});
}

/// Whether some events file of an events directory has `text`.
fn directory_has(context: *Context, directory: []const u8, text: []const u8) !bool {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(context.io, directory, .{ .iterate = true }) catch return false;
    defer dir.close(context.io);
    var iterator = dir.iterate();
    while (try iterator.next(context.io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const path = try std.fs.path.join(context.arena, &.{ directory, entry.name });
        const content = try cwd.readFileAlloc(context.io, path, context.arena, .limited(1 << 30));
        if (std.mem.indexOf(u8, content, text) != null) return true;
    }
    return false;
}

/// Antithesis's "restarted nodes may change IP addresses": restarts asked for by the scenario;
/// the node answers at its name every time (hosts files follow it) and in some timeline came
/// back at a new address.
fn check_readdress(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const report = try explore(context, &.{
        "--program",  program, "--profile", "movable", "--scenario", "readdress", "--seed", "1",
        "--branches", "4",
    });
    const answers = std.mem.indexOf(u8, report, "PASS always                hit in    4/4 " ++
        "branches, failing in    0  a restarted node answers at its name") != null;
    const moved = std.mem.indexOf(u8, report, "PASS sometimes") != null and
        std.mem.indexOf(u8, report, "a restarted node comes back at a new address") != null;
    expect(context, answers and moved, "readdress: restarted nodes answer at their names, " ++
        "some at a new address", .{});
    if (!(answers and moved)) std.debug.print("{s}\n", .{lines_with(context.arena, report, &.{
        "FAIL", "PASS", "readdress",
    }) catch ""});
}

/// A targeted run (--changed): the Python maze with a diff of three lines, matched by their
/// line coverage although the diff names repository paths and the image has its own. The line
/// every timeline runs ran in all, the first digit's in some, and the tree returned to them just
/// after; the solved maze's line never ran.
fn check_changed(context: *Context) !void {
    const arena = context.arena;
    const record = try std.fmt.allocPrint(arena, "{s}/changed.jsonl", .{context.scratch});
    // One generation in flight: the tree returns from the second one on (with the default three,
    // 48 timelines would all be roots).
    const report = try explore(context, &.{
        "--compose",  "tests/antithesis-compat/python/compose.yaml", "--scenario", "maze",
        "--seed",     "1",                                           "--branches", "48",
        "--changed",  "tests/changed/maze.diff",                     "--record",   record,
        "--pipeline", "1",
    });
    const file = "tests/antithesis-compat/python/client/maze/singleton_driver_maze.py";
    const every = try std.fmt.allocPrint(arena, "ran in   48/48 timelines  {s}:24-24", .{file});
    const never = try std.fmt.allocPrint(arena, "NEVER RAN  {s}:23-23", .{file});
    const some = try std.fmt.allocPrint(arena, "{s}:17-17", .{file});
    const cwd = std.Io.Dir.cwd();
    const recorded = cwd.readFileAlloc(context.io, record, arena, .limited(64 << 20)) catch "";
    const passes = std.mem.indexOf(u8, report, "2 of 3 hunks ran") != null and
        std.mem.indexOf(u8, report, every) != null and
        std.mem.indexOf(u8, report, never) != null and
        std.mem.indexOf(u8, report, some) != null and
        std.mem.indexOf(u8, recorded, "just after it first ran changed code") != null;
    expect(context, passes, "changed: a targeted run says which hunks ran and which never did, " ++
        "and returns to changed code", .{});
    if (!passes) std.debug.print("{s}\n", .{lines_with(arena, report, &.{
        "changed code", "ran in", "NEVER", "tree:",
    }) catch ""});
}

/// libvoidstar.so, Antithesis's native library, in a node: Python (musl) loads it with ctypes,
/// and its SDK message is an event, its random number a decision (the same on a replay), its
/// coverage an edge event of the module, in the timeline's events.
fn check_voidstar(context: *Context) !void {
    const arena = context.arena;
    const code =
        \\det-nodes exec client python3 -c '
        \\import ctypes, json
        \\lib = ctypes.CDLL("/usr/lib/libvoidstar.so")
        \\lib.fuzz_get_random.restype = ctypes.c_uint64
        \\lib.init_coverage_module.restype = ctypes.c_uint64
        \\lib.notify_coverage.restype = ctypes.c_bool
        \\number = lib.fuzz_get_random()
        \\message = json.dumps({"event": "voidstar", "details": {"random": number}}).encode()
        \\lib.fuzz_json_data(message, len(message))
        \\lib.fuzz_flush()
        \\base = lib.init_coverage_module(3, b"none.sym.tsv")
        \\print("voidstar", number, base, lib.notify_coverage(ctypes.c_size_t(base + 1)))'
    ;
    var outputs: [2][]const u8 = undefined;
    var events_found = true;
    for (&outputs, 0..) |*output, attempt| {
        const events = try std.fmt.allocPrint(arena, "{s}/voidstar-{d}", .{
            context.scratch, attempt,
        });
        const report = try explore(context, &.{
            "--compose",    "tests/antithesis-compat/python/compose.yaml", "--scenario", "bank",
            "--seed",       "1",                                           "--branch",   "0",
            "--until",      "event=command_start",                         "--exec",     code,
            "--events-dir", events,
        });
        output.* = try lines_with(arena, report, &.{"voidstar"});
        const path = try std.fs.path.join(arena, &.{ events, "branch-0.jsonl" });
        const cwd = std.Io.Dir.cwd();
        const text = cwd.readFileAlloc(context.io, path, arena, .limited(64 << 20)) catch "";
        const event = std.mem.indexOf(u8, text, "\"event\": \"voidstar\"") != null; // json.dumps'.
        const edge = std.mem.indexOf(u8, text, "edge none.sym.tsv:1") != null;
        events_found = events_found and event and edge;
    }
    // notify_coverage answers False: the edge is reported once, never asked about again.
    const answered = std.mem.indexOf(u8, outputs[0], "voidstar ") != null and
        std.mem.indexOf(u8, outputs[0], "False") != null;
    const same = std.mem.eql(u8, outputs[0], outputs[1]);
    // Thread-local state would be the host program's (static-pie: local-exec): none at all.
    const library = try std.fs.path.join(arena, &.{ context.bin, "libvoidstar.so" });
    const tls_free = !(try elf_has_tls(context, library));
    const passes = answered and events_found and same and tls_free;
    expect(context, passes, "voidstar: a node's Python loads libvoidstar.so; its message, " ++
        "decision and coverage reach the timeline, the same twice", .{});
    if (!passes) std.debug.print("tls free: {}\n{s}\n{s}\n", .{
        tls_free, outputs[0], outputs[1],
    });
}

/// Whether an ELF file has a PT_TLS program header.
fn elf_has_tls(context: *Context, path: []const u8) !bool {
    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(context.io, path, context.arena, .limited(64 << 20));
    if (bytes.len < 64 or !std.mem.eql(u8, bytes[0..4], "\x7fELF")) return error.NotElf;
    const offset = std.mem.readInt(u64, bytes[0x20..][0..8], .little);
    const size = std.mem.readInt(u16, bytes[0x36..][0..2], .little);
    const count = std.mem.readInt(u16, bytes[0x38..][0..2], .little);
    for (0..count) |index| {
        const at = offset + index * size;
        if (at + 4 > bytes.len) return error.NotElf;
        const kind = std.mem.readInt(u32, bytes[at..][0..4], .little);
        if (kind == 7) return true; // PT_TLS
    }
    return false;
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
    return @trunc(seconds * std.time.ms_per_s);
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
    const middle_ms: u64 = @trunc((setup_s + branch_end_s) / 2 * 1000);
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
/// Snapshots saved to disk along a replay (saver.zig), each the pages changed since the one
/// before: the futures from each, loaded instead of booted to and replayed, are the futures a
/// replay to that moment forks.
fn check_saved(context: *Context) !void {
    const arena = context.arena;
    const program = try std.fs.path.join(arena, &.{ context.bin, "bank-test" });
    const tapes = try std.fmt.allocPrint(arena, "{s}/saved-tapes", .{context.scratch});
    const snapshots = try std.fmt.allocPrint(arena, "{s}/saved-snapshots", .{context.scratch});
    const common = [_][]const u8{ "--program", program, "--scenario", "bank", "--seed", "11" };
    const ran = try explore(context, &(common ++ [_][]const u8{
        "--branches", "2", "--branching", "flat", "--tape-dir", tapes,
    }));
    var lines = std.mem.tokenizeScalar(u8, ran, '\n');
    const vtime_s = while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "[branch ") or std.mem.indexOf(u8, line, " 1]") == null) continue;
        const text = field(line, "vtime=") orelse continue;
        break std.fmt.parseFloat(f64, std.mem.trimEnd(u8, text, "s")) catch continue;
    } else 0;
    const moments = [_]u64{ @trunc(vtime_s * 400), @trunc(vtime_s * 700) };
    const tape = try std.fmt.allocPrint(arena, "{s}/branch-1.jsonl", .{tapes});
    const saved = try explore(context, &(common ++ [_][]const u8{
        "--tape",           tape,
        "--save-snapshots", snapshots,
        "--save-at-ms",     try std.fmt.allocPrint(arena, "{d},{d}", .{ moments[0], moments[1] }),
    }));
    const saved_count = std.mem.count(u8, saved, "saved snapshot ");
    var same = vtime_s > 0;
    for (moments) |ms| {
        const at = try std.fmt.allocPrint(arena, "{d}", .{ms});
        const replayed = try explore(context, &(common ++ [_][]const u8{
            "--tape", tape, "--from-vtime-ms", at, "--branches", "4", "--jobs", "2",
        }));
        const name = try std.fmt.allocPrint(arena, "{s}/b1-{d}", .{ snapshots, ms });
        const loaded = try explore(context, &(common ++ [_][]const u8{
            "--from-snapshot", name, "--branches", "4", "--jobs", "2",
        }));
        var from_replay: [branches_max]Branch = undefined;
        var from_disk: [branches_max]Branch = undefined;
        const count = parse_branches(replayed, &from_replay);
        same = same and count == 4 and parse_branches(loaded, &from_disk) == count and
            same_timelines(from_replay[0..count], from_disk[0..count]);
    }
    expect(context, saved_count == 2 and same, "saved: {d} snapshots on disk along branch 1 " ++
        "(at {d} and {d} ms); the futures from each, loaded, are the ones a replay forks there", .{
        saved_count, moments[0], moments[1],
    });
    if (saved_count != 2) std.debug.print("{s}\n", .{saved});
}

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
