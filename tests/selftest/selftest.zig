// SPDX-License-Identifier: MIT
//! det-selftest: determinismo testing itself through a real system (ARCHITECTURE.md §14).
//!
//! One node, det-selftest-node, from a `binary` source. Scenarios:
//!   steady     the node answers; every property passes
//!   node_exit  a driver makes the node exit: the built-in property
//!              "nodes do not exit unexpectedly" must fail
//!   stress     drivers hammer clocks, sleeps, yields, page faults and forks at once, and report
//!              what they observe as events: any nondeterminism changes the event hash
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");

const Nodes = struct { echo: sdk.Node, csdk: sdk.Node };
const System = sdk.System(Nodes);
const port = 7000;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .steady = steady, .node_exit = node_exit, .stress = stress },
    });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = .{
            .pause = false,
            .isolate = false,
            .partition = false,
            .degrade = false,
            .throttle = false,
            .process_pause = false,
        },
    });
    // A node in C reporting through the C SDK; no faults (its properties are about the SDK).
    default.node(.csdk, .{
        .binary = "zig-out/bin/det-selftest-c",
        .faults = .{
            .pause = false,
            .isolate = false,
            .partition = false,
            .degrade = false,
            .throttle = false,
            .process_pause = false,
        },
    });
}

fn steady(s: *System.Scenario) void {
    s.parallel_driver("ping", ping);
    s.finally("ping_after", ping);
}

fn node_exit(s: *System.Scenario) void {
    s.singleton_driver("kill_echo", tell_die);
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

fn ping(context: *System.Context) !void {
    var reply: [16]u8 = undefined;
    const answer = try request(context.nodes.echo.address, "ping\n", &reply);
    sdk.always(std.mem.eql(u8, answer, "ping\n"), "the echo node echoes", .{});
}

fn tell_die(context: *System.Context) !void {
    var reply: [16]u8 = undefined;
    _ = request(context.nodes.echo.address, "die\n", &reply) catch {}; // It exits instead.
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
