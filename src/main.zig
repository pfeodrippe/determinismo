// SPDX-License-Identifier: MIT
//! The determinismo command line.
//!
//!   run       boot one timeline from scratch
//!   explore   boot once, snapshot at setup_complete, then run many branches from the snapshot,
//!             each with its own decisions, and report properties across the multiverse
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const VM = @import("vm.zig");
const Snapshot = @import("snapshot.zig");
const Events = @import("events.zig");
const report = @import("report.zig");
const Strategy = @import("strategy.zig");
const tape = @import("tape.zig");
const prepare = @import("prepare.zig");
const serve = @import("serve.zig");
const mcp = @import("mcp.zig");
const merge = @import("merge.zig");
const script = @import("script.zig");
const tla = @import("tla.zig");
const query = @import("query.zig");
const causality = @import("causality.zig");
const extract = @import("extract.zig");
const event_sets = @import("event_sets.zig");
const profiler = @import("profile.zig");

const usage =
    \\usage: determinismo run     <machine options> [--trace <out.txt>] [--events <out.jsonl>]
    \\       determinismo serve   [--listen <address:port>] [--data <dir>] [--archive "<cmd>"]
    \\                            <machine options>
    \\       determinismo mcp     <machine options>   (an MCP server on stdio, for agents)
    \\       determinismo explore <machine options> [--branches <n>] [--branch <index>] [--jobs <n>]
    \\                            [--time-budget <duration>]   (e.g. 90s, 10m, 2h: timelines until
    \\                            then, --branches at most)
    \\                            [--branching flat|tree]   (tree: also from moments of earlier
    \\                            branches that reached new behaviors; replay one by its tape)
    \\                            [--strategy "<plugin> <args>"] [--tape-dir <dir>]
    \\                            [--tape <branch.jsonl>]
    \\                            [--at-vtime-ms <ms>] [--until '<condition>' [--rewind-ms <ms>]]
    \\                            (both: the condition, or that time at the latest)
    \\                            [--exec "<cmd>" | --exec-script <file>]
    \\                            [--continue]   (after --exec, run on to the end)
    \\                            [--from-branch <index> --from-vtime-ms <ms> [--from-exec "<cmd>"]]
    \\                            [--record <results.jsonl>] [--shard <k>/<n>]
    \\                            [--cpu-modulation]   (branches run at varying speeds)
    \\                            [--serve <host:port>]   (a run of that serve, in its web UI)
    \\                            [--events-dir <dir>]   (every branch's events, for query)
    \\       determinismo merge   <results.jsonl>...   (the records of an exploration's shards)
    \\       determinismo script  <events.jsonl>       (a branch's shape, for --script)
    \\       determinismo tla     --spec <Spec.tla> --events <events.jsonl> [--tla2tools <jar>]
    \\       determinismo query   <events-dir> '<condition>' [temporal conditions] (see query.zig)
    \\       determinismo events  <events-dir> '<pipeline>' (event sets, see event_sets.zig)
    \\       determinismo causality <options> --branch <n> --property '<message>' [--points <k>]
    \\       determinismo extract <options> --branch <n> (--at-vtime-ms <ms> | --until '<cond>')
    \\                            --file <node>:<path> --to <local file>
    \\       determinismo inject  <options> --branch <n> (--at-vtime-ms <ms> | --until '<cond>')
    \\                            --file <node>:<path> --from <local file> [--mode <octal>]
    \\                            [--then '<command>'] [--continue]
    \\       determinismo profile <options> --branch <n> (--at-vtime-ms <ms> | --until '<cond>')
    \\                            --node <node> [--ms <duration>] [--interval-us <us>] [--all]
    \\                            [--pid <pid>] [--svg <flame graph.svg>] [--folded <file>]
    \\       determinismo stacks  <options> --branch <n> (--at-vtime-ms <ms> | --until '<cond>')
    \\                            --node <node> [--pid <pid>]   (every thread's stack there)
    \\
    \\system options (instead of --disk; see ARCHITECTURE.md §10):
    \\  (--program <test program> | --compose <compose.yaml>) [--profile <name>|<a,b,..>|all]
    \\  [--scenario <name>|all] [--cache <dir>] [--script <script.json>]
    \\
    \\machine options:
    \\  --kernel <bzImage> [--initrd <file>] [--memory-mib <n>] [--disk <image>]...
    \\  [--cmdline <text> | --append <text>] [--deterministic] [--seed <n>]
    \\  [--margin-branches <n>] [--timer-slack-us <n>]
    \\
    \\--deterministic needs the determinismo-patched KVM; explore implies it.
    \\
;

/// print-fatal-signals: the kernel logs every process killed by a core-dumping signal (segfault,
/// abort, ...), even after a handler printed a trace: det-init's "no process crashes" reads it.
const cmdline_default = "console=ttyS0 earlyprintk=serial,ttyS0 acpi=off pci=off nokaslr " ++
    "reboot=t panic=-1 i8042.nokbd i8042.noaux tsc=reliable no_timer_check " ++
    "print-fatal-signals=1";
const memory_mib_min = 64;
const memory_mib_max = VM.memory_size_max >> 20;
const arguments_max = 64;
const branches_max = 100_000;

const Command = enum { run, explore };

const Arguments = struct {
    command: Command,
    kernel_path: []const u8 = "",
    initrd_path: ?[]const u8 = null,
    memory_mib: u32 = 1024,
    cmdline: []const u8 = cmdline_default,
    deterministic: bool = false,
    seed: u64 = 0,
    margin_branches: u32 = 128,
    timer_slack_us: u64 = 100,
    /// The raw PMU event that is the guest's clock (see VM.Options.branch_event).
    branch_event: u64 = 0x01c4,
    events_path: ?[]const u8 = null,
    /// The resolved system (nodes, scenarios), recorded with the run: its environment.
    system: ?std.json.Value = null,
    /// The moment is the first event matching this (`--until '<condition>'`, query.zig).
    until: ?*const query.Condition = null,
    /// Every branch's events: setup.jsonl (boot and setup, shared), fork.jsonl (from the
    /// snapshot to a fork point), branch-<index>.jsonl (each branch after them).
    events_directory: ?[]const u8 = null,
    trace_path: ?[]const u8 = null,
    branches: u32 = 16,
    branches_given: bool = false,
    /// flat: every branch from the setup snapshot; tree: from moments of earlier branches too.
    branching: enum { flat, tree } = .flat,
    /// Explore until this much wall time has passed (from the start, boot included), at most
    /// `branches` timelines: as many as fit, as an Antithesis run's duration.
    time_budget_ns: ?u64 = null,
    time_budget_text: ?[]const u8 = null,
    /// Run only this branch (to replay one timeline of an exploration).
    branch_only: ?u32 = null,
    strategy_command: ?[]const u8 = null,
    tape_directory: ?[]const u8 = null,
    /// Replay the branch recorded in this tape.
    tape_path: ?[]const u8 = null,
    /// Explore from a moment of a branch: replay branch `from_branch` to `from_vtime_ms`,
    /// snapshot there, and branch from that snapshot.
    from_branch: ?u32 = null,
    from_vtime_ms: ?u64 = null,
    /// A command to run at the fork point before exploring its futures.
    from_exec: ?[]const u8 = null,
    /// After --exec at the moment, run on to the end of the timeline.
    moment_continue: bool = false,
    cpu_modulation: bool = false,
    /// Run the exploration in a `determinismo serve` at this address (host:port) instead of
    /// here: it then shows in the web UI, with its record, events, tapes and notebook.
    serve_address: ?[]const u8 = null,
    /// This host runs the branches whose index modulo `shard_count` is `shard_index`
    /// (`--shard k/n`); `determinismo merge` combines the shards' records.
    shard_index: u32 = 0,
    shard_count: u32 = 1,
    /// Write results as JSON lines here (see report.record).
    record_path: ?[]const u8 = null,
    /// Parallel workers for branches (default: one per available CPU).
    jobs: ?u32 = null,
    /// Multiverse debugging: stop the (single) branch at this virtual time, run this there.
    moment_vtime_ms: ?u64 = null,
    /// With --until: the moment this long (virtual time) before the condition first holds.
    rewind_ms: ?u64 = null,
    moment_command: ?[]const u8 = null,
    /// Commands for the moment, one per line, run one after the other (instead of --exec).
    moment_script_path: ?[]const u8 = null,
    /// Read-only disk images, in guest order (/dev/vda first).
    disk_paths: [VM.disks_max][]const u8 = undefined,
    disk_count: u32 = 0,
    /// A test program: its system becomes the disks, its scenario the guest's work.
    program_path: ?[]const u8 = null,
    /// Or a Compose file: services become nodes, Antithesis test templates scenarios.
    compose_path: ?[]const u8 = null,
    /// Commands and faults follow this script (determinismo script) instead of choosing.
    script_path: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    scenario: ?[]const u8 = null,
    cache_directory: []const u8 = ".determinismo-cache",
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "serve")) return command_serve(init, argv[2..]);
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "mcp")) return command_mcp(init, argv[2..]);
    if (argv.len >= 2) {
        if (try command_tool(arena, init.io, argv)) |status| std.process.exit(status);
    }
    if (argv.len == 3 and std.mem.eql(u8, argv[1], "script")) {
        return script.extract(arena, init.io, argv[2]);
    }
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "merge")) {
        const failing = try merge.merge(arena, init.io, argv[2..]);
        if (failing > 0) std.process.exit(3);
        return;
    }
    const arguments = parse_arguments(arena, argv) catch {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    };
    if (arguments.serve_address) |address| return submit(arena, arguments, address);
    const vm = try arena.create(VM); // Large (port statistics): never on the stack.
    const profile = arguments.profile orelse "";
    const all = std.mem.eql(u8, profile, "all");
    const several = std.mem.indexOfScalar(u8, profile, ',') != null;
    if (!all and !several) {
        if (try system_run(init, vm, arguments) > 0) std.process.exit(3);
        return;
    }
    // Several profiles (e.g. a system and its mutants): their own disks, snapshot and verdict.
    const names = if (all) try prepare.profile_names(arena, init.io, .{
        .program = arguments.program_path,
        .compose = arguments.compose_path,
        .cache_directory = arguments.cache_directory,
    }) else try list_split(arena, profile);
    const verdicts = try arena.alloc(u32, names.len);
    for (names, verdicts) |name, *failing| {
        std.debug.print("[determinismo] profile {s}\n", .{name});
        var copy = arguments;
        copy.profile = name;
        failing.* = try system_run(init, vm, copy);
    }
    std.debug.print("[determinismo] profiles:\n", .{});
    for (names, verdicts) |name, failing| {
        const status = if (failing > 0) "FAIL" else "PASS";
        const line = "  {s} {s} ({d} scenarios with failing properties)\n";
        std.debug.print(line, .{ status, name, failing });
    }
    for (verdicts) |failing| if (failing > 0) std.process.exit(3);
}

/// The commands that read what explorations wrote (tla, query, causality): their exit status,
/// or null for other commands. A usage error exits with 2.
fn command_tool(arena: std.mem.Allocator, io: std.Io, argv: []const [:0]const u8) !?u8 {
    const eql = std.mem.eql;
    const name = argv[1];
    const rest = argv[2..];
    const result = if (eql(u8, name, "causality"))
        causality.run(arena, io, argv[0], rest)
    else if (eql(u8, name, "extract"))
        extract.run(arena, io, argv[0], rest)
    else if (eql(u8, name, "inject"))
        extract.inject_run(arena, io, argv[0], rest)
    else if (eql(u8, name, "profile"))
        profiler.run(arena, io, argv[0], rest)
    else if (eql(u8, name, "stacks"))
        profiler.stacks_run(arena, io, argv[0], rest)
    else if (eql(u8, name, "query"))
        query.run(arena, io, rest)
    else if (eql(u8, name, "events"))
        event_sets.run(arena, io, rest)
    else if (eql(u8, name, "tla"))
        tla.check(arena, io, rest)
    else
        return null;
    return result catch |err| {
        std.debug.print("{s}\n{s}", .{ @errorName(err), usage });
        return 2;
    };
}

fn list_split(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.tokenizeScalar(u8, text, ',');
    while (parts.next()) |name| try names.append(arena, name);
    return names.items;
}

/// Prepares the system (if any), then runs or explores its scenarios. Returns the number of
/// scenarios with failing properties.
fn system_run(init: std.process.Init, vm: *VM, arguments_given: Arguments) !u32 {
    const arena = init.arena.allocator();
    var arguments = arguments_given;
    const has_system = arguments.program_path != null or arguments.compose_path != null;
    const prepared = if (has_system) try system_prepare(arena, init.io, &arguments) else null;
    const cwd = std.Io.Dir.cwd();
    if (arguments.moment_script_path) |path| {
        const lines = try cwd.readFileAlloc(init.io, path, arena, .unlimited);
        arguments.moment_command = try commands_join(arena, lines);
    }
    const kernel = try cwd.readFileAlloc(init.io, arguments.kernel_path, arena, .unlimited);
    const initrd = if (arguments.initrd_path) |path|
        try cwd.readFileAlloc(init.io, path, arena, .unlimited)
    else
        null;
    var options = VM.Options{
        .memory_size = @as(u64, arguments.memory_mib) << 20,
        .kernel = kernel,
        .initrd = initrd,
        .cmdline = arguments.cmdline,
        .deterministic = arguments.deterministic,
        .seed = arguments.seed,
        .margin_branches = arguments.margin_branches,
        .timer_slack_ns = arguments.timer_slack_us * std.time.ns_per_us,
        .branch_event = arguments.branch_event,
        .events_fd = if (arguments.events_path) |path| try open_for_writing(arena, path) else null,
        .events_parse_buffer = try arena.alloc(u8, Events.parse_buffer_size),
        .trace_fd = if (arguments.trace_path) |path| try open_for_writing(arena, path) else null,
        .moment_vtime_ns = if (arguments.moment_vtime_ms) |ms| ms * std.time.ns_per_ms else null,
        .moment_command = arguments.moment_command,
        .until = arguments.until,
        .disks = try open_disks(arena, arguments.disk_paths[0..arguments.disk_count]),
        .builtin_properties = has_system,
        .cpu_modulation = arguments.cpu_modulation,
    };
    const context = Context{
        .arena = arena,
        .io = init.io,
        .environ = init.minimal.environ.block.slice,
    };
    const base_cmdline = arguments.cmdline;
    var failing_scenarios: u32 = 0;
    var catalog = report.Catalog{ .arena = arena };
    const scenarios = try scenarios_selected(arena, &arguments, prepared);
    for (scenarios) |scenario| {
        options.cmdline = try cmdline_build(arena, base_cmdline, arguments.disk_count, scenario);
        if (scenario) |name| std.debug.print("[determinismo] scenario {s}\n", .{name});
        switch (arguments.command) {
            .run => try command_run(vm, &options),
            .explore => {
                const multiverse = try command_explore(context, vm, &options, &arguments);
                failing_scenarios += @intFromBool(multiverse.failing_properties() > 0);
                try multiverse.catalog_reached(&catalog);
            },
        }
    }
    // Catalogs span scenarios (a test program's, a service serving several): an assertion
    // must be reached in some scenario, judged once all ran.
    const every_scenario = if (prepared) |known| scenarios.len == known.system.scenarios.len else
        true;
    if (catalog.judge(every_scenario) > 0) failing_scenarios += 1;
    return failing_scenarios;
}

/// `explore --serve <host:port>`: the exploration becomes a run of that `serve` (its machine
/// options apply), so it shows in the web UI. Prints the run's address.
fn submit(arena: std.mem.Allocator, arguments: Arguments, address_text: []const u8) !void {
    if (arguments.command != .explore) return error.Usage;
    const colon = std.mem.lastIndexOfScalar(u8, address_text, ':') orelse return error.Usage;
    const port = try std.fmt.parseInt(u16, address_text[colon + 1 ..], 10);
    const host = address_text[0..colon];
    var address: [4]u8 = .{ 127, 0, 0, 1 };
    if (!std.mem.eql(u8, host, "localhost")) {
        var parts = std.mem.splitScalar(u8, host, '.');
        for (&address) |*byte| byte.* = try std.fmt.parseInt(u8, parts.next() orelse "", 10);
    }
    const Request = struct {
        program: ?[]const u8,
        compose: ?[]const u8,
        scenario: ?[]const u8,
        profile: ?[]const u8,
        seed: u64,
        branches: ?u32,
        time_budget: ?[]const u8,
        branching: []const u8,
        jobs: ?u32,
        strategy: ?[]const u8,
        from_branch: ?u32,
        from_vtime_ms: ?u64,
        cpu_modulation: bool,
    };
    const body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(Request{
        .program = arguments.program_path,
        .compose = arguments.compose_path,
        .scenario = arguments.scenario,
        .profile = arguments.profile,
        .seed = arguments.seed,
        .branches = if (arguments.branches_given) arguments.branches else null,
        .time_budget = arguments.time_budget_text,
        .branching = @tagName(arguments.branching),
        .jobs = arguments.jobs,
        .strategy = arguments.strategy_command,
        .from_branch = arguments.from_branch,
        .from_vtime_ms = arguments.from_vtime_ms,
        .cpu_modulation = arguments.cpu_modulation,
    }, .{})});
    var buffer: [256]u8 = undefined;
    const tcp = @import("determinismo").tcp;
    const response = try tcp.http(address, port, "POST", "/runs", body, &buffer);
    if (response.status != 201) {
        std.debug.print("[determinismo] serve refused the run ({d}): {s}\n", .{
            response.status, response.body,
        });
        return error.ServeRefused;
    }
    const Created = struct { id: u32 };
    const created = try std.json.parseFromSliceLeaky(Created, arena, response.body, .{});
    std.debug.print("[determinismo] run {d}: http://{s}/#{d}\n", .{
        created.id, address_text, created.id,
    });
}

/// `determinismo serve [--listen <address:port>] [--data <dir>] <machine options>`: the HTTP
/// API (serve.zig). Machine options are passed to every run it starts.
fn command_serve(init: std.process.Init, argv: []const [:0]const u8) !void {
    const arena = init.arena.allocator();
    var listen: []const u8 = "127.0.0.1:7878";
    var data: []const u8 = ".determinismo-data";
    var explorer: ?[]const u8 = null;
    var archive: ?[]const u8 = null;
    var bb: []const u8 = "bb";
    var machine: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const flag = argv[index];
        const value = if (index + 1 < argv.len) argv[index + 1] else "";
        if (std.mem.eql(u8, flag, "--listen")) {
            listen = value;
            index += 1;
        } else if (std.mem.eql(u8, flag, "--data")) {
            data = value;
            index += 1;
        } else if (std.mem.eql(u8, flag, "--archive")) {
            archive = value;
            index += 1;
        } else if (std.mem.eql(u8, flag, "--explorer")) {
            explorer = value; // Self-tests: a stand-in for `determinismo explore`.
            index += 1;
        } else if (std.mem.eql(u8, flag, "--bb")) {
            bb = value;
            index += 1;
        } else {
            try machine.append(arena, flag);
        }
    }
    var self_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const self_size = linux.readlink("/proc/self/exe", &self_buffer, self_buffer.len);
    if (linux.errno(self_size) != .SUCCESS) return error.SelfPath;
    try serve.serve(arena, init.io, .{
        .listen = listen,
        .data_directory = data,
        .machine = machine.items,
        .self = explorer orelse self_buffer[0..self_size],
        .archive = archive,
        .bb = bb,
    });
}

/// `determinismo mcp <machine options>`: an MCP server on stdio (mcp.zig).
fn command_mcp(init: std.process.Init, argv: []const [:0]const u8) !void {
    const arena = init.arena.allocator();
    const machine = try arena.alloc([]const u8, argv.len);
    for (argv, machine) |argument, *target| target.* = argument;
    var self_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const self_size = linux.readlink("/proc/self/exe", &self_buffer, self_buffer.len);
    if (linux.errno(self_size) != .SUCCESS) return error.SelfPath;
    try mcp.serve(arena, init.io, .{
        .machine = machine,
        .self = self_buffer[0..self_size],
        .scratch_directory = "/tmp/determinismo-mcp",
    });
}

/// Builds the disks of the program's system and records what was resolved.
fn system_prepare(
    arena: std.mem.Allocator,
    io: std.Io,
    arguments: *Arguments,
) !prepare.Prepared {
    if (arguments.disk_count > 0) return error.DisksAndProgram;
    if (arguments.program_path != null and arguments.compose_path != null) return error.Usage;
    const prepared = try prepare.prepare(arena, io, .{
        .program = arguments.program_path,
        .compose = arguments.compose_path,
        .script = arguments.script_path,
        .profile = arguments.profile,
        .cache_directory = arguments.cache_directory,
    });
    if (prepared.disk_paths.len > VM.disks_max) return error.TooManyDisks;
    const system_json = prepared.system_json;
    arguments.system = try std.json.parseFromSliceLeaky(std.json.Value, arena, system_json, .{});
    for (prepared.disk_paths, 0..) |path, index| arguments.disk_paths[index] = path;
    arguments.disk_count = @intCast(prepared.disk_paths.len);
    std.debug.print("[determinismo] system {x:0>16}: profile {s}, {d} nodes, disk {s}\n", .{
        prepared.hash, prepared.system.profile, prepared.system.nodes.len, prepared.disk_paths[0],
    });
    return prepared;
}

/// The scenarios to run, one at a time (null: the guest decides, as without --program).
fn scenarios_selected(
    arena: std.mem.Allocator,
    arguments: *const Arguments,
    prepared: ?prepare.Prepared,
) ![]const ?[]const u8 {
    const system = (prepared orelse return &.{null}).system;
    const wanted = arguments.scenario orelse if (system.scenarios.len == 1)
        system.scenarios[0].name
    else {
        std.debug.print("[determinismo] pick a scenario with --scenario (or all)\n", .{});
        return error.Usage;
    };
    if (std.mem.eql(u8, wanted, "all")) {
        const all = try arena.alloc(?[]const u8, system.scenarios.len);
        for (system.scenarios, all) |scenario, *name| name.* = scenario.name;
        return all;
    }
    if (system.scenario(wanted) == null) {
        std.debug.print("[determinismo] no scenario named {s}\n", .{wanted});
        return error.Usage;
    }
    const one = try arena.alloc(?[]const u8, 1);
    one[0] = wanted;
    return one;
}

fn cmdline_build(
    arena: std.mem.Allocator,
    base: []const u8,
    disk_count: u32,
    scenario: ?[]const u8,
) ![]const u8 {
    var parts: [3][]const u8 = undefined;
    var count: u32 = 0;
    parts[count] = base;
    count += 1;
    if (disk_count > 0) {
        parts[count] = try VM.disks_cmdline(arena, disk_count);
        count += 1;
    }
    if (scenario) |name| {
        parts[count] = try std.fmt.allocPrint(arena, "det.scenario={s}", .{name});
        count += 1;
    }
    return std.mem.join(arena, " ", parts[0..count]);
}

fn command_run(vm: *VM, options: *const VM.Options) !void {
    assert(!options.stop_at_setup_complete);
    try vm.init(options);
    defer vm.deinit();
    const time_start_ns = monotonic_ns();
    const outcome = try vm.run_until_exit();
    try report.run(vm, .{ .outcome = outcome, .wall_ns = monotonic_ns() - time_start_ns });
    switch (outcome) {
        .failed => std.process.exit(1),
        .debug_exit => |status| std.process.exit(status),
        .shutdown, .hlt, .moment_reached, .command_done => {},
        .setup_complete => unreachable,
    }
}

const Context = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    /// determinismo's environment, which strategy plugins inherit.
    environ: [:null]const ?[*:0]const u8,
};

/// What drives the branches of one exploration besides the seed.
const Exploration = struct {
    /// Set when branching from a moment of another branch.
    fork: ?tape.Fork = null,
    /// Identifies what the machine boots; recorded in tapes.
    inputs: u64 = 0,
    exploration_seed: u64,
    strategy: ?*Strategy = null,
    tape_directory: ?[]const u8 = null,
    /// Set when replaying one recorded branch.
    replay: ?struct { header: tape.Header, overrides: *tape.Overrides } = null,
};

/// Boots once to setup_complete, snapshots, then runs every branch from the snapshot.
/// Returns the multiverse: its verdict, and what the test program's catalog saw.
fn command_explore(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    arguments: *const Arguments,
) !*const report.Multiverse {
    assert(options.deterministic);
    var exploration = Exploration{
        .exploration_seed = arguments.seed,
        .tape_directory = arguments.tape_directory,
    };
    if (arguments.tape_directory) |directory| {
        try std.Io.Dir.cwd().createDirPath(context.io, directory);
    }
    exploration.inputs = inputs_hash(options, arguments);
    const signature = host_cpu_signature()[3];
    std.debug.print("[determinismo] inputs {x:0>16} (determinism ABI {d}, CPU signature " ++
        "{x:0>8})\n", .{ exploration.inputs, VM.determinism_abi, signature });
    if (arguments.record_path) |path| {
        if (report.record_fd == null) {
            report.record_fd = try open_for_appending(context.arena, path);
        }
        report.record(.{ .run = .{
            .scenario = scenario_of(options.cmdline),
            .profile = arguments.profile,
            .program = arguments.program_path,
            .compose = arguments.compose_path,
            .system = arguments.system,
            .inputs = &hex16(exploration.inputs),
            .seed = &hex16(arguments.seed),
            .branches = arguments.branches,
            .from_branch = arguments.from_branch,
            .from_vtime_ms = arguments.from_vtime_ms,
            .shard = &.{ arguments.shard_index, arguments.shard_count },
            .time_budget_s = if (arguments.time_budget_ns) |ns| ns / std.time.ns_per_s else null,
            .jobs = jobs_count(arguments),
            .strategy = arguments.strategy_command,
            .branching = @tagName(arguments.branching),
        } });
    }
    if (arguments.tape_path) |path| {
        const overrides = try context.arena.create(tape.Overrides);
        const cwd = std.Io.Dir.cwd();
        const source = try cwd.readFileAlloc(context.io, path, context.arena, .unlimited);
        const scratch = try context.arena.alloc(u8, 64 * 1024);
        const header = try tape.parse(source, scratch, overrides);
        if (header.inputs != exploration.inputs) {
            std.debug.print("[determinismo] the tape was recorded with inputs {x:0>16}; " ++
                "these are {x:0>16} (kernel, initramfs, command line or disks differ)\n", .{
                header.inputs, exploration.inputs,
            });
            return error.TapeInputsDiffer;
        }
        exploration.exploration_seed = header.exploration_seed;
        exploration.replay = .{ .header = header, .overrides = overrides };
        exploration.fork = header.fork;
    }
    if (arguments.from_branch) |branch| {
        if (exploration.replay != null) return error.Usage; // The tape says where it forked.
        exploration.fork = .{
            .branch = branch,
            .vtime_ns = arguments.from_vtime_ms.? * 1_000_000,
            .exec = arguments.from_exec,
        };
    }
    if (arguments.strategy_command != null and exploration.replay != null) {
        return error.ReplayWithStrategy; // Tapes replace plugins.
    }
    const time_start_ns = monotonic_ns();
    options.seed = exploration.exploration_seed;
    const snapshot = try context.arena.create(Snapshot);
    if (arguments.events_directory) |directory| {
        try std.Io.Dir.cwd().createDirPath(context.io, directory);
        options.events_fd = try events_file(context.arena, directory, "setup.jsonl");
    }
    try explore_snapshot(vm, options, snapshot);
    report.snapshot_taken(snapshot, monotonic_ns() - time_start_ns);
    report.record(.{ .snapshot = .{
        .vtime_ns = snapshot.tsc / report.tsc_per_ns,
        .wall_ns = monotonic_ns() - time_start_ns,
    } });
    if (arguments.events_directory) |directory| {
        close(options.events_fd.?);
        options.events_fd = if (exploration.fork != null)
            try events_file(context.arena, directory, "fork.jsonl")
        else
            null;
    }
    var start = if (exploration.fork) |fork| try explore_fork(context, vm, options, .{
        .from = snapshot,
        .exploration = &exploration,
        .fork = fork,
    }) else snapshot;
    // A tree explorer's branch replays along its path: each ancestor to the moment the next
    // branched from it, snapshotted there as the exploration did.
    if (exploration.replay) |replay| {
        for (replay.header.chain) |segment| {
            const arena = context.arena;
            start = try node_make(arena, vm, options, start, segment.seed, segment.vtime_ns);
        }
    }
    if (arguments.events_directory != null) {
        if (options.events_fd) |fd| close(fd);
        options.events_fd = null; // Each branch writes its own file.
    }
    const multiverse = try context.arena.create(report.Multiverse);
    multiverse.* = .{};
    const branches = Branches{
        .snapshot = start,
        .multiverse = multiverse,
        .exploration = &exploration,
        .arguments = arguments,
        .deadline_ns = if (arguments.time_budget_ns) |ns| time_start_ns + ns else null,
    };
    const jobs = jobs_count(arguments);
    if (arguments.branching == .tree) {
        try explore_tree(context, vm, options, branches, jobs);
    } else if (jobs == 1) {
        try strategy_start(context, arguments, &exploration);
        defer if (exploration.strategy) |strategy| strategy.stop();
        try explore_branches(context, vm, options, branches);
    } else {
        if (arguments.time_budget_text) |budget| {
            std.debug.print("[determinismo] branches for {s} (at most {d}) on {d} workers\n", .{
                budget, arguments.branches, jobs,
            });
        } else {
            std.debug.print("[determinismo] {d} branches on {d} workers\n", .{
                arguments.branches, jobs,
            });
        }
        try explore_parallel(context, vm, options, branches, jobs);
    }
    multiverse.summarize(monotonic_ns() - time_start_ns);
    return multiverse;
}

const Fork = struct { from: *const Snapshot, exploration: *const Exploration, fork: tape.Fork };

/// Replays branch `fork.branch` of the setup snapshot to the moment and snapshots it there.
fn explore_fork(context: Context, vm: *VM, options: *VM.Options, fork: Fork) !*const Snapshot {
    const time_start_ns = monotonic_ns();
    try moment_after_snapshot(fork.from, fork.fork.vtime_ns);
    options.seed = branch_seed(fork.exploration.exploration_seed, fork.fork.branch);
    options.moment_vtime_ns = fork.fork.vtime_ns;
    options.moment_command = fork.fork.exec;
    const until = options.until;
    options.until = null; // The fork point is the moment; --until belongs to its branches.
    defer options.until = until;
    options.moment_continue = false;
    defer options.moment_vtime_ns = null;
    defer options.moment_command = null;
    try vm.init_from_snapshot(options, fork.from);
    const outcome = try vm.run_until_exit();
    const expected: VM.Outcome = if (fork.fork.exec != null) .command_done else .moment_reached;
    if (std.meta.activeTag(outcome) != std.meta.activeTag(expected)) {
        std.debug.print("[determinismo] branch {d} ended ({s}) before {d}ns\n", .{
            fork.fork.branch, @tagName(outcome), fork.fork.vtime_ns,
        });
        vm.deinit();
        return error.ForkPointNotReached;
    }
    const snapshot = try context.arena.create(Snapshot);
    try snapshot.take_copy(vm);
    vm.deinit();
    std.debug.print("[determinismo] forked branch {d} at vtime={d}ns branches={d} " ++
        "({d:.3}s wall); its branches follow\n", .{
        fork.fork.branch, fork.fork.vtime_ns, snapshot.branches,
        @as(f64, @floatFromInt(monotonic_ns() - time_start_ns)) / std.time.ns_per_s,
    });
    return snapshot;
}

/// Branches start at their snapshot: a moment before it would be in the past.
fn moment_after_snapshot(snapshot: *const Snapshot, vtime_ns: u64) !void {
    const snapshot_ns = snapshot.tsc / (cpuid_tsc_hz / std.time.ns_per_s);
    if (vtime_ns > snapshot_ns) return;
    std.debug.print("[determinismo] the moment {d}ns is not after the snapshot ({d}ns): " ++
        "branches start there\n", .{ vtime_ns, snapshot_ns });
    return error.MomentBeforeSnapshot;
}

const cpuid_tsc_hz = @import("cpuid.zig").tsc_hz;

fn strategy_start(context: Context, arguments: *const Arguments, exploration: *Exploration) !void {
    const command = arguments.strategy_command orelse return;
    const strategy = try context.arena.create(Strategy);
    try strategy.start(context.arena, command, context.environ);
    try strategy.hello(exploration.exploration_seed);
    exploration.strategy = strategy;
}

/// Workers for the branches: one per CPU this process may run on, unless one branch is asked
/// for or events are logged (one log, one timeline at a time).
fn jobs_count(arguments: *const Arguments) u32 {
    const single = arguments.branch_only != null or arguments.tape_path != null;
    if (single or arguments.events_path != null) return 1;
    const jobs = arguments.jobs orelse cpus_available();
    const shard_branches = std.math.divCeil(u32, arguments.branches, arguments.shard_count) catch
        unreachable;
    return @max(1, @min(jobs, shard_branches, jobs_max));
}

/// A duration: a number of seconds, or with a unit (`500ms`, `90s`, `10m`, `2h`).
fn duration_parse(text: []const u8) !u64 {
    const units = [_]struct { suffix: []const u8, ns: u64 }{
        .{ .suffix = "ms", .ns = std.time.ns_per_ms },
        .{ .suffix = "s", .ns = std.time.ns_per_s },
        .{ .suffix = "m", .ns = std.time.ns_per_min },
        .{ .suffix = "h", .ns = std.time.ns_per_hour },
    };
    for (units) |unit| {
        if (!std.mem.endsWith(u8, text, unit.suffix)) continue;
        const number = text[0 .. text.len - unit.suffix.len];
        // "10ms" also ends in "s": the longer suffix is tried first.
        if (number.len > 0 and std.ascii.isDigit(number[number.len - 1])) {
            return try std.math.mul(u64, try std.fmt.parseInt(u64, number, 10), unit.ns);
        }
    }
    return try std.math.mul(u64, try std.fmt.parseInt(u64, text, 10), std.time.ns_per_s);
}

test duration_parse {
    try std.testing.expectEqual(@as(u64, 500 * std.time.ns_per_ms), try duration_parse("500ms"));
    try std.testing.expectEqual(@as(u64, 90 * std.time.ns_per_s), try duration_parse("90s"));
    try std.testing.expectEqual(@as(u64, 90 * std.time.ns_per_s), try duration_parse("90"));
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_min), try duration_parse("10m"));
    try std.testing.expectEqual(@as(u64, 2 * std.time.ns_per_hour), try duration_parse("2h"));
    try std.testing.expectError(error.InvalidCharacter, duration_parse("ten"));
}

fn cpus_available() u32 {
    var set: linux.cpu_set_t = undefined;
    const result = linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &set);
    if (linux.errno(result) != .SUCCESS) return 1;
    var count: u32 = 0;
    for (set) |word| count += @popCount(word);
    return @max(count, 1);
}

/// Forks `jobs` workers after the snapshot: each makes its own VMs from it (copy-on-write) and
/// runs branches `index % jobs == worker`, then sends its results through a pipe. A branch's
/// timeline does not depend on which worker runs it.
fn explore_parallel(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    branches: Branches,
    jobs: u32,
) !void {
    assert(jobs > 1 and jobs <= jobs_max);
    var readers: [jobs_max]linux.fd_t = undefined;
    var pids: [jobs_max]linux.pid_t = undefined;
    for (0..jobs) |worker| {
        var pipe: [2]linux.fd_t = undefined;
        if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
        const pid = linux.fork();
        if (linux.errno(pid) != .SUCCESS) return error.Fork;
        if (pid == 0) {
            _ = linux.close(pipe[0]);
            worker_run(context, vm, options, branches, .{
                .worker = @intCast(worker),
                .jobs = jobs,
                .results_fd = pipe[1],
            });
        }
        _ = linux.close(pipe[1]);
        readers[worker] = pipe[0];
        pids[worker] = @intCast(pid);
    }
    const results = try context.arena.create(report.Multiverse);
    for (readers[0..jobs], pids[0..jobs]) |reader, pid| {
        var received = read_exact(reader, std.mem.asBytes(results));
        // Then a tree generation's summaries: their count, and each.
        if (branches.summaries) |summaries| {
            var count: u32 = 0;
            received = received and read_exact(reader, std.mem.asBytes(&count));
            received = received and summaries.count + count <= summaries.items.len;
            if (received) {
                const into = summaries.items[summaries.count..][0..count];
                received = read_exact(reader, std.mem.sliceAsBytes(into));
                summaries.count += count;
            }
        }
        _ = linux.close(reader);
        var status: i32 = 0;
        _ = linux.waitpid(pid, &status, 0);
        if (!received or status != 0) return error.WorkerFailed;
        try branches.multiverse.absorb(results);
    }
}

const Worker = struct { worker: u32, jobs: u32, results_fd: linux.fd_t };

fn worker_run(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    branches: Branches,
    worker: Worker,
) noreturn {
    cpu_pin(worker.worker);
    var exploration = branches.exploration.*;
    var mine = branches;
    mine.exploration = &exploration;
    mine.worker = worker.worker;
    mine.jobs = worker.jobs;
    mine.multiverse.* = .{};
    var summaries: Summaries = undefined;
    if (branches.summaries) |all| {
        summaries = .{ .items = all.items };
        mine.summaries = &summaries;
    }
    const ok = worker_explore(context, vm, options, mine, &exploration);
    if (ok) write_all(worker.results_fd, std.mem.asBytes(mine.multiverse));
    if (ok and branches.summaries != null) {
        write_all(worker.results_fd, std.mem.asBytes(&summaries.count));
        write_all(worker.results_fd, std.mem.sliceAsBytes(summaries.items[0..summaries.count]));
    }
    linux.exit_group(if (ok) 0 else 1);
}

fn worker_explore(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    branches: Branches,
    exploration: *Exploration,
) bool {
    strategy_start(context, branches.arguments, exploration) catch return false;
    defer if (exploration.strategy) |strategy| strategy.stop();
    explore_branches(context, vm, options, branches) catch |err| {
        std.debug.print("[determinismo] worker {d}: {s}\n", .{ branches.worker, @errorName(err) });
        return false;
    };
    return true;
}

/// Spreads workers over CPUs (VMs run faster when not migrated); best effort.
fn cpu_pin(worker: u32) void {
    var available: linux.cpu_set_t = undefined;
    const size = @sizeOf(linux.cpu_set_t);
    if (linux.errno(linux.sched_getaffinity(0, size, &available)) != .SUCCESS) return;
    const bits_per_word = @bitSizeOf(@TypeOf(available[0]));
    var seen: u32 = 0;
    for (0..available.len * bits_per_word) |cpu| {
        const word = available[cpu / bits_per_word];
        if (word >> @intCast(cpu % bits_per_word) & 1 == 0) continue;
        if (seen == worker % cpus_available()) {
            var set: linux.cpu_set_t = @splat(0);
            set[cpu / bits_per_word] = @as(@TypeOf(set[0]), 1) << @intCast(cpu % bits_per_word);
            _ = linux.sched_setaffinity(0, &set) catch {};
            return;
        }
        seen += 1;
    }
}

fn read_exact(fd: linux.fd_t, target: []u8) bool {
    var done: u64 = 0;
    while (done < target.len) {
        const result = linux.read(fd, target[done..].ptr, target.len - done);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS or result == 0) return false;
        done += result;
    }
    return true;
}

fn write_all(fd: linux.fd_t, bytes: []const u8) void {
    var done: u64 = 0;
    while (done < bytes.len) {
        const result = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS) return;
        done += result;
    }
}

fn explore_snapshot(vm: *VM, options: *VM.Options, snapshot: *Snapshot) !void {
    options.stop_at_setup_complete = true;
    defer options.stop_at_setup_complete = false;
    // Moments belong to branches: none during the run to the snapshot.
    const moment_vtime_ns = options.moment_vtime_ns;
    const moment_command = options.moment_command;
    const until = options.until;
    options.moment_vtime_ns = null;
    options.moment_command = null;
    options.until = null;
    defer options.moment_vtime_ns = moment_vtime_ns;
    defer options.moment_command = moment_command;
    defer options.until = until;
    try vm.init(options);
    const outcome = try vm.run_until_exit();
    if (outcome != .setup_complete) {
        std.debug.print("[determinismo] the guest never signalled setup_complete ({s})\n", .{
            @tagName(outcome),
        });
        std.process.exit(1);
    }
    try snapshot.take(vm);
    vm.deinit();
    assert(snapshot.branches > 0);
}

const Branches = struct {
    snapshot: *const Snapshot,
    multiverse: *report.Multiverse,
    exploration: *const Exploration,
    arguments: *const Arguments,
    /// No branch starts after this (monotonic_ns): the time budget.
    deadline_ns: ?u64 = null,
    /// The tree explorer's generation: which branches run, and where each starts. Null: the
    /// branches `0..arguments.branches`, all from `snapshot`.
    plan: ?[]const Planned = null,
    /// Where the branches of a plan tell how they went (behaviors, for the next generation).
    summaries: ?*Summaries = null,
    /// This process runs the branches whose index modulo `jobs` is `worker`.
    worker: u32 = 0,
    jobs: u32 = 1,
};

const jobs_max = 256;

fn explore_branches(context: Context, vm: *VM, options: *VM.Options, branches: Branches) !void {
    const exploration = branches.exploration;
    const replay_branch = if (exploration.replay) |replay| replay.header.branch else null;
    const first = replay_branch orelse branches.arguments.branch_only orelse 0;
    const single = replay_branch != null or branches.arguments.branch_only != null;
    const count = if (single) 1 else branches.arguments.branches;
    if (branches.arguments.moment_vtime_ms) |ms| {
        try moment_after_snapshot(branches.snapshot, ms * std.time.ns_per_ms);
    }
    const total = if (branches.plan) |plan| plan.len else count;
    for (0..total) |position| {
        const place = branch_place(branches, first + position, single, position) orelse continue;
        const index = place.index;
        if (branches.deadline_ns) |deadline| {
            if (monotonic_ns() >= deadline) break;
        }
        options.seed = place.seed;
        const moment_ms = branches.arguments.moment_vtime_ms;
        options.moment_vtime_ns = if (moment_ms) |ms| ms * std.time.ns_per_ms else null;
        options.moment_command = branches.arguments.moment_command;
        options.moment_continue = branches.arguments.moment_continue;
        options.until = branches.arguments.until;
        if (branches.arguments.rewind_ms) |ms| {
            try rewind(vm, options, branches.snapshot, exploration, ms * std.time.ns_per_ms);
        }
        try vm.init_from_snapshot(options, place.snapshot);
        defer vm.deinit();
        if (branches.arguments.events_directory) |directory| {
            const name = try std.fmt.allocPrint(context.arena, "branch-{d}.jsonl", .{index});
            vm.events.log_fd = try events_file(context.arena, directory, name);
        }
        defer if (branches.arguments.events_directory != null) close(vm.events.log_fd.?);
        vm.strategy = exploration.strategy;
        if (exploration.replay) |replay| vm.overrides = replay.overrides;
        if (exploration.strategy) |strategy| try strategy.branch(index, options.seed);
        if (exploration.tape_directory) |directory| {
            vm.tape_fd = try open_tape(context.arena, directory, index);
            tape.write_header(vm.tape_fd.?, .{
                .inputs = exploration.inputs,
                .exploration_seed = exploration.exploration_seed,
                .branch = index,
                .branch_seed = options.seed,
                .fork = exploration.fork,
                .chain = place.path,
            });
        }
        defer if (vm.tape_fd) |fd| close(fd);
        const time_start_ns = monotonic_ns();
        const outcome = try vm.run_until_exit();
        try branches.multiverse.add(vm, .{
            .index = index,
            .seed = options.seed,
            .outcome = outcome,
            .wall_ns = monotonic_ns() - time_start_ns,
            .start_tsc = place.snapshot.tsc,
            .path = place.path,
            .generation = place.generation,
            .why = place.why,
        });
        if (branches.summaries) |summaries| summaries.note(vm, place);
        if (exploration.strategy) |strategy| {
            const end = BranchResult{ .index = index, .outcome = outcome };
            if (try strategy_branch_end(strategy, vm, end)) break;
        }
    }
}

/// Where the branch at `position` starts, if this worker (and shard) runs it: the snapshot, or
/// (a tree explorer's branch) a moment of another.
fn branch_place(branches: Branches, index_flat: usize, single: bool, position: usize) ?Planned {
    if (branches.plan) |plan| {
        if (position % branches.jobs != branches.worker) return null;
        return plan[position];
    }
    const index: u32 = @intCast(index_flat);
    const shards = if (single) 1 else branches.arguments.shard_count;
    const shard = if (single) 0 else branches.arguments.shard_index;
    if (index % shards != shard) return null;
    if (index / shards % branches.jobs != branches.worker) return null;
    const exploration = branches.exploration;
    const replay = exploration.replay;
    return .{
        .index = index,
        .seed = if (replay) |tape_replay|
            tape_replay.header.branch_seed
        else
            branch_seed(seed_base(exploration), index),
        .snapshot = branches.snapshot,
        .path = if (replay) |tape_replay| tape_replay.header.chain else &.{},
    };
}

/// Where a branch starts and with what: the tree explorer plans these, a generation at a time.
const Planned = struct {
    index: u32,
    seed: u64,
    snapshot: *const Snapshot,
    /// From the setup snapshot to `snapshot`: the ancestors and the moments they branched.
    path: []const tape.Segment = &.{},
    generation: u32 = 0,
    /// Why it starts there, for people (the tree explorer's reason).
    why: []const u8 = "",
};

/// How a branch went, for planning the next generation: the behaviors it reached first, when.
const Summary = struct {
    index: u32,
    start_ns: u64,
    end_ns: u64,
    behavior_count: u32,
    behaviors: [Events.behavior_count_max]Events.Behavior,
};

const Summaries = struct {
    items: []Summary,
    count: u32 = 0,

    fn note(summaries: *Summaries, vm: *VM, place: Planned) void {
        assert(summaries.count < summaries.items.len);
        const summary = &summaries.items[summaries.count];
        summaries.count += 1;
        summary.index = place.index;
        summary.start_ns = place.snapshot.tsc / (cpuid_tsc_hz / std.time.ns_per_s);
        summary.end_ns = if (vm.moment()) |moment| moment.vtime_ns else |_| summary.start_ns;
        summary.behavior_count = vm.events.behavior_count;
        @memcpy(
            summary.behaviors[0..summary.behavior_count],
            vm.events.behaviors[0..vm.events.behavior_count],
        );
    }
};

/// Antithesis's exploration, as a tree: every branch is a potential branch point. The first
/// generation starts from the setup snapshot; after each, the branches that reached behaviors
/// no branch before them had are returned to (Go-Explore): a snapshot at the moment just after
/// the new behavior (replaying the branch to it), and new branches from there, with their own
/// seeds. Some branches of every generation start from the setup snapshot again. A generation
/// is planned only from the ones before it, so the tree is the same whatever the workers.
const tree = struct {
    const generation_size = 16;
    /// From the setup snapshot, in every generation after the first.
    const roots = 4;
    /// Moments returned to per generation, and branches from each.
    const nodes = 3;
    const children = (generation_size - roots) / nodes;
    comptime {
        assert(roots + nodes * children == generation_size);
    }
};

fn explore_tree(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    branches: Branches,
    jobs: u32,
) !void {
    const arena = context.arena;
    const exploration = branches.exploration;
    const total = branches.arguments.branches;
    const base = seed_base(exploration);
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var plan: std.ArrayList(Planned) = .empty;
    var next_index: u32 = 0;
    while (next_index < total and plan.items.len < tree.generation_size) : (next_index += 1) {
        try plan.append(arena, .{
            .index = next_index,
            .seed = branch_seed(base, next_index),
            .snapshot = branches.snapshot,
        });
    }
    var generation: u32 = 0;
    const items = try arena.alloc(Summary, tree.generation_size);
    while (plan.items.len > 0) : (generation += 1) {
        if (branches.deadline_ns) |deadline| {
            if (monotonic_ns() >= deadline) break;
        }
        var summaries = Summaries{ .items = items };
        var mine = branches;
        mine.plan = plan.items;
        mine.summaries = &summaries;
        const workers: u32 = @intCast(@min(jobs, plan.items.len));
        if (workers == 1) {
            try explore_branches(context, vm, options, mine);
        } else {
            try explore_parallel(context, vm, options, mine, workers);
        }
        // In index order (workers finish in any): what each reached that none before it had.
        const done = summaries.items[0..summaries.count];
        std.mem.sort(Summary, done, {}, summary_before);
        var candidates: [tree.generation_size]Candidate = undefined;
        var candidate_count: u32 = 0;
        const generation_seed = base ^ (@as(u64, generation) *% 0x9e3779b97f4a7c15);
        var random: std.Random.DefaultPrng = .init(generation_seed);
        for (done) |*summary| {
            var novel: u32 = 0;
            var moment: ?u64 = null;
            var label: []const u8 = "";
            // The frontier (Go-Explore): its latest new behavior that leaves room to go on (in
            // its first four fifths); the branches return just after it.
            const room_end = summary.start_ns + (summary.end_ns -| summary.start_ns) / 5 * 4;
            for (summary.behaviors[0..summary.behavior_count]) |behavior| {
                const known = try seen.getOrPut(arena, behavior.hash);
                if (known.found_existing) continue;
                novel += 1;
                if (behavior.vtime_ns <= room_end) {
                    moment = behavior.vtime_ns;
                    label = behavior.name();
                }
            }
            candidates[candidate_count] = .{
                .summary = summary,
                .novel = novel,
                .moment = moment,
                .label = label,
            };
            candidate_count += 1;
        }
        const chosen = candidates[0..candidate_count];
        std.mem.sort(Candidate, chosen, {}, candidate_before);
        var next: std.ArrayList(Planned) = .empty;
        var made: u32 = 0;
        for (chosen) |candidate| {
            if (made == tree.nodes or next_index >= total) break;
            const summary = candidate.summary;
            const parent = for (plan.items) |entry| {
                if (entry.index == summary.index) break entry;
            } else unreachable;
            // Just after a new behavior, else (nothing new) anywhere in the branch.
            const span = summary.end_ns -| summary.start_ns;
            if (span < 2 * std.time.ns_per_ms) continue;
            const after = if (candidate.moment) |moment| moment + std.time.ns_per_us else
                summary.start_ns + random.random().uintLessThan(u64, span);
            const at = std.math.clamp(
                after,
                summary.start_ns + std.time.ns_per_ms,
                summary.end_ns - std.time.ns_per_ms,
            );
            const from = parent.snapshot;
            const snapshot = node_make(arena, vm, options, from, parent.seed, at) catch |err| {
                std.debug.print("[determinismo] tree: no snapshot at {d}ns of branch {d}: {s}\n", .{
                    at, parent.index, @errorName(err),
                });
                continue;
            };
            made += 1;
            const why = if (candidate.moment != null)
                try std.fmt.allocPrint(arena, "Returned to #{d} just after it first reached " ++
                    "{s} ({d} behaviors no timeline before it had): its frontier.", .{
                    parent.index, candidate.label, candidate.novel,
                })
            else
                try std.fmt.allocPrint(arena, "A random moment of #{d}: no timeline of this " ++
                    "generation reached anything new, so a moment is chosen at random.", .{
                    parent.index,
                });
            const path = try arena.alloc(tape.Segment, parent.path.len + 1);
            @memcpy(path[0..parent.path.len], parent.path);
            path[parent.path.len] = .{
                .branch = parent.index,
                .seed = parent.seed,
                .vtime_ns = at,
            };
            for (0..tree.children) |_| {
                if (next_index >= total) break;
                try next.append(arena, .{
                    .index = next_index,
                    .seed = branch_seed(base, next_index),
                    .snapshot = snapshot,
                    .path = path,
                    .generation = generation + 1,
                    .why = why,
                });
                next_index += 1;
            }
        }
        // This generation's snapshots served their branches, and their children's snapshots.
        for (plan.items) |entry| node_free(entry.snapshot, branches.snapshot);
        // The rest of the generation starts over from the setup snapshot.
        while (next_index < total and next.items.len < tree.generation_size) : (next_index += 1) {
            try next.append(arena, .{
                .index = next_index,
                .seed = branch_seed(base, next_index),
                .snapshot = branches.snapshot,
                .generation = generation + 1,
                .why = "From the setup snapshot: some timelines of every generation start " ++
                    "over, so the tree does not only deepen.",
            });
        }
        std.debug.print("[determinismo] tree: generation {d}: {d} branches, {d} new behaviors " ++
            "({d} known); {d} moments returned to\n", .{
            generation, done.len, new_behaviors(chosen), seen.count(), made,
        });
        plan = next;
    }
    for (plan.items) |entry| node_free(entry.snapshot, branches.snapshot);
}

const Candidate = struct { summary: *const Summary, novel: u32, moment: ?u64, label: []const u8 };

fn candidate_before(_: void, a: Candidate, b: Candidate) bool {
    if (a.novel != b.novel) return a.novel > b.novel;
    return a.summary.index < b.summary.index;
}

fn summary_before(_: void, a: Summary, b: Summary) bool {
    return a.index < b.index;
}

fn new_behaviors(candidates: []const Candidate) u32 {
    var sum: u32 = 0;
    for (candidates) |candidate| sum += candidate.novel;
    return sum;
}

/// A snapshot at `vtime_ns` of the branch that starts at `from` with `seed`: replays it there.
fn node_make(
    arena: std.mem.Allocator,
    vm: *VM,
    options: *const VM.Options,
    from: *const Snapshot,
    seed: u64,
    vtime_ns: u64,
) !*const Snapshot {
    try moment_after_snapshot(from, vtime_ns);
    var probe = options.*;
    probe.seed = seed;
    probe.moment_vtime_ns = vtime_ns;
    probe.moment_command = null;
    probe.moment_continue = false;
    probe.until = null;
    probe.events_fd = null;
    try vm.init_from_snapshot(&probe, from);
    const outcome = try vm.run_until_exit();
    if (outcome != .moment_reached) {
        vm.deinit();
        return error.MomentNotReached;
    }
    const snapshot = try arena.create(Snapshot);
    try snapshot.take_copy(vm);
    vm.deinit();
    return snapshot;
}

/// Releases a tree node's memory (never the setup snapshot's), once its branches ran.
fn node_free(snapshot: *const Snapshot, root: *const Snapshot) void {
    if (snapshot == root or snapshot.memory_fd < 0) return;
    close(snapshot.memory_fd);
    @constCast(snapshot).memory_fd = -1;
}

/// Antithesis's rewind: runs the branch to the first event matching --until, then moves the
/// moment `ns` of virtual time before it. Decisions come from the seed (or the replayed tape), so
/// the rerun reaches the earlier moment on the same path.
fn rewind(
    vm: *VM,
    options: *VM.Options,
    snapshot: *const Snapshot,
    exploration: *const Exploration,
    ns: u64,
) !void {
    assert(options.until != null);
    assert(exploration.strategy == null);
    var probe = options.*;
    probe.moment_command = null;
    probe.moment_continue = false;
    try vm.init_from_snapshot(&probe, snapshot);
    defer vm.deinit();
    if (exploration.replay) |replay| vm.overrides = replay.overrides;
    const outcome = try vm.run_until_exit();
    if (outcome != .moment_reached or !vm.until_hit) {
        std.debug.print("[determinismo] rewind: the condition does not hold in time\n", .{});
        return;
    }
    const at = (try vm.moment()).vtime_ns;
    const target = at -| ns;
    try moment_after_snapshot(snapshot, target);
    std.debug.print("[determinismo] rewind: the condition holds at {d}ns; the moment is {d}ns\n", .{
        at, target,
    });
    options.until = null;
    options.moment_vtime_ns = target;
}

fn events_file(arena: std.mem.Allocator, directory: []const u8, name: []const u8) !linux.fd_t {
    const path = try std.fs.path.join(arena, &.{ directory, name });
    return open_for_writing(arena, path);
}

/// Tells the strategy how the branch ended; returns true when it asks to stop.
const BranchResult = struct { index: u32, outcome: VM.Outcome };

fn strategy_branch_end(strategy: *Strategy, vm: *VM, branch: BranchResult) !bool {
    var failing_buffer: [64][]const u8 = undefined;
    var failing_count: u32 = 0;
    for (vm.events.properties[0..vm.events.property_count]) |*property| {
        if (property.passing()) continue;
        if (failing_count == failing_buffer.len) break;
        failing_buffer[failing_count] = property.name();
        failing_count += 1;
    }
    return strategy.branch_end(.{
        .index = branch.index,
        .outcome = @tagName(branch.outcome),
        .events = vm.events.count,
        .failing = failing_buffer[0..failing_count],
    });
}

fn open_tape(arena: std.mem.Allocator, directory: []const u8, index: u32) !linux.fd_t {
    assert(directory.len > 0);
    const path = try std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ directory, index });
    return open_for_writing(arena, path);
}

fn close(fd: linux.fd_t) void {
    assert(fd >= 0);
    _ = linux.close(fd);
}

/// What a timeline depends on besides its decisions: the kernel and initramfs bytes, the
/// command line (scenario included) and the disks. Disks are named by their content (image IDs,
/// system hashes), so their names stand for their bytes; other disks are hashed by path.
fn inputs_hash(options: *const VM.Options, arguments: *const Arguments) u64 {
    var hasher = std.hash.Wyhash.init(0x696e70757473);
    hasher.update(options.kernel);
    if (options.initrd) |initrd| hasher.update(initrd);
    hasher.update(options.cmdline);
    hasher.update(std.mem.asBytes(&options.timer_slack_ns)); // Where timer interrupts land.
    hasher.update(std.mem.asBytes(&options.branch_event)); // What time is made of.
    if (options.cpu_modulation) hasher.update("cpu-modulation"); // And how fast it runs.
    for (arguments.disk_paths[0..arguments.disk_count]) |path| {
        hasher.update(std.fs.path.basename(path));
    }
    // Replays are guaranteed on the same CPU model and determinism ABI only (ARCHITECTURE.md §12).
    hasher.update(std.mem.asBytes(&VM.determinism_abi));
    hasher.update(std.mem.asBytes(&host_cpu_signature()));
    return hasher.final();
}

/// The host CPU's vendor and family/model/stepping (CPUID leaves 0 and 1): retired-branch
/// counts are only known to agree on the same model.
fn host_cpu_signature() [4]u32 {
    const vendor = cpuid_raw(0);
    const signature = cpuid_raw(1);
    return .{ vendor[1], vendor[3], vendor[2], signature[0] };
}

fn cpuid_raw(leaf: u32) [4]u32 {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (@as(u32, 0)),
    );
    return .{ eax, ebx, ecx, edx };
}

/// The seed branches derive theirs from: the exploration's, or for branches from a fork point,
/// one derived from it and the fork, so that every subtree has its own branches.
fn seed_base(exploration: *const Exploration) u64 {
    const fork = exploration.fork orelse return exploration.exploration_seed;
    const key = [3]u64{ exploration.exploration_seed, fork.branch, fork.vtime_ns };
    var hasher = std.hash.Wyhash.init(0x666f726b);
    hasher.update(std.mem.asBytes(&key));
    if (fork.exec) |command| hasher.update(command); // A changed system: other branches.
    return hasher.final();
}

/// Each branch's decisions derive from the exploration seed and the branch index only, so any
/// branch can be replayed alone with --branch.
fn branch_seed(seed: u64, index: u32) u64 {
    const key = [2]u64{ seed, index };
    return std.hash.Wyhash.hash(0x6272616e6368, std.mem.asBytes(&key));
}

fn parse_arguments(arena: std.mem.Allocator, argv: []const [:0]const u8) !Arguments {
    if (argv.len < 2) return error.Usage;
    if (argv.len > arguments_max) return error.Usage;
    var arguments = Arguments{ .command = std.meta.stringToEnum(Command, argv[1]) orelse {
        return error.Usage;
    } };
    var index: u32 = 2;
    while (index < argv.len) : (index += 1) {
        if (std.mem.eql(u8, argv[index], "--deterministic")) {
            arguments.deterministic = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--continue")) {
            arguments.moment_continue = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--cpu-modulation")) {
            arguments.cpu_modulation = true;
            continue;
        }
        if (index + 1 == argv.len) return error.Usage;
        try parse_option(arena, &arguments, argv[index], argv[index + 1]);
        index += 1;
    }
    assert(index == argv.len);
    // A run submitted to `serve` boots with serve's machine options.
    if (arguments.kernel_path.len == 0 and arguments.serve_address == null) return error.Usage;
    if (arguments.memory_mib < memory_mib_min) return error.Usage;
    if (arguments.memory_mib > memory_mib_max) return error.Usage;
    if (arguments.time_budget_ns != null and !arguments.branches_given) {
        arguments.branches = branches_max;
    }
    if (arguments.branches == 0 or arguments.branches > branches_max) return error.Usage;
    if (arguments.command == .explore) arguments.deterministic = true;
    // A command runs at a moment: a virtual time, or the first event matching --until.
    const moment = arguments.moment_vtime_ms != null or arguments.until != null;
    const commands = arguments.moment_command != null or arguments.moment_script_path != null;
    if (commands and !moment) return error.Usage;
    if (arguments.moment_command != null and arguments.moment_script_path != null) {
        return error.Usage;
    }
    if (arguments.rewind_ms != null and arguments.until == null) return error.Usage;
    if (arguments.branching == .tree) {
        // The tree explorer plans its own branches; strategies plan theirs. One of its
        // branches replays from its tape (which holds its path).
        const planned = arguments.strategy_command != null or arguments.branch_only != null or
            arguments.tape_path != null or arguments.from_branch != null or
            arguments.shard_count > 1;
        if (planned or moment or commands) return error.Usage;
    }
    if (arguments.rewind_ms != null and arguments.strategy_command != null) return error.Usage;
    if ((arguments.from_branch == null) != (arguments.from_vtime_ms == null)) return error.Usage;
    if (arguments.deterministic) {
        const parts = [_][]const u8{ arguments.cmdline, VM.cmdline_deterministic };
        arguments.cmdline = try std.mem.join(arena, " ", &parts);
    }
    assert(arguments.cmdline.len > 0);
    return arguments;
}

fn parse_option(
    arena: std.mem.Allocator,
    arguments: *Arguments,
    flag: []const u8,
    value: []const u8,
) !void {
    assert(flag.len > 0);
    const eql = std.mem.eql;
    if (eql(u8, flag, "--kernel")) {
        arguments.kernel_path = value;
    } else if (eql(u8, flag, "--initrd")) {
        arguments.initrd_path = value;
    } else if (eql(u8, flag, "--memory-mib")) {
        arguments.memory_mib = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--cmdline")) {
        arguments.cmdline = value;
    } else if (eql(u8, flag, "--append")) {
        arguments.cmdline = try std.mem.join(arena, " ", &.{ arguments.cmdline, value });
    } else if (eql(u8, flag, "--disk")) {
        if (arguments.disk_count == VM.disks_max) return error.Usage;
        arguments.disk_paths[arguments.disk_count] = value;
        arguments.disk_count += 1;
    } else if (eql(u8, flag, "--program")) {
        arguments.program_path = value;
    } else if (eql(u8, flag, "--script")) {
        arguments.script_path = value;
    } else if (eql(u8, flag, "--compose")) {
        arguments.compose_path = value;
    } else if (eql(u8, flag, "--profile")) {
        arguments.profile = value;
    } else if (eql(u8, flag, "--scenario")) {
        arguments.scenario = value;
    } else if (eql(u8, flag, "--cache")) {
        arguments.cache_directory = value;
    } else if (eql(u8, flag, "--seed")) {
        arguments.seed = try std.fmt.parseInt(u64, value, 0);
    } else if (eql(u8, flag, "--margin-branches")) {
        arguments.margin_branches = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--branch-event")) {
        arguments.branch_event = try std.fmt.parseInt(u64, value, 0);
    } else if (eql(u8, flag, "--timer-slack-us")) {
        arguments.timer_slack_us = try std.fmt.parseInt(u64, value, 10);
    } else if (eql(u8, flag, "--events")) {
        arguments.events_path = value;
    } else if (eql(u8, flag, "--events-dir")) {
        arguments.events_directory = value;
    } else if (eql(u8, flag, "--trace")) {
        arguments.trace_path = value;
    } else if (eql(u8, flag, "--branches")) {
        arguments.branches = try std.fmt.parseInt(u32, value, 10);
        arguments.branches_given = true;
    } else if (eql(u8, flag, "--branching")) {
        arguments.branching = std.meta.stringToEnum(@TypeOf(arguments.branching), value) orelse
            return error.Usage;
    } else if (eql(u8, flag, "--time-budget")) {
        arguments.time_budget_ns = try duration_parse(value);
        arguments.time_budget_text = value;
    } else if (eql(u8, flag, "--branch")) {
        arguments.branch_only = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--from-branch")) {
        arguments.from_branch = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--from-exec")) {
        arguments.from_exec = value;
    } else if (eql(u8, flag, "--from-vtime-ms")) {
        arguments.from_vtime_ms = try std.fmt.parseInt(u64, value, 10);
    } else if (eql(u8, flag, "--shard")) {
        const slash = std.mem.indexOfScalar(u8, value, '/') orelse return error.Usage;
        arguments.shard_index = try std.fmt.parseInt(u32, value[0..slash], 10);
        arguments.shard_count = try std.fmt.parseInt(u32, value[slash + 1 ..], 10);
        if (arguments.shard_count == 0 or arguments.shard_index >= arguments.shard_count) {
            return error.Usage;
        }
    } else if (eql(u8, flag, "--record")) {
        arguments.record_path = value;
    } else if (eql(u8, flag, "--jobs")) {
        arguments.jobs = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--strategy")) {
        arguments.strategy_command = value;
    } else if (eql(u8, flag, "--tape-dir")) {
        arguments.tape_directory = value;
    } else if (eql(u8, flag, "--tape")) {
        arguments.tape_path = value;
    } else if (eql(u8, flag, "--at-vtime-ms")) {
        arguments.moment_vtime_ms = try std.fmt.parseInt(u64, value, 10);
    } else if (eql(u8, flag, "--serve")) {
        arguments.serve_address = value;
    } else if (eql(u8, flag, "--rewind-ms")) {
        arguments.rewind_ms = try std.fmt.parseInt(u64, value, 10);
    } else if (eql(u8, flag, "--exec")) {
        arguments.moment_command = value;
    } else if (eql(u8, flag, "--exec-script")) {
        arguments.moment_script_path = value;
    } else if (eql(u8, flag, "--until")) {
        const condition = try arena.create(query.Condition);
        condition.* = try query.parse(arena, value);
        arguments.until = condition;
    } else {
        return error.Usage;
    }
}

fn open_disks(arena: std.mem.Allocator, paths: []const []const u8) ![]const VM.Disk {
    assert(paths.len <= VM.disks_max);
    const disks = try arena.alloc(VM.Disk, paths.len);
    for (paths, disks) |path, *disk| {
        const path_z = try arena.dupeSentinel(u8, path, 0);
        const result = linux.open(path_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(result) != .SUCCESS) {
            std.debug.print("[determinismo] cannot open disk {s}\n", .{path});
            return error.OpenFailed;
        }
        const fd: linux.fd_t = @intCast(result);
        const size = linux.lseek(fd, 0, linux.SEEK.END);
        if (linux.errno(size) != .SUCCESS) return error.DiskSize;
        if (size % 512 != 0) return error.DiskSizeNotSectors;
        disk.* = .{ .fd = fd, .size = size };
    }
    return disks;
}

/// A new results file (truncated once per process; scenarios of one run append to it).
fn open_for_appending(arena: std.mem.Allocator, path: []const u8) !linux.fd_t {
    assert(path.len > 0);
    const path_z = try arena.dupeSentinel(u8, path, 0);
    const flags: linux.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .APPEND = true,
        .CLOEXEC = true,
    };
    const result = linux.open(path_z, flags, 0o644);
    if (linux.errno(result) != .SUCCESS) return error.OpenFailed;
    return @intCast(result);
}

fn hex16(value: u64) [16]u8 {
    var text: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&text, "{x:0>16}", .{value}) catch unreachable;
    return text;
}

/// The scenario a command line runs (`det.scenario=`), if any.
fn scenario_of(cmdline: []const u8) ?[]const u8 {
    var words = std.mem.tokenizeScalar(u8, cmdline, ' ');
    while (words.next()) |word| {
        if (std.mem.startsWith(u8, word, "det.scenario=")) return word["det.scenario=".len..];
    }
    return null;
}

/// A script's non-empty lines as one moment command: separated by NUL bytes, which the VMM runs
/// one after the other.
fn commands_join(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var joined: std.ArrayList(u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOfScalar(u8, line, 0) != null) return error.BadScript;
        if (joined.items.len > 0) try joined.append(arena, 0);
        try joined.appendSlice(arena, line);
    }
    if (joined.items.len == 0) return error.BadScript;
    return joined.items;
}

fn open_for_writing(arena: std.mem.Allocator, path: []const u8) !linux.fd_t {
    assert(path.len > 0);
    const path_z = try arena.dupeSentinel(u8, path, 0);
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const result = linux.open(path_z, flags, 0o644);
    if (linux.errno(result) != .SUCCESS) return error.OpenFailed;
    assert(result <= std.math.maxInt(i32));
    return @intCast(result);
}

fn monotonic_ns() u64 {
    var time: linux.timespec = undefined;
    const result = linux.clock_gettime(.MONOTONIC, &time);
    assert(linux.errno(result) == .SUCCESS);
    return @as(u64, @intCast(time.sec)) * std.time.ns_per_s + @as(u64, @intCast(time.nsec));
}

test branch_seed {
    try std.testing.expect(branch_seed(1, 0) != branch_seed(1, 1));
    try std.testing.expectEqual(branch_seed(7, 3), branch_seed(7, 3));
}

test {
    _ = @import("kvm.zig");
    _ = @import("rtc.zig");
    _ = @import("pit.zig");
    _ = @import("serial.zig");
    _ = @import("cpuid.zig");
    _ = @import("decisions.zig");
    _ = @import("events.zig");
    _ = @import("tape.zig");
    _ = @import("virtio_block.zig");
    _ = @import("prepare.zig");
    _ = @import("serve.zig");
    _ = @import("mcp.zig");
    _ = @import("merge.zig");
    _ = @import("script.zig");
    _ = @import("tla.zig");
    _ = @import("guest_memory.zig");
    _ = @import("query.zig");
    _ = @import("causality.zig");
    _ = @import("extract.zig");
    _ = @import("event_sets.zig");
    _ = @import("profile.zig");
    _ = @import("regex.zig");
    _ = @import("compose.zig");
    _ = @import("yaml.zig");
}
