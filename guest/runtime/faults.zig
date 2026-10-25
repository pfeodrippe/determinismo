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

const Kind = enum { pause, isolate, partition, degrade, restart, clock_skip };
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
    const details = .{
        .kind = @tagName(fault.kind),
        .node = fault.node,
        .peer = fault.peer,
        .duration_ns = duration_ns,
    };
    switch (fault.kind) {
        .pause => {
            nodes.freeze(fault.node, .frozen) catch return;
            sdk.event("fault", details);
            sleep_ns(duration_ns);
            nodes.freeze(fault.node, .thawed) catch {};
        },
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
            const netem = nodes.Netem{
                .delay_ns = sdk.random_below(degrade_delay_ns_max),
                .jitter_ns = sdk.random_below(degrade_delay_ns_max / 4),
                .loss_percent = @intCast(sdk.random_below(degrade_loss_percent_max + 1)),
                .seed = sdk.random_u64(),
            };
            nodes.link_degrade(fault.node, fault.peer, netem) catch return;
            sdk.event("fault", .{
                .kind = "degrade",
                .from = fault.node,
                .to = fault.peer,
                .delay_ns = netem.delay_ns,
                .loss_percent = netem.loss_percent,
                .duration_ns = duration_ns,
            });
            sleep_ns(duration_ns);
            nodes.link_degrade(fault.node, fault.peer, null) catch {};
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
    // a: pause, restart; with the runner and with b: partition and degrade both ways (6).
    // b: pause, isolate; with the runner: partition and degrade both ways (3). Clock skip.
    try std.testing.expectEqual(@as(u32, 14), faults_collect(&system, &scenario, &faults));
}
