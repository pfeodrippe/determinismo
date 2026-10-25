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
//!
//! Quiet periods (Antithesis's pausing faults): `det-stop-faults <seconds>`, from any node or
//! command, writes to the control FIFO. The fault under way ends there (the network heals, a
//! node comes back), and no new faults start until the longest requested period is over,
//! except clock skips, which go on.
//!
//! Network faults overlap (see "Network faults" below); node faults happen one at a time.
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
    /// A power loss: the node's disk keeps what was synced, then it starts again.
    crash,
    /// It starts again fresh from its image, everything it wrote gone.
    wipe,
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
const throttle_percent_max = 50;
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
    sdk.event("faults_start", .{ .faults = count });
    baseline_start(&system);
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
};

/// A fault's parameters, drawn from platform randomness.
fn draw(fault: *const Fault) Applied {
    var applied = Applied{
        .kind = fault.kind,
        .node = fault.node,
        .peer = fault.peer,
        .program = fault.program,
        .duration_ns = sdk.random_below_named("fault.duration_ns", duration_ns_max),
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
        },
        .clog => {
            applied.disruption = sdk.random_choice(Disruption, std.enums.values(Disruption));
            applied.direction = sdk.random_choice(Direction, std.enums.values(Direction));
        },
        else => {},
    }
    return applied;
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
        if (allowed.crash) faults_add(faults, &count, .{ .kind = .crash, .node = node.name });
        if (allowed.wipe) faults_add(faults, &count, .{ .kind = .wipe, .node = node.name });
        if (allowed.throttle) faults_add(faults, &count, .{ .kind = .throttle, .node = node.name });
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
        .pause => {
            nodes.freeze(applied.node, .frozen) catch return;
            sdk.event("fault", applied.*);
            sleep_ns(applied.duration_ns);
            nodes.freeze(applied.node, .thawed) catch {};
        },
        .restart, .crash, .wipe => {
            const stopped = switch (applied.kind) {
                .crash => nodes.crash(applied.node),
                .wipe => nodes.wipe(applied.node),
                else => nodes.kill(applied.node),
            };
            stopped catch |err| {
                sdk.event("fault_failed", .{ .node = applied.node, .err = @errorName(err) });
                return;
            };
            sdk.event("fault", applied.*);
            sleep_ns(applied.duration_ns);
            const node = system.node(applied.node) orelse return;
            nodes.start(arena, system, node) catch |err| {
                const details = .{ .node = applied.node, .err = @errorName(err) };
                sdk.event("fault_restart_failed", details);
                return;
            };
            network_node_new(system, applied.node); // Its links are new.
        },
        .throttle => {
            nodes.cpu_limit(applied.node, applied.cpu_percent) catch return;
            sdk.event("fault", applied.*);
            sleep_ns(applied.duration_ns);
            nodes.cpu_limit(applied.node, null) catch {};
        },
        .process_pause => apply_process_pause(applied),
        .thread_pause => apply_thread_pause(applied),
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

const ptrace_detach = 17;
const wait_all = 0x40000000; // __WALL: threads too.

/// Stops one thread with ptrace (seize, interrupt) for the fault's duration, then detaches:
/// the process's other threads run on meanwhile.
fn apply_thread_pause(applied: *const Applied) void {
    var pids: [processes_max]linux.pid_t = undefined;
    const count = nodes.processes(applied.node, &pids) catch return;
    if (count == 0) return;
    const pid = pids[applied.process_index % count];
    var tids: [threads_max]linux.pid_t = undefined;
    const threads = nodes.threads(pid, &tids);
    if (threads == 0) return;
    const tid = tids[applied.thread_index % threads];
    if (linux.errno(linux.ptrace(linux.PTRACE.SEIZE, tid, 0, 0, 0)) != .SUCCESS) return;
    defer _ = linux.ptrace(ptrace_detach, tid, 0, 0, 0);
    if (linux.errno(linux.ptrace(linux.PTRACE.INTERRUPT, tid, 0, 0, 0)) != .SUCCESS) return;
    var status: i32 = 0;
    _ = linux.wait4(tid, &status, wait_all, null); // Stopped.
    sdk.event("fault", applied.*);
    sleep_ns(applied.duration_ns);
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
            applied.groups[b] != group_none and applied.groups[a] != applied.groups[b],
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
        if (system_active) |system| network_expire(system, now_ns);
        if (now_ns >= deadline_ns or stopping.load(.acquire)) return;
        const wake_ns = @min(deadline_ns, network_next_end() orelse deadline_ns);
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
        if (requests_read() > 0) {
            if (system_active) |system| network_heal(system);
            return;
        }
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

/// Takes the pending requests: the quiet period ends at the latest one asks for. Returns
/// how many there were.
fn requests_read() u32 {
    var requests: [64]u64 = undefined;
    const bytes: [*]u8 = @ptrCast(&requests);
    const size = linux.read(control, bytes, @sizeOf(@TypeOf(requests)));
    if (linux.errno(size) != .SUCCESS) return 0;
    const count: u32 = @intCast(size / @sizeOf(u64));
    const now_ns = monotonic_ns();
    for (requests[0..count]) |request| {
        const duration_ns = std.mem.littleToNative(u64, request);
        if (duration_ns == 0) {
            // A zero-length request ends the quiet period (Antithesis's unpause).
            quiet_until_ns = 0;
            sdk.event("faults_resume", .{});
            continue;
        }
        quiet_until_ns = @max(quiet_until_ns, now_ns + duration_ns);
        sdk.event("faults_quiet", .{ .duration_ns = duration_ns, .until_ns = quiet_until_ns });
    }
    return count;
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
    // partition and degrade both ways (3). Thread pauses where process pauses are (2). A clog
    // of b (it allows isolation), groups across the runner, a and b. Clock skip. A restore.
    try std.testing.expectEqual(@as(u32, 23), faults_collect(&system, &scenario, &faults));
    const groups = faults[0..23];
    const has_groups = for (groups) |fault| {
        if (fault.kind == .partition_groups) break true;
    } else false;
    try std.testing.expect(has_groups);
    try std.testing.expectEqual(Kind.restore, faults[22].kind);
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
