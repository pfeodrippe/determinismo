// SPDX-License-Identifier: MIT
//! `determinismo merge <record>...`: one exploration from the records of its shards (hosts that
//! ran `explore ... --shard k/n --record <file>`).
//!
//! The shards must have explored the same thing (inputs, seed, scenario, fork point); their
//! branches must not overlap. The merged record (run, branches, summary) goes to stdout as JSON
//! lines; the summary is printed as explore prints it. Returns the number of failing properties.
const std = @import("std");
const assert = std.debug.assert;
const report = @import("report.zig");
const Events = @import("events.zig");

const Run = struct {
    scenario: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    program: ?[]const u8 = null,
    inputs: []const u8,
    seed: []const u8,
    branches: u32,
    from_branch: ?u32 = null,
    from_vtime_ms: ?u64 = null,
    shard: ?[2]u32 = null,
};

const Branch = struct {
    index: u32,
    seed: []const u8,
    outcome: []const u8,
    vtime_ns: u64,
    wall_ns: u64,
    events: u64,
    events_hash: []const u8,
    failing: []const []const u8,
};

const Property = struct {
    kind: []const u8,
    message: []const u8,
    /// Across the merged multiverse (report.property_failing), set once merged.
    failing: bool = false,
    branches_hit: u32,
    branches_true: u32 = 0,
    branches_failing: u32,
    example_branch: ?u32 = null,
};

const Summary = struct {
    branches: u32,
    failing_branches: u32,
    wall_ns: u64,
    skid_max: u64,
    overshoots: u64,
    properties: []const Property,
};

const Line = struct { run: ?Run = null, branch: ?Branch = null, summary: ?Summary = null };

pub fn merge(arena: std.mem.Allocator, io: std.Io, paths: []const [:0]const u8) !u32 {
    if (paths.len == 0) return error.Usage;
    var run: ?Run = null;
    var branches: std.ArrayList(Branch) = .empty;
    var properties: std.ArrayList(Property) = .empty;
    var total = Summary{
        .branches = 0,
        .failing_branches = 0,
        .wall_ns = 0,
        .skid_max = 0,
        .overshoots = 0,
        .properties = &.{},
    };
    for (paths) |path| {
        const source = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 30));
        var lines = std.mem.tokenizeScalar(u8, source, '\n');
        while (lines.next()) |text| {
            const line = try std.json.parseFromSliceLeaky(Line, arena, text, .{
                .ignore_unknown_fields = true,
            });
            if (line.run) |this| try run_check(&run, this, path);
            if (line.branch) |branch| try branch_add(arena, &branches, branch, path);
            if (line.summary) |summary| try summary_add(arena, &total, &properties, summary);
        }
    }
    const merged_run = run orelse return error.NoRunLine;
    var failing: u32 = 0;
    for (properties.items) |*property| {
        const kind = std.meta.stringToEnum(Events.Kind, property.kind) orelse return error.BadKind;
        property.failing = report.property_failing(kind, .{
            .branches_hit = property.branches_hit,
            .branches_true = property.branches_true,
            .branches_failing = property.branches_failing,
        });
        failing += @intFromBool(property.failing);
    }
    total.properties = properties.items;
    try output(io, merged_run, branches.items, total);
    summary_print(&total, merged_run);
    return failing;
}

fn run_check(known: *?Run, run: Run, path: []const u8) !void {
    const first = known.* orelse {
        known.* = run;
        return;
    };
    const eql = std.mem.eql;
    const same = eql(u8, first.inputs, run.inputs) and eql(u8, first.seed, run.seed) and
        eql(u8, first.scenario orelse "", run.scenario orelse "") and
        first.from_branch == run.from_branch and first.from_vtime_ms == run.from_vtime_ms;
    if (!same) {
        std.debug.print("[determinismo] {s} explored something else (inputs, seed, scenario " ++
            "or fork point differ)\n", .{path});
        return error.ShardsDiffer;
    }
}

fn branch_add(
    arena: std.mem.Allocator,
    branches: *std.ArrayList(Branch),
    branch: Branch,
    path: []const u8,
) !void {
    for (branches.items) |known| {
        if (known.index != branch.index) continue;
        std.debug.print("[determinismo] branch {d} appears twice (again in {s})\n", .{
            branch.index, path,
        });
        return error.ShardsOverlap;
    }
    try branches.append(arena, branch);
}

fn summary_add(
    arena: std.mem.Allocator,
    total: *Summary,
    properties: *std.ArrayList(Property),
    summary: Summary,
) !void {
    total.branches += summary.branches;
    total.failing_branches += summary.failing_branches;
    total.wall_ns = @max(total.wall_ns, summary.wall_ns); // Shards run side by side.
    total.skid_max = @max(total.skid_max, summary.skid_max);
    total.overshoots += summary.overshoots;
    for (summary.properties) |incoming| {
        const property = for (properties.items) |*known| {
            if (std.mem.eql(u8, known.message, incoming.message)) break known;
        } else {
            try properties.append(arena, incoming);
            continue;
        };
        property.branches_hit += incoming.branches_hit;
        property.branches_true += incoming.branches_true;
        property.branches_failing += incoming.branches_failing;
        const example = incoming.example_branch orelse continue;
        if (property.example_branch == null or example < property.example_branch.?) {
            property.example_branch = example;
        }
    }
}

fn output(
    io: std.Io,
    run: Run,
    branches: []Branch,
    total: Summary,
) !void {
    std.mem.sort(Branch, branches, {}, struct {
        fn less(_: void, a: Branch, b: Branch) bool {
            return a.index < b.index;
        }
    }.less);
    var buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;
    var merged = run;
    merged.shard = null;
    try std.json.Stringify.value(.{ .run = merged }, .{}, out);
    try out.writeAll("\n");
    for (branches) |branch| {
        try std.json.Stringify.value(.{ .branch = branch }, .{}, out);
        try out.writeAll("\n");
    }
    try std.json.Stringify.value(.{ .summary = total }, .{}, out);
    try out.writeAll("\n");
    try out.flush();
}

fn summary_print(total: *const Summary, run: Run) void {
    const print = std.debug.print;
    print("[determinismo] merged: {d} of {d} branches, {d} with failing properties\n", .{
        total.branches, run.branches, total.failing_branches,
    });
    for (total.properties) |property| {
        const status = if (property.failing) "FAIL" else "PASS";
        print("  {s} {s:<21} hit in {d:>4}/{d} branches, failing in {d:>4}  {s}", .{
            status,         property.kind,             property.branches_hit,
            total.branches, property.branches_failing, property.message,
        });
        if (property.example_branch) |branch| print("  (e.g. --branch {d})", .{branch});
        print("\n", .{});
    }
    if (total.branches < run.branches) {
        print("[determinismo] {d} branches missing: was every shard merged?\n", .{
            run.branches - total.branches,
        });
    }
}
