// SPDX-License-Identifier: MIT
//! End-to-end checks on the Linux host: the whole system, through the command line, as a user
//! runs it. `zig build e2e` (after building the guest kernel and initramfs, see README.md).
//!
//! Each check boots real VMs: exploration finds the examples' known bugs without overshoots,
//! branches replay from fresh boots with identical event hashes, tapes replay without their
//! strategy, and a tape refuses to replay on different inputs.
//!
//! Usage: e2e [--bin <dir>] [--guest <dir>] [--cache <dir>]
//!   --bin    built programs (zig-out/bin)       --guest  vmlinuz and base.cpio ($HOME/guest)
//!   --cache  determinismo's cache ($HOME/cache)
const std = @import("std");
const assert = std.debug.assert;

const Context = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    determinismo: []const u8,
    machine: []const []const u8,
    bin: []const u8,
    scratch: []const u8,
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
    var index: usize = 1;
    while (index + 1 < arguments.len) : (index += 2) {
        const flag = arguments[index];
        const value = arguments[index + 1];
        if (std.mem.eql(u8, flag, "--bin")) bin = value else if (std.mem.eql(u8, flag, "--guest")) {
            guest = value;
        } else if (std.mem.eql(u8, flag, "--cache")) cache = value else return error.Usage;
    }
    var context = Context{
        .arena = arena,
        .io = init.io,
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

    try check_example(&context, .{ .program = "bank-test", .scenario = "bank", .branches = 12 });
    try check_example(&context, .{ .program = "shop-test", .scenario = "prices", .branches = 4 });
    try check_tapes(&context);
    try check_python_strategy(&context);
    try check_builtin_properties(&context);
    try check_kernel_entropy(&context);
    try check_coverage(&context);
    try check_parallel(&context);
    try check_fork(&context);
    try check_compose(&context);
    try check_shards(&context);
    try check_stress(&context);
    try check_controller(&context);
    try check_clojure(&context);
    try check_k3s(&context);
    try check_script(&context);
    try check_tla(&context, try std.fs.path.join(arena, &.{ home, "opt", "tla", "tla2tools.jar" }));
    if (context.failures > 0) {
        std.debug.print("e2e: {d} checks failed\n", .{context.failures});
        std.process.exit(1);
    }
    std.debug.print("e2e: all checks passed\n", .{});
}

const Example = struct { program: []const u8, scenario: []const u8, branches: u32 };

/// Explores, then replays the first failing branch (if any) and the first passing one alone.
fn check_example(context: *Context, example: Example) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, example.program });
    const branches_text = try std.fmt.allocPrint(context.arena, "{d}", .{example.branches});
    const report = try explore(context, &.{
        "--program", program, "--scenario", example.scenario, "--seed", "7",
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
            "--program", program, "--scenario", example.scenario, "--seed", "7",
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
        "--program", program, "--scenario", "bank", "--seed", "11", "--branches", "4",
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
        "--compose", "examples/compose-python/compose.yaml", "--scenario", "maze",
    };
    const java = [_][]const u8{
        "--compose", "examples/compose-java/compose.yaml", "--scenario", "maze",
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
        "--seed",       "1",
        "--branches",   try std.fmt.allocPrint(arena, "{d}", .{maze.branches}),
        "--jobs",       try std.fmt.allocPrint(arena, "{d}", .{maze.jobs}),
        "--strategy",   strategy,
        "--tape-dir",   tapes,
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
        "--branches", "12", "--jobs", "1", "--strategy", "python3 plugins/python/extremes.py",
        "--tape-dir", tapes,
    }));
    var branches: [12]Branch = undefined;
    const count = parse_branches(report, &branches);
    expect(context, count == 12, "python strategy: explored {d} branches", .{count});
    if (count == 0) return;
    // The bandit tries its rates in order: branch 1 overrides 5% of the decisions.
    const tape = try std.fs.path.join(context.arena, &.{ tapes, "branch-1.jsonl" });
    const recorded = std.Io.Dir.cwd().readFileAlloc(context.io, tape, context.arena,
        .limited(1 << 24)) catch "";
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
    try check_k3s_compose(context, "examples/k3s/compose.yaml", "4096", "one node");
    try check_k3s_compose(context, "examples/k3s/cluster.yaml", "8192", "three nodes");
}

fn check_k3s_compose(
    context: *Context,
    compose: []const u8,
    memory_mib: []const u8,
    label: []const u8,
) !void {
    const common = [_][]const u8{
        "--compose", compose, "--scenario", "cluster", "--seed", "1", "--memory-mib", memory_mib,
    };
    const report = try explore(context, &(common ++ [_][]const u8{ "--branches", "4" }));
    const passes = std.mem.indexOf(u8, report, "4 branches, 0 with failing properties") != null;
    expect(context, passes, "k3s ({s}): the workload survives faults in 4 branches", .{label});
    var branches: [4]Branch = undefined;
    const count = parse_branches(report, &branches);
    if (count == 0) return;
    const index = try std.fmt.allocPrint(context.arena, "{d}", .{branches[0].index});
    const replay = try explore(context, &(common ++ [_][]const u8{ "--branch", index }));
    var replayed: [1]Branch = undefined;
    const same = parse_branches(replay, &replayed) == 1 and
        std.mem.eql(u8, replayed[0].events_hash, branches[0].events_hash);
    expect(context, same, "k3s ({s}): branch {d} replays exactly", .{ label, branches[0].index });
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
        const log = std.Io.Dir.cwd().readFileAlloc(context.io, events, context.arena,
            .limited(1 << 24)) catch "";
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
        "--program", program, "--profile", "default,mutant", "--scenario", "steady",
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
        "--program", program, "--profile", "memory", "--scenario", "oom", "--seed", "1",
        "--branches", "1",
    });
    const workers = try explore(context, &.{
        "--program", program, "--profile", "workers", "--scenario", "steady", "--seed", "1",
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
    const common = [_][]const u8{
        "--compose", "examples/clojure-bank/compose.yaml", "--scenario", "bank", "--seed", "5",
    };
    const spec = "examples/clojure-bank/tla/Bank.tla";
    const scratch = context.scratch;
    const buggy_events = try std.fs.path.join(context.arena, &.{ scratch, "tla-buggy.jsonl" });
    const buggy = [_][]const u8{ "--branch", "1", "--events", buggy_events };
    _ = try explore(context, &(common ++ buggy));
    const fixed_events = try std.fs.path.join(context.arena, &.{ scratch, "tla-fixed.jsonl" });
    _ = try explore(context, &(common ++ [_][]const u8{
        "--from-branch", "1",        "--from-vtime-ms", "3000",
        "--from-exec",   "det-nodes exec bank /app/patch.sh", "--branch", "2",
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
    const common = [_][]const u8{
        "--compose", "examples/clojure-bank/compose.yaml", "--scenario", "bank", "--seed", "5",
    };
    const fork = common ++ [_][]const u8{
        "--from-branch", "0", "--from-vtime-ms", "3000", "--branches", "4",
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

/// Self-test level 1 (§14): the HTTP API under faults keeps every run and its result.
fn check_controller(context: *Context) !void {
    const program = try std.fs.path.join(context.arena, &.{ context.bin, "det-selftest" });
    const report = try explore(context, &.{
        "--program", program, "--profile", "controller", "--scenario", "controller",
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
    const common = [_][]const u8{
        "--compose", "examples/compose-bank/compose.yaml", "--scenario", "bank", "--seed", "3",
    };
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
