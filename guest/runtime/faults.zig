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
    sdk.event("faults_start", .{ .faults = count });
    if (script_faults(arena)) |scripted| return run_script(arena, &system, scripted);
    var injections: u32 = 0;
    while (injections < injections_max) : (injections += 1) {
        sleep_ns(delay_ns_min + sdk.random_below(delay_ns_max - delay_ns_min));
        if (stopping.load(.acquire)) break;
        const applied = draw(&sdk.random_choice(Fault, faults[0..count]));
        if (monotonic_ns() < quiet_until_ns and applied.kind != .clock_skip) continue;
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
        .thread_pause => apply_thread_pause(applied),
        .process_kill => apply_process_kill(applied),
        .isolate, .partition, .degrade => apply_link(system, applied),
        .clock_skip => {
            sdk.event("fault", applied.*);
            clock_shift(applied.skip_ns, .{ .forward = applied.forward });
            sleep_through_ns(applied.duration_ns); // Quiet periods leave clock skips alone.
            if (applied.permanent) return; // It stays, and later skips stack on it.
            clock_shift(applied.skip_ns, .{ .forward = !applied.forward });
        },
        .partition_groups, .clog => apply_disruption(system, applied),
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
    const threads = threads_list(pid, &tids);
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

/// The threads of a process, in /proc's order (by id).
fn threads_list(pid: linux.pid_t, tids: *[threads_max]linux.pid_t) u32 {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/task", .{pid}, 0) catch return 0;
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const fd = linux.open(path, flags, 0);
    if (linux.errno(fd) != .SUCCESS) return 0;
    defer _ = linux.close(@intCast(fd));
    var count: u32 = 0;
    var entries: [4096]u8 align(8) = undefined;
    while (true) {
        const size = linux.getdents64(@intCast(fd), &entries, entries.len);
        if (linux.errno(size) != .SUCCESS or size == 0) return count;
        var offset: usize = 0;
        while (offset < size) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[offset]);
            const name_offset = offset + @offsetOf(linux.dirent64, "name");
            offset += entry.reclen;
            const name: [*:0]const u8 = @ptrCast(&entries[name_offset]);
            const tid = std.fmt.parseInt(linux.pid_t, std.mem.span(name), 10) catch continue;
            if (count == threads_max) return count;
            tids[count] = tid;
            count += 1;
        }
    }
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
    const name = struct {
        fn of(the_system: *const schema.System, index: usize) []const u8 {
            return if (index == 0) schema.runner_name else the_system.nodes[index - 1].name;
        }
    }.of;
    const endpoints = system.nodes.len + 1;
    for (0..endpoints) |a| for (0..endpoints) |b| {
        if (a == b) continue;
        const from = name(system, a);
        const to = name(system, b);
        const cut = switch (applied.kind) {
            .partition_groups => applied.groups[a] != group_none and
                applied.groups[b] != group_none and applied.groups[a] != applied.groups[b],
            .clog => switch (applied.direction.?) {
                .outbound => std.mem.eql(u8, from, applied.node),
                .inbound => std.mem.eql(u8, to, applied.node),
                .both => std.mem.eql(u8, from, applied.node) or std.mem.eql(u8, to, applied.node),
            },
            else => unreachable,
        };
        if (!cut) continue;
        links[count] = .{ .from = from, .to = to };
        count += 1;
    };
    return count;
}

/// Disrupts each direction of the chosen links for the fault's duration: dropped (stopped),
/// delayed (slowed), or held until the fault ends and then delivered (jammed).
fn apply_disruption(system: *const schema.System, applied: *const Applied) void {
    var links: [directed_max]Directed = undefined;
    const count = disrupted_links(system, applied, &links);
    if (count == 0) return;
    const delay_ns = switch (applied.disruption.?) {
        .stopped => 0,
        .slowed => slowed_delay_ns_min +
            applied.duration_ns % (slowed_delay_ns_max - slowed_delay_ns_min),
        .jammed => applied.duration_ns,
    };
    const netem = nodes.Netem{
        .delay_ns = delay_ns,
        .loss_percent = if (applied.disruption.? == .stopped) 100 else 0,
        .seed = applied.duration_ns,
    };
    for (links[0..count]) |link| nodes.link_degrade(link.from, link.to, netem) catch {};
    sdk.event("fault", applied.*);
    sleep_ns(applied.duration_ns);
    if (applied.disruption.? == .jammed) {
        // Release what is held (delay 0 keeps the queue), then remove the qdisc.
        var release = netem;
        release.delay_ns = 0;
        for (links[0..count]) |link| nodes.link_degrade(link.from, link.to, release) catch {};
        sleep_through_ns(10 * std.time.ns_per_ms);
    }
    for (links[0..count]) |link| nodes.link_degrade(link.from, link.to, null) catch {};
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
/// then undoes its fault).
fn sleep_ns(duration_ns: u64) void {
    if (control < 0) return nodes.sleep_ns(duration_ns);
    const deadline_ns = monotonic_ns() + duration_ns;
    for (0..injections_max) |_| {
        const now_ns = monotonic_ns();
        if (now_ns >= deadline_ns or stopping.load(.acquire)) return;
        const left_ns = deadline_ns - now_ns;
        var timeout = linux.timespec{
            .sec = @intCast(left_ns / std.time.ns_per_s),
            .nsec = @intCast(left_ns % std.time.ns_per_s),
        };
        var poll = [1]linux.pollfd{.{ .fd = control, .events = linux.POLL.IN, .revents = 0 }};
        const result = linux.ppoll(&poll, 1, &timeout, null);
        if (linux.errno(result) == .INTR) return; // A stop.
        if (linux.errno(result) != .SUCCESS or result == 0) continue;
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

/// Takes the pending requests: the quiet period ends at the latest one asks for. Returns
/// how many there were.
fn requests_read() u32 {
    var requests: [64]u64 = undefined;
    const bytes: [*]u8 = @ptrCast(&requests);
    const size = linux.read(control, bytes, @sizeOf(@TypeOf(requests)));
    if (linux.errno(size) != .SUCCESS) return 0;
    const count: u32 = @intCast(size / @sizeOf(u64));
    const now_ns = monotonic_ns();
    var longest_ns: u64 = 0;
    for (requests[0..count]) |request| {
        longest_ns = @max(longest_ns, std.mem.littleToNative(u64, request));
    }
    if (count > 0) {
        quiet_until_ns = @max(quiet_until_ns, now_ns + longest_ns);
        sdk.event("faults_quiet", .{ .duration_ns = longest_ns, .until_ns = quiet_until_ns });
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
    // of b (it allows isolation), groups across the runner, a and b. Clock skip.
    try std.testing.expectEqual(@as(u32, 22), faults_collect(&system, &scenario, &faults));
    const groups = faults[0..22];
    const has_groups = for (groups) |fault| {
        if (fault.kind == .partition_groups) break true;
    } else false;
    try std.testing.expect(has_groups);
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
