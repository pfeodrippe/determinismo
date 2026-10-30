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
//! Branch points: the platform tells det-agent (its `det:branch` action, agent.zig), which tells
//! this, where a timeline begins at a moment of another (the tree's returns, just after a new
//! behavior), and which node that behavior came from. A quiet stretch of the pacing ends there
//! and a fault is drawn at once, among those involving that node when any does: each branch is
//! perturbed right after the moment it was chosen for, where it happened, never seconds later
//! somewhere else. Quiet periods a node or command asked for stay.
//!
//! Faults from the scenario: `det-faults inject '<json>'` (any language, any node or command)
//! or the SDK's `fault`, while the injector runs, apply that fault now, logged and undone like a
//! drawn one: {"kind": "pause", "node": "db", "duration_ms": 2000}, {"kind":
//! "partition_groups", "groups": [["runner", "a"], ["b", "c"]], "disruption": "stopped",
//! "direction": "both"}, {"kind": "degrade", "node": "a", "peer": "b", "flavor": "delay_loss"},
//! {"kind": "clog", "node": "a", "direction": "inbound"}, {"kind": "throttle", "node": "a",
//! "cpu_percent": 10}, {"kind": "clock_skip", "skip_ms": 500, "forward": true} (permanent),
//! {"kind": "clock_skew", "node": "a", "skip_ms": 300, "forward": false} (with "strobe_ms": 50,
//! coming and going), {"kind": "restore"}, {"kind": "disk", "node": "db", "failure": "lost_writes"} (failures:
//! errors, write_errors, lost_writes, corrupt_reads, slow with "delay_ms"); {"kind": "outage",
//! "nodes": ["a", "b"]} (every node that allows crashes when none are named); restart, crash,
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
/// A clock skew's size, log-uniform from a millisecond (within a hybrid logical clock's maximum
/// offset) up to the node's largest (Faults.clock_skew_ms_max; seconds: past leases, timeouts).
const clock_skew_ns_min = std.time.ns_per_ms;
const clock_skew_ns_max = 10 * std.time.ns_per_s;

const Kind = enum {
    pause,
    isolate,
    partition,
    degrade,
    restart,
    /// A power loss: the node's disk keeps what was synced, then it starts again.
    crash,
    /// A power loss of several nodes at the same moment (a rack's, a datacenter's; Jepsen's
    /// kill of a majority or of all): each keeps what it synced, and all start again at its end.
    /// Systems that acknowledge before a sync, counting on their replicas (Galera's
    /// recommended settings, Kafka's), lose acknowledged writes only so. For nodes that allow
    /// restarts but not power losses, a kill of several at once instead (`power` false): Jepsen
    /// found YugabyteDB 1.3.1's #2125 killing every master together.
    outage,
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
    /// One pod of a Kubernetes node (Faults.pods) frozen, killed, cut off, or its network
    /// degraded, in its own network namespace.
    pod_pause,
    pod_kill,
    pod_isolate,
    pod_degrade,
    /// Two pods of a Kubernetes node cut off from each other (each drops what it sends to the
    /// other), the rest of their network as it was.
    pod_partition,
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
    /// One node's realtime clock skewed, forward or back, for a while (Jepsen's clock bumps;
    /// nodes.clock_offset): the other nodes' clocks as they were.
    clock_skew,
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
    /// For outage: power losses (false: kills, the nodes allowing restarts).
    power: bool = true,
    /// For clock_skew: the node's largest skew.
    skew_ns_max: u64 = clock_skew_ns_max,
};

/// Set by the SIGTERM handler; checked between steps so a stop never leaves a fault applied.
var stopping = std.atomic.Value(bool).init(false);

fn on_terminate(_: linux.SIG) callconv(.c) void {
    stopping.store(true, .release);
}

/// A built-in property: the main loop is never busy (not waiting for its next fault or a
/// fault's end) for long. It once waited forever on a lock (a deadlock with the durability
/// listener), and the only signs were nodes left down and isolations never healed (srv3,
/// 2026-10-28, Kafka run 24).
const stall_property = "the fault injector never stalls";
const stall_ns = 30 * std.time.ns_per_s;
const watchdog_interval_ns = 5 * std.time.ns_per_s;
/// When the main loop's work in hand began (CLOCK_MONOTONIC), 0 while it waits.
var busy_since_ns = std.atomic.Value(u64).init(0);
var watchdog_done = std.atomic.Value(bool).init(false);
var stall_reported = std.atomic.Value(bool).init(false);

fn busy_begin() void {
    if (busy_since_ns.load(.monotonic) == 0) busy_since_ns.store(monotonic_ns(), .monotonic);
}

/// What the main loop is doing ("apply crash kafka-1", "end restart kafka-3", "heal"), for the
/// watchdog to say with a stall: run 68's (srv3, a 34 s stall in timeline 98) said only how long.
/// A diagnostic: the watchdog's copy may catch it mid-write.
var doing_buffer: [96]u8 = undefined;
var doing_size = std.atomic.Value(u8).init(0);

fn doing_set(comptime phase: []const u8, kind: ?Kind, node: []const u8) void {
    doing_size.store(0, .release);
    const text = std.fmt.bufPrint(&doing_buffer, phase ++ "{s}{s}{s}{s}", .{
        if (kind != null) " " else "",
        if (kind) |known| @tagName(known) else "",
        if (node.len > 0) " " else "",
        node,
    }) catch doing_buffer[0..0];
    doing_size.store(@intCast(text.len), .release);
}

fn busy_end() void {
    busy_since_ns.store(0, .monotonic);
}

/// Watches the main loop from a thread of its own: a stall fails `stall_property` once, with
/// how long the loop had been busy.
fn watchdog() void {
    while (!watchdog_done.load(.acquire)) {
        nodes.sleep_ns(watchdog_interval_ns);
        const since = busy_since_ns.load(.monotonic);
        if (since == 0 or stall_reported.load(.monotonic)) continue;
        const busy = monotonic_ns() -| since;
        if (busy < stall_ns) continue;
        stall_reported.store(true, .monotonic);
        var doing: [96]u8 = undefined;
        const size = doing_size.load(.acquire);
        @memcpy(doing[0..size], doing_buffer[0..size]);
        sdk.assert_computed(.always, false, stall_property, .{
            .busy_ms = busy / std.time.ns_per_ms,
            .doing = doing[0..size],
        });
    }
}

fn watchdog_start() void {
    const thread = std.Thread.spawn(.{}, watchdog, .{}) catch return;
    thread.detach();
}

/// The loop is over (its faults undone): a timeline without a stall passes the property.
fn watchdog_finish() void {
    watchdog_done.store(true, .release);
    if (!stall_reported.load(.monotonic)) sdk.assert_computed(.always, true, stall_property, .{});
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
    // `det-faults aim <node>` ("" for none): as the SDKs' fault_aim, for those that run commands.
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "aim")) {
        return control_request(aim_flag, arguments[2][0..@min(arguments[2].len, branch_node_max)]);
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
    busy_begin();
    watchdog_start();
    baseline_start(&system);
    disk_baseline_start(&system);
    if (script_faults(arena)) |scripted| return run_script(arena, &system, scripted);
    const mixed = swarm_select(&faults, count);
    const names = try fault_names(arena, faults[0..mixed]);
    const pacing = scenario.pacing;
    // With bursts: when the stretch of faults under way ends (CLOCK_MONOTONIC).
    var active_until_ns: u64 = if (pacing.active_ms_max > 0) monotonic_ns() + stretch_ns("fault.active_ms", pacing.active_ms_max) else std.math.maxInt(u64);
    var injections: u32 = 0;
    while (injections < injections_max) : (injections += 1) {
        const wait_ns = sdk.random_below_named("fault.wait_ns", delay_ns_max - delay_ns_min);
        sleep_ns(delay_ns_min + wait_ns);
        if (stopping.load(.acquire)) break;
        if (monotonic_ns() >= active_until_ns) {
            // A quiet stretch (healing what is under way), then the next stretch of faults.
            if (pacing.quiet_ms_max > 0) {
                quiet_request(stretch_ns("fault.quiet_ms", pacing.quiet_ms_max));
                quiet_pacing = true;
                const now_ns = monotonic_ns();
                if (quiet_until_ns > now_ns) sleep_ns(quiet_until_ns - now_ns);
                if (stopping.load(.acquire)) break;
            }
            active_until_ns = @max(quiet_until_ns, monotonic_ns()) + stretch_ns("fault.active_ms", pacing.active_ms_max);
        }
        // Labeled decisions: a strategy sees which faults it chooses among, by name.
        const applied = draw(&faults[fault_choose(faults[0..mixed], names)]);
        if (monotonic_ns() < quiet_until_ns and applied.kind != .clock_skip) continue;
        apply(arena, &system, &applied);
    }
    busy_begin();
    doing_set("heal", null, "");
    node_heal(&system);
    network_stop(&system);
    leftovers_check(&system);
    busy_end();
    watchdog_finish();
    sdk.event("faults_stop", .{ .injections = injections });
}

/// Once faults stop, nothing of them lasts: what the system does after (its recovery, the
/// eventually commands) is its own. Each node's state as the kernel has it (nodes.leftover), and
/// the injector's own: no durability point armed, no link down or degraded beyond the baseline.
fn leftovers_check(system: *const schema.System) void {
    for (system.nodes, 0..) |node, index| {
        const node_left = nodes.leftover(node.name);
        const armed = durable_active[index];
        const left = if (node_left.len > 0) node_left else if (armed) "a durability point armed" else "";
        sdk.assert_computed(.always, left.len == 0, "faults leave nothing behind once they stop", .{
            .node = node.name,
            .left = left,
        });
    }
    var links_down: u32 = 0;
    // The links still down, by name ("runner-raft-1 raft-2-raft-3"), as many as fit.
    var names_buffer: [256]u8 = undefined;
    var names: std.Io.Writer = .fixed(&names_buffer);
    for (network.down, 0..) |row, a| {
        for (row, 0..) |down, b| {
            if (!down) continue;
            links_down += 1;
            names.print("{s}{s}-{s}", .{
                if (links_down == 1) "" else " ", endpoint_name(system, a), endpoint_name(system, b),
            }) catch {};
        }
    }
    sdk.assert_computed(.always, links_down == 0 and network.count == 0, "faults leave nothing behind once they stop", .{
        .node = "",
        .left = if (links_down > 0) "links down" else if (network.count > 0) "network faults under way" else "",
        .links = names.buffered(),
    });
}

/// A stretch of the pacing, drawn from a tenth of `max_ms` up to it.
fn stretch_ns(comptime name: []const u8, max_ms: u32) u64 {
    const floor_ms = max_ms / 10;
    const drawn_ms = floor_ms + sdk.random_below_named(name, max_ms - floor_ms + 1);
    return drawn_ms * std.time.ns_per_ms;
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
/// Swarm testing (Groce et al., "Swarm Testing", ISSTA 2012; Antithesis's exploration credits it
/// too): this timeline's faults are some of the kinds allowed, each kind in or out half and half
/// by a named decision ("fault.swarm <kind>", for strategies to steer), one at least. A mix
/// without some kinds reaches what the full mix makes improbable (partitions on and on with no
/// restart healing them); a branch from a moment keeps its timeline's mix, subtrees differ.
/// The kinds kept go first in `faults`: how many.
fn swarm_select(faults: *[faults_max]Fault, count: u32) u32 {
    if (count == 0) return 0;
    if (swarm_off()) return count; // explore --no-swarm: every kind, for comparisons.
    var allowed: std.EnumSet(Kind) = .empty;
    for (faults[0..count]) |fault| allowed.insert(fault.kind);
    var kept: std.EnumSet(Kind) = .empty;
    var kinds = allowed.iterator();
    while (kinds.next()) |kind| {
        var label_buffer: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buffer, "fault.swarm {s}", .{@tagName(kind)}) catch "fault.swarm";
        if (sdk.random_below_named(label, 2) == 0) kept.insert(kind);
    }
    if (kept.count() == 0) {
        var pick = sdk.random_below_named("fault.swarm_one", allowed.count());
        var any = allowed.iterator();
        while (any.next()) |kind| {
            if (pick == 0) kept.insert(kind);
            pick -|= 1;
        }
    }
    var front: u32 = 0;
    for (0..count) |index| {
        if (!kept.contains(faults[index].kind)) continue;
        std.mem.swap(Fault, &faults[front], &faults[index]);
        front += 1;
    }
    var names_buffer: [512]u8 = undefined;
    var names: std.Io.Writer = .fixed(&names_buffer);
    var listed = kept.iterator();
    while (listed.next()) |kind| names.print("{s}{s}", .{ if (names.end == 0) "" else " ", @tagName(kind) }) catch break;
    sdk.event("fault_swarm", .{ .kinds = names.buffered(), .faults = front, .of = count });
    return front;
}

/// `det.swarm=0` among the kernel's command line's words (explore's --no-swarm).
fn swarm_off() bool {
    const fd = linux.open("/proc/cmdline", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return false;
    defer _ = linux.close(@intCast(fd));
    var buffer: [4096]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return false;
    var words = std.mem.tokenizeAny(u8, buffer[0..size], " \n");
    while (words.next()) |word| if (std.mem.eql(u8, word, "det.swarm=0")) return true;
    return false;
}

test swarm_select {
    // Outside the guest the decisions are the local random source: whatever is kept goes first,
    // one kind at least, and nothing is lost.
    var faults: [faults_max]Fault = undefined;
    const kinds = [_]Kind{ .pause, .restart, .pause, .isolate, .restart };
    for (kinds, 0..) |kind, index| faults[index] = .{ .kind = kind, .node = "n" };
    const kept = swarm_select(&faults, kinds.len);
    try std.testing.expect(kept >= 1 and kept <= kinds.len);
    for (faults[0..kept]) |kept_fault| for (faults[kept..kinds.len]) |left| {
        try std.testing.expect(kept_fault.kind != left.kind);
    };
}

fn fault_names(arena: std.mem.Allocator, faults: []const Fault) ![]const []const u8 {
    const names = try arena.alloc([]const u8, faults.len);
    for (faults, names) |fault, *name| {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(arena, @tagName(fault.kind));
        if (fault.kind == .outage and !fault.power) try text.appendSlice(arena, " kill");
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
    /// For clock_skew: 0 holds the skew for the fault's duration; otherwise it comes and goes
    /// every this many nanoseconds (Jepsen's strobe: a clock flipping as a confused NTP might).
    strobe_ns: u64 = 0,
    disruption: ?Disruption = null,
    direction: ?Direction = null,
    /// For custom: the program in the node, and its exit status (in the event).
    program: []const u8 = "",
    /// For partition_groups: each endpoint's group (runner first), group_none for those left out.
    /// (u16, not u8: JSON writes byte arrays as strings.)
    groups: [endpoints_max]u16 = @splat(group_none),
    /// For outage: the nodes that lose power, or are killed (`power` false) (runner first,
    /// never it).
    outage: [endpoints_max]bool = @splat(false),
    power: bool = true,
    /// For process_pause, thread_pause and process_kill: the process's command name, as it was
    /// (which of a node's processes is the question: a master or a backend).
    process: []const u8 = "",
    /// Asked for by the scenario (`det-faults inject`, the SDK's `fault`), not drawn.
    injected: bool = false,
    disk: ?nodes.DiskFault = null,
    /// For durable_crash and sync_stall: one durability point in this many is picked; a crash
    /// there is just after the sync or before it; a stall lasts up to stall_ms_max.
    one_in: u32 = 0,
    after_sync: bool = false,
    stall_ms_min: u32 = 1,
    stall_ms_max: u32 = 0,
    /// For the pod faults: the pod's name (process_index picks it among the node's pods), and
    /// for pod_partition the other one's (thread_index picks it).
    pod: []const u8 = "",
    peer_pod: []const u8 = "",
};

/// A clock skew's size up to `max_ns`: a decade from a millisecond (1 ms, 10 ms, 100 ms, 1 s)
/// below it, then uniform within that decade (or up to the maximum).
fn clock_skew_draw(max_ns: u64) u64 {
    assert(max_ns >= clock_skew_ns_min * 10);
    var decades: u64 = 0;
    var top: u64 = clock_skew_ns_min * 10;
    while (top < max_ns and decades < 3) : (decades += 1) top *= 10;
    var low: u64 = clock_skew_ns_min;
    for (0..sdk.random_below(decades + 1)) |_| low *= 10;
    return low + sdk.random_below(@min(low * 10, max_ns) - low);
}

test clock_skew_draw {
    // Every size within the maximum, from a millisecond.
    for ([_]u64{ 10 * std.time.ns_per_ms, 400 * std.time.ns_per_ms, clock_skew_ns_max }) |max_ns| {
        for (0..200) |_| {
            const size = clock_skew_draw(max_ns);
            try std.testing.expect(size >= clock_skew_ns_min and size < max_ns);
        }
    }
}

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
        .process_pause, .process_kill, .pod_pause, .pod_kill, .pod_isolate => {
            applied.process_index = @intCast(sdk.random_below(processes_max));
        },
        .pod_partition => {
            applied.process_index = @intCast(sdk.random_below(processes_max));
            applied.thread_index = @intCast(sdk.random_below(processes_max));
        },
        .pod_degrade => {
            applied.process_index = @intCast(sdk.random_below(processes_max));
            const flavor = sdk.random_choice(Degradation, std.enums.values(Degradation));
            applied.flavor = flavor;
            applied.netem = degradation(flavor);
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
        .clock_skew => {
            applied.forward = sdk.random_below(2) == 0;
            applied.skip_ns = clock_skew_draw(fault.skew_ns_max);
            // One in four strobes, flipping every 10 ms to a second.
            if (sdk.random_below(4) == 0) applied.strobe_ns = (10 + sdk.random_below(991)) * std.time.ns_per_ms;
        },
        .outage => {
            applied.outage = outage_draw(fault.endpoints);
            applied.power = fault.power;
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

/// The nodes of an outage, among those allowed: all of them half the time (a datacenter's
/// power), else a random group of at least two (a rack's).
fn outage_draw(allowed: [endpoints_max]bool) [endpoints_max]bool {
    if (sdk.random_below_named("fault.outage_all", 2) == 0) return allowed;
    var candidates: [endpoints_max]u8 = undefined;
    var count: u32 = 0;
    for (allowed, 0..) |yes, index| {
        if (!yes) continue;
        candidates[count] = @intCast(index);
        count += 1;
    }
    assert(count >= 2);
    const size = 2 + sdk.random_below_named("fault.outage_size", count - 1);
    // The first `size` of a partial Fisher-Yates shuffle.
    var picked: [endpoints_max]bool = @splat(false);
    for (0..size) |at| {
        const other = at + sdk.random_below(count - at);
        std.mem.swap(u8, &candidates[at], &candidates[other]);
        picked[candidates[at]] = true;
    }
    return picked;
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
        // name no node). The runner is no node of the system's, and never gone: its links'
        // faults ("degrade runner ...") were all skipped, the scripted timeline missing them.
        const runner = std.mem.eql(u8, fault.node, "runner");
        const gone = fault.node.len > 0 and !runner and system.node(fault.node) == null;
        if (gone) continue;
        apply(arena, system, fault);
        injections += 1;
    }
    node_heal(system);
    network_stop(system);
    leftovers_check(system);
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
        if (allowed.clock_skew) faults_add(faults, &count, .{
            .kind = .clock_skew,
            .node = node.name,
            .skew_ns_max = @as(u64, @max(10, allowed.clock_skew_ms_max)) * std.time.ns_per_ms,
        });
        if (allowed.sync_stall) faults_add(faults, &count, .{ .kind = .sync_stall, .node = node.name });
        if (allowed.process_pause) {
            faults_add(faults, &count, .{ .kind = .process_pause, .node = node.name });
            faults_add(faults, &count, .{ .kind = .thread_pause, .node = node.name });
        }
        if (allowed.process_kill) {
            faults_add(faults, &count, .{ .kind = .process_kill, .node = node.name });
        }
        if (allowed.pods) {
            for ([_]Kind{ .pod_pause, .pod_kill, .pod_isolate, .pod_degrade, .pod_partition }) |kind| {
                faults_add(faults, &count, .{ .kind = kind, .node = node.name });
            }
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
    var crashable: [endpoints_max]bool = @splat(false);
    var crashable_count: u32 = 0;
    var restartable: [endpoints_max]bool = @splat(false);
    var restartable_count: u32 = 0;
    for (system.nodes, 1..) |node, index| {
        crashable[index] = node.faults.crash;
        crashable_count += @intFromBool(node.faults.crash);
        restartable[index] = node.faults.restart;
        restartable_count += @intFromBool(node.faults.restart);
    }
    if (crashable_count >= 2) faults_add(faults, &count, .{ .kind = .outage, .endpoints = crashable });
    if (restartable_count >= 2) {
        faults_add(faults, &count, .{ .kind = .outage, .endpoints = restartable, .power = false });
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
    if (node.faults.runner_links) links_add(faults, count, node, schema.runner_name, .{});
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
    doing_set("apply", applied.kind, applied.node);
    defer doing_set("wait", null, "");
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
        .clock_skew,
        .process_pause,
        .thread_pause,
        .pod_pause,
        .pod_isolate,
        .pod_degrade,
        .pod_partition,
        => node_start(system, applied),
        .outage => outage_start(system, applied),
        .process_kill => apply_process_kill(system, applied),
        .pod_kill => apply_pod_kill(applied),
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
    /// A strobing clock skew: when it next comes or goes, and whether it is on now.
    flip_ns: ?u64 = null,
    skewed: bool = true,
    /// The process or thread stopped (process_pause, thread_pause); for a pod fault, a process
    /// of the pod (its network namespace).
    pid: linux.pid_t = 0,
    /// thread_pause: its stop reported (a thread in a kernel wait stops only as it returns).
    stopped: bool = false,
    /// The pod's cgroup (pod faults), and for pod_partition the other one's, its process, and
    /// the two pods' addresses.
    pod: Pod = .{},
    peer: Pod = .{},
    peer_pid: linux.pid_t = 0,
    addresses: [2]nodes.Address = undefined,
    /// The stopped process's command name (process_pause, thread_pause), for its event.
    command: [16]u8 = undefined,
    command_size: u8 = 0,
};

/// A process's command name (/proc/<pid>/comm), into `buffer`.
fn command_of(pid: linux.pid_t, buffer: *[16]u8) []const u8 {
    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/comm", .{pid}, 0) catch return "";
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return "";
    defer _ = linux.close(@intCast(fd));
    const size = linux.read(@intCast(fd), buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return "";
    return std.mem.trimEnd(u8, buffer[0..size], "\n");
}
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

/// A clock skew's signed offset.
fn skew_ns(applied: *const Applied) i64 {
    const size: i64 = @intCast(applied.skip_ns);
    return if (applied.forward) size else -size;
}

fn skew_begin(applied: *const Applied, fault: *NodeFault) !void {
    try nodes.clock_offset(applied.node, skew_ns(applied));
    if (applied.strobe_ns > 0) fault.flip_ns = monotonic_ns() + applied.strobe_ns;
}

fn node_start(system: *const schema.System, applied: *const Applied) void {
    const slot = node_slot(system, applied.node) orelse return;
    if (slot.* != null) return;
    var fault = NodeFault{ .applied = applied.*, .end_ns = monotonic_ns() + applied.duration_ns };
    const started: anyerror!void = switch (applied.kind) {
        .pod_pause, .pod_isolate, .pod_degrade => pod_begin(&fault),
        .pod_partition => pod_partition_begin(&fault),
        .pause => nodes.freeze(applied.node, .frozen),
        .restart => nodes.kill(applied.node),
        .crash => nodes.crash(applied.node),
        .durable_crash, .sync_stall => durable_arm(applied),
        .wipe => nodes.wipe(applied.node),
        .stop => stop_begin(applied.node, &fault),
        .disk => nodes.disk_fail(applied.node, applied.disk.?),
        .throttle => nodes.cpu_limit(applied.node, applied.cpu_percent),
        .clock_skew => skew_begin(applied, &fault),
        .process_pause => process_stop(applied, &fault),
        .thread_pause => thread_stop(applied, &fault),
        else => unreachable,
    };
    started catch |err| {
        // Nothing to fault (no pod to pick right now): not a failure.
        const skipped = err == error.NoPods or err == error.OnePod;
        sdk.event(if (skipped) "fault_skipped" else "fault_failed", .{ .node = applied.node, .err = @errorName(err) });
        return;
    };
    slot.* = fault;
    // A pod fault's event names its pod (kept in the slot, which the event reads).
    const node_fault = &slot.*.?;
    if (node_fault.command_size > 0) node_fault.applied.process = node_fault.command[0..node_fault.command_size];
    if (node_fault.pod.path_size > 0) node_fault.applied.pod = node_fault.pod.name();
    if (node_fault.peer.path_size > 0) node_fault.applied.peer_pod = node_fault.peer.name();
    sdk.event("fault", node_fault.applied);
}

fn node_end(system: *const schema.System, slot: *?NodeFault) void {
    const fault = slot.* orelse return;
    slot.* = null;
    const name = fault.applied.node;
    doing_set("end", fault.applied.kind, name);
    defer doing_set("wait", null, "");
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
        .restart, .crash, .outage, .wipe, .stop => {
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
        // A node started again meanwhile has a fresh namespace: this sets what it has already.
        .clock_skew => nodes.clock_offset(name, 0) catch {},
        .process_pause => _ = linux.kill(fault.pid, .CONT),
        .thread_pause => thread_release(fault.pid, fault.stopped),
        // The pod may be gone (killed, rescheduled), its cgroup and namespace with it: said.
        .pod_pause => fault.pod.write("cgroup.freeze", "0") catch |err| if (fault.pod.exists()) {
            sdk.event("fault_heal_failed", .{ .node = name, .pod = fault.pod.name(), .err = @errorName(err) });
        },
        // A pod gone meanwhile took its namespace, and what was set there, with it.
        .pod_isolate, .pod_degrade => nodes.pod_netem(fault.pid, null) catch |err| if (err != error.NoSuchNamespace) {
            sdk.event("fault_heal_failed", .{ .node = name, .pod = fault.pod.name(), .err = @errorName(err) });
        },
        .pod_partition => pod_partition_end(&fault),
        else => {},
    }
}
// Pod faults (Faults.pods) --------------------------------------------------------------------
// A Kubernetes node's pods are cgroups of its own (kubepods/<qos>/pod<uid>, or kubepods/pod<uid>
// for guaranteed ones): one is picked in name order by the fault's process_index.

const pods_max = 256;
const pod_containers_max = 16;

const Pod = struct {
    path_buffer: [nodes.path_size_max]u8 = undefined,
    path_size: usize = 0,
    name_buffer: [64]u8 = undefined,
    name_size: usize = 0,

    fn path(pod: *const Pod) []const u8 {
        return pod.path_buffer[0..pod.path_size];
    }

    /// Its name: a process's HOSTNAME (the pod's, as Kubernetes sets it), else its cgroup's.
    fn name(pod: *const Pod) []const u8 {
        if (pod.name_size > 0) return pod.name_buffer[0..pod.name_size];
        return std.fs.path.basename(pod.path());
    }

    /// Whether its cgroup is still there (a deleted pod's goes).
    fn exists(pod: *const Pod) bool {
        var buffer: [nodes.path_size_max]u8 = undefined;
        const directory = nodes.print_z(&buffer, "{s}", .{pod.path()}) catch return false;
        return linux.errno(linux.access(directory, linux.F_OK)) == .SUCCESS;
    }

    fn write(pod: *const Pod, file: []const u8, content: []const u8) !void {
        var buffer: [nodes.path_size_max + 32]u8 = undefined;
        try nodes.file_write(try nodes.print_z(&buffer, "{s}/{s}", .{ pod.path(), file }), content);
    }
};

const Directories = struct {
    paths: [pods_max][nodes.path_size_max]u8 = undefined,
    sizes: [pods_max]usize = undefined,
    count: usize = 0,

    fn get(directories: *const Directories, index: usize) []const u8 {
        return directories.paths[index][0..directories.sizes[index]];
    }

    /// The subdirectories of `parent` whose names start with `prefix`.
    fn add(directories: *Directories, parent: [:0]const u8, prefix: []const u8) void {
        const flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
        const opened = linux.open(parent, flags, 0);
        if (linux.errno(opened) != .SUCCESS) return;
        const fd: linux.fd_t = @intCast(opened);
        defer _ = linux.close(fd);
        var entries: [8192]u8 align(8) = undefined;
        while (true) {
            const size = linux.getdents64(fd, &entries, entries.len);
            if (linux.errno(size) != .SUCCESS or size == 0) return;
            var at: usize = 0;
            while (at < size) {
                const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[at]);
                at += entry.reclen;
                if (entry.type != linux.DT.DIR) continue;
                const entry_name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
                if (entry_name[0] == '.' or !std.mem.startsWith(u8, entry_name, prefix)) continue;
                if (directories.count == pods_max) return;
                const slot = &directories.paths[directories.count];
                const full = std.fmt.bufPrint(slot, "{s}/{s}", .{ parent, entry_name }) catch continue;
                directories.sizes[directories.count] = full.len;
                directories.count += 1;
            }
        }
    }

    fn before(directories: *const Directories, a: usize, b: usize) bool {
        return std.mem.lessThan(u8, directories.get(a), directories.get(b));
    }
};

/// The node's pod picked by `index` (their cgroups in name order: the same pod on a replay),
/// and a process of it (the first with a HOSTNAME naming the pod). Spared, the cluster's own
/// pods (kube-system: CoreDNS, the storage provisioner; node faults reach them) and, with
/// spare_drivers, the pods whose containers hold test templates (the drivers run there,
/// through kubectl exec: a kill would fail them, not the system).
fn pod_pick(node: []const u8, index: u32, pod: *Pod, spare_drivers: bool) !linux.pid_t {
    var pods: Directories = .{};
    var parent_buffer: [nodes.path_size_max]u8 = undefined;
    for ([_][]const u8{ "", "/burstable", "/besteffort" }) |class| {
        const format = nodes.cgroup_root ++ "/{s}/kubepods{s}";
        pods.add(try nodes.print_z(&parent_buffer, format, .{ node, class }), "pod");
    }
    if (pods.count == 0) return error.NoPods;
    var order: [pods_max]usize = undefined;
    for (order[0..pods.count], 0..) |*slot, at| slot.* = at;
    std.sort.insertion(usize, order[0..pods.count], &pods, Directories.before);
    var candidates: usize = 0;
    for (order[0..pods.count]) |at| {
        if (pod_in_namespace(node, pods.get(at), "kube-system")) continue;
        if (spare_drivers and pod_has_templates(pods.get(at))) continue;
        order[candidates] = at;
        candidates += 1;
    }
    if (candidates == 0) return error.NoPods;
    // The drawn pod, or the next in order with a process (a pod being deleted, or between its
    // containers' restarts, keeps a cgroup with none for a while).
    for (0..candidates) |attempt| {
        const picked = pods.get(order[(index + attempt) % candidates]);
        @memcpy(pod.path_buffer[0..picked.len], picked);
        pod.path_size = picked.len;
        pod.name_size = 0;
        if (try pod_process(pod)) |pid| return pid;
    }
    return error.NoPods;
}

/// A process of the pod (the first with a HOSTNAME naming the pod, which it notes), if any.
fn pod_process(pod: *Pod) !?linux.pid_t {
    var parent_buffer: [nodes.path_size_max]u8 = undefined;
    var containers: Directories = .{};
    containers.add(try nodes.print_z(&parent_buffer, "{s}", .{pod.path()}), "");
    var pid: ?linux.pid_t = null;
    for (0..@min(containers.count, pod_containers_max)) |at| {
        var procs_buffer: [nodes.path_size_max + 16]u8 = undefined;
        const procs = try nodes.print_z(&procs_buffer, "{s}/cgroup.procs", .{containers.get(at)});
        var text_buffer: [64]u8 = undefined;
        const text = nodes.read_small(procs, &text_buffer) orelse continue;
        const line = std.mem.trim(u8, std.mem.sliceTo(text, '\n'), " ");
        const first = std.fmt.parseInt(linux.pid_t, line, 10) catch continue;
        if (pid == null) pid = first;
        if (hostname_of(first, &pod.name_buffer)) |host| {
            pod.name_size = host.len;
            return first;
        }
    }
    return pid;
}

/// Whether the pod is in `namespace`: its service account's projected volume names it, in the
/// node's /var/lib/kubelet/pods/<uid> (a tmpfs of the node's mount namespace: seen through its
/// main process, K3s).
fn pod_in_namespace(node: []const u8, path: []const u8, namespace: []const u8) bool {
    const directory = std.fs.path.basename(path);
    if (!std.mem.startsWith(u8, directory, "pod")) return false;
    const uid = directory["pod".len..];
    const main_pid = nodes.pid_recorded(node) orelse return false;
    var projected: Directories = .{};
    var buffer: [nodes.path_size_max]u8 = undefined;
    const format = "/proc/{d}/root/var/lib/kubelet/pods/{s}/volumes/kubernetes.io~projected";
    projected.add(nodes.print_z(&buffer, format, .{ main_pid, uid }) catch return false, "kube-api-access");
    for (0..projected.count) |at| {
        var file_buffer: [nodes.path_size_max + 16]u8 = undefined;
        const file = nodes.print_z(&file_buffer, "{s}/namespace", .{projected.get(at)}) catch continue;
        var text_buffer: [256]u8 = undefined;
        const text = nodes.read_small(file, &text_buffer) orelse continue;
        return std.mem.eql(u8, std.mem.trim(u8, text, " \n"), namespace);
    }
    return false;
}

/// Whether one of the pod's containers holds Antithesis test templates.
fn pod_has_templates(path: []const u8) bool {
    var containers: Directories = .{};
    var buffer: [nodes.path_size_max]u8 = undefined;
    containers.add(nodes.print_z(&buffer, "{s}", .{path}) catch return false, "");
    for (0..@min(containers.count, pod_containers_max)) |at| {
        var procs_buffer: [nodes.path_size_max + 16]u8 = undefined;
        const procs = nodes.print_z(&procs_buffer, "{s}/cgroup.procs", .{containers.get(at)}) catch continue;
        var text_buffer: [64]u8 = undefined;
        const text = nodes.read_small(procs, &text_buffer) orelse continue;
        const line = std.mem.trim(u8, std.mem.sliceTo(text, '\n'), " ");
        const pid = std.fmt.parseInt(linux.pid_t, line, 10) catch continue;
        var templates_buffer: [64]u8 = undefined;
        const templates = std.fmt.bufPrintSentinel(&templates_buffer, "/proc/{d}/root/opt/antithesis/test/v1", .{pid}, 0) catch continue;
        if (linux.errno(linux.access(templates, linux.F_OK)) == .SUCCESS) return true;
    }
    return false;
}

/// A process's HOSTNAME (from its environment), into `buffer`.
fn hostname_of(pid: linux.pid_t, buffer: *[64]u8) ?[]const u8 {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/environ", .{pid}, 0) catch
        return null;
    var environment: [8192]u8 = undefined;
    const text = nodes.read_small(path, &environment) orelse return null;
    var entries = std.mem.splitScalar(u8, text, 0);
    while (entries.next()) |entry| {
        if (!std.mem.startsWith(u8, entry, "HOSTNAME=")) continue;
        const value = entry["HOSTNAME=".len..];
        if (value.len == 0 or value.len > buffer.len) return null;
        @memcpy(buffer[0..value.len], value);
        return buffer[0..value.len];
    }
    return null;
}

/// A pod fault with a duration begins: the pod frozen, or its network cut off or degraded.
fn pod_begin(fault: *NodeFault) !void {
    const applied = &fault.applied;
    fault.pid = try pod_pick(applied.node, applied.process_index, &fault.pod, false);
    switch (applied.kind) {
        .pod_pause => try fault.pod.write("cgroup.freeze", "1"),
        .pod_isolate => try nodes.pod_netem(fault.pid, .{
            .delay_ns = 0,
            .loss_ppm = nodes.Netem.ppm,
            .seed = applied.duration_ns,
        }),
        .pod_degrade => try nodes.pod_netem(fault.pid, applied.netem.?),
        else => unreachable,
    }
}

/// A partition between two pods begins: each drops what it sends to the other (a blackhole route
/// to the other's address, in its own network namespace). The second pod is picked by the
/// fault's thread_index, the next one when that is the first.
fn pod_partition_begin(fault: *NodeFault) !void {
    const applied = &fault.applied;
    fault.pid = try pod_pick(applied.node, applied.process_index, &fault.pod, false);
    fault.peer_pid = try pod_pick(applied.node, applied.thread_index, &fault.peer, false);
    if (std.mem.eql(u8, fault.pod.path(), fault.peer.path())) {
        fault.peer_pid = try pod_pick(applied.node, applied.thread_index +% 1, &fault.peer, false);
        if (std.mem.eql(u8, fault.pod.path(), fault.peer.path())) return error.OnePod;
    }
    fault.addresses[0] = try pod_address(applied.node, &fault.pod);
    fault.addresses[1] = try pod_address(applied.node, &fault.peer);
    try nodes.pod_blackhole(fault.pid, fault.addresses[1], true);
    nodes.pod_blackhole(fault.peer_pid, fault.addresses[0], true) catch |err| {
        nodes.pod_blackhole(fault.pid, fault.addresses[1], false) catch {};
        return err;
    };
}

fn pod_partition_end(fault: *const NodeFault) void {
    const name = fault.applied.node;
    for ([_]linux.pid_t{ fault.pid, fault.peer_pid }, [_]nodes.Address{ fault.addresses[1], fault.addresses[0] }) |pid, address| {
        nodes.pod_blackhole(pid, address, false) catch |err| if (err != error.NoSuchNamespace) {
            sdk.event("fault_heal_failed", .{ .node = name, .pod = fault.pod.name(), .peer_pod = fault.peer.name(), .err = @errorName(err) });
        };
    }
}

/// A pod's address: the file of the cluster's address management (host-local, in the node's
/// /var/lib/cni/networks/cbr0, seen through its main process) that names its sandbox, one of
/// the pod's container cgroups.
fn pod_address(node: []const u8, pod: *const Pod) !nodes.Address {
    const main_pid = nodes.pid_recorded(node) orelse return error.NodeNotRunning;
    var directory_buffer: [nodes.path_size_max]u8 = undefined;
    const directory = try nodes.print_z(&directory_buffer, "/proc/{d}/root/var/lib/cni/networks/cbr0", .{main_pid});
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const opened = linux.open(directory, flags, 0);
    if (linux.errno(opened) != .SUCCESS) return error.NoAddresses;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var entries: [8192]u8 align(8) = undefined;
    while (true) {
        const size = linux.getdents64(fd, &entries, entries.len);
        if (linux.errno(size) != .SUCCESS or size == 0) return error.NoAddress;
        var at: usize = 0;
        while (at < size) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[at]);
            at += entry.reclen;
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
            const address = address_parse(name) orelse continue;
            var file_buffer: [nodes.path_size_max + 32]u8 = undefined;
            const file = nodes.print_z(&file_buffer, "{s}/{s}", .{ directory, name }) catch continue;
            var text_buffer: [256]u8 = undefined;
            const text = nodes.read_small(file, &text_buffer) orelse continue;
            const sandbox = std.mem.trim(u8, std.mem.sliceTo(text, '\n'), " \r");
            if (sandbox.len == 0) continue;
            var sandbox_buffer: [nodes.path_size_max + 80]u8 = undefined;
            const cgroup = nodes.print_z(&sandbox_buffer, "{s}/{s}", .{ pod.path(), sandbox }) catch continue;
            if (linux.errno(linux.access(cgroup, linux.F_OK)) == .SUCCESS) return address;
        }
    }
}

/// An IPv4 address written as such ("10.42.0.5"), else null.
fn address_parse(text: []const u8) ?nodes.Address {
    var address: nodes.Address = undefined;
    var parts = std.mem.splitScalar(u8, text, '.');
    for (&address) |*byte| {
        byte.* = std.fmt.parseInt(u8, parts.next() orelse return null, 10) catch return null;
    }
    if (parts.next() != null) return null;
    return address;
}

test address_parse {
    try std.testing.expectEqual(nodes.Address{ 10, 42, 0, 5 }, address_parse("10.42.0.5").?);
    try std.testing.expectEqual(@as(?nodes.Address, null), address_parse("last_reserved_ip.0"));
    try std.testing.expectEqual(@as(?nodes.Address, null), address_parse("lock"));
    try std.testing.expectEqual(@as(?nodes.Address, null), address_parse("10.42.0"));
}

/// Every process of a pod killed at once (cgroup.kill): kubelet starts its containers again.
fn apply_pod_kill(applied: *const Applied) void {
    var pod: Pod = .{};
    _ = pod_pick(applied.node, applied.process_index, &pod, true) catch |err| {
        const skipped = err == error.NoPods;
        sdk.event(if (skipped) "fault_skipped" else "fault_failed", .{ .node = applied.node, .err = @errorName(err) });
        return;
    };
    pod.write("cgroup.kill", "1") catch |err| {
        sdk.event("fault_failed", .{ .node = applied.node, .err = @errorName(err) });
        return;
    };
    var named = applied.*;
    named.pod = pod.name();
    sdk.event("fault", named);
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
    doing_set("start again", null, name);
    // Waiting for the node to be ready (60 s at most: nodes.ready_wait) is not a stall: a
    // PostgreSQL recovering after a power loss took over 30 s in 95 timelines of run 43 (srv3),
    // each one failing the property.
    busy_end();
    defer busy_begin();
    nodes.start(arena, system, node) catch |err| {
        sdk.event("fault_restart_failed", .{ .node = name, .err = @errorName(err) });
        return;
    };
    network_node_new(system, name); // Its links are new.
}

fn node_expire(system: *const schema.System, now_ns: u64) void {
    threads_release_pending(0);
    for (&nodes_faulted) |*slot| {
        const fault = &(slot.* orelse continue);
        if (fault.grace_end_ns) |grace_end_ns| if (grace_end_ns <= now_ns) {
            nodes.kill_remaining(fault.applied.node) catch {};
            slot.*.?.grace_end_ns = null;
        };
        if (fault.flip_ns) |flip_ns| if (flip_ns <= now_ns and fault.end_ns > now_ns) {
            const skewed = !fault.skewed;
            nodes.clock_offset(fault.applied.node, if (skewed) skew_ns(&fault.applied) else 0) catch {};
            slot.*.?.skewed = skewed;
            slot.*.?.flip_ns = now_ns + fault.applied.strobe_ns;
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
        if (fault.flip_ns) |flip_ns| next = @min(next.?, flip_ns);
    }
    return next;
}

fn node_heal(system: *const schema.System) void {
    for (&nodes_faulted) |*slot| node_end(system, slot);
    threads_release_pending(threads_release_wait_ns);
}

/// How long healing waits for paused threads to stop so they can be let go.
const threads_release_wait_ns = 5 * std.time.ns_per_s;

/// An outage begins: its nodes all frozen first (none runs on while the others go down), then
/// each crashed (or killed, `power` false), each holding its own slot until the fault's end,
/// when all start again.
/// A node busy with another fault, or down already, is left out; with fewer than two left
/// there is no outage.
fn outage_start(system: *const schema.System, applied: *const Applied) void {
    var taken = applied.*;
    const count_nodes = system.nodes.len;
    var count: u32 = 0;
    for (system.nodes, nodes_faulted[0..count_nodes], taken.outage[1..][0..count_nodes]) |node, slot, *in| {
        if (!in.*) continue;
        in.* = slot == null and nodes.state_of(node.name) != .stopped;
        count += @intFromBool(in.*);
    }
    if (count < 2) {
        sdk.event("fault_skipped", .{ .kind = "outage", .err = "FewerThanTwoNodes" });
        return;
    }
    for (system.nodes, taken.outage[1..][0..count_nodes]) |node, in| {
        if (in) nodes.freeze(node.name, .frozen) catch {};
    }
    const end_ns = monotonic_ns() + applied.duration_ns;
    var down: u32 = 0;
    for (system.nodes, nodes_faulted[0..count_nodes], taken.outage[1..][0..count_nodes]) |node, *slot, *in| {
        if (!in.*) continue;
        const ended = if (applied.power) nodes.crash(node.name) else killed: {
            const result = nodes.kill(node.name);
            nodes.freeze(node.name, .thawed) catch {}; // Its next start runs.
            break :killed result;
        };
        ended catch |err| {
            nodes.freeze(node.name, .thawed) catch {};
            sdk.event("fault_failed", .{ .kind = "outage", .node = node.name, .err = @errorName(err) });
            in.* = false;
            continue;
        };
        var one = taken;
        one.node = node.name;
        slot.* = .{ .applied = one, .end_ns = end_ns };
        down += 1;
    }
    if (down == 0) return;
    // Its event names them all ("a,b,c"), as the logs and the causality analysis show it.
    var names: std.ArrayList(u8) = .empty;
    if (arena_active) |arena| {
        for (system.nodes, taken.outage[1..][0..count_nodes]) |node, in| {
            if (!in) continue;
            if (names.items.len > 0) names.append(arena, ',') catch {};
            names.appendSlice(arena, node.name) catch {};
        }
    }
    taken.node = names.items;
    sdk.event("fault", taken);
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
        // Crashed already during this fault (two of its threads were parked at durability
        // points): it is down until the fault's end starts it again.
        if (durable_crashed[node[1]]) {
            sdk.event("durable_crash_again", .{ .node = node[0], .pid = request.pid });
            continue;
        }
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
    fault.command_size = @intCast(command_of(fault.pid, &fault.command).len);
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
    fault.command_size = @intCast(command_of(pid, &fault.command).len);
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
    // Stopped at its next return to user space: one in a kernel wait (a sync held, a page fault)
    // stops only when it ends. Not waited for (run 177's timeline 24: 31 s, the injector stalled
    // meanwhile): the pause begins when the thread stops.
    fault.pid = tid;
    fault.stopped = thread_stopped(tid);
}

/// Whether the tracee `tid` reported its stop, or exited (polled, never waited for).
fn thread_stopped(tid: linux.pid_t) bool {
    var status: i32 = 0;
    const result = linux.wait4(tid, &status, wait_all | linux.W.NOHANG, null);
    return linux.errno(result) != .SUCCESS or result == tid;
}

/// Threads paused whose pause ended before they stopped: detached once they do (a seized thread
/// is detached only stopped), each pass of the injector's loop (threads_release_pending).
var threads_pending: [threads_pending_max]linux.pid_t = undefined;
var threads_pending_count: u32 = 0;
const threads_pending_max = 64;

fn thread_release(tid: linux.pid_t, stopped: bool) void {
    if (stopped or thread_stopped(tid)) {
        _ = linux.ptrace(ptrace_detach, tid, 0, 0, 0);
        return;
    }
    if (threads_pending_count == threads_pending_max) {
        // Never expected (one pause a node at a time): waited for rather than left stopped.
        var status: i32 = 0;
        _ = linux.wait4(tid, &status, wait_all, null);
        _ = linux.ptrace(ptrace_detach, tid, 0, 0, 0);
        return;
    }
    threads_pending[threads_pending_count] = tid;
    threads_pending_count += 1;
}

/// The pending threads that stopped meanwhile, detached; with `wait_ns`, waiting that long at
/// most for the rest (faults stop: none left stopped, leftovers_check says so if one is).
fn threads_release_pending(wait_ns: u64) void {
    const deadline_ns = monotonic_ns() + wait_ns;
    while (true) {
        var kept: u32 = 0;
        for (threads_pending[0..threads_pending_count]) |tid| {
            if (thread_stopped(tid)) {
                _ = linux.ptrace(ptrace_detach, tid, 0, 0, 0);
                continue;
            }
            threads_pending[kept] = tid;
            kept += 1;
        }
        threads_pending_count = kept;
        if (kept == 0 or monotonic_ns() >= deadline_ns) return;
        sleep_ns(std.time.ns_per_ms);
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

/// A crash: one of the node's processes other than its main one (a worker, a pod's process)
/// is killed, for whatever supervises it to notice; one of the names the node allows, when it
/// names some. Nothing to undo.
fn apply_process_kill(system: *const schema.System, applied: *const Applied) void {
    const names = if (system.node(applied.node)) |node| node.faults.process_kill_names else &.{};
    var pids: [processes_max]linux.pid_t = undefined;
    const count = nodes.processes(applied.node, &pids) catch return;
    const main_pid = nodes.pid_recorded(applied.node);
    var others: u32 = 0;
    for (pids[0..count]) |pid| {
        if (pid == main_pid) continue;
        if (names.len > 0 and !command_named(pid, names)) continue;
        pids[others] = pid;
        others += 1;
    }
    if (others == 0) return;
    const pid = pids[applied.process_index % others];
    var named = applied.*;
    var command: [16]u8 = undefined;
    named.process = command_of(pid, &command);
    _ = linux.kill(pid, .KILL);
    sdk.event("fault", named);
}

/// Whether the process's command name (/proc/<pid>/comm) is one of `names`.
fn command_named(pid: linux.pid_t, names: []const []const u8) bool {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/comm", .{pid}, 0) catch return false;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return false;
    defer _ = linux.close(@intCast(fd));
    var buffer: [64]u8 = undefined;
    const read = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(read) != .SUCCESS) return false;
    const command = std.mem.trimEnd(u8, buffer[0..read], "\n");
    for (names) |name| if (std.mem.eql(u8, command, name)) return true;
    return false;
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
    if (a == b or !faultable(system, a, b)) return false;
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
    if (changed) {
        doing_set("refresh network", null, "");
        defer doing_set("wait", null, "");
        network_refresh(system);
    }
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
        const to = endpoint_name(system, b);
        // A failure leaves the link as it was, and the next refresh tries again: said, since a
        // link left down after faults stop was all run 100 (timeline 360) could tell. Bringing
        // up a link whose interface or namespace is gone is done, though: a node restarting
        // makes its links anew, up (run 123: hundreds of such failures, 7 timelines ending
        // their faults with a link marked down that no longer existed).
        nodes.link_set(system, from, to, state) catch |err| {
            const gone = err == error.NoSuchInterface or err == error.NoSuchNamespace;
            if (!(gone and state == .up)) {
                sdk.event("link_set_failed", .{ .from = from, .to = to, .state = @tagName(state), .err = @errorName(err) });
                continue;
            }
        };
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
        if (wanted == null and faultable(system, a, b) and degradable(system, from) and
            degradable(system, to))
        {
            wanted = baseline;
        }
        if (std.meta.eql(wanted, network.netem[a][b])) continue;
        nodes.link_degrade(from, to, wanted) catch continue;
        network.netem[a][b] = wanted;
    };
}

/// Whether link faults may reach the link between endpoints a and b: not the runner's with a
/// node that keeps it (Faults.runner_links).
fn faultable(system: *const schema.System, a: usize, b: usize) bool {
    if (a != 0 and b != 0) return true;
    if (a == b) return false;
    return system.nodes[@max(a, b) - 1].faults.runner_links;
}

/// Whether a fault takes the link between endpoints a and b down (isolate, partition).
fn cuts_link(system: *const schema.System, applied: *const Applied, a: usize, b: usize) bool {
    if (!faultable(system, a, b)) return false;
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
        busy_begin(); // Until it waits: what follows, and the caller's work after it returns.
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
        busy_end();
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
/// with its top bit set, the length (low 32 bits) of the JSON fault that follows (`inject`),
/// or, with `branch_flag`, the length (low 8 bits) of the node name that follows, "" for none
/// (`branch`), or with `aim_flag` the same for the node the scenario aims faults at (sdk's
/// `fault_aim`). Each fits in one write of at most PIPE_BUF: atomic.
const inject_flag: u64 = 1 << 63;
pub const branch_flag: u64 = 1 << 62;
pub const aim_flag: u64 = 1 << 61;
/// The quiet period under way is the pacing's own (no node or command asked for it): a branch
/// point ends it.
var quiet_pacing = false;
const request_size_max = 4096;

/// Takes the pending requests: injected faults are applied; the quiet period ends at the latest
/// one asks for; a branch point ends the pacing's. Returns how many requests end a sleep (quiet
/// periods and branch points).
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
        if (header & aim_flag != 0) {
            const length: usize = @intCast(header & 0xff);
            if (at + length > size) break;
            aim_set(buffer[at..][0..length]);
            at += length;
            continue;
        }
        quiet += 1;
        if (header & branch_flag != 0) {
            const length: usize = @intCast(header & 0xff);
            if (at + length > size) break;
            branch_point(buffer[at..][0..length]);
            at += length;
            continue;
        }
        quiet_pacing = false; // A node or command asked: it stays, branch points or not.
        quiet_request(header);
    }
    return quiet;
}

/// A timeline begins here, at a moment of another: the pacing's quiet stretch ends, the sleep
/// under way returns, and the main loop draws a fault at once, aimed at `node` when one of the
/// faults involves it.
fn branch_point(node: []const u8) void {
    const quiet = quiet_pacing and quiet_until_ns > monotonic_ns();
    if (quiet) {
        quiet_until_ns = 0;
        quiet_pacing = false;
    }
    // The FIFO's header allows 255 bytes; det-agent sends at most branch_node_max.
    branch_node_size = @min(node.len, branch_node_max);
    @memcpy(branch_node[0..branch_node_size], node[0..branch_node_size]);
    sdk.event("faults_branch", .{ .quiet_ended = quiet, .node = node });
}

/// The next fault's index: after a branch point, one of those involving its node (a named
/// decision: strategies see it, tapes replay it), when any does; else, while the scenario aims
/// at a node, one involving it half the time (named decisions too); else any (`fault`).
fn fault_choose(faults: []const Fault, names: []const []const u8) usize {
    defer branch_node_size = 0;
    var aimed: [faults_max]usize = undefined;
    const branched = involving(faults, branch_node[0..branch_node_size], &aimed);
    if (branched > 0) return aimed[sdk.random_below_named("fault.branch_aim", branched)];
    if (aim_node_size > 0 and sdk.random_below_named("fault.aim", 2) == 0) {
        const count = involving(faults, aim_node[0..aim_node_size], &aimed);
        if (count > 0) return aimed[sdk.random_below_named("fault.aimed", count)];
    }
    return sdk.decide("fault", names);
}

/// The indices of the faults that involve `node` (theirs, or the other end of a link), into
/// `aimed`; how many. None for "".
fn involving(faults: []const Fault, node: []const u8, aimed: *[faults_max]usize) usize {
    if (node.len == 0) return 0;
    var count: usize = 0;
    for (faults, 0..) |fault, index| {
        if (std.mem.eql(u8, fault.node, node) or std.mem.eql(u8, fault.peer, node)) {
            aimed[count] = index;
            count += 1;
        }
    }
    return count;
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
    /// clock_skip (permanent: later skips stack on it), clock_skew (the node's; with
    /// strobe_ms, coming and going that often).
    skip_ms: u64 = 0,
    strobe_ms: u64 = 0,
    forward: bool = true,
    program: []const u8 = "",
    /// disk.
    failure: nodes.DiskFailure = .errors,
    delay_ms: u32 = 50,
    /// outage: the nodes that lose power (none named: every node that allows crashes), or with
    /// `power` false are killed (none named: every node that allows restarts).
    nodes: []const []const u8 = &.{},
    power: bool = true,
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
        .process_pause, .process_kill, .pod_pause, .pod_kill, .pod_isolate => {
            applied.process_index = @intCast(sdk.random_below(processes_max));
        },
        .pod_partition => {
            applied.process_index = @intCast(sdk.random_below(processes_max));
            applied.thread_index = @intCast(sdk.random_below(processes_max));
        },
        .pod_degrade => {
            applied.process_index = @intCast(sdk.random_below(processes_max));
            const flavor = sdk.random_choice(Degradation, std.enums.values(Degradation));
            applied.flavor = flavor;
            applied.netem = degradation(flavor);
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
        .clock_skew => {
            applied.skip_ns = request.skip_ms * std.time.ns_per_ms;
            applied.forward = request.forward;
            applied.strobe_ns = request.strobe_ms * std.time.ns_per_ms;
        },
        .custom => applied.program = request.program,
        .outage => {
            applied.power = request.power;
            for (system.nodes, 1..) |node, index| applied.outage[index] = request.nodes.len == 0 and
                if (request.power) node.faults.crash else node.faults.restart;
            for (request.nodes) |name| {
                const index = endpoint_index(system, name) orelse return error.UnknownNode;
                if (index == 0) return error.UnknownNode; // The runner has no power to lose.
                applied.outage[index] = true;
            }
            if (std.mem.count(bool, &applied.outage, &.{true}) < 2) return error.FewerThanTwoNodes;
        },
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
/// Tells the running injector a timeline begins here (det-agent, on the platform's `det:branch`),
/// and at which node (the newest behavior's, "" for none) its first fault aims. Without an
/// injector (no driver phase under way), nothing to do.
pub fn branch_request(node: []const u8) void {
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true };
    const fd = linux.open(control_path, flags, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    var message: [8 + branch_node_max]u8 = undefined;
    const size = @min(node.len, branch_node_max);
    std.mem.writeInt(u64, message[0..8], branch_flag | size, .little);
    @memcpy(message[8..][0..size], node[0..size]);
    _ = linux.write(@intCast(fd), &message, 8 + size);
}

const branch_node_max = 32;
/// The node a branch point aims the next fault at (cleared once drawn).
var branch_node: [branch_node_max]u8 = undefined;
var branch_node_size: usize = 0;
/// The node the scenario aims faults at (sdk's `fault_aim`: a primary, a leader it found), until
/// it names another or none.
var aim_node: [branch_node_max]u8 = undefined;
var aim_node_size: usize = 0;

fn aim_set(node: []const u8) void {
    var previous_buffer: [branch_node_max]u8 = undefined;
    const previous_size = aim_node_size;
    @memcpy(previous_buffer[0..previous_size], aim_node[0..previous_size]);
    const previous = previous_buffer[0..previous_size];
    aim_node_size = @min(node.len, branch_node_max);
    @memcpy(aim_node[0..aim_node_size], node[0..aim_node_size]);
    sdk.event("faults_aim", .{ .node = aim_node[0..aim_node_size] });
    // The scenario aims at the node that matters (a leader, a primary, a coordinator): another
    // one now means it moved, a rare state the tree returns to first (what follows a failover is
    // where systems break). Computed: a system that never moves it is not failed for it.
    const current = aim_node[0..aim_node_size];
    if (previous.len > 0 and current.len > 0 and !std.mem.eql(u8, previous, current)) {
        // `node`: a branch from just after it aims its first fault at the new one.
        sdk.assert_computed(.sometimes, true, "the aimed node moved (a leader or primary changed)", .{
            .from = previous,
            .node = current,
        });
    }
}

fn inject_request(json: []const u8) !void {
    return control_request(inject_flag, json);
}

/// One request on the control FIFO: `flag` with the length of `body`, then `body`.
fn control_request(flag: u64, body: []const u8) !void {
    if (body.len + 8 > request_size_max) return error.RequestTooLarge;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true };
    const fd = linux.open(control_path, flags, 0);
    if (linux.errno(fd) != .SUCCESS) {
        std.debug.print("det-faults: no fault injector is running (faults happen while " ++
            "drivers run)\n", .{});
        return error.NoInjector;
    }
    defer _ = linux.close(@intCast(fd));
    var message: [request_size_max]u8 = undefined;
    std.mem.writeInt(u64, message[0..8], flag | body.len, .little);
    @memcpy(message[8..][0..body.len], body);
    const written = linux.write(@intCast(fd), &message, body.len + 8);
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
    resolved[1].faults = .{ .clock_skew = true };
    const scenario = schema.Scenario{ .name = "s", .commands = &.{}, .clock_skip = true };
    const system = schema.System{ .profile = "p", .nodes = &resolved, .scenarios = &.{scenario} };
    var faults: [faults_max]Fault = undefined;
    // a: pause, restart, throttle, process pause; with the runner and with b: partition and
    // degrade both ways (6). b: pause, isolate, throttle, clock skew, process pause; with the
    // runner: partition and degrade both ways (3). Thread pauses where process pauses are (2).
    // Sync stalls (on by default) on both (2). A clog of b (it allows isolation), groups across
    // the runner, a and b. Clock skip. A restore.
    try std.testing.expectEqual(@as(u32, 26), faults_collect(&system, &scenario, &faults));
    const groups = faults[0..26];
    const has_groups = for (groups) |fault| {
        if (fault.kind == .partition_groups) break true;
    } else false;
    try std.testing.expect(has_groups);
    // b's clock skews reach its largest, ten seconds by default (10^10 ns: past u32).
    const skew = for (groups) |fault| {
        if (fault.kind == .clock_skew) break fault;
    } else unreachable;
    try std.testing.expectEqualStrings("b", skew.node);
    try std.testing.expectEqual(10 * std.time.ns_per_s, skew.skew_ns_max);
    try std.testing.expectEqual(Kind.restore, faults[25].kind); // The last one.
}

test fault_choose {
    const faults = [_]Fault{
        .{ .kind = .pause, .node = "a" },
        .{ .kind = .pause, .node = "b" },
        .{ .kind = .partition, .node = "a", .peer = "b" },
        .{ .kind = .pause, .node = "c" },
    };
    const names = [_][]const u8{ "pause a", "pause b", "partition a b", "pause c" };
    // Aimed at b: half the draws among its two faults, the other half any (two of four its):
    // three in four involve it. Not aimed: two in four.
    for ([_]struct { []const u8, u32, u32 }{ .{ "b", 240, 360 }, .{ "", 140, 260 } }) |case| {
        // As aim_set sets it (without its event).
        @memcpy(aim_node[0..case[0].len], case[0]);
        aim_node_size = case[0].len;
        defer aim_node_size = 0;
        var involving_b: u32 = 0;
        for (0..400) |_| {
            const fault = faults[fault_choose(&faults, &names)];
            if (std.mem.eql(u8, fault.node, "b") or std.mem.eql(u8, fault.peer, "b")) involving_b += 1;
        }
        try std.testing.expect(involving_b >= case[1] and involving_b <= case[2]);
    }
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

test "runner_links: a client node's link with the runner is never faulted" {
    const base = schema.Resolved{
        .name = "server",
        .address = "10.0.0.2",
        .disk = "vdb",
        .digest = "",
        .command = &.{"x"},
        .env = &.{},
    };
    var resolved = [2]schema.Resolved{ base, base };
    resolved[1].name = "client";
    resolved[1].faults.runner_links = false;
    const scenario = schema.Scenario{ .name = "s", .commands = &.{} };
    const system = schema.System{ .profile = "p", .nodes = &resolved, .scenarios = &.{scenario} };
    var faults: [faults_max]Fault = undefined;
    const count = faults_collect(&system, &scenario, &faults);
    var client_server: u32 = 0;
    for (faults[0..count]) |fault| {
        if (fault.kind != .partition and fault.kind != .degrade) continue;
        const node_client = std.mem.eql(u8, fault.node, "client");
        const peer_client = std.mem.eql(u8, fault.peer, "client");
        const node_runner = std.mem.eql(u8, fault.node, schema.runner_name);
        const peer_runner = std.mem.eql(u8, fault.peer, schema.runner_name);
        try std.testing.expect(!(node_client and peer_runner) and !(node_runner and peer_client));
        if (std.mem.eql(u8, fault.node, "client") or std.mem.eql(u8, fault.peer, "client")) {
            client_server += 1;
        }
    }
    // Its links with the server are: a partition and a degradation each way.
    try std.testing.expectEqual(@as(u32, 3), client_server);
    var groups: [endpoints_max]u16 = @splat(group_none);
    groups[0] = 0; // runner
    groups[1] = 0; // server
    groups[2] = 1; // client
    const partition = Applied{
        .kind = .partition_groups,
        .duration_ns = 1,
        .disruption = .stopped,
        .groups = groups,
    };
    var links: [directed_max]Directed = undefined;
    // The client is cut from the server only, both ways.
    try std.testing.expectEqual(@as(u32, 2), disrupted_links(&system, &partition, &links));
    const clog = Applied{
        .kind = .clog,
        .node = "client",
        .duration_ns = 1,
        .disruption = .stopped,
        .direction = .both,
    };
    try std.testing.expectEqual(@as(u32, 2), disrupted_links(&system, &clog, &links));
    const isolate = Applied{ .kind = .isolate, .node = "client", .duration_ns = 1 };
    try std.testing.expect(!cuts_link(&system, &isolate, 0, 2));
    try std.testing.expect(cuts_link(&system, &isolate, 1, 2));
}
