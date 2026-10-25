// SPDX-License-Identifier: MIT
//! det-composer: runs one timeline of a scenario, following Antithesis's test-command rules
//! (docs: test_composer_reference). Every choice it makes (which command, how many in parallel,
//! when) is a randomness pull from the platform, so a strategy can steer it and a tape replays
//! it.
//!
//! Usage: det-composer --scenario <name>
//!
//! The scenario comes from /det/system.json; its commands run as `/det/program run <scenario>
//! <command>`. The composer runs the scenario's setup command and then signals setup_complete
//! itself: that is where determinismo snapshots, so every branch starts after setup.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");

const commands_max = 64;
const running_max = 8;
const starts_max = 64;
const parallelism_max = 4;
const pause_ns_max = 20 * std.time.ns_per_ms;
const faults_path = "/opt/determinismo/bin/det-faults";
const program_path = "/det/program";
const nodes_path = "/opt/determinismo/bin/det-nodes";
const nodes = @import("nodes.zig");
const schema = sdk.schema;
const Kind = schema.Kind;

const Command = struct {
    name: [:0]const u8,
    kind: Kind,
    /// For scenarios in a node: the executable there (run with det-nodes exec).
    path: ?[:0]const u8 = null,
};

const Running = struct { pid: linux.pid_t, command: *const Command };

const Composer = struct {
    commands: [commands_max]Command = undefined,
    command_count: u32 = 0,
    running: [running_max]Running = undefined,
    running_count: u32 = 0,
    started_count: u32 = 0,
    scenario: [:0]const u8 = "",
    /// The node the scenario's commands run in, if not the runner.
    node: ?[:0]const u8 = null,
    /// Whether the scenario uses the fault injector, and its process while it runs.
    faults: bool = false,
    faults_pid: ?linux.pid_t = null,

    fn kind_count(composer: *const Composer, kind: Kind) u32 {
        var count: u32 = 0;
        for (composer.commands[0..composer.command_count]) |command| {
            count += @intFromBool(command.kind == kind);
        }
        assert(count <= composer.command_count);
        return count;
    }

    /// A uniformly chosen command of `kind`; the caller checked that one exists.
    fn pick(composer: *const Composer, kind: Kind) *const Command {
        const count = composer.kind_count(kind);
        assert(count > 0);
        var skip = sdk.random_below(count);
        for (composer.commands[0..composer.command_count]) |*command| {
            if (command.kind != kind) continue;
            if (skip == 0) return command;
            skip -= 1;
        }
        unreachable;
    }

    fn start(composer: *Composer, command: *const Command) void {
        assert(composer.running_count < running_max);
        assert(composer.started_count < starts_max * 2);
        const pid = if (composer.node) |node|
            spawn(&.{ nodes_path, "exec", node, command.path.? })
        else
            spawn(&.{ program_path, "run", composer.scenario, command.name });
        composer.running[composer.running_count] = .{ .pid = pid, .command = command };
        composer.running_count += 1;
        composer.started_count += 1;
    }

    /// Waits for one running command to exit and reports how it ended.
    fn wait_one(composer: *Composer) void {
        assert(composer.running_count > 0);
        for (0..running_max + 1) |_| { // The injector may exit first, at most once.
            var status: i32 = 0;
            const result = linux.wait4(-1, &status, 0, null);
            assert(linux.errno(result) == .SUCCESS);
            const pid: linux.pid_t = @intCast(result);
            if (composer.faults_pid == pid) {
                composer.faults_pid = null; // It ran out of injections: faults are over.
                continue;
            }
            for (composer.running[0..composer.running_count], 0..) |entry, index| {
                if (entry.pid != pid) continue;
                report_exit(entry.command, @bitCast(status));
                composer.running[index] = composer.running[composer.running_count - 1];
                composer.running_count -= 1;
                return;
            }
            unreachable; // Every child is a command we started, or the injector.
        }
        unreachable;
    }

    /// Faults run during the driver phase only, as in Antithesis: not during first commands,
    /// and stopped before eventually and finally commands, which check recovery.
    fn faults_start(composer: *Composer) void {
        assert(composer.faults_pid == null);
        if (!composer.faults) return;
        composer.faults_pid = spawn(&.{ faults_path, "--scenario", composer.scenario });
    }

    fn faults_stop(composer: *Composer) void {
        const pid = composer.faults_pid orelse return;
        _ = linux.kill(pid, .TERM); // It undoes its faults before exiting.
        var status: i32 = 0;
        _ = linux.waitpid(pid, &status, 0);
        composer.faults_pid = null;
    }

    fn wait_all(composer: *Composer) void {
        while (composer.running_count > 0) composer.wait_one();
        assert(composer.running_count == 0);
    }

    fn run_to_completion(composer: *Composer, command: *const Command) void {
        assert(composer.running_count == 0);
        composer.start(command);
        composer.wait_all();
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    if (arguments.len != 3 or !std.mem.eql(u8, arguments[1], "--scenario")) return error.Usage;
    const system = try nodes.system_load(arena);
    const scenario = system.scenario(arguments[2]) orelse return error.UnknownScenario;
    var composer: Composer = .{ .scenario = arguments[2], .faults = scenario.faults };
    if (scenario.node) |node| composer.node = try arena.dupeSentinel(u8, node, 0);
    var setup: ?Command = null;
    for (scenario.commands) |command| {
        const name = try arena.dupeSentinel(u8, command.name, 0);
        const path = if (command.path) |path| try arena.dupeSentinel(u8, path, 0) else null;
        if (composer.node != null and path == null) return error.CommandWithoutPath;
        if (command.kind == .setup) {
            if (setup != null) return error.SeveralSetupCommands;
            setup = .{ .name = name, .kind = .setup, .path = path };
            continue;
        }
        if (composer.command_count == commands_max) return error.TooManyCommands;
        composer.commands[composer.command_count] = .{
            .name = name,
            .kind = command.kind,
            .path = path,
        };
        composer.command_count += 1;
    }
    if (setup) |*command| composer.run_to_completion(command);
    sdk.setup_complete(.{ .scenario = composer.scenario });
    const drivers = composer.kind_count(.parallel_driver) + composer.kind_count(.serial_driver);
    const singletons = composer.kind_count(.singleton_driver);
    if (drivers + singletons + composer.kind_count(.anytime) == 0) return error.NoDriverCommands;

    sdk.event("composer_start", .{ .commands = composer.command_count });
    if (composer.kind_count(.first) > 0) composer.run_to_completion(composer.pick(.first));
    const singleton_timeline = singletons > 0 and (drivers == 0 or sdk.random_below(2) == 0);
    composer.faults_start();
    if (singleton_timeline) {
        run_singleton(&composer);
    } else {
        run_drivers(&composer);
    }
    composer.wait_all();
    composer.faults_stop();
    run_ending(&composer);
    sdk.event("composer_done", .{ .commands_started = composer.started_count });
}

fn run_singleton(composer: *Composer) void {
    assert(composer.kind_count(.singleton_driver) > 0);
    if (composer.kind_count(.anytime) > 0) {
        if (sdk.random_below(2) == 0) composer.start(composer.pick(.anytime));
    }
    composer.start(composer.pick(.singleton_driver));
    composer.wait_all();
}

/// Parallel and serial drivers in random order and parallelism, with anytime checks mixed in.
fn run_drivers(composer: *Composer) void {
    const starts = 4 + sdk.random_below(starts_max - 4);
    const parallelism = 1 + sdk.random_below(parallelism_max);
    assert(starts <= starts_max);
    var kinds_buffer: [3]Kind = undefined;
    var kinds: []Kind = kinds_buffer[0..0];
    for ([_]Kind{ .parallel_driver, .serial_driver, .anytime }) |kind| {
        if (composer.kind_count(kind) > 0) {
            kinds_buffer[kinds.len] = kind;
            kinds = kinds_buffer[0 .. kinds.len + 1];
        }
    }
    assert(kinds.len > 0);
    for (0..starts) |_| {
        const kind = sdk.random_choice(Kind, kinds);
        switch (kind) {
            .serial_driver => {
                composer.wait_all();
                composer.run_to_completion(composer.pick(.serial_driver));
            },
            .parallel_driver, .anytime => {
                while (composer.running_count >= parallelism) composer.wait_one();
                composer.start(composer.pick(kind));
            },
            else => unreachable,
        }
        pause(sdk.random_below(pause_ns_max));
    }
}

/// At most one eventually command (which stops everything else) or one finally command.
fn run_ending(composer: *Composer) void {
    assert(composer.running_count == 0);
    const eventually = composer.kind_count(.eventually) > 0;
    const finally = composer.kind_count(.finally) > 0;
    if (eventually and (!finally or sdk.random_below(2) == 0)) {
        composer.run_to_completion(composer.pick(.eventually));
    } else if (finally) {
        composer.run_to_completion(composer.pick(.finally));
    }
}

const environment = [_:null]?[*:0]const u8{
    "PATH=/opt/determinismo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "HOME=/root",
};

const spawn_arguments_max = 4;
comptime {
    assert(spawn_arguments_max >= 4); // program, "run", scenario, command.
}

fn spawn(arguments: []const [*:0]const u8) linux.pid_t {
    assert(arguments.len >= 1);
    assert(arguments.len <= spawn_arguments_max);
    const result = linux.fork();
    assert(linux.errno(result) == .SUCCESS);
    if (result == 0) {
        var argv: [spawn_arguments_max:null]?[*:0]const u8 = @splat(null);
        for (arguments, 0..) |argument, index| argv[index] = argument;
        _ = linux.execve(arguments[0], &argv, &environment);
        linux.exit_group(127); // Exec failed: reported by the parent as status 127.
    }
    return @intCast(result);
}

fn report_exit(command: *const Command, status: u32) void {
    const exited = status & 0x7f == 0;
    const code = if (exited) (status >> 8) & 0xff else 128 + (status & 0x7f);
    const name = command.name;
    sdk.event("command_exit", .{ .command = name, .status = code });
    sdk.always(code == 0, "test commands exit successfully", .{ .command = name, .status = code });
}

fn pause(duration_ns: u64) void {
    assert(duration_ns < pause_ns_max);
    const request = linux.timespec{
        .sec = 0,
        .nsec = @intCast(duration_ns),
    };
    _ = linux.nanosleep(&request, null); // Interruption only shortens a random pause.
}

