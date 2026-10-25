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
    var injections: u32 = 0;
    while (injections < injections_max) : (injections += 1) {
        sleep_ns(delay_ns_min + sdk.random_below(delay_ns_max - delay_ns_min));
        if (stopping.load(.acquire)) break;
        inject(arena, &system, &sdk.random_choice(Fault, faults[0..count]));
    }
    sdk.event("faults_stop", .{ .injections = injections });
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

/// Applies one fault for a random duration and undoes it, even when stopped meanwhile.
fn inject(arena: std.mem.Allocator, system: *const schema.System, fault: *const Fault) void {
    const duration_ns = sdk.random_below(duration_ns_max);
    switch (fault.kind) {
        .pause, .restart, .throttle, .process_pause => {
            inject_node(arena, system, fault, duration_ns);
        },
        .isolate, .partition, .degrade => inject_link(system, fault, duration_ns),
        .clock_skip => inject_clock(duration_ns),
    }
}

fn inject_node(
    arena: std.mem.Allocator,
    system: *const schema.System,
    fault: *const Fault,
    duration_ns: u64,
) void {
    const details = .{
        .kind = @tagName(fault.kind),
        .node = fault.node,
        .duration_ns = duration_ns,
    };
    switch (fault.kind) {
        .pause => {
            nodes.freeze(fault.node, .frozen) catch return;
            sdk.event("fault", details);
            sleep_ns(duration_ns);
            nodes.freeze(fault.node, .thawed) catch {};
        },
        .restart => {
            nodes.kill(fault.node) catch return;
            sdk.event("fault", details);
            sleep_ns(duration_ns);
            const node = system.node(fault.node).?;
            nodes.start(arena, system, node) catch |err| {
                sdk.event("fault_restart_failed", .{ .node = fault.node, .err = @errorName(err) });
            };
        },
        .throttle => {
            const range = throttle_percent_max - throttle_percent_min;
            const percent: u8 = @intCast(throttle_percent_min + sdk.random_below(range + 1));
            nodes.cpu_limit(fault.node, percent) catch return;
            sdk.event("fault", .{ .kind = "throttle", .node = fault.node, .cpu_percent = percent });
            sleep_ns(duration_ns);
            nodes.cpu_limit(fault.node, null) catch {};
        },
        .process_pause => {
            var pids: [processes_max]linux.pid_t = undefined;
            const count = nodes.processes(fault.node, &pids) catch return;
            if (count == 0) return;
            const pid = sdk.random_choice(linux.pid_t, pids[0..count]);
            _ = linux.kill(pid, .STOP);
            sdk.event("fault", .{ .kind = "process_pause", .node = fault.node, .pid = pid });
            sleep_ns(duration_ns);
            _ = linux.kill(pid, .CONT);
        },
        else => unreachable,
    }
}

fn inject_link(system: *const schema.System, fault: *const Fault, duration_ns: u64) void {
    const details = .{
        .kind = @tagName(fault.kind),
        .node = fault.node,
        .peer = fault.peer,
        .duration_ns = duration_ns,
    };
    switch (fault.kind) {
        .isolate => {
            if (!links_set(system, fault.node, .down)) return;
            sdk.event("fault", details);
            sleep_ns(duration_ns);
            _ = links_set(system, fault.node, .up);
        },
        .partition => {
            nodes.link_set(system, fault.node, fault.peer, .down) catch return;
            sdk.event("fault", details);
            sleep_ns(duration_ns);
            nodes.link_set(system, fault.node, fault.peer, .up) catch {};
        },
        .degrade => {
            const flavor = sdk.random_choice(Degradation, std.enums.values(Degradation));
            const netem = degradation(flavor);
            nodes.link_degrade(fault.node, fault.peer, netem) catch return;
            sdk.event("fault", .{
                .kind = "degrade",
                .flavor = @tagName(flavor),
                .from = fault.node,
                .to = fault.peer,
                .netem = netem,
                .duration_ns = duration_ns,
            });
            sleep_ns(duration_ns);
            nodes.link_degrade(fault.node, fault.peer, null) catch {};
        },
        else => unreachable,
    }
}

fn inject_clock(duration_ns: u64) void {
    const forward = sdk.random_below(2) == 0;
    const skip_ns = sdk.random_below(clock_skip_ns_max);
    sdk.event("fault", .{ .kind = "clock_skip", .forward = forward, .skip_ns = skip_ns });
    clock_shift(skip_ns, .{ .forward = forward });
    sleep_ns(duration_ns);
    clock_shift(skip_ns, .{ .forward = !forward }); // Skips are temporary.
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
