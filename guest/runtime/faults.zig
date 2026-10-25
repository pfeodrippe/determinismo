// SPDX-License-Identifier: MIT
//! det-faults: the in-guest fault injector. The composer starts it for the driver phase of a
//! timeline and stops it (SIGTERM) before eventually/finally commands; on stop it undoes what it
//! did. Every choice (when, which fault, how long) is a randomness pull from the platform, so a
//! strategy steers faults like any other decision and a tape replays them.
//!
//! Usage: det-faults <faults.conf>, where each line is one fault the injector may use:
//!   pause <pidfile>                 SIGSTOP the process for a while, then SIGCONT
//!   restart <pidfile> <command...>  SIGKILL the process, wait, run the command (via /bin/sh)
//!   clock_skip                      jump the wall clock (CLOCK_REALTIME) and later jump back
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");

const faults_max = 16;
const injections_max = 10_000;
const config_size_max = 8 * 1024;
const delay_ns_min = 10 * std.time.ns_per_ms;
const delay_ns_max = 300 * std.time.ns_per_ms;
const duration_ns_max = 500 * std.time.ns_per_ms;
const clock_skip_ns_max = 60 * std.time.ns_per_s;

const Kind = enum { pause, restart, clock_skip };

const Fault = struct {
    kind: Kind,
    pidfile: [:0]const u8 = "",
    command: [:0]const u8 = "",
};

/// Set by the SIGTERM handler; checked between steps so a stop never leaves a fault applied.
var stopping = std.atomic.Value(bool).init(false);

fn on_terminate(_: linux.SIG) callconv(.c) void {
    stopping.store(true, .release);
}

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len != 2) return error.Usage;
    const limit: std.Io.Limit = .limited(config_size_max);
    const arena = init.arena.allocator();
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, arguments[1], arena, limit);
    var faults: [faults_max]Fault = undefined;
    const count = try parse(arena, source, &faults);
    if (count == 0) return; // Nothing configured: nothing to inject.
    const action = linux.Sigaction{
        .handler = .{ .handler = on_terminate },
        .mask = linux.sigemptyset(),
        .flags = 0, // No SA_RESTART: a pending sleep returns early on stop.
    };
    _ = linux.sigaction(.TERM, &action, null);

    sdk.event("faults_start", .{ .faults = count });
    var injections: u32 = 0;
    while (injections < injections_max) : (injections += 1) {
        sleep_ns(delay_ns_min + sdk.random_below(delay_ns_max - delay_ns_min));
        if (stopping.load(.acquire)) break;
        inject(&sdk.random_choice(Fault, faults[0..count]));
    }
    sdk.event("faults_stop", .{ .injections = injections });
}

/// Applies one fault for a random duration and undoes it, even when stopped meanwhile.
fn inject(fault: *const Fault) void {
    const duration_ns = sdk.random_below(duration_ns_max);
    switch (fault.kind) {
        .pause => {
            const pid = read_pid(fault.pidfile) orelse return;
            _ = linux.kill(pid, .STOP);
            sdk.event("fault", .{ .kind = "pause", .pid = pid, .duration_ns = duration_ns });
            sleep_ns(duration_ns);
            _ = linux.kill(pid, .CONT);
        },
        .restart => {
            const pid = read_pid(fault.pidfile) orelse return;
            _ = linux.kill(pid, .KILL);
            sdk.event("fault", .{ .kind = "restart", .pid = pid, .downtime_ns = duration_ns });
            sleep_ns(duration_ns);
            run_shell(fault.command);
        },
        .clock_skip => {
            const forward = sdk.random_below(2) == 0;
            const skip_ns = sdk.random_below(clock_skip_ns_max);
            sdk.event("fault", .{ .kind = "clock_skip", .forward = forward, .skip_ns = skip_ns });
            clock_shift(skip_ns, .{ .forward = forward });
            sleep_ns(duration_ns);
            clock_shift(skip_ns, .{ .forward = !forward }); // Skips are temporary.
        },
    }
}

fn parse(arena: std.mem.Allocator, source: []const u8, faults: *[faults_max]Fault) !u32 {
    var count: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (count == faults_max) return error.TooManyFaults;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const kind = std.meta.stringToEnum(Kind, words.next().?) orelse return error.UnknownFault;
        var fault = Fault{ .kind = kind };
        if (kind != .clock_skip) {
            const pidfile = words.next() orelse return error.MissingPidfile;
            fault.pidfile = try arena.dupeSentinel(u8, pidfile, 0);
        }
        if (kind == .restart) {
            const command = std.mem.trim(u8, words.rest(), " ");
            if (command.len == 0) return error.MissingRestartCommand;
            fault.command = try arena.dupeSentinel(u8, command, 0);
        }
        faults[count] = fault;
        count += 1;
    }
    assert(count <= faults_max);
    return count;
}

fn read_pid(pidfile: [:0]const u8) ?linux.pid_t {
    assert(pidfile.len > 0);
    const fd = linux.open(pidfile, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null; // Not running right now: skip this fault.
    defer _ = linux.close(@intCast(fd));
    var buffer: [32]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    const text = std.mem.trim(u8, buffer[0..size], " \n");
    return std.fmt.parseInt(linux.pid_t, text, 10) catch null;
}

fn run_shell(command: [:0]const u8) void {
    assert(command.len > 0);
    const pid = linux.fork();
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command.ptr };
        const environment = [_:null]?[*:0]const u8{
            "PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        };
        _ = linux.execve("/bin/sh", &argv, &environment);
        linux.exit_group(127);
    }
    var status: i32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0); // Restart commands daemonize and return.
}

fn clock_shift(skip_ns: u64, direction: struct { forward: bool }) void {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &now);
    const now_ns: i128 = @as(i128, now.sec) * std.time.ns_per_s + now.nsec;
    const shifted_ns = if (direction.forward) now_ns + skip_ns else now_ns - skip_ns;
    const shifted = linux.timespec{
        .sec = @intCast(@divFloor(shifted_ns, std.time.ns_per_s)),
        .nsec = @intCast(@mod(shifted_ns, std.time.ns_per_s)),
    };
    _ = linux.clock_settime(.REALTIME, &shifted);
}

fn sleep_ns(duration_ns: u64) void {
    const request = linux.timespec{
        .sec = @intCast(duration_ns / std.time.ns_per_s),
        .nsec = @intCast(duration_ns % std.time.ns_per_s),
    };
    _ = linux.nanosleep(&request, null); // A stop interrupts it; the caller checks the flag.
}

test parse {
    var faults: [faults_max]Fault = undefined;
    const source = "# comment\npause /tmp/a.pid\n" ++
        "restart /tmp/b.pid service --daemonize yes\nclock_skip\n";
    const count = try parse(std.testing.allocator, source, &faults);
    defer for (faults[0..count]) |fault| {
        if (fault.pidfile.len > 0) std.testing.allocator.free(fault.pidfile);
        if (fault.command.len > 0) std.testing.allocator.free(fault.command);
    };
    try std.testing.expectEqual(@as(u32, 3), count);
    try std.testing.expectEqualStrings("service --daemonize yes", faults[1].command);
}
