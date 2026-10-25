// SPDX-License-Identifier: MIT
//! det-selftest: determinismo testing itself through a real system (ARCHITECTURE.md §14).
//!
//! One node, det-selftest-node, from a `binary` source. Scenarios:
//!   steady     the node answers; every property passes
//!   node_exit  a driver makes the node exit: the built-in property
//!              "nodes do not exit unexpectedly" must fail
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");

const Nodes = struct { echo: sdk.Node };
const System = sdk.System(Nodes);
const port = 7000;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{ .steady = steady, .node_exit = node_exit },
    });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = .{ .pause = false, .isolate = false, .partition = false, .degrade = false },
    });
}

fn steady(s: *System.Scenario) void {
    s.parallel_driver("ping", ping);
    s.finally("ping_after", ping);
}

fn node_exit(s: *System.Scenario) void {
    s.singleton_driver("kill_echo", tell_die);
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
