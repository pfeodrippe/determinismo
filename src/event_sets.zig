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
//!   {"narrow": ["<path>", ...]}     events with only those fields (a null field is left out)
//!   {"through": "<command>"}        any program, in any language, as map, flatmap and fold:
//!                                   it reads the set as JSON lines ({"branch", "index",
//!                                   "vtime_ns", "event"}, timeline by timeline, in order) and
//!                                   writes the new set the same way (an event's moment is its
//!                                   branch and index: the event of the timeline it stands for)
//!
//! Each pipeline starts from every event of every timeline. Synthetic fields go into the event's
//! JSON, so later conditions see them (`last_fault.event.details.kind=partition`).
//!
//! Pipelines run on the run's events database (store.zig): the universe is a temporary table of
//! every timeline's events, numbered in each timeline (`idx`), and each operation makes the next
//! set as a temporary table of the request's connection.
const std = @import("std");
const assert = std.debug.assert;
const query = @import("query.zig");
const duckdb = @import("duckdb.zig");
const store = @import("store.zig");

const pipeline_depth_max = 8;

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
    return @trunc(seconds * std.time.ns_per_s);
}

/// The event as its set's operations see it: the object itself, or another value under `value`.
const object_sql = "(CASE WHEN json_type(event) = 'OBJECT' THEN event " ++
    "ELSE json_object('value', event) END)";

/// Pipelines evaluated on a run's events database, set by set (temporary tables of
/// `connection`: timeline, idx, vtime_ns, seq, event).
const Evaluator = struct {
    connection: *duckdb.Connection,
    arena: std.mem.Allocator,
    io: std.Io,
    sets: u32 = 0,

    /// The universe: every event of every timeline (or of one), numbered in it.
    fn universe(evaluator: *Evaluator, only_branch: ?u32) !void {
        const scope = if (only_branch) |branch|
            try std.fmt.allocPrint(evaluator.arena, " WHERE timeline = {d}", .{branch})
        else
            "";
        try evaluator.exec(
            \\CREATE TEMP TABLE universe AS SELECT timeline,
            \\    (row_number() OVER (PARTITION BY timeline ORDER BY vtime_ns, seq) - 1)::UBIGINT
            \\        AS idx,
            \\    vtime_ns, seq, event FROM timeline_events{s}
        , .{scope});
    }

    fn exec(evaluator: *Evaluator, comptime format: []const u8, arguments: anytype) !void {
        const sql = try std.fmt.allocPrintSentinel(evaluator.arena, format, arguments, 0);
        try evaluator.connection.exec(sql);
    }

    /// A new set from a SELECT of its five columns: its table.
    fn set(evaluator: *Evaluator, select: []const u8) ![]const u8 {
        evaluator.sets += 1;
        const name = try std.fmt.allocPrint(evaluator.arena, "set_{d}", .{evaluator.sets});
        const create = "CREATE TEMP TABLE {s} AS " ++
            "SELECT timeline, idx, vtime_ns, seq, event FROM ({s})";
        try evaluator.exec(create, .{
            name, select,
        });
        return name;
    }

    fn condition(evaluator: *Evaluator, value: *const query.Condition) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(evaluator.arena);
        try value.sql(&out.writer, false); // Sets carry synthetic fields: the JSON says.
        return out.written();
    }

    fn literal(evaluator: *Evaluator, text: []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(evaluator.arena);
        try query.string_literal(&out.writer, text);
        return out.written();
    }

    fn pipeline(evaluator: *Evaluator, operations: Pipeline) anyerror![]const u8 {
        var current: []const u8 = "universe";
        for (operations) |*operation| current = try evaluator.apply(operation, current);
        return current;
    }

    fn apply(evaluator: *Evaluator, operation: *const Operation, input: []const u8) ![]const u8 {
        const arena = evaluator.arena;
        const print = std.fmt.allocPrint;
        return switch (operation.*) {
            .filter => |*value| evaluator.set(try print(arena, "SELECT * FROM {s} WHERE ({s})", .{
                input, try evaluator.condition(value),
            })),
            // Conditions are never NULL: NOT keeps exactly what does not match.
            .exclude => |*value| evaluator.set(try print(arena, "SELECT * FROM {s} WHERE NOT ({s})", .{
                input, try evaluator.condition(value),
            })),
            .with_last => |named| {
                var current = input;
                for (named) |*entry| current = try evaluator.with_last(current, entry);
                return current;
            },
            .with_next => |next| evaluator.with_next(input, next.sets, next.timeout_ns),
            .@"union" => |others| evaluator.set_union(input, others),
            .intersect => |others| {
                var current = input;
                for (others) |other| {
                    const table = try evaluator.pipeline(other);
                    current = try evaluator.set(try print(arena,
                        \\SELECT s.* FROM {s} s SEMI JOIN {s} o USING (timeline, idx, vtime_ns)
                    , .{ current, table }));
                }
                return current;
            },
            .difference => |other| {
                const table = try evaluator.pipeline(other);
                return evaluator.set(try print(arena,
                    \\SELECT s.* FROM {s} s ANTI JOIN {s} o USING (timeline, idx, vtime_ns)
                , .{ input, table }));
            },
            .narrow => |paths| evaluator.narrow(input, paths),
            .through => |command| evaluator.through(input, command),
        };
    }

    /// `last_<name>`: the nearest earlier event of the timeline (the universe's) matching.
    fn with_last(evaluator: *Evaluator, input: []const u8, named: *const Named) ![]const u8 {
        const field = try std.fmt.allocPrint(evaluator.arena, "last_{s}", .{named.name});
        return evaluator.set(try std.fmt.allocPrint(evaluator.arena,
            \\WITH found AS (
            \\    SELECT timeline, idx, last_value(CASE WHEN {s} THEN
            \\        json_object('vtime_ns', vtime_ns, 'seq', seq, 'event', event) END
            \\        IGNORE NULLS) OVER (PARTITION BY timeline ORDER BY idx
            \\            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS found
            \\    FROM universe
            \\)
            \\SELECT s.timeline, s.idx, s.vtime_ns, s.seq,
            \\    CASE WHEN f.found IS NULL THEN s.event
            \\        ELSE json_merge_patch({s}, json_object({s}, f.found)) END AS event
            \\FROM {s} s LEFT JOIN found f USING (timeline, idx)
        , .{
            try evaluator.condition(&named.condition), object_sql,
            try evaluator.literal(field),              input,
        }));
    }

    /// For each event, the next of its timeline matching one of the sets (the first set
    /// matching names it), or a timeout where the timeline went on past it.
    fn with_next(
        evaluator: *Evaluator,
        input: []const u8,
        named: []const Named,
        timeout_ns: ?u64,
    ) ![]const u8 {
        const arena = evaluator.arena;
        var types: std.Io.Writer.Allocating = .init(arena);
        try types.writer.writeAll("CASE");
        for (named) |*entry| {
            try types.writer.print(" WHEN {s} THEN {s}", .{
                try evaluator.condition(&entry.condition), try evaluator.literal(entry.name),
            });
        }
        try types.writer.writeAll(" END");
        const within = if (timeout_ns) |timeout|
            try std.fmt.allocPrint(arena, " AND next_vtime_ns <= vtime_ns + {d}", .{timeout})
        else
            "";
        const timeouts = if (timeout_ns) |timeout| try std.fmt.allocPrint(arena,
            \\UNION ALL
            \\SELECT p.timeline, p.idx, p.vtime_ns + {d}, p.seq,
            \\    json_object('with_next_type', 'timeout', 'last_event', p.event)
            \\FROM paired p
            \\JOIN (SELECT timeline, max(vtime_ns) AS end_ns FROM universe GROUP BY timeline) e
            \\    USING (timeline)
            \\WHERE (p.next_idx IS NULL OR p.next_vtime_ns > p.vtime_ns + {d})
            \\    AND e.end_ns >= p.vtime_ns + {d}
        , .{ timeout, timeout, timeout }) else "";
        return evaluator.set(try std.fmt.allocPrint(arena,
            \\WITH matching AS (
            \\    SELECT * FROM (
            \\        SELECT timeline, idx, vtime_ns, seq, event, {s} AS type FROM universe
            \\    )
            \\    WHERE type IS NOT NULL
            \\), paired AS (
            \\    SELECT s.*, m.idx AS next_idx, m.vtime_ns AS next_vtime_ns, m.seq AS next_seq,
            \\        m.event AS next_event, m.type AS next_type
            \\    FROM {s} s ASOF LEFT JOIN matching m ON s.timeline = m.timeline AND s.idx < m.idx
            \\)
            \\SELECT timeline, next_idx AS idx, next_vtime_ns AS vtime_ns, next_seq AS seq,
            \\    json_merge_patch(CASE WHEN json_type(next_event) = 'OBJECT' THEN next_event
            \\        ELSE json_object('value', next_event) END,
            \\        json_object('last_event', event, 'with_next_type', next_type)) AS event
            \\FROM paired WHERE next_idx IS NOT NULL{s}
            \\{s}
        , .{ types.written(), input, within, timeouts }));
    }

    /// The set and the others' events at moments not yet in it (the first one's version).
    fn set_union(evaluator: *Evaluator, input: []const u8, others: []const Pipeline) ![]const u8 {
        const arena = evaluator.arena;
        var sources: std.Io.Writer.Allocating = .init(arena);
        for (others, 1..) |other, source| {
            const table = try evaluator.pipeline(other);
            if (source > 1) try sources.writer.writeAll(" UNION ALL ");
            const select = "SELECT *, {d} AS source, row_number() OVER () AS position FROM {s}";
            try sources.writer.print(select, .{
                source, table,
            });
        }
        return evaluator.set(try std.fmt.allocPrint(arena,
            \\SELECT * FROM {s}
            \\UNION ALL
            \\SELECT timeline, idx, vtime_ns, seq, event FROM ({s}) o
            \\WHERE NOT EXISTS (SELECT 1 FROM {s} s
            \\    WHERE s.timeline = o.timeline AND s.idx = o.idx AND s.vtime_ns = o.vtime_ns)
            \\QUALIFY row_number()
            \\    OVER (PARTITION BY timeline, idx, vtime_ns ORDER BY source, position) = 1
        , .{ input, sources.written(), input }));
    }

    /// Only the paths given, each where it was (a missing or null one left out).
    fn narrow(
        evaluator: *Evaluator,
        input: []const u8,
        paths: []const []const []const u8,
    ) ![]const u8 {
        const arena = evaluator.arena;
        var expression: std.Io.Writer.Allocating = .init(arena);
        try expression.writer.writeAll("'{}'::JSON");
        for (paths) |path| {
            var json_path: std.Io.Writer.Allocating = .init(arena);
            try json_path.writer.writeAll("$");
            for (path) |key| try json_path.writer.print(".\"{s}\"", .{key});
            const found = try std.fmt.allocPrint(arena, "json_extract(event, {s})", .{
                try evaluator.literal(json_path.written()),
            });
            var nested: []const u8 = found;
            var at = path.len;
            while (at > 0) {
                at -= 1;
                nested = try std.fmt.allocPrint(arena, "json_object({s}, {s})", .{
                    try evaluator.literal(path[at]), nested,
                });
            }
            const previous = try arena.dupe(u8, expression.written());
            expression.clearRetainingCapacity();
            const merged = "CASE WHEN {s} IS NULL THEN {s} ELSE json_merge_patch({s}, {s}) END";
            try expression.writer.print(merged, .{
                found, previous, previous, nested,
            });
        }
        return evaluator.set(try std.fmt.allocPrint(arena,
            \\SELECT timeline, idx, vtime_ns, seq, {s} AS event FROM {s}
        , .{ expression.written(), input }));
    }

    /// The set through a program: JSON lines in (from a file, so that the program may read at
    /// its pace), JSON lines out, each naming the timeline event it stands for.
    fn through(evaluator: *Evaluator, input: []const u8, command: []const u8) ![]const u8 {
        const arena = evaluator.arena;
        const Row = struct { branch: u32, index: u64, vtime_ns: u64, event: []const u8 };
        const rows = try evaluator.connection.rows(Row, arena, try std.fmt.allocPrintSentinel(arena,
            \\SELECT timeline, idx, vtime_ns, event FROM {s} ORDER BY timeline, idx, vtime_ns
        , .{input}, 0), .{});
        var lines: std.Io.Writer.Allocating = .init(arena);
        for (rows) |row| {
            try lines.writer.print(item_format, .{
                row.branch, row.index, row.vtime_ns, row.event,
            });
        }
        const pid = std.os.linux.getpid();
        const at = evaluator.sets;
        const in_path = try std.fmt.allocPrint(arena, "/tmp/determinismo-events-{d}-{d}.in", .{
            pid, at,
        });
        const out_path = try std.fmt.allocPrint(arena, "/tmp/determinismo-events-{d}-{d}.out", .{
            pid, at,
        });
        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(evaluator.io, .{ .sub_path = in_path, .data = lines.written() });
        defer cwd.deleteFile(evaluator.io, in_path) catch {};
        const result = try std.process.run(arena, evaluator.io, .{
            .argv = &.{ "/bin/sh", "-c", "exec <\"$0\"; eval \"$1\"", in_path, command },
        });
        if (result.term != .exited or result.term.exited != 0) {
            const failed = "[determinismo] events: `{s}` failed:\n{s}";
            std.debug.print(failed, .{ command, result.stderr });
            return error.ThroughFailed;
        }
        if (std.mem.trim(u8, result.stdout, " \n").len == 0) {
            return evaluator.set("SELECT * FROM universe WHERE false");
        }
        try cwd.writeFile(evaluator.io, .{ .sub_path = out_path, .data = result.stdout });
        defer cwd.deleteFile(evaluator.io, out_path) catch {};
        const table = try evaluator.set(try std.fmt.allocPrint(arena,
            \\SELECT o.branch AS timeline, o."index" AS idx,
            \\    coalesce(o.vtime_ns, u.vtime_ns) AS vtime_ns,
            \\    u.seq AS seq, o.event AS event
            \\FROM read_json({s}, format = 'newline_delimited',
            \\    columns = {{
            \\        branch: 'UINTEGER', "index": 'UBIGINT', vtime_ns: 'UBIGINT', event: 'JSON'
            \\    }}) o
            \\LEFT JOIN universe u ON u.timeline = o.branch AND u.idx = o."index"
        , .{try evaluator.literal(out_path)}));
        const Unknown = struct { count: u64 };
        const unknown_sql = try std.fmt.allocPrintSentinel(arena, "SELECT count(*) FROM {s} " ++
            "WHERE seq IS NULL", .{table}, 0);
        const unknown = (try evaluator.connection.row(Unknown, arena, unknown_sql, .{})).?;
        // A branch or index not in the set's universe.
        if (unknown.count > 0) return error.ThroughUnknownEvent;
        return table;
    }
};

/// An item of a set as JSON lines carry it (answers, and `through`'s programs).
const item_format = "{{\"branch\":{d},\"index\":{d},\"vtime_ns\":{d},\"event\":{s}}}\n";

/// A pipeline as JSON, for the HTTP API and agents (MCP).
pub const Request = struct {
    pipeline: std.json.Value,
    branch: ?u32 = null,
    limit: u64 = 100,
    output: query.Output = .events,
};

const Show = struct { limit: u64, output: query.Output, json: bool };

/// Evaluates a pipeline on a run's events database (`connection`'s); writes the set, and
/// returns how many events it has.
pub fn answer(
    connection: *duckdb.Connection,
    arena: std.mem.Allocator,
    io: std.Io,
    pipeline: Pipeline,
    only_branch: ?u32,
    show: Show,
    out: *std.Io.Writer,
) !u64 {
    var evaluator: Evaluator = .{ .connection = connection, .arena = arena, .io = io };
    try evaluator.universe(only_branch);
    const table = try evaluator.pipeline(pipeline);
    const Count = struct { count: u64 };
    const counting = "SELECT count(*) FROM {s}";
    const total_sql = try std.fmt.allocPrintSentinel(arena, counting, .{table}, 0);
    const total = (try connection.row(Count, arena, total_sql, .{})).?.count;
    switch (show.output) {
        .events, .marks => { // Event sets show whole events.
            const Row = struct { branch: u32, index: u64, vtime_ns: u64, event: []const u8 };
            const rows = try connection.rows(Row, arena, try std.fmt.allocPrintSentinel(arena,
                \\SELECT timeline, idx, vtime_ns, event FROM {s}
                \\ORDER BY timeline, idx, vtime_ns LIMIT {d}
            , .{ table, @min(show.limit, std.math.maxInt(i64)) }, 0), .{});
            for (rows) |row| {
                if (show.json) {
                    try out.print(item_format, .{ row.branch, row.index, row.vtime_ns, row.event });
                    continue;
                }
                try out.print("branch {d} vtime {d}.{d:0>6}s  {s}  (--from-branch {d} " ++
                    "--from-vtime-ms {d})\n", .{
                    row.branch,                              row.vtime_ns / std.time.ns_per_s,
                    row.vtime_ns % std.time.ns_per_s / 1000, row.event,
                    row.branch,                              row.vtime_ns / std.time.ns_per_ms,
                });
            }
        },
        .branches => {
            const Row = struct { branch: u32, matches: u64, first_vtime_ns: u64 };
            const rows = try connection.rows(Row, arena, try std.fmt.allocPrintSentinel(arena,
                \\SELECT timeline, count(*), first(vtime_ns ORDER BY idx, vtime_ns) FROM {s}
                \\GROUP BY timeline ORDER BY timeline
            , .{table}, 0), .{});
            for (rows) |row| {
                if (show.json) {
                    try out.print("{{\"branch\":{d},\"matches\":{d},\"first_vtime_ns\":{d}}}\n", .{
                        row.branch, row.matches, row.first_vtime_ns,
                    });
                } else {
                    try out.print("branch {d}: {d} events, first at vtime {d}ns\n", .{
                        row.branch, row.matches, row.first_vtime_ns,
                    });
                }
            }
        },
        .count => {
            const Row = struct { branches: u64, timelines: u64 };
            const row = (try connection.row(Row, arena, try std.fmt.allocPrintSentinel(arena,
                \\SELECT (SELECT count(DISTINCT timeline) FROM {s}),
                \\    (SELECT count(DISTINCT timeline) FROM universe)
            , .{table}, 0), .{})).?;
            if (show.json) {
                try out.print("{{\"events\":{d},\"branches\":{d},\"timelines\":{d}}}\n", .{
                    total, row.branches, row.timelines,
                });
            } else {
                try out.print("{d} events in {d} of {d} timelines\n", .{
                    total, row.branches, row.timelines,
                });
            }
        },
    }
    return total;
}

/// A request (the HTTP API's, an agent's) on a run's events database: its answer as JSON lines.
pub fn request_answer(
    connection: *duckdb.Connection,
    arena: std.mem.Allocator,
    io: std.Io,
    request: Request,
    out: *std.Io.Writer,
) !void {
    const pipeline = try pipeline_parse(arena, request.pipeline);
    _ = try answer(connection, arena, io, pipeline, request.branch, .{
        .limit = request.limit,
        .output = request.output,
        .json = true,
    }, out);
}

/// The command: arguments after `events`. Exit status 0 when the set is not empty, 1 when it
/// is (as grep), 2 on usage errors.
pub fn run(arena: std.mem.Allocator, io: std.Io, arguments: []const [:0]const u8) !u8 {
    if (arguments.len < 2) return error.Usage;
    var show = Show{ .limit = std.math.maxInt(u64), .output = .events, .json = false };
    var branch: ?u32 = null;
    var pipeline_value: std.json.Value = undefined;
    // `events <dir> '{"pipeline": [...], ...}'`: the HTTP API's request, and its answer.
    if (arguments.len == 2 and std.mem.startsWith(u8, arguments[1], "{\"pipeline\"")) {
        const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
        const asked = try std.json.parseFromSliceLeaky(Request, arena, arguments[1], options);
        pipeline_value = asked.pipeline;
        branch = asked.branch;
        show = .{ .limit = asked.limit, .output = asked.output, .json = true };
    } else {
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
        pipeline_value = try std.json.parseFromSliceLeaky(std.json.Value, arena, arguments[1], .{});
    }
    const pipeline = try pipeline_parse(arena, pipeline_value);
    const opened = try store.open_for_command(arena, io, arguments[0]);
    defer opened.close();
    var buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;
    const total = answer(&opened.connection, arena, io, pipeline, branch, show, out) catch |err| {
        std.debug.print("error: {s}\n", .{opened.connection.failure.text()});
        return err;
    };
    try stdout.interface.flush();
    return if (total > 0) 0 else 1;
}

const testing = std.testing;

test "pipelines: with_last, with_next and timeouts, set operations, narrow, through" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 1 }, &failure);
    defer database.close();
    var connection = try database.connect(&failure);
    defer connection.close();
    try connection.exec(
        \\CREATE TABLE timeline_events AS SELECT 0::UINTEGER AS timeline, seq::UBIGINT AS seq,
        \\    seq::UBIGINT * 1000000000 AS vtime_ns, event::JSON AS event FROM (VALUES
        \\    (0, '{"event":"fault","details":{"kind":"partition"}}'),
        \\    (1, '{"event":"request","details":{"ok":false}}'),
        \\    (2, '{"event":"fault","details":{"kind":"pause"}}'),
        \\    (3, '{"event":"request","details":{"ok":true}}'),
        \\    (4, '{"event":"request","details":{"ok":true}}')
        \\) t(seq, event);
    );
    const Check = struct { []const u8, []const u8 };
    const checks = [_]Check{
        // Failed requests whose last fault was a partition.
        .{
            \\[{"filter": "event=request details.ok=false"},
            \\ {"with_last": {"fault": "event=fault"}},
            \\ {"filter": "last_fault.event.details.kind=partition"}]
            ,
            \\{"branch":0,"index":1,"vtime_ns":1000000000,"event":{"event":"request",
            ++
                \\"details":{"ok":false},"last_fault":{"vtime_ns":0,"seq":0,
            ++
                \\"event":{"event":"fault",
            ++
                \\"details":{"kind":"partition"}}}}}
                \\
        },
        // After each fault, the next successful request (or a timeout: 2 s later is past 1.5 s).
        .{
            \\[{"filter": "event=fault"},
            \\ {"with_next": {"ok": "event=request details.ok=true"}, "timeout": 1.5},
            \\ {"narrow": ["with_next_type", "last_event.details.kind"]}]
            ,
            \\{"branch":0,"index":0,"vtime_ns":1500000000,"event":{"with_next_type":"timeout",
            ++
                \\"last_event":{"details":{"kind":"partition"}}}}
                \\{"branch":0,"index":3,"vtime_ns":3000000000,"event":{"with_next_type":"ok",
            ++
                \\"last_event":{"details":{"kind":"pause"}}}}
                \\
        },
        // Set operations: requests minus the failed ones, plus faults, without the pause.
        .{
            \\[{"filter": "event=request"},
            \\ {"difference": [{"filter": "details.ok=false"}]},
            \\ {"union": [[{"filter": "event=fault"}]]},
            \\ {"intersect": [[{"exclude": "details.kind=pause"}]]},
            \\ {"narrow": ["event"]}]
            ,
            \\{"branch":0,"index":0,"vtime_ns":0,"event":{"event":"fault"}}
            \\{"branch":0,"index":3,"vtime_ns":3000000000,"event":{"event":"request"}}
            \\{"branch":0,"index":4,"vtime_ns":4000000000,"event":{"event":"request"}}
            \\
        },
        // Any program as map: every other event, renamed.
        .{
            \\[{"filter": "event=request"},
            \\ {"through": "sed -n '1p;3p' | sed 's/\"request\"/\"call\"/'"},
            \\ {"narrow": ["event"]}]
            ,
            \\{"branch":0,"index":1,"vtime_ns":1000000000,"event":{"event":"call"}}
            \\{"branch":0,"index":4,"vtime_ns":4000000000,"event":{"event":"call"}}
            \\
        },
    };
    for (checks) |check| {
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, check[0], .{});
        const pipeline = try pipeline_parse(arena, value);
        // A connection per request, as serve's: the sets are its temporary tables.
        var request = try database.connect(&failure);
        defer request.close();
        var out: std.Io.Writer.Allocating = .init(arena);
        _ = answer(&request, arena, testing.io, pipeline, null, .{
            .limit = 100,
            .output = .events,
            .json = true,
        }, &out.writer) catch |err| {
            std.debug.print("{s}\n{s}\n", .{ check[0], request.failure.text() });
            return err;
        };
        testing.expectEqualStrings(check[1], out.written()) catch |err| {
            std.debug.print("{s}\n", .{check[0]});
            return err;
        };
    }
}
