// SPDX-License-Identifier: MIT
//! What determinismo prints: one run's report, and the multiverse summary of an exploration.
const std = @import("std");
const assert = std.debug.assert;
const VM = @import("vm.zig");
const Snapshot = @import("snapshot.zig");
const Events = @import("events.zig");
const cpuid = @import("cpuid.zig");

const print = std.debug.print;
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
            "idle_skips={d} idle_vtime={d:.3}s mtf_steps={d} overflows={d} overshoots={d}\n", .{
            seconds(state.tsc / tsc_per_ns), state.branches,
            state.rdtsc_exits,               vm.stats.timer_fires,
            vm.stats.idle_skips,             seconds(vm.stats.idle_tsc / tsc_per_ns),
            state.mtf_steps,                 state.overflows,
            state.overshoots,
        });
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
        print("[branch {d:>4}] seed={x:0>16} {s:<8} vtime={d:.3}s wall={d:.3}s events={d} " ++
            "events_hash={x:0>16} failing={d}", .{
            branch.index,                    branch.seed,             @tagName(branch.outcome),
            seconds(state.tsc / tsc_per_ns), seconds(branch.wall_ns), vm.events.count,
            vm.events.hash.final(),          failing,
        });
        for (vm.events.properties[0..vm.events.property_count]) |*property| {
            try multiverse.merge(property, branch.index);
            if (!property.passing()) print("  FAIL \"{s}\"", .{property.name()});
        }
        print("\n", .{});
        assert(multiverse.failing_branches <= multiverse.branches);
    }

    fn merge(multiverse: *Multiverse, property: *const Events.Property, branch: u32) !void {
        assert(property.trues <= property.hits);
        const aggregate = for (multiverse.aggregates[0..multiverse.aggregate_count]) |*aggregate| {
            if (std.mem.eql(u8, aggregate.property.name(), property.name())) break aggregate;
        } else blk: {
            const full = multiverse.aggregate_count == Events.property_count_max;
            if (full) return error.TooManyProperties;
            multiverse.aggregates[multiverse.aggregate_count] = .{ .property = property.* };
            multiverse.aggregate_count += 1;
            break :blk &multiverse.aggregates[multiverse.aggregate_count - 1];
        };
        if (property.hits > 0) aggregate.branches_hit += 1;
        if (!property.passing()) {
            aggregate.branches_failing += 1;
            if (aggregate.first_failing_branch == null) {
                aggregate.first_failing_branch = branch;
                aggregate.first_failure = property.first_failure;
            }
        }
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
    }
};

fn seconds(ns: u64) f64 {
    assert(ns < 1 << 53); // Exact in an f64.
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}
