// SPDX-License-Identifier: MIT
//! What determinismo prints: one run's report, and the multiverse summary of an exploration.
const std = @import("std");
const assert = std.debug.assert;
const VM = @import("vm.zig");
const Snapshot = @import("snapshot.zig");
const Events = @import("events.zig");
const tape = @import("tape.zig");
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
pub const tsc_per_ns = cpuid.tsc_hz / std.time.ns_per_s;

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

/// The catalog across the scenarios explored: an assertion must be reached (made
/// true, for a `sometimes`) in some timeline of some scenario, as in an Antithesis run, which
/// explores every test template together.
pub const Catalog = struct {
    arena: std.mem.Allocator,
    entries: std.StringArrayHashMapUnmanaged(Entry) = .empty,

    const Entry = struct { kind: Events.Kind, reached: bool };

    pub fn note(catalog: *Catalog, kind: Events.Kind, message: []const u8, reached: bool) !void {
        const entry = try catalog.entries.getOrPut(catalog.arena, message);
        if (!entry.found_existing) {
            entry.key_ptr.* = try catalog.arena.dupe(u8, message);
            entry.value_ptr.* = .{ .kind = kind, .reached = false };
        }
        entry.value_ptr.reached = entry.value_ptr.reached or reached;
    }

    /// Prints the assertions no scenario reached; returns how many fail (always, sometimes,
    /// reachable: the kinds that must be reached), when every scenario was explored.
    pub fn judge(catalog: *const Catalog, every_scenario: bool) u32 {
        var failing: u32 = 0;
        var header = false;
        for (catalog.entries.keys(), catalog.entries.values()) |message, entry| {
            if (entry.reached) continue;
            const must = switch (entry.kind) {
                .always, .sometimes, .reachable => true,
                .always_or_unreachable, .@"unreachable" => false,
            };
            if (!must) continue;
            if (!header) {
                const scope = if (every_scenario) "any scenario" else "the scenarios explored";
                print("[determinismo] assertions not reached in {s}:\n", .{scope});
                header = true;
            }
            const status = if (every_scenario) "FAIL" else "----";
            print("  {s} {s:<21} {s}\n", .{ status, @tagName(entry.kind), message });
            failing += @intFromBool(every_scenario);
        }
        return failing;
    }
};

test Catalog {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var catalog = Catalog{ .arena = arena_state.allocator() };
    // Scenario one reaches the first; scenario two reaches the second.
    try catalog.note(.sometimes, "reached in one", true);
    try catalog.note(.sometimes, "reached in two", false);
    try catalog.note(.sometimes, "reached in one", false);
    try catalog.note(.sometimes, "reached in two", true);
    try catalog.note(.reachable, "reached nowhere", false);
    try catalog.note(.@"unreachable", "never reached, rightly", false);
    // Only what no scenario reached, of the kinds that must be reached, and only when every
    // scenario was explored.
    try std.testing.expectEqual(@as(u32, 1), catalog.judge(true));
    try std.testing.expectEqual(@as(u32, 0), catalog.judge(false));
}

/// Whether a property fails across the multiverse (Antithesis's semantics): an `always` fails
/// where a timeline made it false or if no timeline hit it; `always_or_unreachable` and
/// `unreachable` where a timeline violated them; `sometimes` if no timeline made it true;
/// `reachable` if no timeline reached it.
pub fn property_failing(kind: Events.Kind, counts: struct {
    branches_hit: u32,
    branches_true: u32,
    branches_failing: u32,
}) bool {
    return switch (kind) {
        .always => counts.branches_failing > 0 or counts.branches_hit == 0,
        .always_or_unreachable, .@"unreachable" => counts.branches_failing > 0,
        .sometimes => counts.branches_true == 0,
        .reachable => counts.branches_hit == 0,
    };
}

test property_failing {
    const counts = .{ .branches_hit = 8, .branches_true = 0, .branches_failing = 0 };
    try std.testing.expect(property_failing(.sometimes, counts)); // Never true anywhere.
    try std.testing.expect(!property_failing(.reachable, counts));
    try std.testing.expect(!property_failing(.always, counts));
    const never = .{ .branches_hit = 0, .branches_true = 0, .branches_failing = 0 };
    try std.testing.expect(property_failing(.reachable, never)); // Declared, never reached.
    try std.testing.expect(property_failing(.always, never));
    try std.testing.expect(!property_failing(.always_or_unreachable, never));
    const one_true = .{ .branches_hit = 8, .branches_true = 1, .branches_failing = 0 };
    try std.testing.expect(!property_failing(.sometimes, one_true));
}

const logging_property = "logging output stays under 200 MB per hour of virtual time";
const logging_bytes_per_hour_max = 200 * 1000 * 1000;

/// Properties across all branches of an exploration.
pub const Multiverse = struct {
    branches: u32 = 0,
    failing_branches: u32 = 0,
    aggregates: [Events.property_count_max]Aggregate = undefined,
    aggregate_count: u32 = 0,
    /// Exactness of the stops at branch-count targets, over all branches.
    skid_max: u64 = 0,
    overshoots: u64 = 0,
    /// Virtual time the branches simulated (from their snapshot on), and the wall time they
    /// took, each on one core: Antithesis's "virtual time per wall time".
    vtime_ns: u64 = 0,
    wall_ns: u64 = 0,
    /// Output the timelines printed, and the virtual time they printed it over: Antithesis's
    /// "Logging output was limited" is a ratio over the whole simulation, not per timeline.
    output_bytes: u64 = 0,
    output_span_ns: u64 = 0,

    pub const Branch = struct {
        index: u32,
        seed: u64,
        outcome: VM.Outcome,
        wall_ns: u64,
        /// Where the branch started: its snapshot's virtual TSC.
        start_tsc: u64,
        /// Its path from the setup snapshot (the tree explorer's; empty: it starts there).
        path: []const tape.Segment = &.{},
        generation: u32 = 0,
        why: []const u8 = "",
    };

    const Aggregate = struct {
        property: Events.Property, // Identity (kind, message) of the first branch that hit it.
        branches_hit: u32 = 0,
        /// Branches where it held at least once (what a `sometimes` asks for).
        branches_true: u32 = 0,
        /// Branches that violate it (an `always` false, an `unreachable` reached).
        branches_failing: u32 = 0,
        first_failing_branch: ?u32 = null,
        first_failure: ?Events.Moment = null,
        /// For a property judged across the whole run (no timeline violates it alone): whether
        /// it fails.
        run_failing: ?bool = null,

        /// An assertion no timeline of this scenario reached (known from a catalog): a test
        /// program or a service may serve several scenarios, so it is judged across the
        /// scenarios explored (main.zig), not here.
        fn unreached_here(aggregate: *const Aggregate) bool {
            const must_hit = switch (aggregate.property.kind) {
                .always, .sometimes, .reachable => true,
                .always_or_unreachable, .@"unreachable" => false,
            };
            return must_hit and aggregate.branches_hit == 0;
        }

        fn failing(aggregate: *const Aggregate) bool {
            if (aggregate.run_failing) |verdict| return verdict;
            if (aggregate.unreached_here()) return false;
            return property_failing(aggregate.property.kind, .{
                .branches_hit = aggregate.branches_hit,
                .branches_true = aggregate.branches_true,
                .branches_failing = aggregate.branches_failing,
            });
        }
    };

    /// Properties that fail across the multiverse: what an exploration's verdict (exit status)
    /// is about.
    pub fn failing_properties(multiverse: *const Multiverse) u32 {
        var count: u32 = 0;
        for (multiverse.aggregates[0..multiverse.aggregate_count]) |*aggregate| {
            count += @intFromBool(aggregate.failing());
        }
        return count;
    }

    pub fn add(multiverse: *Multiverse, vm: *VM, branch: Branch) !void {
        assert(vm.deterministic);
        const failing = vm.events.failing_count();
        multiverse.branches += 1;
        if (failing > 0) multiverse.failing_branches += 1;
        const state = try vm.det_state();
        multiverse.skid_max = @max(multiverse.skid_max, state.skid_max);
        multiverse.overshoots += state.overshoots;
        multiverse.vtime_ns += (state.tsc -| branch.start_tsc) / tsc_per_ns;
        multiverse.wall_ns += branch.wall_ns;
        multiverse.output_bytes += vm.events.output_bytes;
        multiverse.output_span_ns += vm.events.output_span_ns(state.tsc / tsc_per_ns);
        try multiverse.logging_judge();
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
            .path = branch.path,
            .generation = branch.generation,
            .why = branch.why,
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
        location_adopt(&aggregate.property, property);
        if (property.hits > 0) aggregate.branches_hit += 1;
        if (property.trues > 0) aggregate.branches_true += 1;
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
        multiverse.vtime_ns += other.vtime_ns;
        multiverse.wall_ns += other.wall_ns;
        multiverse.output_bytes += other.output_bytes;
        multiverse.output_span_ns += other.output_span_ns;
        for (other.aggregates[0..other.aggregate_count]) |*incoming| {
            const aggregate = try multiverse.aggregate_find(&incoming.property);
            location_adopt(&aggregate.property, &incoming.property);
            aggregate.branches_hit += incoming.branches_hit;
            aggregate.branches_true += incoming.branches_true;
            aggregate.branches_failing += incoming.branches_failing;
            const branch = incoming.first_failing_branch orelse continue;
            const earlier = if (aggregate.first_failing_branch) |known| branch < known else true;
            if (earlier) {
                aggregate.first_failing_branch = branch;
                aggregate.first_failure = incoming.first_failure;
            }
        }
        try multiverse.logging_judge();
        assert(multiverse.failing_branches <= multiverse.branches);
    }

    /// Antithesis's "Logging output was limited": output over the virtual time of all timelines
    /// (one vCPU each: core-hours) stays under 200 MB an hour.
    fn logging_judge(multiverse: *Multiverse) !void {
        var property = Events.Property{
            .kind = .always,
            .message = undefined,
            .message_size = logging_property.len,
        };
        @memcpy(property.message[0..logging_property.len], logging_property);
        const aggregate = try multiverse.aggregate_find(&property);
        const limit: u128 = @as(u128, logging_bytes_per_hour_max) * multiverse.output_span_ns;
        const over = @as(u128, multiverse.output_bytes) * std.time.ns_per_hour >= limit and
            multiverse.output_span_ns >= std.time.ns_per_s; // Too short to judge a rate.
        aggregate.branches_hit = multiverse.branches;
        aggregate.branches_true = if (over) 0 else multiverse.branches;
        aggregate.branches_failing = 0; // No timeline violates it alone.
        aggregate.run_failing = over;
    }

    /// A property's location, from whichever branch or worker reported one.
    fn location_adopt(into: *Events.Property, from: *const Events.Property) void {
        if (into.location_size > 0 or from.location_size == 0) return;
        into.location = from.location;
        into.location_size = from.location_size;
    }

    pub fn summarize(multiverse: *const Multiverse, wall_ns: u64) void {
        assert(multiverse.branches > 0);
        const header = "[determinismo] multiverse: {d} branches, {d} with failing properties, " ++
            "{d:.3}s wall\n";
        print(header, .{
            multiverse.branches, multiverse.failing_branches, seconds(wall_ns),
        });
        for (multiverse.aggregates[0..multiverse.aggregate_count]) |*aggregate| {
            // Listed once, after all scenarios, with the program's catalog (main.zig).
            if (aggregate.unreached_here()) continue;
            const status = if (aggregate.failing()) "FAIL" else "PASS";
            print("  {s} {s:<21} hit in {d:>4}/{d} branches, failing in {d:>4}  {s}", .{
                status,              @tagName(aggregate.property.kind), aggregate.branches_hit,
                multiverse.branches, aggregate.branches_failing,        aggregate.property.name(),
            });
            if (aggregate.first_failing_branch) |branch| {
                print("  (e.g. --branch {d})", .{branch});
            }
            const where = aggregate.property.where();
            if (where.len > 0) print("  at {s}", .{where});
            print("\n", .{});
        }
        print("[determinismo] exact stops: largest skid {d} branches, {d} overshoots\n", .{
            multiverse.skid_max, multiverse.overshoots,
        });
        print("[determinismo] virtual time per wall time: {d:.2} (one core; {d:.3}s virtual " ++
            "in {d:.3}s)\n", .{
            multiverse.vtime_per_wall(), seconds(multiverse.vtime_ns), seconds(multiverse.wall_ns),
        });
        overshoot_warn(multiverse.overshoots);
        multiverse.record_summary(wall_ns);
    }

    /// The catalog as this multiverse saw it: each assertion, and whether a timeline reached it
    /// (made it true, for a `sometimes`).
    pub fn catalog_reached(multiverse: *const Multiverse, catalog: *Catalog) !void {
        for (multiverse.aggregates[0..multiverse.aggregate_count]) |*aggregate| {
            const reached = aggregate.branches_hit > 0 and !property_failing(
                aggregate.property.kind,
                .{
                    .branches_hit = aggregate.branches_hit,
                    .branches_true = aggregate.branches_true,
                    .branches_failing = 0, // Violations are judged in their scenario.
                },
            );
            try catalog.note(aggregate.property.kind, aggregate.property.name(), reached);
        }
    }

    fn vtime_per_wall(multiverse: *const Multiverse) f64 {
        if (multiverse.wall_ns == 0) return 0;
        const vtime: f64 = @floatFromInt(multiverse.vtime_ns);
        return vtime / @as(f64, @floatFromInt(multiverse.wall_ns));
    }

    fn record_summary(multiverse: *const Multiverse, wall_ns: u64) void {
        if (record_fd == null) return;
        const Line = struct {
            kind: []const u8,
            message: []const u8,
            failing: bool,
            branches_hit: u32,
            branches_true: u32,
            branches_failing: u32,
            example_branch: ?u32,
            location: ?[]const u8,
        };
        var lines: [Events.property_count_max]Line = undefined;
        for (multiverse.aggregates[0..multiverse.aggregate_count], 0..) |*aggregate, index| {
            lines[index] = .{
                .kind = @tagName(aggregate.property.kind),
                .message = aggregate.property.name(),
                .failing = aggregate.failing(),
                .branches_hit = aggregate.branches_hit,
                .branches_true = aggregate.branches_true,
                .branches_failing = aggregate.branches_failing,
                .example_branch = aggregate.first_failing_branch,
                .location = if (aggregate.property.location_size > 0)
                    aggregate.property.where()
                else
                    null,
            };
        }
        record(.{ .summary = .{
            .branches = multiverse.branches,
            .failing_branches = multiverse.failing_branches,
            .wall_ns = wall_ns,
            .skid_max = multiverse.skid_max,
            .overshoots = multiverse.overshoots,
            .vtime_ns = multiverse.vtime_ns,
            .vtime_per_wall = multiverse.vtime_per_wall(),
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
