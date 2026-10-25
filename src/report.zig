// SPDX-License-Identifier: MIT
//! What determinismo prints: one run's report, and the multiverse summary of an exploration.
const std = @import("std");
const assert = std.debug.assert;
const VM = @import("vm.zig");
const Snapshot = @import("snapshot.zig");
const Events = @import("events.zig");
const cpuid = @import("cpuid.zig");

const print = std.debug.print;

/// Where `explore --record` writes results as JSON lines: a `run` line, one `branch` line per
/// branch as it ends, and a `summary` line. Opened with O_APPEND before workers fork, so each
/// line (one write) stays whole.
pub var record_fd: ?std.os.linux.fd_t = null;
const record_line_size_max = 64 * 1024;

pub fn record(value: anytype) void {
    const fd = record_fd orelse return;
    var buffer: [record_line_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    std.json.Stringify.value(value, .{}, &writer) catch return; // Too large: dropped.
    writer.writeAll("\n") catch return;
    _ = std.os.linux.write(fd, writer.buffered().ptr, writer.buffered().len);
}

fn hex(value: u64) [16]u8 {
    var text: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&text, "{x:0>16}", .{value}) catch unreachable;
    return text;
}
const tsc_per_ns = cpuid.tsc_hz / std.time.ns_per_s;

pub fn run(vm: *VM, result: struct { outcome: VM.Outcome, wall_ns: u64 }) !void {
    assert(vm.events.property_count <= vm.events.properties.len);
    assert(result.wall_ns > 0);
    print("\n[determinismo] outcome={s} wall={d:.3}s serial_bytes={d} serial_hash={x:0>16}\n", .{
        @tagName(result.outcome),      seconds(result.wall_ns), vm.serial.output_bytes,
        vm.serial.output_hash.final(),
    });
    if (result.outcome == .failed) print("[determinismo] failed: {s}\n", .{result.outcome.failed});
    if (vm.deterministic) {
        const state = try vm.det_state();
        print("[determinismo] vtime={d:.3}s branches={d} rdtsc_exits={d} timer_fires={d} " ++
            "idle_skips={d} idle_vtime={d:.3}s mtf_steps={d} overflows={d} overshoots={d} " ++
            "skid_max={d} soft_exits={d} exit_timer_fires={d} fast_steps={d}\n", .{
            seconds(state.tsc / tsc_per_ns), state.branches,
            state.rdtsc_exits,               vm.stats.timer_fires,
            vm.stats.idle_skips,             seconds(vm.stats.idle_tsc / tsc_per_ns),
            state.mtf_steps,                 state.overflows,
            state.overshoots,                state.skid_max,
            state.soft_exits,                vm.stats.exit_timer_fires,
            state.fast_steps,
        });
        overshoot_warn(state.overshoots);
    }
    print("[determinismo] events={d} events_hash={x:0>16} random_pulls={d}\n", .{
        vm.events.count, vm.events.hash.final(), vm.decisions.pulls,
    });
    if (vm.events.setup_complete) |moment| {
        print("[determinismo] setup_complete at vtime={d}ns branches={d}\n", .{
            moment.vtime_ns, moment.branches,
        });
    }
    if (vm.events.property_count > 0) properties(&vm.events);
    var iterator = vm.stats.exits.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.* > 0) {
            print("[determinismo] exits.{s}={d}\n", .{ @tagName(entry.key), entry.value.* });
        }
    }
}

fn properties(events: *const Events) void {
    assert(events.property_count > 0);
    print("[determinismo] properties ({d} failing):\n", .{events.failing_count()});
    for (events.properties[0..events.property_count]) |*property| {
        print("  {s:<4} {s:<21} hits={d:<6} true={d:<6} {s}", .{
            if (property.passing()) "PASS" else "FAIL", @tagName(property.kind),
            property.hits,                              property.trues,
            property.name(),
        });
        if (property.first_failure) |moment| {
            print("  (first failure: vtime={d}ns branches={d})", .{
                moment.vtime_ns, moment.branches,
            });
        }
        print("\n", .{});
    }
}

pub fn snapshot_taken(snapshot: *const Snapshot, wall_ns: u64) void {
    assert(snapshot.branches > 0);
    print("[determinismo] snapshot at setup_complete: vtime={d:.3}s branches={d} msrs={d} " ++
        "(boot + setup took {d:.3}s wall)\n", .{
        seconds(snapshot.tsc / tsc_per_ns), snapshot.branches,
        snapshot.msrs.count,                seconds(wall_ns),
    });
}

/// Properties across all branches of an exploration.
pub const Multiverse = struct {
    branches: u32 = 0,
    failing_branches: u32 = 0,
    aggregates: [Events.property_count_max]Aggregate = undefined,
    aggregate_count: u32 = 0,
    /// Exactness of the stops at branch-count targets, over all branches.
    skid_max: u64 = 0,
    overshoots: u64 = 0,

    pub const Branch = struct { index: u32, seed: u64, outcome: VM.Outcome, wall_ns: u64 };

    const Aggregate = struct {
        property: Events.Property, // Identity (kind, message) of the first branch that hit it.
        branches_hit: u32 = 0,
        branches_failing: u32 = 0,
        first_failing_branch: ?u32 = null,
        first_failure: ?Events.Moment = null,
    };

    pub fn add(multiverse: *Multiverse, vm: *VM, branch: Branch) !void {
        assert(vm.deterministic);
        const failing = vm.events.failing_count();
        multiverse.branches += 1;
        if (failing > 0) multiverse.failing_branches += 1;
        const state = try vm.det_state();
        multiverse.skid_max = @max(multiverse.skid_max, state.skid_max);
        multiverse.overshoots += state.overshoots;
        // One write per line: parallel workers share the terminal.
        var line_buffer: [4096]u8 = undefined;
        var line: std.Io.Writer = .fixed(&line_buffer);
        line.print("[branch {d:>4}] seed={x:0>16} {s:<8} vtime={d:.3}s wall={d:.3}s events={d} " ++
            "events_hash={x:0>16} failing={d}", .{
            branch.index,                    branch.seed,             @tagName(branch.outcome),
            seconds(state.tsc / tsc_per_ns), seconds(branch.wall_ns), vm.events.count,
            vm.events.hash.final(),          failing,
        }) catch {};
        var failing_names: [64][]const u8 = undefined;
        var failing_count: u32 = 0;
        for (vm.events.properties[0..vm.events.property_count]) |*property| {
            try multiverse.merge(property, branch.index);
            if (property.passing()) continue;
            line.print("  FAIL \"{s}\"", .{property.name()}) catch {};
            if (failing_count < failing_names.len) {
                failing_names[failing_count] = property.name();
                failing_count += 1;
            }
        }
        record(.{ .branch = .{
            .index = branch.index,
            .seed = &hex(branch.seed),
            .outcome = @tagName(branch.outcome),
            .vtime_ns = state.tsc / tsc_per_ns,
            .wall_ns = branch.wall_ns,
            .events = vm.events.count,
            .events_hash = &hex(vm.events.hash.final()),
            .failing = failing_names[0..failing_count],
        } });
        line.writeAll("\n") catch {
            line.end = line_buffer.len - 1;
            line_buffer[line.end] = '\n';
            line.end += 1;
        };
        _ = std.os.linux.write(2, line.buffered().ptr, line.buffered().len);
        assert(multiverse.failing_branches <= multiverse.branches);
    }

    fn aggregate_find(multiverse: *Multiverse, property: *const Events.Property) !*Aggregate {
        for (multiverse.aggregates[0..multiverse.aggregate_count]) |*aggregate| {
            if (std.mem.eql(u8, aggregate.property.name(), property.name())) return aggregate;
        }
        if (multiverse.aggregate_count == Events.property_count_max) return error.TooManyProperties;
        multiverse.aggregates[multiverse.aggregate_count] = .{ .property = property.* };
        multiverse.aggregate_count += 1;
        return &multiverse.aggregates[multiverse.aggregate_count - 1];
    }

    fn merge(multiverse: *Multiverse, property: *const Events.Property, branch: u32) !void {
        assert(property.trues <= property.hits);
        const aggregate = try multiverse.aggregate_find(property);
        if (property.hits > 0) aggregate.branches_hit += 1;
        if (!property.passing()) {
            aggregate.branches_failing += 1;
            if (aggregate.first_failing_branch == null) {
                aggregate.first_failing_branch = branch;
                aggregate.first_failure = property.first_failure;
            }
        }
    }

    /// Adds another worker's results. The example branch of a failing property is the lowest
    /// failing index, so the summary does not depend on which worker finished first.
    pub fn absorb(multiverse: *Multiverse, other: *const Multiverse) !void {
        multiverse.branches += other.branches;
        multiverse.failing_branches += other.failing_branches;
        multiverse.skid_max = @max(multiverse.skid_max, other.skid_max);
        multiverse.overshoots += other.overshoots;
        for (other.aggregates[0..other.aggregate_count]) |*incoming| {
            const aggregate = try multiverse.aggregate_find(&incoming.property);
            aggregate.branches_hit += incoming.branches_hit;
            aggregate.branches_failing += incoming.branches_failing;
            const branch = incoming.first_failing_branch orelse continue;
            const earlier = if (aggregate.first_failing_branch) |known| branch < known else true;
            if (earlier) {
                aggregate.first_failing_branch = branch;
                aggregate.first_failure = incoming.first_failure;
            }
        }
        assert(multiverse.failing_branches <= multiverse.branches);
    }

    pub fn summarize(multiverse: *const Multiverse, wall_ns: u64) void {
        assert(multiverse.branches > 0);
        const header = "[determinismo] multiverse: {d} branches, {d} with failing properties, " ++
            "{d:.3}s wall\n";
        print(header, .{
            multiverse.branches, multiverse.failing_branches, seconds(wall_ns),
        });
        for (multiverse.aggregates[0..multiverse.aggregate_count]) |*aggregate| {
            const status = if (aggregate.branches_failing > 0) "FAIL" else "PASS";
            print("  {s} {s:<21} hit in {d:>4}/{d} branches, failing in {d:>4}  {s}", .{
                status,              @tagName(aggregate.property.kind), aggregate.branches_hit,
                multiverse.branches, aggregate.branches_failing,        aggregate.property.name(),
            });
            if (aggregate.first_failing_branch) |branch| {
                print("  (e.g. --branch {d})", .{branch});
            }
            print("\n", .{});
        }
        print("[determinismo] exact stops: largest skid {d} branches, {d} overshoots\n", .{
            multiverse.skid_max, multiverse.overshoots,
        });
        overshoot_warn(multiverse.overshoots);
        multiverse.record_summary(wall_ns);
    }

    fn record_summary(multiverse: *const Multiverse, wall_ns: u64) void {
        if (record_fd == null) return;
        const Line = struct {
            kind: []const u8,
            message: []const u8,
            branches_hit: u32,
            branches_failing: u32,
            example_branch: ?u32,
        };
        var lines: [Events.property_count_max]Line = undefined;
        for (multiverse.aggregates[0..multiverse.aggregate_count], 0..) |*aggregate, index| {
            lines[index] = .{
                .kind = @tagName(aggregate.property.kind),
                .message = aggregate.property.name(),
                .branches_hit = aggregate.branches_hit,
                .branches_failing = aggregate.branches_failing,
                .example_branch = aggregate.first_failing_branch,
            };
        }
        record(.{ .summary = .{
            .branches = multiverse.branches,
            .failing_branches = multiverse.failing_branches,
            .wall_ns = wall_ns,
            .skid_max = multiverse.skid_max,
            .overshoots = multiverse.overshoots,
            .properties = lines[0..multiverse.aggregate_count],
        } });
    }
};

/// An overshoot means a timer or moment landed later than its branch count: such a timeline
/// may not replay. It only happens if the margin is below the PMU's interrupt skid.
fn overshoot_warn(overshoots: u64) void {
    if (overshoots == 0) return;
    print("[determinismo] WARNING: {d} overshoots: these timelines may not replay exactly; " ++
        "raise --margin-branches above the largest skid\n", .{overshoots});
}

fn seconds(ns: u64) f64 {
    assert(ns < 1 << 53); // Exact in an f64.
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}
