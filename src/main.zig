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

const usage =
    \\usage: determinismo run     <machine options> [--trace <out.txt>] [--events <out.jsonl>]
    \\       determinismo explore <machine options> [--branches <n>] [--branch <index>]
    \\                            [--strategy "<plugin> <args>"] [--tape-dir <dir>]
    \\                            [--tape <branch.jsonl>]
    \\                            [--at-vtime-ms <ms> [--exec "<shell command>"]]
    \\
    \\system options (instead of --disk; see ARCHITECTURE.md §10):
    \\  --program <test program> [--profile <name>] [--scenario <name>|all] [--cache <dir>]
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
    events_path: ?[]const u8 = null,
    trace_path: ?[]const u8 = null,
    branches: u32 = 16,
    /// Run only this branch (to replay one timeline of an exploration).
    branch_only: ?u32 = null,
    strategy_command: ?[]const u8 = null,
    tape_directory: ?[]const u8 = null,
    /// Replay the branch recorded in this tape.
    tape_path: ?[]const u8 = null,
    /// Multiverse debugging: stop the (single) branch at this virtual time, run this there.
    moment_vtime_ms: ?u64 = null,
    moment_command: ?[]const u8 = null,
    /// Read-only disk images, in guest order (/dev/vda first).
    disk_paths: [VM.disks_max][]const u8 = undefined,
    disk_count: u32 = 0,
    /// A test program: its system becomes the disks, its scenario the guest's work.
    program_path: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    scenario: ?[]const u8 = null,
    cache_directory: []const u8 = ".determinismo-cache",
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var arguments = parse_arguments(arena, try init.minimal.args.toSlice(arena)) catch {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    };
    const prepared = if (arguments.program_path) |program| try system_prepare(
        arena,
        init.io,
        &arguments,
        program,
    ) else null;
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
        .events_fd = if (arguments.events_path) |path| try open_for_writing(arena, path) else null,
        .events_parse_buffer = try arena.alloc(u8, Events.parse_buffer_size),
        .trace_fd = if (arguments.trace_path) |path| try open_for_writing(arena, path) else null,
        .moment_vtime_ns = if (arguments.moment_vtime_ms) |ms| ms * std.time.ns_per_ms else null,
        .moment_command = arguments.moment_command,
        .disks = try open_disks(arena, arguments.disk_paths[0..arguments.disk_count]),
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

/// Builds the disks of the program's system and records what was resolved.
fn system_prepare(
    arena: std.mem.Allocator,
    io: std.Io,
    arguments: *Arguments,
    program: []const u8,
) !prepare.Prepared {
    if (arguments.disk_count > 0) return error.DisksAndProgram;
    const prepared = try prepare.prepare(arena, io, .{
        .program = program,
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
    }
    if (arguments.strategy_command) |command| {
        if (exploration.replay != null) return error.ReplayWithStrategy; // Tapes replace plugins.
        const strategy = try context.arena.create(Strategy);
        try strategy.start(context.arena, command);
        try strategy.hello(exploration.exploration_seed);
        exploration.strategy = strategy;
    }
    defer if (exploration.strategy) |strategy| strategy.stop();

    const time_start_ns = monotonic_ns();
    options.seed = exploration.exploration_seed;
    const snapshot = try context.arena.create(Snapshot);
    try explore_snapshot(vm, options, snapshot);
    report.snapshot_taken(snapshot, monotonic_ns() - time_start_ns);
    const multiverse = try context.arena.create(report.Multiverse);
    multiverse.* = .{};
    try explore_branches(context, vm, options, .{
        .snapshot = snapshot,
        .multiverse = multiverse,
        .exploration = &exploration,
        .arguments = arguments,
    });
    multiverse.summarize(monotonic_ns() - time_start_ns);
    return multiverse.failing_branches;
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
};

fn explore_branches(context: Context, vm: *VM, options: *VM.Options, branches: Branches) !void {
    const exploration = branches.exploration;
    const replay_branch = if (exploration.replay) |replay| replay.header.branch else null;
    const first = replay_branch orelse branches.arguments.branch_only orelse 0;
    const single = replay_branch != null or branches.arguments.branch_only != null;
    const count = if (single) 1 else branches.arguments.branches;
    for (first..first + count) |index_usize| {
        const index: u32 = @intCast(index_usize);
        options.seed = if (exploration.replay) |replay|
            replay.header.branch_seed
        else
            branch_seed(exploration.exploration_seed, index);
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
    for (arguments.disk_paths[0..arguments.disk_count]) |path| {
        hasher.update(std.fs.path.basename(path));
    }
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
}
