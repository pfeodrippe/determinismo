// SPDX-License-Identifier: MIT
//! det-faults: the in-guest fault injector. The composer starts it for the driver phase of a
//! timeline and stops it (SIGTERM) before eventually/finally commands; on stop it undoes what it
//! did. Every choice (when, which fault, how long) is a randomness pull from the platform, so a
//! strategy steers faults like any other decision and a tape replays them.
//!
//! Usage: det-faults --scenario <name>
//!        det-faults inject '<json>'   (a fault now, from a scenario: see below)
//!
//! The faults come from /det/system.json: what each node allows (pause, isolate, partition,
//! restart) and whether the scenario wants clock skips.
//!
//! Quiet periods (Antithesis's pausing faults): `det-stop-faults <seconds>`, from any node or
//! command, writes to the control FIFO. The fault under way ends there (the network heals, a
//! node comes back), and no new faults start until the longest requested period is over,
//! except clock skips, which go on.
//!
//! Network faults overlap (see "Network faults" below); node faults happen one at a time on a
//! node, several nodes at once (see "Node faults").
//!
//! Faults from the scenario: `det-faults inject '<json>'` (any language, any node or command)
//! or the SDK's `fault`, while the injector runs, apply that fault now, logged and undone like a
//! drawn one: {"kind": "pause", "node": "db", "duration_ms": 2000}, {"kind":
//! "partition_groups", "groups": [["runner", "a"], ["b", "c"]], "disruption": "stopped",
//! "direction": "both"}, {"kind": "degrade", "node": "a", "peer": "b", "flavor": "delay_loss"},
//! {"kind": "clog", "node": "a", "direction": "inbound"}, {"kind": "throttle", "node": "a",
//! "cpu_percent": 10}, {"kind": "clock_skip", "skip_ms": 500, "forward": true} (permanent),
//! {"kind": "restore"}, {"kind": "disk", "node": "db", "failure": "lost_writes"} (failures:
//! errors, write_errors, lost_writes, corrupt_reads, slow with "delay_ms"); restart, crash,
//! durable_crash, wipe, stop, process_pause, thread_pause, process_kill, isolate and partition
//! (with "peer") too.
//!
//! Durability points (sync_stall, durable_crash): while the fault lasts, the guest module makes
//! each of the node's fsyncs and sync writes a decision, and one in a few is picked. A stall
//! holds the syncing thread there while the node's other threads run (the interleavings around
//! persisting). A crash parks it there, before its data reaches the disk or just after, and
//! asks for the node's crash: a power loss exactly where a system persists what it acts on (a
//! vote granted, a write acknowledged). A thread here waits for those asks and crashes the node;
//! it starts again at the fault's end.
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
/// Most faults are short, interleaving with the system's steps; one in `long_one_in` may last
/// up to `duration_ns_max` (Antithesis's example partition: 10 s), outlasting election
/// timeouts, retries and snapshot intervals, so nodes come back far behind or with messages
/// queued.
const duration_short_ns_max = 500 * std.time.ns_per_ms;
const duration_ns_max = 10 * std.time.ns_per_s;
const long_one_in = 4;
const clock_skip_ns_max = 60 * std.time.ns_per_s;

const Kind = enum {
    pause,
    isolate,
    partition,
    degrade,
    restart,
    /// A power loss: the node's disk keeps what was synced, then it starts again.
    crash,
    /// A power loss at a durability point: its fsyncs and sync writes are decisions, and the
    /// one picked crashes the node there (before its data is on disk, or just after).
    durable_crash,
    /// Its fsyncs and sync writes are decisions, and the ones picked are held for a while.
    sync_stall,
    /// It starts again fresh from its image, everything it wrote gone.
    wipe,
    /// A graceful stop (SIGTERM, then a kill after a grace period), then it starts again.
    stop,
    /// Its disk fails for a while (nodes.DiskFailure).
    disk,
    throttle,
    process_pause,
    /// One thread of one of its processes stopped (ptrace), the others running: interleavings
    /// within a process, without instrumentation (Antithesis's thread pausing).
    thread_pause,
    process_kill,
    /// The runner and the nodes split into groups that cannot talk across (Antithesis's
    /// partitions), with one disruption form.
    partition_groups,
    /// One node's inbound, outbound or both directions disrupted on all its links.
    clog,
    /// One of the node's own fault programs (Faults.custom), run to completion in the node.
    custom,
    /// Every network fault under way ends (Antithesis's restore); skipped when none is.
    restore,
    clock_skip,
};
/// How a disrupted link behaves (Antithesis's forms): packets dropped, delayed, or held for
/// the whole fault and then delivered.
const Disruption = enum { stopped, slowed, jammed };
const Direction = enum { inbound, outbound, both };
const slowed_delay_ns_min = 50 * std.time.ns_per_ms;
const slowed_delay_ns_max = 500 * std.time.ns_per_ms;
/// Endpoints of a partition: the runner (0), then the nodes in order.
const endpoints_max = schema.nodes_max + 1;
/// A group outside every partition: the endpoint does not allow partitions.
const group_none = 255;
const throttle_percent_min = 5;
/// The longest a sync_stall may hold one sync (each stall draws up to its fault's maximum).
const stall_ms_max = 1000;
const throttle_percent_max = 50;
const disk_delay_ms_max = 200;
const disk_sector_size = 512;
const processes_max = 1024;
const threads_max = 1024;
/// What a degraded link does: one flavor per fault.
const Degradation = enum { delay_loss, duplicate, corrupt, reorder, congestion };
const degrade_delay_ns_max = 200 * std.time.ns_per_ms;
const degrade_loss_percent_max = 30;
/// The network's normal variation, on every link that allows degradation, for the whole run
/// (Antithesis's baseline latency): a small delay with jitter and a rare drop.
const baseline_delay_ns_min = 100 * std.time.ns_per_us;
const baseline_delay_ns_max = 2 * std.time.ns_per_ms;
const baseline_loss_ppm_max = 1000;
const disk_baseline_ms_max = 2;
/// Drawn once per timeline; links return to it when a fault on them ends.
var baseline: ?nodes.Netem = null;

const Fault = struct {
    kind: Kind,
    node: []const u8 = "",
    /// The other end of a partitioned link (a node or the runner).
    peer: []const u8 = "",
    /// For partition_groups: the endpoints that may be cut off (runner first).
    endpoints: [endpoints_max]bool = @splat(false),
    /// For custom: the program in the node.
    program: []const u8 = "",
};

/// Set by the SIGTERM handler; checked between steps so a stop never leaves a fault applied.
var stopping = std.atomic.Value(bool).init(false);

fn on_terminate(_: linux.SIG) callconv(.c) void {
    stopping.store(true, .release);
}

/// The control FIFO, under /opt/determinismo, which every node sees (read-only, which FIFOs
/// ignore). Each request is a u64, little endian: the quiet period in nanoseconds.
pub const control_path = "/opt/determinismo/faults-control";
var control: linux.fd_t = -1;
/// The system whose network faults sleeps expire (set once faults start).
var system_active: ?*const schema.System = null;
/// Until when (CLOCK_MONOTONIC) only clock skips are injected.
var quiet_until_ns: u64 = 0;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "inject")) {
        return inject_request(arguments[2]);
    }
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

    control_open();
    system_active = &system;
    arena_active = arena;
    sdk.event("faults_start", .{ .faults = count });
    baseline_start(&system);
    disk_baseline_start(&system);
    if (script_faults(arena)) |scripted| return run_script(arena, &system, scripted);
    const names = try fault_names(arena, faults[0..count]);
    var injections: u32 = 0;
    while (injections < injections_max) : (injections += 1) {
        const wait_ns = sdk.random_below_named("fault.wait_ns", delay_ns_max - delay_ns_min);
        sleep_ns(delay_ns_min + wait_ns);
        if (stopping.load(.acquire)) break;
        // Labeled decisions: a strategy sees which faults it chooses among, by name.
        const applied = draw(&faults[sdk.decide("fault", names)]);
        if (monotonic_ns() < quiet_until_ns and applied.kind != .clock_skip) continue;
        apply(arena, &system, &applied);
    }
    node_heal(&system);
    network_stop(&system);
    sdk.event("faults_stop", .{ .injections = injections });
}

/// The stop: every network fault heals (what jammed links hold is delivered first).
fn network_stop(system: *const schema.System) void {
    network_heal(system);
    if (network.count == 0) return;
    nodes.sleep_ns(release_ns); // A stop ends sleep_ns: this one is plain.
    network_expire(system, monotonic_ns() + release_ns);
}

/// Each fault's name, as a strategy reads it: its kind and whom it hits ("pause raft-2",
/// "partition raft-1 raft-3", "degrade raft-1 runner").
fn fault_names(arena: std.mem.Allocator, faults: []const Fault) ![]const []const u8 {
    const names = try arena.alloc([]const u8, faults.len);
    for (faults, names) |fault, *name| {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(arena, @tagName(fault.kind));
        for ([_][]const u8{ fault.node, fault.peer, fault.program }) |part| {
            if (part.len == 0) continue;
            try text.append(arena, ' ');
            try text.appendSlice(arena, part);
        }
        name.* = text.items;
    }
    return names;
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
    thread_index: u32 = 0,
    flavor: ?Degradation = null,
    netem: ?nodes.Netem = null,
    forward: bool = false,
    skip_ns: u64 = 0,
    /// A clock skip that is never undone: skips then stack.
    permanent: bool = false,
    disruption: ?Disruption = null,
    direction: ?Direction = null,
    /// For custom: the program in the node, and its exit status (in the event).
    program: []const u8 = "",
    /// For partition_groups: each endpoint's group (runner first), group_none for those left out.
    /// (u16, not u8: JSON writes byte arrays as strings.)
    groups: [endpoints_max]u16 = @splat(group_none),
    /// Asked for by the scenario (`det-faults inject`, the SDK's `fault`), not drawn.
    injected: bool = false,
    disk: ?nodes.DiskFault = null,
    /// For durable_crash and sync_stall: one durability point in this many is picked; a crash
    /// there is just after the sync or before it; a stall lasts up to stall_ms_max.
    one_in: u32 = 0,
    after_sync: bool = false,
    stall_ms_min: u32 = 1,
    stall_ms_max: u32 = 0,
};

/// A fault's parameters, drawn from platform randomness.
fn draw(fault: *const Fault) Applied {
    var applied = Applied{
        .kind = fault.kind,
        .node = fault.node,
        .peer = fault.peer,
        .program = fault.program,
        .duration_ns = duration_draw(),
    };
    switch (fault.kind) {
        .throttle => {
            const range = throttle_percent_max - throttle_percent_min;
            applied.cpu_percent = @intCast(throttle_percent_min + sdk.random_below(range + 1));
        },
        .process_pause, .process_kill => {
            applied.process_index = @intCast(sdk.random_below(processes_max));
        },
        .thread_pause => {
            applied.process_index = @intCast(sdk.random_below(processes_max));
            applied.thread_index = @intCast(sdk.random_below(threads_max));
            // Antithesis: "Threads are paused for small periods of time."
            applied.duration_ns = @min(applied.duration_ns, duration_short_ns_max);
        },
        .degrade => {
            const flavor = sdk.random_choice(Degradation, std.enums.values(Degradation));
            applied.flavor = flavor;
            applied.netem = degradation(flavor);
        },
        .clock_skip => {
            applied.forward = sdk.random_below(2) == 0;
            applied.skip_ns = sdk.random_below(clock_skip_ns_max);
            applied.permanent = sdk.random_below(4) == 0;
        },
        .partition_groups => {
            applied.disruption = sdk.random_choice(Disruption, std.enums.values(Disruption));
            applied.groups = groups_draw(fault.endpoints);
            // Asymmetric half the time (Antithesis's): only from lower groups to higher
            // (outbound) or the other way (inbound).
            applied.direction = if (sdk.random_below(2) == 0)
                .both
            else if (sdk.random_below(2) == 0) .outbound else .inbound;
        },
        .clog => {
            applied.disruption = sdk.random_choice(Disruption, std.enums.values(Disruption));
            applied.direction = sdk.random_choice(Direction, std.enums.values(Direction));
        },
        .durable_crash => {
            applied.one_in = 1 + @as(u32, @intCast(sdk.random_below_named("fault.durable_one_in", 8)));
            applied.after_sync = sdk.random_below_named("fault.durable_after", 2) == 1;
        },
        .sync_stall => {
            applied.one_in = 1 + @as(u32, @intCast(sdk.random_below_named("fault.stall_one_in", 4)));
            applied.stall_ms_max = 1 + @as(u32, @intCast(sdk.random_below_named("fault.stall_ms", stall_ms_max)));
        },
        .disk => {
            const failures = std.enums.values(nodes.DiskFailure);
            applied.disk = .{
                .failure = sdk.random_choice(nodes.DiskFailure, failures),
                .delay_ms = @intCast(1 + sdk.random_below(disk_delay_ms_max)),
                .corrupt_byte = @intCast(1 + sdk.random_below(disk_sector_size)),
                .corrupt_value = @intCast(sdk.random_below(256)),
            };
        },
        else => {},
    }
    return applied;
}

fn duration_draw() u64 {
    const long = sdk.random_below_named("fault.duration_long", long_one_in) == 0;
    const max: u64 = if (long) duration_ns_max else duration_short_ns_max;
    return sdk.random_below_named("fault.duration_ns", max);
}

/// Two or three groups over the endpoints that allow partitions, never all in one.
fn groups_draw(allowed: [endpoints_max]bool) [endpoints_max]u16 {
    var groups: [endpoints_max]u16 = @splat(group_none);
    const count: u16 = @intCast(2 + sdk.random_below(2));
    var first: ?usize = null;
    var split = false;
    for (allowed, &groups, 0..) |ok, *group, index| {
        if (!ok) continue;
        group.* = @intCast(sdk.random_below(count));
        if (first) |at| split = split or groups[at] != group.* else first = index;
    }
    if (!split) if (first) |at| {
        groups[at] = (groups[at] + 1) % count; // At least two sides.
    };
    return groups;
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
        sleep_through_ns(start_ns + fault.at_ns -| monotonic_ns());
        if (stopping.load(.acquire)) break;
        // A fault of a node that is gone is skipped (clock skips and partitions into groups
        // name no node).
        const gone = fault.node.len > 0 and system.node(fault.node) == null;
        if (gone) continue;
        apply(arena, system, fault);
        injections += 1;
    }
    node_heal(system);
    network_stop(system);
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
        if (allowed.crash) {
            faults_add(faults, &count, .{ .kind = .crash, .node = node.name });
            faults_add(faults, &count, .{ .kind = .durable_crash, .node = node.name });
        }
        if (allowed.wipe) faults_add(faults, &count, .{ .kind = .wipe, .node = node.name });
        if (allowed.stop) faults_add(faults, &count, .{ .kind = .stop, .node = node.name });
        if (allowed.disk) faults_add(faults, &count, .{ .kind = .disk, .node = node.name });
        if (allowed.throttle) faults_add(faults, &count, .{ .kind = .throttle, .node = node.name });
        if (allowed.sync_stall) faults_add(faults, &count, .{ .kind = .sync_stall, .node = node.name });
        if (allowed.process_pause) {
            faults_add(faults, &count, .{ .kind = .process_pause, .node = node.name });
            faults_add(faults, &count, .{ .kind = .thread_pause, .node = node.name });
        }
        if (allowed.process_kill) {
            faults_add(faults, &count, .{ .kind = .process_kill, .node = node.name });
        }
        for (allowed.custom) |program| {
            faults_add(faults, &count, .{ .kind = .custom, .node = node.name, .program = program });
        }
        links_collect(system, index, faults, &count);
    }
    var endpoints: [endpoints_max]bool = @splat(false);
    endpoints[0] = true; // The runner allows all.
    var partitionable: u32 = 1;
    for (system.nodes, 1..) |node, index| {
        endpoints[index] = node.faults.partition;
        partitionable += @intFromBool(node.faults.partition);
        if (node.faults.isolate) faults_add(faults, &count, .{ .kind = .clog, .node = node.name });
    }
    if (partitionable >= 3) {
        faults_add(faults, &count, .{ .kind = .partition_groups, .endpoints = endpoints });
    }
    if (scenario.clock_skip) faults_add(faults, &count, .{ .kind = .clock_skip });
    const networked = for (faults[0..count]) |fault| switch (fault.kind) {
        .isolate, .partition, .degrade, .partition_groups, .clog => break true,
        else => {},
    } else false;
    if (networked) faults_add(faults, &count, .{ .kind = .restore });
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
        .pause,
        .restart,
        .crash,
        .durable_crash,
        .sync_stall,
        .wipe,
        .stop,
        .disk,
        .throttle,
        .process_pause,
        .thread_pause,
        => node_start(system, applied),
        .process_kill => apply_process_kill(applied),
        .isolate, .partition, .degrade, .partition_groups, .clog => network_start(system, applied),
        .restore => network_restore(system, applied),
        .clock_skip => {
            sdk.event("fault", applied.*);
            clock_shift(applied.skip_ns, .{ .forward = applied.forward });
            sleep_through_ns(applied.duration_ns); // Quiet periods leave clock skips alone.
            if (applied.permanent) return; // It stays, and later skips stack on it.
            clock_shift(applied.skip_ns, .{ .forward = !applied.forward });
        },
        .custom => apply_custom(arena, system, applied),
    }
}

// Node faults -----------------------------------------------------------------------------
// Antithesis's: one at a time on a node (another drawn for it meanwhile is skipped, and not
// logged), several nodes at once. Each is undone at its end, and all at a quiet period or the
// stop.

const NodeFault = struct {
    applied: Applied,
    end_ns: u64,
    /// A stop: when what the node left running is killed (its grace period ends), if still
    /// pending.
    grace_end_ns: ?u64 = null,
    /// The process or thread stopped (process_pause, thread_pause).
    pid: linux.pid_t = 0,
};
var nodes_faulted: [schema.nodes_max]?NodeFault = @splat(null);
/// For starting nodes again when their fault ends (set once faults start).
var arena_active: ?std.mem.Allocator = null;
/// How long a graceful stop waits for the node to exit before it is killed. A node's main
/// process is the init of its PID namespace: without a SIGTERM handler, it ignores the signal
/// (as in a container), and the grace period ends in a kill.
const stop_grace_ns = 3 * std.time.ns_per_s;

fn node_slot(system: *const schema.System, name: []const u8) ?*?NodeFault {
    const index = endpoint_index(system, name) orelse return null;
    if (index == 0) return null; // The runner is not a node.
    return &nodes_faulted[index - 1];
}

fn node_start(system: *const schema.System, applied: *const Applied) void {
    const slot = node_slot(system, applied.node) orelse return;
    if (slot.* != null) return;
    var fault = NodeFault{ .applied = applied.*, .end_ns = monotonic_ns() + applied.duration_ns };
    const started: anyerror!void = switch (applied.kind) {
        .pause => nodes.freeze(applied.node, .frozen),
        .restart => nodes.kill(applied.node),
        .crash => nodes.crash(applied.node),
        .durable_crash, .sync_stall => durable_arm(applied),
        .wipe => nodes.wipe(applied.node),
        .stop => stop_begin(applied.node, &fault),
        .disk => nodes.disk_fail(applied.node, applied.disk.?),
        .throttle => nodes.cpu_limit(applied.node, applied.cpu_percent),
        .process_pause => process_stop(applied, &fault),
        .thread_pause => thread_stop(applied, &fault),
        else => unreachable,
    };
    started catch |err| {
        sdk.event("fault_failed", .{ .node = applied.node, .err = @errorName(err) });
        return;
    };
    sdk.event("fault", applied.*);
    slot.* = fault;
}

fn node_end(system: *const schema.System, slot: *?NodeFault) void {
    const fault = slot.* orelse return;
    slot.* = null;
    const name = fault.applied.node;
    switch (fault.applied.kind) {
        .pause => nodes.freeze(name, .thawed) catch {},
        .sync_stall => durable_disarm(name),
        .durable_crash => {
            const index = node_index_of(system, name) orelse return;
            durable_lock_take();
            durable_active[index] = false;
            durable_disarm(name);
            const crashed = durable_crashed[index];
            durable_crashed[index] = false;
            durable_lock.unlock();
            // Crashed at a durability point meanwhile: it starts again, as after a crash.
            if (crashed) {
                if (system.node(name)) |node| readdress_maybe(system, node);
                node_start_again(system, name);
            }
        },
        .restart, .crash, .wipe, .stop => {
            if (fault.grace_end_ns != null) nodes.kill_remaining(name) catch {}; // Healed early.
            // Antithesis's restarted nodes may rejoin with a new address: a decision.
            if (system.node(name)) |node| readdress_maybe(system, node);
            node_start_again(system, name);
        },
        .disk => {
            const again = nodes.disk_heal(name) catch |err| {
                sdk.event("fault_heal_failed", .{ .node = name, .err = @errorName(err) });
                return;
            };
            if (again) node_start_again(system, name);
        },
        .throttle => nodes.cpu_limit(name, null) catch {},
        .process_pause => _ = linux.kill(fault.pid, .CONT),
        .thread_pause => _ = linux.ptrace(ptrace_detach, fault.pid, 0, 0, 0),
        else => {},
    }
}

fn readdress_maybe(system: *const schema.System, node: *const schema.Resolved) void {
    if (!node.faults.new_address) return;
    if (sdk.random_below_named("fault.new_address", 2) != 0) return;
    _ = nodes.readdress(system, node) catch |err| {
        sdk.event("fault_readdress_failed", .{ .node = node.name, .err = @errorName(err) });
    };
}

fn node_start_again(system: *const schema.System, name: []const u8) void {
    const node = system.node(name) orelse return;
    const arena = arena_active orelse return;
    nodes.start(arena, system, node) catch |err| {
        sdk.event("fault_restart_failed", .{ .node = name, .err = @errorName(err) });
        return;
    };
    network_node_new(system, name); // Its links are new.
}

fn node_expire(system: *const schema.System, now_ns: u64) void {
    for (&nodes_faulted) |*slot| {
        const fault = &(slot.* orelse continue);
        if (fault.grace_end_ns) |grace_end_ns| if (grace_end_ns <= now_ns) {
            nodes.kill_remaining(fault.applied.node) catch {};
            slot.*.?.grace_end_ns = null;
        };
        if (fault.end_ns <= now_ns) node_end(system, slot);
    }
}

/// A graceful stop begins: SIGTERM to the node's main process; what is left when the grace
/// period ends is killed (node_expire), and the node starts again at the fault's end.
fn stop_begin(name: []const u8, fault: *NodeFault) !void {
    try nodes.stop_signal(name);
    const grace_end_ns = monotonic_ns() + stop_grace_ns;
    fault.grace_end_ns = grace_end_ns;
    fault.end_ns = @max(fault.end_ns, grace_end_ns);
}

fn node_next_end() ?u64 {
    var next: ?u64 = null;
    for (nodes_faulted) |slot| {
        const fault = slot orelse continue;
        next = @min(next orelse fault.end_ns, fault.end_ns);
        if (fault.grace_end_ns) |grace_end_ns| next = @min(next.?, grace_end_ns);
    }
    return next;
}

fn node_heal(system: *const schema.System) void {
    for (&nodes_faulted) |*slot| node_end(system, slot);
}

// Durability points ---------------------------------------------------------------------------
// The guest module's (det_guest.c): armed per node cgroup, asked through /dev/determinismo.

const ioctl_durability_arm = 0xde02;
const ioctl_durability_wait = 0xde03;
const DurabilityMode = enum(u32) { stall = 0, crash_before = 1, crash_after = 2 };

const DurabilityArm = extern struct {
    cgroup: u64 align(1),
    one_in: u32 align(1),
    mode: DurabilityMode align(1),
    stall_ms_min: u32 align(1),
    stall_ms_max: u32 align(1),
    node: [32]u8 align(1),
};
const DurabilityRequest = extern struct {
    cgroup: u64 align(1),
    pid: i32 align(1),
    mode: DurabilityMode align(1),
    comm: [16]u8 align(1),
};

comptime {
    assert(@sizeOf(DurabilityArm) == 56); // The module's struct det_durability_arm (packed).
    assert(@sizeOf(DurabilityRequest) == 32);
}

/// The listener crashes nodes while the main loop ends their faults: under this lock, a crash
/// comes only while the node's fault lasts, and its end sees whether one came.
var durable_lock: std.atomic.Mutex = .unlocked;
/// The node's durable_crash fault lasts.
var durable_active: [schema.nodes_max]bool = @splat(false);
/// The node crashed at a durability point during its fault (it starts again at the end).
var durable_crashed: [schema.nodes_max]bool = @splat(false);
var durable_device: linux.fd_t = -1;
var durable_listening: bool = false;

fn node_index_of(system: *const schema.System, name: []const u8) ?usize {
    for (system.nodes, 0..) |node, index| {
        if (std.mem.eql(u8, node.name, name)) return index;
    }
    return null;
}

/// The node's cgroup, as the module names it: its directory's inode number.
fn node_cgroup(name: []const u8) !u64 {
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/{s}", .{ nodes.cgroup_root, name }, 0);
    var stat: linux.Statx = undefined;
    const result = linux.statx(linux.AT.FDCWD, path, 0, .{ .INO = true }, &stat);
    if (linux.errno(result) != .SUCCESS) return error.NoCgroup;
    return stat.ino;
}

fn durable_lock_take() void {
    while (!durable_lock.tryLock()) {
        const pause: linux.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = linux.nanosleep(&pause, null);
    }
}

fn durable_arm(applied: *const Applied) !void {
    if (durable_device < 0) {
        const fd = linux.open(sdk.device_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        if (linux.errno(fd) != .SUCCESS) return error.NoDevice;
        durable_device = @intCast(fd);
    }
    if (!durable_listening) {
        const listener = try std.Thread.spawn(.{}, durable_listen, .{});
        listener.detach();
        durable_listening = true;
    }
    var arm: DurabilityArm = .{
        .cgroup = try node_cgroup(applied.node),
        .one_in = applied.one_in,
        .mode = if (applied.kind == .sync_stall)
            .stall
        else if (applied.after_sync) .crash_after else .crash_before,
        .stall_ms_min = applied.stall_ms_min,
        .stall_ms_max = @max(applied.stall_ms_max, applied.stall_ms_min),
        .node = @splat(0),
    };
    const length = @min(applied.node.len, arm.node.len - 1);
    @memcpy(arm.node[0..length], applied.node[0..length]);
    if (applied.kind == .durable_crash) {
        const system = system_active orelse return error.NoSystem;
        const index = node_index_of(system, applied.node) orelse return error.UnknownNode;
        durable_lock_take();
        defer durable_lock.unlock();
        durable_active[index] = true;
    }
    const armed = linux.ioctl(durable_device, ioctl_durability_arm, @intFromPtr(&arm));
    if (linux.errno(armed) != .SUCCESS) return error.ArmFailed;
}

fn durable_disarm(name: []const u8) void {
    if (durable_device < 0) return;
    var arm: DurabilityArm = .{
        .cgroup = node_cgroup(name) catch return,
        .one_in = 0,
        .mode = .stall,
        .stall_ms_min = 0,
        .stall_ms_max = 0,
        .node = @splat(0),
    };
    _ = linux.ioctl(durable_device, ioctl_durability_arm, @intFromPtr(&arm));
}

/// The listener: each ask of a durability point, its node crashed there.
fn durable_listen() void {
    const system = system_active orelse return;
    while (true) {
        var request: DurabilityRequest = undefined;
        const asked = linux.ioctl(durable_device, ioctl_durability_wait, @intFromPtr(&request));
        if (linux.errno(asked) == .INTR) continue;
        if (linux.errno(asked) != .SUCCESS) return;
        const node = for (system.nodes, 0..) |node, index| {
            const cgroup = node_cgroup(node.name) catch continue;
            if (cgroup == request.cgroup) break .{ node.name, index };
        } else continue;
        durable_lock_take();
        defer durable_lock.unlock();
        if (!durable_active[node[1]]) continue; // Its fault ended: disarmed, nothing parked.
        sdk.event("durable_crash", .{
            .node = node[0],
            .process = std.mem.sliceTo(&request.comm, 0),
            .pid = request.pid,
            .when = if (request.mode == .crash_after) "after_sync" else "before_sync",
        });
        // Disarmed once the freeze is asked for: the parked process goes on into it.
        nodes.crash_with(node[0], durable_disarm) catch |err| {
            sdk.event("fault_failed", .{ .node = node[0], .err = @errorName(err) });
            continue;
        };
        durable_crashed[node[1]] = true;
    }
}

/// One of the node's processes stopped (SIGSTOP).
fn process_stop(applied: *const Applied, fault: *NodeFault) !void {
    var pids: [processes_max]linux.pid_t = undefined;
    const count = try nodes.processes(applied.node, &pids);
    if (count == 0) return error.NoProcess;
    fault.pid = pids[applied.process_index % count];
    _ = linux.kill(fault.pid, .STOP);
}

const ptrace_detach = 17;
const wait_all = 0x40000000; // __WALL: threads too.

/// One thread stopped with ptrace (seize, interrupt): the process's other threads run on.
fn thread_stop(applied: *const Applied, fault: *NodeFault) !void {
    var pids: [processes_max]linux.pid_t = undefined;
    const count = try nodes.processes(applied.node, &pids);
    if (count == 0) return error.NoProcess;
    const pid = pids[applied.process_index % count];
    var tids: [threads_max]linux.pid_t = undefined;
    const threads = nodes.threads(pid, &tids);
    if (threads == 0) return error.NoThread;
    const tid = tids[applied.thread_index % threads];
    if (linux.errno(linux.ptrace(linux.PTRACE.SEIZE, tid, 0, 0, 0)) != .SUCCESS) {
        return error.Ptrace;
    }
    if (linux.errno(linux.ptrace(linux.PTRACE.INTERRUPT, tid, 0, 0, 0)) != .SUCCESS) {
        _ = linux.ptrace(ptrace_detach, tid, 0, 0, 0);
        return error.Ptrace;
    }
    var status: i32 = 0;
    _ = linux.wait4(tid, &status, wait_all, null); // Stopped.
    fault.pid = tid;
}

/// Runs the node's fault program to completion (its duration is its own); nothing to undo.
/// The program is a command line split at spaces (no shell: nodes may have none).
fn apply_custom(
    arena: std.mem.Allocator,
    system: *const schema.System,
    applied: *const Applied,
) void {
    const node = system.node(applied.node) orelse return;
    var argv: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeScalar(u8, applied.program, ' ');
    while (words.next()) |word| argv.append(arena, word) catch return;
    if (argv.items.len == 0) return;
    sdk.event("fault", applied.*);
    const status = nodes.exec(arena, node, argv.items) catch |err| {
        sdk.event("fault_custom_failed", .{ .program = applied.program, .err = @errorName(err) });
        return;
    };
    sdk.event("fault_custom_done", .{ .program = applied.program, .status = status });
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

/// The links (one direction each) a partition or clog disrupts.
const Directed = struct { from: []const u8, to: []const u8 };
const directed_max = endpoints_max * endpoints_max;

fn disrupted_links(
    system: *const schema.System,
    applied: *const Applied,
    links: *[directed_max]Directed,
) u32 {
    var count: u32 = 0;
    const endpoints = system.nodes.len + 1;
    for (0..endpoints) |a| for (0..endpoints) |b| {
        if (a == b or !disrupts(system, applied, a, b)) continue;
        links[count] = .{ .from = endpoint_name(system, a), .to = endpoint_name(system, b) };
        count += 1;
    };
    return count;
}

/// Whether a partition into groups or a clog disrupts the direction from endpoint a to b.
fn disrupts(system: *const schema.System, applied: *const Applied, a: usize, b: usize) bool {
    if (a == b) return false;
    return switch (applied.kind) {
        .partition_groups => applied.groups[a] != group_none and
            applied.groups[b] != group_none and switch (applied.direction orelse .both) {
            .both => applied.groups[a] != applied.groups[b],
            .outbound => applied.groups[a] < applied.groups[b],
            .inbound => applied.groups[a] > applied.groups[b],
        },
        .clog => blk: {
            const node = endpoint_index(system, applied.node) orelse break :blk false;
            break :blk switch (applied.direction.?) {
                .outbound => a == node,
                .inbound => b == node,
                .both => a == node or b == node,
            };
        },
        else => false,
    };
}

// Network faults -------------------------------------------------------------------------
// They overlap (Antithesis's): each is active until its end, and every link carries the most
// aggressive of the faults on it (down; else the most loss, then the most delay), or the
// baseline when none is. A restore, a quiet period or the stop heals them all. Only changes
// reach the kernel.

const active_max = 32;
const release_ns = 10 * std.time.ns_per_ms;

const Active = struct {
    applied: Applied,
    end_ns: u64,
    /// A jammed fault that ended: its links let what they held go (delay 0) before they heal,
    /// since removing netem drops its queue.
    releasing: bool = false,
};

const Network = struct {
    active: [active_max]Active = undefined,
    count: u32 = 0,
    /// Each link as the kernel has it: down (both directions, [low][high]), and the netem of
    /// each direction (from, to).
    down: [endpoints_max][endpoints_max]bool = @splat(@splat(false)),
    netem: [endpoints_max][endpoints_max]?nodes.Netem = @splat(@splat(null)),
};
var network: Network = .{};

fn network_start(system: *const schema.System, applied: *const Applied) void {
    if (network.count == active_max) return; // Skipped, so not logged.
    network.active[network.count] = .{
        .applied = applied.*,
        .end_ns = monotonic_ns() + applied.duration_ns,
    };
    network.count += 1;
    network_refresh(system);
    sdk.event("fault", applied.*);
}

/// Antithesis's restore: every network fault under way ends now.
fn network_restore(system: *const schema.System, applied: *const Applied) void {
    if (network.count == 0) return; // Nothing to restore: skipped, so not logged.
    sdk.event("fault", applied.*);
    network_heal(system);
}

/// Ends every network fault: jammed ones release what they hold first.
fn network_heal(system: *const schema.System) void {
    const now_ns = monotonic_ns();
    for (network.active[0..network.count]) |*entry| entry.end_ns = now_ns;
    network_expire(system, now_ns);
}

fn network_expire(system: *const schema.System, now_ns: u64) void {
    var kept: u32 = 0;
    var changed = false;
    for (network.active[0..network.count]) |entry| {
        var next = entry;
        if (entry.end_ns <= now_ns) {
            changed = true;
            const jammed = entry.applied.disruption == .jammed and !entry.releasing;
            if (!jammed) continue;
            next.releasing = true;
            next.end_ns = now_ns + release_ns;
        }
        network.active[kept] = next;
        kept += 1;
    }
    network.count = kept;
    if (changed) network_refresh(system);
}

fn network_next_end() ?u64 {
    var next: ?u64 = null;
    for (network.active[0..network.count]) |entry| {
        next = if (next) |at| @min(at, entry.end_ns) else entry.end_ns;
    }
    return next;
}

/// The node's links are new (it restarted): up, with no netem.
fn network_node_new(system: *const schema.System, name: []const u8) void {
    const index = endpoint_index(system, name) orelse return;
    for (0..endpoints_max) |other| {
        network.down[@min(index, other)][@max(index, other)] = false;
        network.netem[index][other] = null;
        network.netem[other][index] = null;
    }
    network_refresh(system);
}

/// Brings every link to what the active faults (or the baseline) make it.
fn network_refresh(system: *const schema.System) void {
    const endpoints = system.nodes.len + 1;
    for (0..endpoints) |a| for (a + 1..endpoints) |b| {
        var down = false;
        for (network.active[0..network.count]) |*entry| {
            down = down or (!entry.releasing and cuts_link(system, &entry.applied, a, b));
        }
        if (down == network.down[a][b]) continue;
        const state: nodes.LinkState = if (down) .down else .up;
        const from = endpoint_name(system, a);
        nodes.link_set(system, from, endpoint_name(system, b), state) catch continue;
        network.down[a][b] = down;
    };
    for (0..endpoints) |a| for (0..endpoints) |b| {
        if (a == b) continue;
        var wanted: ?nodes.Netem = null;
        for (network.active[0..network.count]) |*entry| {
            const netem = link_netem(system, entry, a, b) orelse continue;
            if (wanted == null or harsher(netem, wanted.?)) wanted = netem;
        }
        const from = endpoint_name(system, a);
        const to = endpoint_name(system, b);
        if (wanted == null and degradable(system, from) and degradable(system, to)) {
            wanted = baseline;
        }
        if (std.meta.eql(wanted, network.netem[a][b])) continue;
        nodes.link_degrade(from, to, wanted) catch continue;
        network.netem[a][b] = wanted;
    };
}

/// Whether a fault takes the link between endpoints a and b down (isolate, partition).
fn cuts_link(system: *const schema.System, applied: *const Applied, a: usize, b: usize) bool {
    const node = endpoint_index(system, applied.node) orelse return false;
    return switch (applied.kind) {
        .isolate => a == node or b == node,
        .partition => blk: {
            const peer = endpoint_index(system, applied.peer) orelse break :blk false;
            break :blk (a == node and b == peer) or (a == peer and b == node);
        },
        else => false,
    };
}

/// What an active fault does to the direction from a to b, if anything.
fn link_netem(system: *const schema.System, entry: *const Active, a: usize, b: usize) ?nodes.Netem {
    const applied = &entry.applied;
    switch (applied.kind) {
        .degrade => {
            const from = endpoint_index(system, applied.node) orelse return null;
            const to = endpoint_index(system, applied.peer) orelse return null;
            return if (a == from and b == to) applied.netem else null;
        },
        .partition_groups, .clog => {
            if (!disrupts(system, applied, a, b)) return null;
            var netem = disruption_netem(applied);
            if (entry.releasing) netem.delay_ns = 0;
            return netem;
        },
        else => return null,
    }
}

/// Dropped (stopped), delayed (slowed), or held until the fault ends and then delivered
/// (jammed).
fn disruption_netem(applied: *const Applied) nodes.Netem {
    const delay_ns = switch (applied.disruption.?) {
        .stopped => 0,
        .slowed => slowed_delay_ns_min +
            applied.duration_ns % (slowed_delay_ns_max - slowed_delay_ns_min),
        .jammed => applied.duration_ns,
    };
    return .{
        .delay_ns = delay_ns,
        .loss_ppm = if (applied.disruption.? == .stopped) nodes.Netem.ppm else 0,
        .seed = applied.duration_ns,
    };
}

/// The more aggressive of two settings: more loss, then more delay.
fn harsher(a: nodes.Netem, b: nodes.Netem) bool {
    if (a.loss_ppm != b.loss_ppm) return a.loss_ppm > b.loss_ppm;
    return a.delay_ns > b.delay_ns;
}

fn endpoint_name(system: *const schema.System, index: usize) []const u8 {
    return if (index == 0) schema.runner_name else system.nodes[index - 1].name;
}

fn endpoint_index(system: *const schema.System, name: []const u8) ?usize {
    if (std.mem.eql(u8, name, schema.runner_name)) return 0;
    for (system.nodes, 1..) |node, index| {
        if (std.mem.eql(u8, node.name, name)) return index;
    }
    return null;
}

/// Draws the baseline and puts it on every link whose ends allow degradation (none: no
/// baseline).
fn baseline_start(system: *const schema.System) void {
    var any = false;
    for (system.nodes) |node| any = any or node.faults.degrade;
    if (!any) return;
    const delay_ns = baseline_delay_ns_min +
        sdk.random_below(baseline_delay_ns_max - baseline_delay_ns_min);
    baseline = .{
        .delay_ns = delay_ns,
        .jitter_ns = sdk.random_below(delay_ns / 2),
        .loss_ppm = @intCast(sdk.random_below(baseline_loss_ppm_max + 1)),
        .seed = sdk.random_u64(),
    };
    network_refresh(system);
    sdk.event("network_baseline", .{
        .delay_ns = baseline.?.delay_ns,
        .jitter_ns = baseline.?.jitter_ns,
        .loss_ppm = baseline.?.loss_ppm,
    });
}

/// Durable disks' latency for the timeline (the network has its baseline, disks theirs): each
/// I/O 0 to `disk_baseline_ms_max` ms, as a real disk's sync takes time.
fn disk_baseline_start(system: *const schema.System) void {
    var any = false;
    for (system.nodes) |node| any = any or node.faults.crash or node.faults.disk;
    if (!any) return;
    const delay_ms: u32 = @intCast(sdk.random_below(disk_baseline_ms_max + 1));
    nodes.disk_baseline_set(system, delay_ms) catch |err| {
        sdk.event("disk_baseline_failed", .{ .err = @errorName(err) });
        return;
    };
    sdk.event("disk_baseline", .{ .delay_ms = delay_ms });
}

fn degradable(system: *const schema.System, name: []const u8) bool {
    if (std.mem.eql(u8, name, schema.runner_name)) return true;
    const node = system.node(name) orelse return false;
    return node.faults.degrade;
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
            const percent = sdk.random_below(degrade_loss_percent_max + 1);
            netem.loss_ppm = @intCast(percent * (nodes.Netem.ppm / 100));
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

fn control_open() void {
    const fifo = linux.S.IFIFO | 0o622;
    const made = linux.mknodat(linux.AT.FDCWD, control_path, fifo, 0);
    if (linux.errno(made) != .SUCCESS and linux.errno(made) != .EXIST) return;
    // Read and write: the FIFO stays open with no writer, and never reports end of file.
    const flags: linux.O = .{ .ACCMODE = .RDWR, .NONBLOCK = true, .CLOEXEC = true };
    const fd = linux.open(control_path, flags, 0);
    if (linux.errno(fd) == .SUCCESS) control = @intCast(fd);
}

/// Sleeps for `duration_ns`, or less: a stop or a quiet-period request ends it (the caller
/// then undoes its fault; a request also heals the network). Network faults end on time
/// meanwhile.
fn sleep_ns(duration_ns: u64) void {
    const deadline_ns = monotonic_ns() + duration_ns;
    for (0..injections_max) |_| {
        const now_ns = monotonic_ns();
        if (system_active) |system| {
            network_expire(system, now_ns);
            node_expire(system, now_ns);
        }
        if (now_ns >= deadline_ns or stopping.load(.acquire)) return;
        const network_end = network_next_end() orelse deadline_ns;
        const node_end_ns = node_next_end() orelse deadline_ns;
        const wake_ns = @min(deadline_ns, network_end, node_end_ns);
        const left_ns = wake_ns -| now_ns;
        if (control < 0) {
            nodes.sleep_ns(left_ns);
            continue;
        }
        var timeout = linux.timespec{
            .sec = @intCast(left_ns / std.time.ns_per_s),
            .nsec = @intCast(left_ns % std.time.ns_per_s),
        };
        var poll = [1]linux.pollfd{.{ .fd = control, .events = linux.POLL.IN, .revents = 0 }};
        const result = linux.ppoll(&poll, 1, &timeout, null);
        if (linux.errno(result) == .INTR) return; // A stop.
        if (linux.errno(result) != .SUCCESS or result == 0) continue;
        // A quiet period healed what was under way as its request was read (before faults
        // injected after it): the caller undoes its own.
        if (requests_read() > 0) return;
    }
}

/// Sleeps the whole `duration_ns` (a stop still ends it), taking quiet-period requests.
fn sleep_through_ns(duration_ns: u64) void {
    const deadline_ns = monotonic_ns() + duration_ns;
    for (0..injections_max) |_| {
        const now_ns = monotonic_ns();
        if (now_ns >= deadline_ns or stopping.load(.acquire)) return;
        sleep_ns(deadline_ns - now_ns);
    }
}

/// A request on the control FIFO is a u64 (little endian): a quiet period in nanoseconds, or,
/// with its top bit set, the length (low 32 bits) of the JSON fault that follows (`inject`).
/// Each fits in one write of at most PIPE_BUF: atomic.
const inject_flag: u64 = 1 << 63;
const request_size_max = 4096;

/// Takes the pending requests: injected faults are applied; the quiet period ends at the latest
/// one asks for. Returns how many quiet-period requests there were.
fn requests_read() u32 {
    var buffer: [16 * request_size_max]u8 = undefined;
    const size = linux.read(control, &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return 0;
    var quiet: u32 = 0;
    var at: usize = 0;
    while (at + 8 <= size) {
        const header = std.mem.readInt(u64, buffer[at..][0..8], .little);
        at += 8;
        if (header & inject_flag != 0) {
            const length: usize = @intCast(header & 0xffff_ffff);
            if (at + length > size) break;
            inject(buffer[at..][0..length]);
            at += length;
            continue;
        }
        quiet += 1;
        quiet_request(header);
    }
    return quiet;
}

fn quiet_request(duration_ns: u64) void {
    // The fault under way ends where a quiet period begins.
    if (duration_ns > 0) if (system_active) |system| {
        network_heal(system);
        node_heal(system);
    };
    if (duration_ns == 0) {
        // A zero-length request ends the quiet period (Antithesis's unpause).
        quiet_until_ns = 0;
        sdk.event("faults_resume", .{});
        return;
    }
    quiet_until_ns = @max(quiet_until_ns, monotonic_ns() + duration_ns);
    sdk.event("faults_quiet", .{ .duration_ns = duration_ns, .until_ns = quiet_until_ns });
}

/// A fault the scenario asks for, as `det-faults inject` and the SDK's `fault` write it.
const Request = struct {
    kind: Kind,
    node: []const u8 = "",
    peer: []const u8 = "",
    duration_ms: u64 = 1000,
    /// partition_groups: the groups, by name ("runner" for the test commands' side).
    groups: []const []const []const u8 = &.{},
    disruption: Disruption = .stopped,
    direction: Direction = .both,
    flavor: Degradation = .delay_loss,
    cpu_percent: u8 = 20,
    /// clock_skip (permanent: later skips stack on it).
    skip_ms: u64 = 0,
    forward: bool = true,
    program: []const u8 = "",
    /// disk.
    failure: nodes.DiskFailure = .errors,
    delay_ms: u32 = 50,
    /// durable_crash and sync_stall: one durability point in `one_in` is picked.
    one_in: u32 = 1,
    after_sync: bool = false,
    stall_ms_min: u32 = 1,
    stall_ms_max: u32 = 100,
};

fn inject(json: []const u8) void {
    const system = system_active orelse return;
    var parse_buffer: [64 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&parse_buffer);
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const allocator = fixed.allocator();
    const request = std.json.parseFromSliceLeaky(Request, allocator, json, options) catch |err| {
        sdk.event("fault_inject_refused", .{ .err = @errorName(err) });
        return;
    };
    const applied = injected_applied(system, &request) catch |err| {
        const kind = @tagName(request.kind);
        sdk.event("fault_inject_refused", .{ .kind = kind, .err = @errorName(err) });
        return;
    };
    if (applied.kind == .clock_skip) {
        sdk.event("fault", applied);
        clock_shift(applied.skip_ns, .{ .forward = applied.forward });
        return;
    }
    apply(arena_active orelse return, system, &applied);
}

/// The fault a request describes; what it leaves out (which process, which thread) is drawn.
fn injected_applied(system: *const schema.System, request: *const Request) !Applied {
    var applied = Applied{
        .kind = request.kind,
        .node = request.node,
        .peer = request.peer,
        .duration_ns = request.duration_ms * std.time.ns_per_ms,
        .injected = true,
    };
    for ([_][]const u8{ request.node, request.peer }) |name| {
        if (name.len > 0 and endpoint_index(system, name) == null) return error.UnknownNode;
    }
    switch (request.kind) {
        .throttle => applied.cpu_percent = request.cpu_percent,
        .process_pause, .process_kill => {
            applied.process_index = @intCast(sdk.random_below(processes_max));
        },
        .thread_pause => {
            applied.process_index = @intCast(sdk.random_below(processes_max));
            applied.thread_index = @intCast(sdk.random_below(threads_max));
        },
        .degrade => {
            applied.flavor = request.flavor;
            applied.netem = degradation(request.flavor);
        },
        .clog => {
            applied.disruption = request.disruption;
            applied.direction = request.direction;
        },
        .partition_groups => {
            if (request.groups.len < 2) return error.FewerThanTwoGroups;
            for (request.groups, 0..) |group, number| {
                for (group) |name| {
                    const index = endpoint_index(system, name) orelse return error.UnknownNode;
                    applied.groups[index] = @intCast(number);
                }
            }
            applied.disruption = request.disruption;
            applied.direction = request.direction;
        },
        .clock_skip => {
            applied.skip_ns = request.skip_ms * std.time.ns_per_ms;
            applied.forward = request.forward;
            applied.permanent = true;
        },
        .custom => applied.program = request.program,
        .durable_crash, .sync_stall => {
            applied.one_in = @max(request.one_in, 1);
            applied.after_sync = request.after_sync;
            applied.stall_ms_min = request.stall_ms_min;
            applied.stall_ms_max = request.stall_ms_max;
        },
        .disk => applied.disk = .{
            .failure = request.failure,
            .delay_ms = request.delay_ms,
            .corrupt_byte = @intCast(1 + sdk.random_below(disk_sector_size)),
            .corrupt_value = @intCast(sdk.random_below(256)),
        },
        else => {},
    }
    return applied;
}

/// `det-faults inject '<json>'`: asks the running injector for that fault now.
fn inject_request(json: []const u8) !void {
    if (json.len + 8 > request_size_max) return error.RequestTooLarge;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true };
    const fd = linux.open(control_path, flags, 0);
    if (linux.errno(fd) != .SUCCESS) {
        std.debug.print("det-faults inject: no fault injector is running (faults happen " ++
            "while drivers run)\n", .{});
        return error.NoInjector;
    }
    defer _ = linux.close(@intCast(fd));
    var message: [request_size_max]u8 = undefined;
    std.mem.writeInt(u64, message[0..8], inject_flag | json.len, .little);
    @memcpy(message[8..][0..json.len], json);
    const written = linux.write(@intCast(fd), &message, json.len + 8);
    if (linux.errno(written) != .SUCCESS) return error.WriteFailed;
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
    // partition and degrade both ways (3). Thread pauses where process pauses are (2). Sync
    // stalls (on by default) on both (2). A clog of b (it allows isolation), groups across the
    // runner, a and b. Clock skip. A restore.
    try std.testing.expectEqual(@as(u32, 25), faults_collect(&system, &scenario, &faults));
    const groups = faults[0..25];
    const has_groups = for (groups) |fault| {
        if (fault.kind == .partition_groups) break true;
    } else false;
    try std.testing.expect(has_groups);
    try std.testing.expectEqual(Kind.restore, faults[24].kind); // The last one.
}

test harsher {
    const stopped = nodes.Netem{ .delay_ns = 0, .loss_ppm = nodes.Netem.ppm, .seed = 0 };
    const jammed = nodes.Netem{ .delay_ns = 400 * std.time.ns_per_ms, .seed = 0 };
    const slowed = nodes.Netem{ .delay_ns = 60 * std.time.ns_per_ms, .seed = 0 };
    try std.testing.expect(harsher(stopped, jammed));
    try std.testing.expect(harsher(jammed, slowed));
    try std.testing.expect(!harsher(slowed, stopped));
}

test groups_draw {
    var allowed: [endpoints_max]bool = @splat(false);
    for (allowed[0..4]) |*ok| ok.* = true;
    for (0..64) |_| {
        const groups = groups_draw(allowed);
        for (groups[4..]) |group| try std.testing.expectEqual(@as(u16, group_none), group);
        const split = for (groups[1..4]) |group| {
            if (group != groups[0]) break true;
        } else false;
        try std.testing.expect(split);
    }
}

test disrupted_links {
    const base = schema.Resolved{
        .name = "a",
        .address = "10.0.0.2",
        .disk = "vdb",
        .digest = "",
        .command = &.{"x"},
        .env = &.{},
    };
    var resolved = [2]schema.Resolved{ base, base };
    resolved[1].name = "b";
    const system = schema.System{ .profile = "p", .nodes = &resolved, .scenarios = &.{} };
    var groups: [endpoints_max]u16 = @splat(group_none);
    groups[0] = 0; // runner
    groups[1] = 0; // a
    groups[2] = 1; // b
    const partition = Applied{
        .kind = .partition_groups,
        .duration_ns = 1,
        .disruption = .jammed,
        .groups = groups,
    };
    var links: [directed_max]Directed = undefined;
    // b is cut from the runner and from a, both ways.
    try std.testing.expectEqual(@as(u32, 4), disrupted_links(&system, &partition, &links));
    const clog = Applied{
        .kind = .clog,
        .node = "a",
        .duration_ns = 1,
        .disruption = .stopped,
        .direction = .inbound,
    };
    // Into a: from the runner and from b.
    try std.testing.expectEqual(@as(u32, 2), disrupted_links(&system, &clog, &links));
}
