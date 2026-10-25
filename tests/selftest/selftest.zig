// SPDX-License-Identifier: MIT
//! det-selftest: determinismo testing itself through a real system (ARCHITECTURE.md §14).
//!
//! One node, det-selftest-node, from a `binary` source. Scenarios:
//!   steady     the node answers; every property passes (and fails on profile "mutant", whose
//!              echo node answers in uppercase: the tests catch the mutant)
//!   node_exit  a driver makes the node exit: the built-in property
//!              "nodes do not exit unexpectedly" must fail
//!   oom        (profile "memory") a command in the echo node exceeds its memory limit: the
//!              built-in property "the kernel kills no process for lack of memory" must fail
//!   stress     drivers hammer clocks, sleeps, yields, page faults and forks at once, and report
//!              what they observe as events: any nondeterminism changes the event hash
//!   quiet      (profile "workers") a driver asks for a 2 second quiet period from inside the
//!              echo node (det-stop-faults, as Antithesis's ANTITHESIS_STOP_FAULTS): no fault
//!              but clock skips may start during it
//!   controller (profile "controller", ARCHITECTURE.md §14 level 1) determinismo's own HTTP API
//!              as the system under test, with a fake explorer, under pauses, partitions and
//!              restarts: every run it accepted must survive with a sensible state
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");

const Nodes = struct {
    echo: ?sdk.Node,
    csdk: ?sdk.Node,
    controller: ?sdk.Node,
    maze: ?sdk.Node,
    zigmaze: ?sdk.Node,
};
pub const System = sdk.System(Nodes);
const port = 7000;
/// No faults: these nodes check the platform, not resilience.
const quiet = sdk.schema.Faults{
    .pause = false,
    .isolate = false,
    .partition = false,
    .degrade = false,
    .throttle = false,
    .process_pause = false,
};

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{
            .steady = steady,
            .node_exit = node_exit,
            .oom = oom,
            .crash = crash,
            .stress = stress,
            .quiet = quiet_scenario,
            .controller = @import("controller.zig").scenario,
            .maze = maze,
        },
    });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = quiet,
    });
    // The same system with a mutant echo node: "steady" must catch it.
    const mutant = try d.profile("mutant");
    mutant.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .env = &.{"DET_MUTANT=1"},
        .ready = .{ .tcp = port },
        .faults = quiet,
    });
    const memory = try d.profile("memory");
    memory.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = quiet,
        .memory_max_mib = 32,
    });
    // Workers under a supervisor, and faults that kill processes (never the main one).
    const workers = try d.profile("workers");
    var kills = quiet;
    kills.process_kill = true;
    kills.custom = &.{"/bin/det-selftest-node custom-fault"};
    workers.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .env = &.{"DET_WORKERS=3"},
        .ready = .{ .tcp = port },
        .faults = kills,
    });
    const maze_profile = try d.profile("maze");
    maze_profile.node(.maze, .{
        .binary = "zig-out/bin/det-maze",
        .command = &.{ "/bin/det-maze", "idle" },
        .faults = quiet,
    });
    // The same maze in Zig: coverage through the Zig SDK.
    const maze_zig = try d.profile("maze-zig");
    maze_zig.node(.zigmaze, .{
        .binary = "zig-out/bin/det-maze-zig",
        .command = &.{ "/bin/det-maze-zig", "idle" },
        .faults = quiet,
    });
    const controller = try d.profile("controller");
    controller.node(.controller, .{
        .directory = "zig-out/bin", // determinismo and det-fake-explore.
        .command = &.{
            "/determinismo", "serve",      "--listen",           "0.0.0.0:7878",
            "--data",        "/var/runs", "--explorer", "/det-fake-explore",
        },
        .ready = .{ .tcp = 7878 },
        .faults = .{ .restart = true },
    });
    // A node in C reporting through the C SDK; no faults (its properties are about the SDK).
    default.node(.csdk, .{
        .binary = "zig-out/bin/det-selftest-c",
        .faults = quiet,
    });
}

fn steady(s: *System.Scenario) void {
    s.first("entropy", entropy);
    s.parallel_driver("ping", ping);
    s.finally("ping_after", ping);
}

fn quiet_scenario(s: *System.Scenario) void {
    s.singleton_driver("quiet_period", quiet_period);
}

/// Faults for a while, a quiet period requested from inside the node, then past its end.
fn quiet_period(context: *System.Context) !void {
    const node = context.nodes.echo orelse return error.NoEchoNode;
    const second = linux.timespec{ .sec = 1, .nsec = 0 };
    _ = linux.nanosleep(&second, null);
    sdk.event("quiet_request", .{ .seconds = 2 });
    _ = try node.exec(&.{ "/opt/determinismo/bin/det-stop-faults", "2" });
    const after = linux.timespec{ .sec = 3, .nsec = 0 };
    _ = linux.nanosleep(&after, null);
}

fn node_exit(s: *System.Scenario) void {
    s.singleton_driver("kill_echo", tell_die);
}

/// A process in the echo node dies of SIGSEGV: "no process crashes" must fail.
fn crash(s: *System.Scenario) void {
    s.singleton_driver("segfault", segfault);
}

fn segfault(context: *System.Context) !void {
    const node = context.nodes.echo orelse return error.NoEchoNode;
    _ = try node.exec(&.{ "/bin/det-selftest-node", "crash" });
}

fn oom(s: *System.Scenario) void {
    s.singleton_driver("hog", hog);
}

fn hog(context: *System.Context) !void {
    const node = context.nodes.echo orelse return error.NoEchoNode;
    const status = try node.exec(&.{ "/bin/det-selftest-node", "hog" });
    sdk.always(status == 128 + 9, "the hog is killed", .{ .status = status });
}

fn stress(s: *System.Scenario) void {
    s.parallel_driver("clocks", clocks);
    s.parallel_driver("sleeps", sleeps);
    s.parallel_driver("faults", page_faults);
    s.parallel_driver("forks", forks);
    s.finally("ping_after", ping);
}

const stress_rounds = 200;

/// Reads every clock in a tight loop: the values (virtual time) must be the same on replay.
fn clocks(_: *System.Context) !void {
    var sum: u64 = 0;
    for (0..stress_rounds) |round| {
        for ([_]linux.clockid_t{ .REALTIME, .MONOTONIC, .BOOTTIME, .PROCESS_CPUTIME_ID }) |clock| {
            var now: linux.timespec = undefined;
            _ = linux.clock_gettime(clock, &now);
            sum +%= @as(u64, @intCast(now.sec)) *% 1_000_000_007 +% @as(u64, @intCast(now.nsec));
        }
        if (round % 50 == 0) sdk.event("clocks", .{ .round = round, .sum = sum });
    }
}

/// Short sleeps and yields: wake-ups land where timers fire.
fn sleeps(_: *System.Context) !void {
    for (0..stress_rounds) |round| {
        const pause = linux.timespec{ .sec = 0, .nsec = @intCast(1 + sdk.random_below(200_000)) };
        _ = linux.nanosleep(&pause, null);
        _ = linux.sched_yield();
        if (round % 50 == 0) {
            var now: linux.timespec = undefined;
            _ = linux.clock_gettime(.MONOTONIC, &now);
            sdk.event("sleeps", .{ .round = round, .ns = now.nsec });
        }
    }
}

/// Maps, touches and unmaps memory: page faults, zeroing, reclaim.
fn page_faults(_: *System.Context) !void {
    const size = 4 << 20;
    var checksum: u64 = 0;
    for (0..stress_rounds / 10) |round| {
        const protection: linux.PROT = .{ .READ = true, .WRITE = true };
        const flags: linux.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
        const address = linux.mmap(null, size, protection, flags, -1, 0);
        if (linux.errno(address) != .SUCCESS) return error.Mmap;
        const memory: [*]u8 = @ptrFromInt(address);
        var offset: usize = 0;
        while (offset < size) : (offset += 4096) memory[offset] = @truncate(offset >> 12);
        checksum +%= memory[sdk.random_below(size / 4096) * 4096];
        _ = linux.munmap(memory, size);
        sdk.event("faults", .{ .round = round, .checksum = checksum });
    }
}

/// Forks children that exit with a status the parent checks: scheduling across processes.
fn forks(_: *System.Context) !void {
    for (0..stress_rounds / 10) |round| {
        const pid = linux.fork();
        if (pid == 0) linux.exit_group(@intCast(round % 7));
        var status: i32 = 0;
        _ = linux.wait4(@intCast(pid), &status, 0, null);
        const code = (@as(u32, @bitCast(status)) >> 8) & 0xff;
        sdk.always(code == round % 7, "children exit with their status", .{ .round = round });
    }
}

/// One attempt at the maze per timeline (profile "maze", or "maze-zig"), inside the maze node:
/// by chance 1 in 10000 timelines solves it.
fn maze(s: *System.Scenario) void {
    s.singleton_driver("attempt", maze_attempt);
}

fn maze_attempt(context: *System.Context) !void {
    if (context.nodes.maze) |node| _ = try node.exec(&.{ "/bin/det-maze", "solve" });
    if (context.nodes.zigmaze) |node| _ = try node.exec(&.{ "/bin/det-maze-zig", "solve" });
}

fn ping(context: *System.Context) !void {
    var reply: [16]u8 = undefined;
    const answer = try request(context.nodes.echo.?.address, "ping\n", &reply);
    sdk.always(std.mem.eql(u8, answer, "ping\n"), "the echo node echoes", .{});
}

/// What the guest kernel's random generator gives after the snapshot: different in every
/// branch (the composer reseeds it from a platform decision), the same when a branch replays.
fn entropy(_: *System.Context) !void {
    var bytes: [8]u8 = undefined;
    const fd = linux.open("/dev/urandom", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.NoUrandom;
    defer _ = linux.close(@intCast(fd));
    if (linux.read(@intCast(fd), &bytes, bytes.len) != bytes.len) return error.ShortRead;
    sdk.event("kernel_entropy", .{ .value = std.mem.readInt(u64, &bytes, .little) });
    // An RNG passed to code that takes one: every draw a platform decision.
    var deck = [_]u16{ 1, 2, 3, 4, 5 };
    sdk.rng().shuffle(u16, &deck);
    sdk.event("shuffled", .{ .deck = &deck });
}

fn tell_die(context: *System.Context) !void {
    var reply: [16]u8 = undefined;
    _ = request(context.nodes.echo.?.address, "die\n", &reply) catch {}; // It exits instead.
    const pause = linux.timespec{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
    _ = linux.nanosleep(&pause, null); // Let the runtime see the exit.
}

fn request(address: [4]u8, message: []const u8, reply: []u8) ![]const u8 {
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket) != .SUCCESS) return error.Socket;
    const fd: linux.fd_t = @intCast(socket);
    defer _ = linux.close(fd);
    const target = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(address),
    };
    if (linux.errno(linux.connect(fd, @ptrCast(&target), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
        return error.Connect;
    }
    _ = linux.write(fd, message.ptr, message.len);
    const size = linux.read(fd, reply.ptr, reply.len);
    if (linux.errno(size) != .SUCCESS) return error.Read;
    return reply[0..size];
}
