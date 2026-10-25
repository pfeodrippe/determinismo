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
/// detfs (det_guest): "1" once an SDK declared the system's setup complete.
const sdk_setup_path = "/opt/determinismo/sdk/setup";
const sdk_setup_wait_ns = 300 * std.time.ns_per_s;

/// A system with an Antithesis SDK declares its own setup (once it is ready: a leader elected,
/// data loaded); the drivers start after it, as Antithesis's do. The platform snapshots at that
/// declaration. A system that never declares it is started anyway after a while.
fn sdk_setup_wait() void {
    const poll_ns = 10 * std.time.ns_per_ms;
    var waited_ns: u64 = 0;
    while (waited_ns < sdk_setup_wait_ns) : (waited_ns += poll_ns) {
        var buffer: [4]u8 = undefined;
        const fd = linux.open(sdk_setup_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(fd) == .SUCCESS) {
            const size = linux.read(@intCast(fd), &buffer, buffer.len);
            _ = linux.close(@intCast(fd));
            if (linux.errno(size) == .SUCCESS and size > 0 and buffer[0] == '1') return;
        }
        nodes.sleep_ns(poll_ns);
    }
    sdk.event("sdk_setup_missing", .{ .waited_ns = waited_ns });
}
const faults_control_path = "/opt/determinismo/faults-control"; // faults.zig's control_path.
const program_path = "/det/program";
const nodes_path = "/opt/determinismo/bin/det-nodes";
const nodes = @import("nodes.zig");
const output = @import("output.zig");
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
    faults_control: ?linux.fd_t = null,

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
        var buffer: [256]u8 = undefined;
        const property = command_property(&buffer, "started", command.name);
        sdk.assert_computed(.reachable, true, property, .{});
        assert(composer.started_count < starts_max * 2);
        const pid = if (composer.node) |node|
            spawn_logged(command.name, &.{ nodes_path, "exec", node, command.path.? })
        else
            spawn_logged(command.name, &.{ program_path, "run", composer.scenario, command.name });
        composer.running[composer.running_count] = .{ .pid = pid, .command = command };
        composer.running_count += 1;
        composer.started_count += 1;
    }

    fn find(composer: *const Composer, name: []const u8) ?*const Command {
        for (composer.commands[0..composer.command_count]) |*command| {
            if (std.mem.eql(u8, command.name, name)) return command;
        }
        return null;
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
        // The control FIFO, held open through the driver phase: requests a driver writes before
        // the injector reads (quiet periods, injected faults) wait in it, not lost.
        const fifo = linux.S.IFIFO | 0o622;
        _ = linux.mknodat(linux.AT.FDCWD, faults_control_path, fifo, 0);
        const flags: linux.O = .{ .ACCMODE = .RDWR, .NONBLOCK = true, .CLOEXEC = true };
        const control = linux.open(faults_control_path, flags, 0);
        if (linux.errno(control) == .SUCCESS) composer.faults_control = @intCast(control);
        composer.faults_pid = spawn(&.{ faults_path, "--scenario", composer.scenario });
        // Declared only when the scenario has faults (commands_declare): not in the catalog.
        sdk.assert_computed(.reachable, true, faults_property, .{});
    }

    fn faults_stop(composer: *Composer) void {
        const pid = composer.faults_pid orelse return;
        _ = linux.kill(pid, .TERM); // It undoes its faults before exiting.
        var status: i32 = 0;
        _ = linux.waitpid(pid, &status, 0);
        composer.faults_pid = null;
        if (composer.faults_control) |control| _ = linux.close(control);
        composer.faults_control = null;
    }

    fn wait_all(composer: *Composer) void {
        while (composer.running_count > 0) composer.wait_one();
        assert(composer.running_count == 0);
    }

    fn run_to_completion(composer: *Composer, command: *const Command) void {
        assert(composer.running_count == 0);
        announce(command, "complete");
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
    if (system.sdk_setup) sdk_setup_wait();
    sdk.setup_complete(.{ .scenario = composer.scenario });
    kernel_reseed();
    commands_declare(&composer);
    const drivers = composer.kind_count(.parallel_driver) + composer.kind_count(.serial_driver);
    const singletons = composer.kind_count(.singleton_driver);
    if (drivers + singletons + composer.kind_count(.anytime) == 0) return error.NoDriverCommands;

    sdk.event("composer_start", .{ .commands = composer.command_count });
    if (script_read(arena)) |script| return run_script(&composer, &script);
    if (composer.kind_count(.first) > 0) composer.run_to_completion(composer.pick(.first));
    const singleton_timeline = singletons > 0 and (drivers == 0 or sdk.random_below(2) == 0);
    sdk.event("faults_phase", .{ .state = "start" });
    composer.faults_start();
    if (singleton_timeline) {
        run_singleton(&composer);
    } else {
        run_drivers(&composer);
    }
    composer.wait_all();
    composer.faults_stop();
    sdk.event("faults_phase", .{ .state = "stop" });
    run_ending(&composer);
    sdk.event("composer_done", .{ .commands_started = composer.started_count });
}

/// A timeline's shape, extracted from a branch's events (`determinismo script`): commands by
/// their start offset from composer_start, faults by theirs from the start of the fault phase.
/// Everything inside (scheduling, test inputs) is still decided by the seed.
pub const Script = struct {
    script: u32 = 1,
    commands: []const ScriptCommand = &.{},
    faults_start_ns: ?u64 = null,
    faults_stop_ns: ?u64 = null,
    faults: []const std.json.Value = &.{},
};

pub const ScriptCommand = struct { at_ns: u64, name: []const u8, mode: []const u8 };

pub const script_path = "/det/script.json";

/// Every branch starts from the same snapshot, the guest kernel's random generator included:
/// without this, what processes draw from it afresh (getrandom, /dev/urandom, TCP sequence
/// numbers) would repeat in every branch. The new seed is a platform decision, so it differs
/// per branch and replays from tapes like any other.
fn kernel_reseed() void {
    const rnd_add_entropy = 0x40085203; // _IOW('R', 3, int[2])
    const rnd_reseed_crng = 0x5207; // _IO('R', 7)
    const seed_size = 32;
    // struct rand_pool_info: entropy bits, buffer size, buffer.
    var request: extern struct { bits: i32, size: i32, bytes: [seed_size]u8 } = .{
        .bits = seed_size * 8,
        .size = seed_size,
        .bytes = undefined,
    };
    sdk.random_bytes(&request.bytes);
    const fd = linux.open("/dev/urandom", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.ioctl(@intCast(fd), rnd_add_entropy, @intFromPtr(&request));
    _ = linux.ioctl(@intCast(fd), rnd_reseed_crng, 0);
}

fn script_read(arena: std.mem.Allocator) ?Script {
    const fd = linux.open(script_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    const buffer = arena.alloc(u8, 1 << 20) catch return null;
    const size = linux.read(@intCast(fd), buffer.ptr, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    return sdk.schema.parse(Script, arena, buffer[0..size]) catch null;
}

/// What a script (determinismo script) is made of: which command started, and how.
fn announce(command: *const Command, mode: []const u8) void {
    sdk.event("command_start", .{ .name = command.name, .mode = mode });
}

fn run_script(composer: *Composer, script: *const Script) void {
    const start_ns = now_ns();
    var phase: enum { before, faults, after } = .before;
    for (script.commands) |item| {
        if (phase == .before and script.faults_start_ns != null and
            script.faults_start_ns.? <= item.at_ns)
        {
            sleep_until(start_ns + script.faults_start_ns.?);
            sdk.event("faults_phase", .{ .state = "start" });
            composer.faults_start();
            phase = .faults;
        }
        if (phase == .faults and script.faults_stop_ns != null and
            script.faults_stop_ns.? <= item.at_ns)
        {
            composer.wait_all(); // As without a script: drivers end before faults stop.
            composer.faults_stop();
            sdk.event("faults_phase", .{ .state = "stop" });
            phase = .after;
        }
        sleep_until(start_ns + item.at_ns);
        const command = composer.find(item.name) orelse continue; // Gone in this build.
        if (std.mem.eql(u8, item.mode, "complete")) {
            composer.wait_all();
            composer.run_to_completion(command);
        } else {
            while (composer.running_count >= running_max) composer.wait_one();
            announce(command, "start");
            composer.start(command);
        }
    }
    composer.wait_all();
    if (phase == .faults) composer.faults_stop();
    sdk.event("composer_done", .{ .commands_started = composer.started_count, .script = true });
}

fn now_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

fn sleep_until(deadline_ns: u64) void {
    const now = now_ns();
    if (now >= deadline_ns) return;
    const wait = deadline_ns - now;
    const request = linux.timespec{
        .sec = @intCast(wait / std.time.ns_per_s),
        .nsec = @intCast(wait % std.time.ns_per_s),
    };
    _ = linux.nanosleep(&request, null);
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
                const command = composer.pick(kind);
                announce(command, "start");
                composer.start(command);
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
    "DETERMINISMO_STOP_FAULTS=" ++ nodes.stop_faults_path,
    "ANTITHESIS_STOP_FAULTS=" ++ nodes.stop_faults_path,
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

/// A test command, its output as events (output.zig) named after it, and in the commands' log.
fn spawn_logged(name: []const u8, arguments: []const [*:0]const u8) linux.pid_t {
    const pipes = output.pipes() catch return spawn(arguments);
    defer for ([_][2]linux.fd_t{ pipes.stdout, pipes.stderr }) |pipe| {
        for (pipe) |fd| _ = linux.close(fd);
    };
    const result = linux.fork();
    assert(linux.errno(result) == .SUCCESS);
    if (result == 0) {
        _ = linux.dup2(pipes.stdout[1], 1);
        _ = linux.dup2(pipes.stderr[1], 2);
        var argv: [spawn_arguments_max:null]?[*:0]const u8 = @splat(null);
        for (arguments, 0..) |argument, index| argv[index] = argument;
        _ = linux.execve(arguments[0], &argv, &environment);
        linux.exit_group(127);
    }
    output.forward(name, commands_log, pipes) catch {};
    return @intCast(result);
}

const commands_log = "/run/det/commands.log";

/// Built-in properties, as Antithesis's test composer has: every command is started, and runs
/// to completion, in some timeline.
/// Antithesis's "The Antithesis Fault Injector was started", for scenarios with faults.
const faults_property = "the fault injector started";

fn commands_declare(composer: *const Composer) void {
    if (composer.faults) sdk.declare("reachable", faults_property);
    for (composer.commands[0..composer.command_count]) |*command| {
        var buffer: [256]u8 = undefined;
        sdk.declare("reachable", command_property(&buffer, "started", command.name));
        sdk.declare("reachable", command_property(&buffer, "completed", command.name));
    }
}

fn command_property(buffer: *[256]u8, what: []const u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "test command {s}: {s}", .{ what, name }) catch
        buffer[0..0];
}

fn report_exit(command: *const Command, status: u32) void {
    const exited = status & 0x7f == 0;
    if (exited) {
        var buffer: [256]u8 = undefined;
        const property = command_property(&buffer, "completed", command.name);
        sdk.assert_computed(.reachable, true, property, .{});
    }
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
