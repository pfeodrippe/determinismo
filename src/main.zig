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

const usage =
    \\usage: determinismo run     <machine options> [--trace <out.txt>] [--events <out.jsonl>]
    \\       determinismo serve   [--listen <address:port>] [--data <dir>] <machine options>
    \\       determinismo mcp     <machine options>   (an MCP server on stdio, for agents)
    \\       determinismo explore <machine options> [--branches <n>] [--branch <index>] [--jobs <n>]
    \\                            [--strategy "<plugin> <args>"] [--tape-dir <dir>]
    \\                            [--tape <branch.jsonl>]
    \\                            [--at-vtime-ms <ms> [--exec "<shell command>"]]
    \\                            [--from-branch <index> --from-vtime-ms <ms>]
    \\                            [--record <results.jsonl>] [--shard <k>/<n>]
    \\       determinismo merge   <results.jsonl>...   (the records of an exploration's shards)
    \\
    \\system options (instead of --disk; see ARCHITECTURE.md §10):
    \\  (--program <test program> | --compose <compose.yaml>) [--profile <name>]
    \\  [--scenario <name>|all] [--cache <dir>]
    \\
    \\machine options:
    \\  --kernel <bzImage> [--initrd <file>] [--memory-mib <n>] [--disk <image>]...
    \\  [--cmdline <text> | --append <text>] [--deterministic] [--seed <n>]
    \\  [--margin-branches <n>] [--timer-slack-us <n>]
    \\
    \\--deterministic needs the determinismo-patched KVM; explore implies it.
    \\
;

const cmdline_default = "console=ttyS0 earlyprintk=serial,ttyS0 acpi=off pci=off nokaslr " ++
    "reboot=t panic=-1 i8042.nokbd i8042.noaux tsc=reliable no_timer_check";
const memory_mib_min = 64;
const memory_mib_max = 3072;
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
    trace_path: ?[]const u8 = null,
    branches: u32 = 16,
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
    moment_command: ?[]const u8 = null,
    /// Read-only disk images, in guest order (/dev/vda first).
    disk_paths: [VM.disks_max][]const u8 = undefined,
    disk_count: u32 = 0,
    /// A test program: its system becomes the disks, its scenario the guest's work.
    program_path: ?[]const u8 = null,
    /// Or a Compose file: services become nodes, Antithesis test templates scenarios.
    compose_path: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    scenario: ?[]const u8 = null,
    cache_directory: []const u8 = ".determinismo-cache",
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "serve")) return command_serve(init, argv[2..]);
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "mcp")) return command_mcp(init, argv[2..]);
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "merge")) {
        const failing = try merge.merge(arena, init.io, argv[2..]);
        if (failing > 0) std.process.exit(3);
        return;
    }
    var arguments = parse_arguments(arena, argv) catch {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    };
    const has_system = arguments.program_path != null or arguments.compose_path != null;
    const prepared = if (has_system) try system_prepare(arena, init.io, &arguments) else null;
    const cwd = std.Io.Dir.cwd();
    const kernel = try cwd.readFileAlloc(init.io, arguments.kernel_path, arena, .unlimited);
    const initrd = if (arguments.initrd_path) |path|
        try cwd.readFileAlloc(init.io, path, arena, .unlimited)
    else
        null;
    // Everything the machines need is reserved here, once.
    const vm = try arena.create(VM); // Large (port statistics): never on the stack.
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
        .disks = try open_disks(arena, arguments.disk_paths[0..arguments.disk_count]),
        .builtin_properties = has_system,
    };
    const context = Context{ .arena = arena, .io = init.io };
    const base_cmdline = arguments.cmdline;
    var failing_scenarios: u32 = 0;
    for (try scenarios_selected(arena, &arguments, prepared)) |scenario| {
        options.cmdline = try cmdline_build(arena, base_cmdline, arguments.disk_count, scenario);
        if (scenario) |name| std.debug.print("[determinismo] scenario {s}\n", .{name});
        switch (arguments.command) {
            .run => try command_run(vm, &options),
            .explore => {
                const failing = try command_explore(context, vm, &options, &arguments);
                failing_scenarios += @intFromBool(failing > 0);
            },
        }
    }
    if (failing_scenarios > 0) std.process.exit(3);
}

/// `determinismo serve [--listen <address:port>] [--data <dir>] <machine options>`: the HTTP
/// API (serve.zig). Machine options are passed to every run it starts.
fn command_serve(init: std.process.Init, argv: []const [:0]const u8) !void {
    const arena = init.arena.allocator();
    var listen: []const u8 = "127.0.0.1:7878";
    var data: []const u8 = ".determinismo-data";
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
        .self = self_buffer[0..self_size],
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
        .profile = arguments.profile,
        .cache_directory = arguments.cache_directory,
    });
    if (prepared.disk_paths.len > VM.disks_max) return error.TooManyDisks;
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

const Context = struct { arena: std.mem.Allocator, io: std.Io };

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
/// Returns the number of branches with failing properties.
fn command_explore(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    arguments: *const Arguments,
) !u32 {
    assert(options.deterministic);
    var exploration = Exploration{
        .exploration_seed = arguments.seed,
        .tape_directory = arguments.tape_directory,
    };
    if (arguments.tape_directory) |directory| {
        try std.Io.Dir.cwd().createDirPath(context.io, directory);
    }
    exploration.inputs = inputs_hash(options, arguments);
    std.debug.print("[determinismo] inputs {x:0>16}\n", .{exploration.inputs});
    if (arguments.record_path) |path| {
        if (report.record_fd == null) {
            report.record_fd = try open_for_appending(context.arena, path);
        }
        report.record(.{ .run = .{
            .scenario = scenario_of(options.cmdline),
            .profile = arguments.profile,
            .program = arguments.program_path,
            .inputs = &hex16(exploration.inputs),
            .seed = &hex16(arguments.seed),
            .branches = arguments.branches,
            .from_branch = arguments.from_branch,
            .from_vtime_ms = arguments.from_vtime_ms,
            .shard = &.{ arguments.shard_index, arguments.shard_count },
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
        exploration.fork = .{ .branch = branch, .vtime_ns = arguments.from_vtime_ms.? * 1_000_000 };
    }
    if (arguments.strategy_command != null and exploration.replay != null) {
        return error.ReplayWithStrategy; // Tapes replace plugins.
    }
    const time_start_ns = monotonic_ns();
    options.seed = exploration.exploration_seed;
    const snapshot = try context.arena.create(Snapshot);
    try explore_snapshot(vm, options, snapshot);
    report.snapshot_taken(snapshot, monotonic_ns() - time_start_ns);
    const start = if (exploration.fork) |fork| try explore_fork(context, vm, options, .{
        .from = snapshot,
        .exploration = &exploration,
        .fork = fork,
    }) else snapshot;
    const multiverse = try context.arena.create(report.Multiverse);
    multiverse.* = .{};
    const branches = Branches{
        .snapshot = start,
        .multiverse = multiverse,
        .exploration = &exploration,
        .arguments = arguments,
    };
    const jobs = jobs_count(arguments);
    if (jobs == 1) {
        try strategy_start(context, arguments, &exploration);
        defer if (exploration.strategy) |strategy| strategy.stop();
        try explore_branches(context, vm, options, branches);
    } else {
        std.debug.print("[determinismo] {d} branches on {d} workers\n", .{
            arguments.branches, jobs,
        });
        try explore_parallel(context, vm, options, branches, jobs);
    }
    multiverse.summarize(monotonic_ns() - time_start_ns);
    return multiverse.failing_branches;
}

const Fork = struct { from: *const Snapshot, exploration: *const Exploration, fork: tape.Fork };

/// Replays branch `fork.branch` of the setup snapshot to the moment and snapshots it there.
fn explore_fork(context: Context, vm: *VM, options: *VM.Options, fork: Fork) !*const Snapshot {
    const time_start_ns = monotonic_ns();
    options.seed = branch_seed(fork.exploration.exploration_seed, fork.fork.branch);
    options.moment_vtime_ns = fork.fork.vtime_ns;
    options.moment_command = null;
    defer options.moment_vtime_ns = null;
    try vm.init_from_snapshot(options, fork.from);
    const outcome = try vm.run_until_exit();
    if (outcome != .moment_reached) {
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

fn strategy_start(context: Context, arguments: *const Arguments, exploration: *Exploration) !void {
    const command = arguments.strategy_command orelse return;
    const strategy = try context.arena.create(Strategy);
    try strategy.start(context.arena, command);
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
        const received = read_exact(reader, std.mem.asBytes(results));
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
    const ok = worker_explore(context, vm, options, mine, &exploration);
    if (ok) write_all(worker.results_fd, std.mem.asBytes(mine.multiverse));
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
    for (first..first + count) |index_usize| {
        const index: u32 = @intCast(index_usize);
        const shards = if (single) 1 else branches.arguments.shard_count;
        const shard = if (single) 0 else branches.arguments.shard_index;
        if (index % shards != shard) continue;
        if (index / shards % branches.jobs != branches.worker) continue;
        options.seed = if (exploration.replay) |replay|
            replay.header.branch_seed
        else
            branch_seed(seed_base(exploration), index);
        const moment_ms = branches.arguments.moment_vtime_ms;
        options.moment_vtime_ns = if (moment_ms) |ms| ms * std.time.ns_per_ms else null;
        options.moment_command = branches.arguments.moment_command;
        try vm.init_from_snapshot(options, branches.snapshot);
        defer vm.deinit();
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
        });
        if (exploration.strategy) |strategy| {
            const end = BranchResult{ .index = index, .outcome = outcome };
            if (try strategy_branch_end(strategy, vm, end)) break;
        }
    }
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
    for (arguments.disk_paths[0..arguments.disk_count]) |path| {
        hasher.update(std.fs.path.basename(path));
    }
    return hasher.final();
}

/// The seed branches derive theirs from: the exploration's, or for branches from a fork point,
/// one derived from it and the fork, so that every subtree has its own branches.
fn seed_base(exploration: *const Exploration) u64 {
    const fork = exploration.fork orelse return exploration.exploration_seed;
    const key = [3]u64{ exploration.exploration_seed, fork.branch, fork.vtime_ns };
    return std.hash.Wyhash.hash(0x666f726b, std.mem.asBytes(&key));
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
        if (index + 1 == argv.len) return error.Usage;
        try parse_option(arena, &arguments, argv[index], argv[index + 1]);
        index += 1;
    }
    assert(index == argv.len);
    if (arguments.kernel_path.len == 0) return error.Usage;
    if (arguments.memory_mib < memory_mib_min) return error.Usage;
    if (arguments.memory_mib > memory_mib_max) return error.Usage;
    if (arguments.branches == 0 or arguments.branches > branches_max) return error.Usage;
    if (arguments.command == .explore) arguments.deterministic = true;
    if (arguments.moment_command != null and arguments.moment_vtime_ms == null) return error.Usage;
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
    } else if (eql(u8, flag, "--trace")) {
        arguments.trace_path = value;
    } else if (eql(u8, flag, "--branches")) {
        arguments.branches = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--branch")) {
        arguments.branch_only = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--from-branch")) {
        arguments.from_branch = try std.fmt.parseInt(u32, value, 10);
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
    } else if (eql(u8, flag, "--exec")) {
        arguments.moment_command = value;
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
    _ = @import("compose.zig");
    _ = @import("yaml.zig");
}
