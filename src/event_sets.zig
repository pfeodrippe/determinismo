// SPDX-License-Identifier: MIT
//! `determinismo events`: event sets, as Antithesis's (docs/ANTITHESIS.md): a pipeline of
//! operations over every event of a multiverse, each taking a set and giving a new one.
//!
//!   determinismo events <events-dir> '<pipeline>' [--branch <n>] [--limit <n>]
//!       [--count | --branches] [--json]
//!
//! A pipeline is a JSON array of operations, each an object with one key:
//!
//!   {"filter": "<condition>"}       events matching the condition (query.zig's syntax)
//!   {"exclude": "<condition>"}      events not matching it
//!   {"with_last": {"<name>": "<condition>", ...}}
//!                                   each event, with `last_<name>`: the nearest earlier event
//!                                   of its timeline matching (when there is one)
//!   {"with_next": {"<name>": "<condition>", ...}, "timeout": <seconds>}
//!                                   for each event, the nearest later event of its timeline
//!                                   matching one of them, with `last_event` (the event it
//!                                   follows) and `with_next_type` (the name); past the timeout
//!                                   without one, a synthetic event of type "timeout"
//!   {"union": [<pipeline>, ...]}    the set and the others' events (one per moment: the
//!                                   first set's version wins, as distinct_by_moment)
//!   {"intersect": [<pipeline>, ...]}  events in the set and in every other
//!   {"difference": <pipeline>}      events in the set but not the other
//!   {"narrow": ["<path>", ...]}     events with only those fields
//!   {"through": "<command>"}        any program, in any language, as map, flatmap and fold:
//!                                   it reads the set as JSON lines ({"branch", "index",
//!                                   "vtime_ns", "event"}, timeline by timeline, in order) and
//!                                   writes the new set the same way (an event's moment is its
//!                                   branch and index: the event of the timeline it stands for)
//!
//! Each pipeline starts from every event of every timeline. Synthetic fields go into the event's
//! JSON, so later conditions see them (`last_fault.event.details.kind=partition`).
const std = @import("std");
const assert = std.debug.assert;
const query = @import("query.zig");

const pipeline_depth_max = 8;

/// One event of a set: the timeline event it stands for, and its JSON (maybe synthetic).
pub const Item = struct {
    timeline: u32,
    index: u32,
    vtime_ns: u64,
    value: std.json.Value,

    fn order(_: void, a: Item, b: Item) bool {
        if (a.timeline != b.timeline) return a.timeline < b.timeline;
        if (a.index != b.index) return a.index < b.index;
        return a.vtime_ns < b.vtime_ns;
    }

    fn key(item: Item) Key {
        return .{ item.timeline, item.index, item.vtime_ns };
    }
};
const Key = struct { u32, u32, u64 };

const Named = struct { name: []const u8, condition: query.Condition };

const Operation = union(enum) {
    filter: query.Condition,
    exclude: query.Condition,
    with_last: []const Named,
    with_next: struct { sets: []const Named, timeout_ns: ?u64 },
    @"union": []const Pipeline,
    intersect: []const Pipeline,
    difference: Pipeline,
    narrow: []const []const []const u8,
    through: []const u8,
};
const Pipeline = []const Operation;

pub fn pipeline_parse(arena: std.mem.Allocator, value: std.json.Value) !Pipeline {
    return pipeline_parse_depth(arena, value, 0);
}

/// Pipelines nest (union, intersect, difference): the error set is open at the recursion.
fn pipeline_parse_depth(
    arena: std.mem.Allocator,
    value: std.json.Value,
    depth: u32,
) anyerror!Pipeline {
    if (depth == pipeline_depth_max) return error.PipelineTooDeep;
    if (value != .array) return error.PipelineNotArray;
    const operations = try arena.alloc(Operation, value.array.items.len);
    for (value.array.items, operations) |item, *operation| {
        operation.* = try operation_parse(arena, item, depth);
    }
    return operations;
}

fn operation_parse(arena: std.mem.Allocator, value: std.json.Value, depth: u32) !Operation {
    if (value != .object) return error.OperationNotObject;
    const object = value.object;
    const eql = std.mem.eql;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        const argument = entry.value_ptr.*;
        if (eql(u8, name, "timeout")) continue;
        if (eql(u8, name, "filter")) return .{ .filter = try condition_of(arena, argument) };
        if (eql(u8, name, "exclude")) return .{ .exclude = try condition_of(arena, argument) };
        if (eql(u8, name, "with_last")) return .{ .with_last = try named_parse(arena, argument) };
        if (eql(u8, name, "with_next")) {
            const timeout: ?u64 = if (object.get("timeout")) |seconds|
                try seconds_ns(seconds)
            else
                null;
            const sets = try named_parse(arena, argument);
            return .{ .with_next = .{ .sets = sets, .timeout_ns = timeout } };
        }
        if (eql(u8, name, "union")) return .{ .@"union" = try pipelines(arena, argument, depth) };
        if (eql(u8, name, "intersect")) {
            return .{ .intersect = try pipelines(arena, argument, depth) };
        }
        if (eql(u8, name, "difference")) {
            return .{ .difference = try pipeline_parse_depth(arena, argument, depth + 1) };
        }
        if (eql(u8, name, "narrow")) return .{ .narrow = try paths_parse(arena, argument) };
        if (eql(u8, name, "through")) {
            if (argument != .string or argument.string.len == 0) return error.BadThrough;
            return .{ .through = argument.string };
        }
        return error.UnknownOperation;
    }
    return error.EmptyOperation;
}

fn condition_of(arena: std.mem.Allocator, value: std.json.Value) !query.Condition {
    if (value != .string) return error.ConditionNotString;
    return query.parse(arena, value.string);
}

fn named_parse(arena: std.mem.Allocator, value: std.json.Value) ![]const Named {
    if (value != .object or value.object.count() == 0) return error.BadNamedSets;
    var named: std.ArrayList(Named) = .empty;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        try named.append(arena, .{
            .name = entry.key_ptr.*,
            .condition = try condition_of(arena, entry.value_ptr.*),
        });
    }
    return named.items;
}

fn pipelines(arena: std.mem.Allocator, value: std.json.Value, depth: u32) ![]const Pipeline {
    if (value != .array or value.array.items.len == 0) return error.BadPipelines;
    const parsed = try arena.alloc(Pipeline, value.array.items.len);
    for (value.array.items, parsed) |item, *pipeline| {
        pipeline.* = try pipeline_parse_depth(arena, item, depth + 1);
    }
    return parsed;
}

fn paths_parse(arena: std.mem.Allocator, value: std.json.Value) ![]const []const []const u8 {
    if (value != .array) return error.BadNarrow;
    const paths = try arena.alloc([]const []const u8, value.array.items.len);
    for (value.array.items, paths) |item, *path| {
        if (item != .string or item.string.len == 0) return error.BadNarrow;
        var parts: std.ArrayList([]const u8) = .empty;
        var split = std.mem.tokenizeScalar(u8, item.string, '.');
        while (split.next()) |part| try parts.append(arena, part);
        path.* = parts.items;
    }
    return paths;
}

fn seconds_ns(value: std.json.Value) !u64 {
    const seconds: f64 = switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => return error.BadTimeout,
    };
    if (!(seconds >= 0)) return error.BadTimeout;
    return @intFromFloat(seconds * std.time.ns_per_s);
}

/// Where the sets come from, and what `through` needs to run programs.
pub const Universe = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    timelines: []const query.Timeline,

    /// The item as an event to match, its JSON in `cell` (the caller's).
    fn event(universe: *const Universe, item: *const Item, cell: *query.Event.Cell) query.Event {
        const original = &universe.timelines[item.timeline].events[item.index];
        cell.* = .{ .value = item.value, .arena = universe.arena };
        return .{
            .branch = original.branch,
            .seq = original.seq,
            .vtime_ns = item.vtime_ns,
            .line = "",
            .cell = cell,
        };
    }

    fn all(universe: *const Universe) ![]Item {
        var count: usize = 0;
        for (universe.timelines) |timeline| count += timeline.events.len;
        const items = try universe.arena.alloc(Item, count);
        var at: usize = 0;
        for (universe.timelines, 0..) |timeline, timeline_index| {
            for (timeline.events, 0..) |original, index| {
                items[at] = .{
                    .timeline = @intCast(timeline_index),
                    .index = @intCast(index),
                    .vtime_ns = original.vtime_ns,
                    .value = original.value(),
                };
                at += 1;
            }
        }
        return items;
    }
};

pub fn evaluate(universe: *const Universe, pipeline: Pipeline) anyerror![]Item {
    var items = try universe.all();
    for (pipeline) |*operation| items = try apply(universe, operation, items);
    return items;
}

fn apply(universe: *const Universe, operation: *const Operation, items: []Item) ![]Item {
    return switch (operation.*) {
        .filter => |*condition| keep(universe, items, condition, true),
        .exclude => |*condition| keep(universe, items, condition, false),
        .with_last => |sets| with_last(universe, items, sets),
        .with_next => |next| with_next(universe, items, next.sets, next.timeout_ns),
        .@"union" => |others| set_union(universe, items, others),
        .intersect => |others| set_intersect(universe, items, others),
        .difference => |other| set_difference(universe, items, other),
        .narrow => |paths| narrow(universe.arena, items, paths),
        .through => |command| through(universe, items, command),
    };
}

fn keep(
    universe: *const Universe,
    items: []Item,
    condition: *const query.Condition,
    wanted: bool,
) []Item {
    var kept: usize = 0;
    for (items) |item| {
        var cell: query.Event.Cell = undefined;
        const event = universe.event(&item, &cell);
        if (condition.matches(&event) != wanted) continue;
        items[kept] = item;
        kept += 1;
    }
    return items[0..kept];
}

/// The timeline event at `index`, as a JSON object: where it is, and the event.
fn moment_value(
    arena: std.mem.Allocator,
    original: *const query.Event,
    value: std.json.Value,
) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "vtime_ns", .{ .integer = @intCast(original.vtime_ns) });
    try object.put(arena, "seq", .{ .integer = @intCast(original.seq) });
    try object.put(arena, "event", value);
    return .{ .object = object };
}

fn with_fields(
    arena: std.mem.Allocator,
    value: std.json.Value,
    fields: []const struct { []const u8, std.json.Value },
) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    if (value == .object) object = try value.object.clone(arena);
    if (value != .object) try object.put(arena, "value", value);
    for (fields) |field| try object.put(arena, field[0], field[1]);
    return .{ .object = object };
}

fn with_last(universe: *const Universe, items: []Item, sets: []const Named) ![]Item {
    const arena = universe.arena;
    for (items) |*item| {
        const events = universe.timelines[item.timeline].events;
        for (sets) |*set| {
            var at: usize = item.index;
            const found = while (at > 0) {
                at -= 1;
                if (set.condition.matches(&events[at])) break &events[at];
            } else null;
            const original = found orelse continue;
            const name = try std.fmt.allocPrint(arena, "last_{s}", .{set.name});
            const last = try moment_value(arena, original, original.value());
            item.value = try with_fields(arena, item.value, &.{.{ name, last }});
        }
    }
    return items;
}

fn with_next(
    universe: *const Universe,
    items: []Item,
    sets: []const Named,
    timeout_ns: ?u64,
) ![]Item {
    const arena = universe.arena;
    var next: std.ArrayList(Item) = .empty;
    for (items) |*item| {
        const events = universe.timelines[item.timeline].events;
        const deadline_ns: ?u64 = if (timeout_ns) |timeout| item.vtime_ns + timeout else null;
        var at: usize = item.index + 1;
        const found: ?struct { usize, []const u8 } = search: while (at < events.len) : (at += 1) {
            if (deadline_ns) |deadline| if (events[at].vtime_ns > deadline) break :search null;
            for (sets) |*set| {
                if (set.condition.matches(&events[at])) break :search .{ at, set.name };
            }
        } else null;
        if (found) |match| {
            const original = &events[match[0]];
            try next.append(arena, .{
                .timeline = item.timeline,
                .index = @intCast(match[0]),
                .vtime_ns = original.vtime_ns,
                .value = try with_fields(arena, original.value(), &.{
                    .{ "last_event", item.value },
                    .{ "with_next_type", .{ .string = match[1] } },
                }),
            });
            continue;
        }
        // A timeout is known only where the timeline went on past it.
        const deadline = deadline_ns orelse continue;
        if (events.len == 0 or events[events.len - 1].vtime_ns < deadline) continue;
        var synthetic: std.json.ObjectMap = .empty;
        try synthetic.put(arena, "with_next_type", .{ .string = "timeout" });
        try synthetic.put(arena, "last_event", item.value);
        try next.append(arena, .{
            .timeline = item.timeline,
            .index = item.index,
            .vtime_ns = deadline,
            .value = .{ .object = synthetic },
        });
    }
    std.mem.sort(Item, next.items, {}, Item.order);
    return next.items;
}

fn keys_of(arena: std.mem.Allocator, items: []const Item) !std.AutoHashMapUnmanaged(Key, void) {
    var keys: std.AutoHashMapUnmanaged(Key, void) = .empty;
    try keys.ensureTotalCapacity(arena, @intCast(items.len));
    for (items) |item| keys.putAssumeCapacity(item.key(), {});
    return keys;
}

fn set_union(universe: *const Universe, items: []Item, others: []const Pipeline) ![]Item {
    const arena = universe.arena;
    var seen = try keys_of(arena, items);
    var all: std.ArrayList(Item) = .fromOwnedSlice(items);
    for (others) |other| {
        for (try evaluate(universe, other)) |item| {
            const entry = try seen.getOrPut(arena, item.key());
            if (entry.found_existing) continue;
            try all.append(arena, item);
        }
    }
    std.mem.sort(Item, all.items, {}, Item.order);
    return all.items;
}

fn set_intersect(universe: *const Universe, items: []Item, others: []const Pipeline) ![]Item {
    var kept = items;
    for (others) |other| {
        const keys = try keys_of(universe.arena, try evaluate(universe, other));
        var count: usize = 0;
        for (kept) |item| {
            if (!keys.contains(item.key())) continue;
            kept[count] = item;
            count += 1;
        }
        kept = kept[0..count];
    }
    return kept;
}

fn set_difference(universe: *const Universe, items: []Item, other: Pipeline) ![]Item {
    const keys = try keys_of(universe.arena, try evaluate(universe, other));
    var count: usize = 0;
    for (items) |item| {
        if (keys.contains(item.key())) continue;
        items[count] = item;
        count += 1;
    }
    return items[0..count];
}

fn narrow(arena: std.mem.Allocator, items: []Item, paths: []const []const []const u8) ![]Item {
    for (items) |*item| {
        var narrowed: std.json.ObjectMap = .empty;
        for (paths) |path| {
            const found = path_get(item.value, path) orelse continue;
            try path_put(arena, &narrowed, path, found);
        }
        item.value = .{ .object = narrowed };
    }
    return items;
}

fn path_get(value: std.json.Value, path: []const []const u8) ?std.json.Value {
    var at = value;
    for (path) |part| {
        if (at != .object) return null;
        at = at.object.get(part) orelse return null;
    }
    return at;
}

fn path_put(
    arena: std.mem.Allocator,
    object: *std.json.ObjectMap,
    path: []const []const u8,
    value: std.json.Value,
) !void {
    assert(path.len > 0);
    if (path.len == 1) return object.put(arena, path[0], value);
    const entry = try object.getOrPut(arena, path[0]);
    if (!entry.found_existing or entry.value_ptr.* != .object) {
        entry.value_ptr.* = .{ .object = .empty };
    }
    try path_put(arena, &entry.value_ptr.object, path[1..], value);
}

/// The set through a program: JSON lines in (from a file, so that the program may read at
/// its pace), JSON lines out.
fn through(universe: *const Universe, items: []Item, command: []const u8) ![]Item {
    const arena = universe.arena;
    var input: std.Io.Writer.Allocating = .init(arena);
    for (items) |*item| try item_write(&input.writer, universe, item);
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/tmp/determinismo-events-{d}-{d}", .{
        std.os.linux.getpid(), @intFromPtr(items.ptr),
    });
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(universe.io, .{ .sub_path = path, .data = input.written() });
    defer cwd.deleteFile(universe.io, path) catch {};
    const result = try std.process.run(arena, universe.io, .{
        .argv = &.{ "/bin/sh", "-c", "exec <\"$0\"; eval \"$1\"", path, command },
    });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("[determinismo] events: `{s}` failed:\n{s}", .{ command, result.stderr });
        return error.ThroughFailed;
    }
    const Line = struct { branch: u32, index: u32, vtime_ns: ?u64 = null, event: std.json.Value };
    var out: std.ArrayList(Item) = .empty;
    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |text| {
        const line = try std.json.parseFromSliceLeaky(Line, arena, text, .{
            .ignore_unknown_fields = true,
        });
        const timeline = timeline_of(universe.timelines, line.branch) orelse
            return error.ThroughUnknownBranch;
        const events = universe.timelines[timeline].events;
        if (line.index >= events.len) return error.ThroughBadIndex;
        try out.append(arena, .{
            .timeline = timeline,
            .index = line.index,
            .vtime_ns = line.vtime_ns orelse events[line.index].vtime_ns,
            .value = line.event,
        });
    }
    std.mem.sort(Item, out.items, {}, Item.order);
    return out.items;
}

fn timeline_of(timelines: []const query.Timeline, branch: u32) ?u32 {
    for (timelines, 0..) |timeline, index| if (timeline.branch == branch) return @intCast(index);
    return null;
}

fn item_write(out: *std.Io.Writer, universe: *const Universe, item: *const Item) !void {
    const branch = universe.timelines[item.timeline].branch;
    try out.print("{{\"branch\":{d},\"index\":{d},\"vtime_ns\":{d},\"event\":{f}}}\n", .{
        branch, item.index, item.vtime_ns, std.json.fmt(item.value, .{}),
    });
}

/// A pipeline as JSON, for the HTTP API and agents (MCP).
pub const Request = struct {
    pipeline: std.json.Value,
    branch: ?u32 = null,
    limit: u64 = 100,
    output: query.Output = .events,
};

pub fn answer(
    arena: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    request: Request,
) ![]const u8 {
    const pipeline = try pipeline_parse(arena, request.pipeline);
    const universe = Universe{
        .arena = arena,
        .io = io,
        .timelines = try query.timelines_read(arena, io, directory, request.branch),
    };
    const items = try evaluate(&universe, pipeline);
    var out: std.Io.Writer.Allocating = .init(arena);
    try write(&out.writer, &universe, items, .{
        .limit = request.limit,
        .output = request.output,
        .json = true,
    });
    return out.written();
}

const Show = struct { limit: u64, output: query.Output, json: bool };

fn write(out: *std.Io.Writer, universe: *const Universe, items: []const Item, show: Show) !void {
    switch (show.output) {
        .events => for (items[0..@min(items.len, show.limit)]) |*item| {
            if (show.json) {
                try item_write(out, universe, item);
                continue;
            }
            const branch = universe.timelines[item.timeline].branch;
            const ms = item.vtime_ns / std.time.ns_per_ms;
            try out.print("branch {d} vtime {d}.{d:0>6}s  {f}  (--from-branch {d} " ++
                "--from-vtime-ms {d})\n", .{
                branch,                         item.vtime_ns / std.time.ns_per_s,
                item.vtime_ns % std.time.ns_per_s / 1000, std.json.fmt(item.value, .{}),
                branch,                         ms,
            });
        },
        .count, .branches => {
            var branches: u64 = 0;
            var at: usize = 0;
            while (at < items.len) {
                const first = at;
                while (at < items.len and items[at].timeline == items[first].timeline) at += 1;
                branches += 1;
                if (show.output != .branches) continue;
                const branch = universe.timelines[items[first].timeline].branch;
                const shown = .{ branch, at - first, items[first].vtime_ns };
                if (show.json) {
                    try out.print("{{\"branch\":{d},\"matches\":{d},\"first_vtime_ns\":{d}}}\n",
                        shown);
                } else {
                    try out.print("branch {d}: {d} events, first at vtime {d}ns\n", shown);
                }
            }
            if (show.output != .count) return;
            const counts = .{ items.len, branches, universe.timelines.len };
            if (show.json) {
                try out.print("{{\"events\":{d},\"branches\":{d},\"timelines\":{d}}}\n", counts);
            } else {
                try out.print("{d} events in {d} of {d} timelines\n", counts);
            }
        },
    }
}

/// The command: arguments after `events`. Exit status 0 when the set is not empty, 1 when it
/// is (as grep), 2 on usage errors.
pub fn run(arena: std.mem.Allocator, io: std.Io, arguments: []const [:0]const u8) !u8 {
    if (arguments.len < 2) return error.Usage;
    // `events <dir> '{"pipeline": [...], ...}'`: the HTTP API's request, and its answer.
    if (arguments.len == 2 and std.mem.startsWith(u8, arguments[1], "{\"pipeline\"")) {
        const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
        const asked = try std.json.parseFromSliceLeaky(Request, arena, arguments[1], options);
        try std.Io.File.stdout().writeStreamingAll(io, try answer(arena, io, arguments[0], asked));
        return 0;
    }
    var show = Show{ .limit = std.math.maxInt(u64), .output = .events, .json = false };
    var branch: ?u32 = null;
    var index: usize = 2;
    while (index < arguments.len) : (index += 1) {
        const flag = arguments[index];
        const eql = std.mem.eql;
        if (eql(u8, flag, "--count")) {
            show.output = .count;
        } else if (eql(u8, flag, "--branches")) {
            show.output = .branches;
        } else if (eql(u8, flag, "--json")) {
            show.json = true;
        } else if (index + 1 < arguments.len and eql(u8, flag, "--limit")) {
            index += 1;
            show.limit = try std.fmt.parseInt(u64, arguments[index], 10);
        } else if (index + 1 < arguments.len and eql(u8, flag, "--branch")) {
            index += 1;
            branch = try std.fmt.parseInt(u32, arguments[index], 10);
        } else return error.Usage;
    }
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, arguments[1], .{});
    const pipeline = try pipeline_parse(arena, value);
    const universe = Universe{
        .arena = arena,
        .io = io,
        .timelines = try query.timelines_read(arena, io, arguments[0], branch),
    };
    const items = try evaluate(&universe, pipeline);
    var buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try write(&stdout.interface, &universe, items, show);
    try stdout.interface.flush();
    return if (items.len > 0) 0 else 1;
}

fn timeline_test(arena: std.mem.Allocator, lines: []const []const u8) !query.Timeline {
    const events = try arena.alloc(query.Event, lines.len);
    for (lines, events, 0..) |line, *event, index| {
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
        event.* = try query.Event.of(arena, .{
            .branch = 0,
            .seq = index,
            .vtime_ns = index * std.time.ns_per_s,
        }, value);
    }
    return .{ .branch = 0, .events = events };
}

fn evaluate_test(universe: *const Universe, pipeline: []const u8) ![]Item {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, universe.arena, pipeline, .{});
    return evaluate(universe, try pipeline_parse(universe.arena, value));
}

test evaluate {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const timelines = [_]query.Timeline{try timeline_test(arena, &.{
        \\{"event":"fault","details":{"kind":"partition"}}
        ,
        \\{"event":"request","details":{"ok":false}}
        ,
        \\{"event":"fault","details":{"kind":"pause"}}
        ,
        \\{"event":"request","details":{"ok":true}}
        ,
        \\{"event":"request","details":{"ok":true}}
    })};
    const universe = Universe{ .arena = arena, .io = undefined, .timelines = &timelines };
    // Failed requests whose last fault was a partition.
    const failed = try evaluate_test(&universe,
        \\[{"filter": "event=request details.ok=false"},
        \\ {"with_last": {"fault": "event=fault"}},
        \\ {"filter": "last_fault.event.details.kind=partition"}]
    );
    try std.testing.expectEqual(@as(usize, 1), failed.len);
    try std.testing.expectEqual(@as(u32, 1), failed[0].index);
    // After each fault, the next successful request (or a timeout).
    const recovered = try evaluate_test(&universe,
        \\[{"filter": "event=fault"},
        \\ {"with_next": {"ok": "event=request details.ok=true"}, "timeout": 1.5}]
    );
    try std.testing.expectEqual(@as(usize, 2), recovered.len);
    const first_type = recovered[0].value.object.get("with_next_type").?.string;
    try std.testing.expectEqualStrings("timeout", first_type); // 2s later: past 1.5s.
    try std.testing.expectEqual(@as(u32, 3), recovered[1].index);
    // Set operations: requests minus the failed ones, plus faults.
    const sets = try evaluate_test(&universe,
        \\[{"filter": "event=request"},
        \\ {"difference": [{"filter": "details.ok=false"}]},
        \\ {"union": [[{"filter": "event=fault"}]]},
        \\ {"intersect": [[{"exclude": "details.kind=pause"}]]},
        \\ {"narrow": ["event"]}]
    );
    try std.testing.expectEqual(@as(usize, 3), sets.len); // Partition, two good requests.
    try std.testing.expectEqual(@as(usize, 1), sets[0].value.object.count());
}
