// SPDX-License-Identifier: MIT
//! det-faults: the in-guest fault injector. The composer starts it for the driver phase of a
//! timeline and stops it (SIGTERM) before eventually/finally commands; on stop it undoes what it
//! did. Every choice (when, which fault, how long) is a randomness pull from the platform, so a
//! strategy steers faults like any other decision and a tape replays them.
//!
//! Usage: det-faults --scenario <name>
//!
//! The faults come from /det/system.json: what each node allows (pause, isolate, partition,
//! restart) and whether the scenario wants clock skips.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");
const schema = sdk.schema;
const nodes = @import("nodes.zig");

const faults_max = 256;
const injections_max = 10_000;
const delay_ns_min = 10 * std.time.ns_per_ms;
const delay_ns_max = 300 * std.time.ns_per_ms;
const duration_ns_max = 500 * std.time.ns_per_ms;
const clock_skip_ns_max = 60 * std.time.ns_per_s;

const Kind = enum {
    pause,
    isolate,
    partition,
    degrade,
    restart,
    throttle,
    process_pause,
    process_kill,
    clock_skip,
};
const throttle_percent_min = 5;
const throttle_percent_max = 50;
const processes_max = 1024;
/// What a degraded link does: one flavor per fault.
const Degradation = enum { delay_loss, duplicate, corrupt, reorder, congestion };
const degrade_delay_ns_max = 200 * std.time.ns_per_ms;
const degrade_loss_percent_max = 30;

const Fault = struct {
    kind: Kind,
    node: []const u8 = "",
    /// The other end of a partitioned link (a node or the runner).
    peer: []const u8 = "",
};

/// Set by the SIGTERM handler; checked between steps so a stop never leaves a fault applied.
var stopping = std.atomic.Value(bool).init(false);

fn on_terminate(_: linux.SIG) callconv(.c) void {
    stopping.store(true, .release);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    if (arguments.len != 3 or !std.mem.eql(u8, arguments[1], "--scenario")) return error.Usage;
    const system = try nodes.system_load(arena);
    const scenario = system.scenario(arguments[2]) orelse return error.UnknownScenario;
    var faults: [faults_max]Fault = undefined;
    const count = faults_collect(&system, scenario, &faults);
    if (count == 0) return; // Nothing allowed: nothing to inject.
    const action = linux.Sigaction{
        .handler = .{ .handler = on_terminate },
        .mask = linux.sigemptyset(),
        .flags = 0, // No SA_RESTART: a pending sleep returns early on stop.
    };
    _ = linux.sigaction(.TERM, &action, null);

    sdk.event("faults_start", .{ .faults = count });
    if (script_faults(arena)) |scripted| return run_script(arena, &system, scripted);
    var injections: u32 = 0;
    while (injections < injections_max) : (injections += 1) {
        sleep_ns(delay_ns_min + sdk.random_below(delay_ns_max - delay_ns_min));
        if (stopping.load(.acquire)) break;
        const applied = draw(&sdk.random_choice(Fault, faults[0..count]));
        apply(arena, &system, &applied);
    }
    sdk.event("faults_stop", .{ .injections = injections });
}

/// One fault as applied: everything needed to apply it again. A script's fault entries are
/// these, with `at_ns` their offset from the start of the fault phase (0 in events).
const Applied = struct {
    at_ns: u64 = 0,
    kind: Kind,
    node: []const u8 = "",
    peer: []const u8 = "",
    duration_ns: u64,
    cpu_percent: u8 = 0,
    process_index: u32 = 0,
    flavor: ?Degradation = null,
    netem: ?nodes.Netem = null,
    forward: bool = false,
    skip_ns: u64 = 0,
};

/// A fault's parameters, drawn from platform randomness.
fn draw(fault: *const Fault) Applied {
    var applied = Applied{
        .kind = fault.kind,
        .node = fault.node,
        .peer = fault.peer,
        .duration_ns = sdk.random_below(duration_ns_max),
    };
    switch (fault.kind) {
        .throttle => {
            const range = throttle_percent_max - throttle_percent_min;
            applied.cpu_percent = @intCast(throttle_percent_min + sdk.random_below(range + 1));
        },
        .process_pause, .process_kill => {
            applied.process_index = @intCast(sdk.random_below(processes_max));
        },
        .degrade => {
            const flavor = sdk.random_choice(Degradation, std.enums.values(Degradation));
            applied.flavor = flavor;
            applied.netem = degradation(flavor);
        },
        .clock_skip => {
            applied.forward = sdk.random_below(2) == 0;
            applied.skip_ns = sdk.random_below(clock_skip_ns_max);
        },
        else => {},
    }
    return applied;
}

fn script_faults(arena: std.mem.Allocator) ?[]const Applied {
    const Script = struct { faults: []const Applied = &.{} };
    const fd = linux.open("/det/script.json", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    const buffer = arena.alloc(u8, 1 << 20) catch return null;
    const size = linux.read(@intCast(fd), buffer.ptr, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    const script = sdk.schema.parse(Script, arena, buffer[0..size]) catch return null;
    return script.faults;
}

/// The script's faults at their offsets (until stopped), instead of drawn ones.
fn run_script(
    arena: std.mem.Allocator,
    system: *const schema.System,
    faults: []const Applied,
) void {
    const start_ns = monotonic_ns();
    var injections: u32 = 0;
    for (faults) |*fault| {
        const now_ns = monotonic_ns();
        if (start_ns + fault.at_ns > now_ns) sleep_ns(start_ns + fault.at_ns - now_ns);
        if (stopping.load(.acquire)) break;
        if (system.node(fault.node) == null and fault.kind != .clock_skip) continue; // Gone.
        apply(arena, system, fault);
        injections += 1;
    }
    sdk.event("faults_stop", .{ .injections = injections, .script = true });
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

fn faults_collect(
    system: *const schema.System,
    scenario: *const schema.Scenario,
    faults: *[faults_max]Fault,
) u32 {
    var count: u32 = 0;
    for (system.nodes, 0..) |node, index| {
        const allowed = node.faults;
        if (allowed.pause) faults_add(faults, &count, .{ .kind = .pause, .node = node.name });
        if (allowed.isolate) faults_add(faults, &count, .{ .kind = .isolate, .node = node.name });
        if (allowed.restart) faults_add(faults, &count, .{ .kind = .restart, .node = node.name });
        if (allowed.throttle) faults_add(faults, &count, .{ .kind = .throttle, .node = node.name });
        if (allowed.process_pause) {
            faults_add(faults, &count, .{ .kind = .process_pause, .node = node.name });
        }
        if (allowed.process_kill) {
            faults_add(faults, &count, .{ .kind = .process_kill, .node = node.name });
        }
        links_collect(system, index, faults, &count);
    }
    if (scenario.clock_skip) faults_add(faults, &count, .{ .kind = .clock_skip });
    assert(count <= faults_max);
    return count;
}

/// Link faults between node `index` and the runner or a later node, as both ends allow (the
/// runner allows all). A degraded link is one direction: both directions are listed.
fn links_collect(
    system: *const schema.System,
    index: usize,
    faults: *[faults_max]Fault,
    count: *u32,
) void {
    const node = &system.nodes[index];
    links_add(faults, count, node, schema.runner_name, .{});
    for (system.nodes[index + 1 ..]) |peer| links_add(faults, count, node, peer.name, peer.faults);
}

fn links_add(
    faults: *[faults_max]Fault,
    count: *u32,
    node: *const schema.Resolved,
    peer: []const u8,
    peer_faults: schema.Faults,
) void {
    if (node.faults.partition and peer_faults.partition) {
        faults_add(faults, count, .{ .kind = .partition, .node = node.name, .peer = peer });
    }
    if (node.faults.degrade and peer_faults.degrade) {
        faults_add(faults, count, .{ .kind = .degrade, .node = node.name, .peer = peer });
        faults_add(faults, count, .{ .kind = .degrade, .node = peer, .peer = node.name });
    }
}

fn faults_add(faults: *[faults_max]Fault, count: *u32, fault: Fault) void {
    if (count.* == faults_max) return;
    faults[count.*] = fault;
    count.* += 1;
}

/// Applies one fault for its duration and undoes it, even when stopped meanwhile. The event
/// carries everything about it, so that `determinismo script` can put it in a script.
fn apply(arena: std.mem.Allocator, system: *const schema.System, applied: *const Applied) void {
    switch (applied.kind) {
        .pause => {
            nodes.freeze(applied.node, .frozen) catch return;
            sdk.event("fault", applied.*);
            sleep_ns(applied.duration_ns);
            nodes.freeze(applied.node, .thawed) catch {};
        },
        .restart => {
            nodes.kill(applied.node) catch return;
            sdk.event("fault", applied.*);
            sleep_ns(applied.duration_ns);
            const node = system.node(applied.node) orelse return;
            nodes.start(arena, system, node) catch |err| {
                const details = .{ .node = applied.node, .err = @errorName(err) };
                sdk.event("fault_restart_failed", details);
            };
        },
        .throttle => {
            nodes.cpu_limit(applied.node, applied.cpu_percent) catch return;
            sdk.event("fault", applied.*);
            sleep_ns(applied.duration_ns);
            nodes.cpu_limit(applied.node, null) catch {};
        },
        .process_pause => apply_process_pause(applied),
        .process_kill => apply_process_kill(applied),
        .isolate, .partition, .degrade => apply_link(system, applied),
        .clock_skip => {
            sdk.event("fault", applied.*);
            clock_shift(applied.skip_ns, .{ .forward = applied.forward });
            sleep_ns(applied.duration_ns);
            clock_shift(applied.skip_ns, .{ .forward = !applied.forward }); // Skips are temporary.
        },
    }
}

fn apply_process_pause(applied: *const Applied) void {
    var pids: [processes_max]linux.pid_t = undefined;
    const count = nodes.processes(applied.node, &pids) catch return;
    if (count == 0) return;
    const pid = pids[applied.process_index % count];
    _ = linux.kill(pid, .STOP);
    sdk.event("fault", applied.*);
    sleep_ns(applied.duration_ns);
    _ = linux.kill(pid, .CONT);
}

/// A crash: one of the node's processes other than its main one (a worker, a pod's process)
/// is killed, for whatever supervises it to notice. Nothing to undo.
fn apply_process_kill(applied: *const Applied) void {
    var pids: [processes_max]linux.pid_t = undefined;
    const count = nodes.processes(applied.node, &pids) catch return;
    const main_pid = nodes.pid_recorded(applied.node);
    var others: u32 = 0;
    for (pids[0..count]) |pid| {
        if (pid == main_pid) continue;
        pids[others] = pid;
        others += 1;
    }
    if (others == 0) return;
    _ = linux.kill(pids[applied.process_index % others], .KILL);
    sdk.event("fault", applied.*);
}

fn apply_link(system: *const schema.System, applied: *const Applied) void {
    switch (applied.kind) {
        .isolate => {
            if (!links_set(system, applied.node, .down)) return;
            sdk.event("fault", applied.*);
            sleep_ns(applied.duration_ns);
            _ = links_set(system, applied.node, .up);
        },
        .partition => {
            nodes.link_set(system, applied.node, applied.peer, .down) catch return;
            sdk.event("fault", applied.*);
            sleep_ns(applied.duration_ns);
            nodes.link_set(system, applied.node, applied.peer, .up) catch {};
        },
        .degrade => {
            const netem = applied.netem orelse return;
            nodes.link_degrade(applied.node, applied.peer, netem) catch return;
            sdk.event("fault", applied.*);
            sleep_ns(applied.duration_ns);
            nodes.link_degrade(applied.node, applied.peer, null) catch {};
        },
        else => unreachable,
    }
}

/// netem settings for one flavor of degradation, every parameter a platform decision.
fn degradation(flavor: Degradation) nodes.Netem {
    var netem = nodes.Netem{
        .delay_ns = sdk.random_below(degrade_delay_ns_max),
        .seed = sdk.random_u64(),
    };
    switch (flavor) {
        .delay_loss => {
            netem.jitter_ns = sdk.random_below(degrade_delay_ns_max / 4);
            netem.loss_percent = @intCast(sdk.random_below(degrade_loss_percent_max + 1));
        },
        .duplicate => netem.duplicate_percent = @intCast(1 + sdk.random_below(30)),
        .corrupt => netem.corrupt_percent = @intCast(1 + sdk.random_below(10)),
        .reorder => {
            netem.delay_ns = 1 + netem.delay_ns; // Reordering needs a delay to jump.
            netem.reorder_percent = @intCast(1 + sdk.random_below(50));
        },
        .congestion => {
            const rate_min = 10 * 1024;
            netem.rate_bytes_per_second = @intCast(rate_min + sdk.random_below(1024 * 1024));
        },
    }
    return netem;
}

/// Every link of `name` (to the runner and to each other node) goes up or down.
fn links_set(system: *const schema.System, name: []const u8, state: nodes.LinkState) bool {
    nodes.link_set(system, name, schema.runner_name, state) catch return false;
    for (system.nodes) |peer| {
        if (std.mem.eql(u8, peer.name, name)) continue;
        nodes.link_set(system, name, peer.name, state) catch {};
    }
    return true;
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
    nodes.sleep_ns(duration_ns); // A stop interrupts it; the caller checks the flag.
}

test faults_collect {
    const node_faults = schema.Faults{ .pause = true, .isolate = false, .restart = true };
    const base = schema.Resolved{
        .name = "a",
        .address = "10.0.0.2",
        .disk = "vdb",
        .digest = "",
        .command = &.{"x"},
        .env = &.{},
    };
    var resolved = [2]schema.Resolved{ base, base };
    resolved[0].faults = node_faults;
    resolved[1].name = "b";
    const scenario = schema.Scenario{ .name = "s", .commands = &.{}, .clock_skip = true };
    const system = schema.System{ .profile = "p", .nodes = &resolved, .scenarios = &.{scenario} };
    var faults: [faults_max]Fault = undefined;
    // a: pause, restart, throttle, process pause; with the runner and with b: partition and
    // degrade both ways (6). b: pause, isolate, throttle, process pause; with the runner:
    // partition and degrade both ways (3). Clock skip.
    try std.testing.expectEqual(@as(u32, 18), faults_collect(&system, &scenario, &faults));
}
