// SPDX-License-Identifier: MIT
//! `determinismo query`: searching the events of a multiverse, as Antithesis's Logs Explorer
//! search and event sets do (docs/ANTITHESIS.md).
//!
//!   determinismo query <events-dir> '<condition>'
//!       [--preceded-by '<condition>' [--within <s>]] [--not-preceded-by ...]
//!       [--followed-by '<condition>' [--within <s>]] [--not-followed-by ...]
//!       [--branch <n>] [--up-to-vtime <s>] [--limit <n>] [--count | --branches] [--json]
//!
//! A query runs on the run's events database (store.zig): a condition is SQL over each
//! timeline's events (`timeline_events`), and temporal conditions are window functions over the
//! timeline. The same conditions are matched live where events are not stored yet: a replay's
//! moment `--until` (vm.zig).
//!
//! A condition is terms joined by `and` and `or` (`or` binds loosest). A term is `path op value`
//! over the event's JSON (`event=fault`, `details.kind=partition`, `output.text~refused`,
//! `assert.condition=false`), or over `vtime` (seconds), `branch` and `seq`. Operators: `=`,
//! `!=`, `~` (contains), `!~`, `=~` (matches a regular expression, see regex.zig), `!=~`, `<`,
//! `<=`, `>`, `>=`, `?` (present), `!?` (absent). Values are words or "quoted strings" (where a
//! backslash escapes the next character: `\\d` for a regex's `\d`); numbers and booleans compare
//! as such. Events without the field never match, negative operators included (as in
//! Antithesis).
//!
//! Temporal conditions look in the same timeline: before the event (preceded by), or after it
//! (followed by), within a window of virtual seconds if given. Every match comes with its moment
//! (`--from-branch <n> --from-vtime-ms <ms>`), to branch from or look at.
const std = @import("std");
const assert = std.debug.assert;
const Regex = @import("regex.zig").Regex;
const duckdb = @import("duckdb.zig");
const store = @import("store.zig");

const terms_max = 32;
const temporal_max = 8;

pub const Operator = enum {
    matches,
    not_matches,
    equal,
    not_equal,
    contains,
    excludes,
    less,
    less_equal,
    greater,
    greater_equal,
    present,
    absent,
};

pub const Term = struct {
    path: []const []const u8,
    operator: Operator,
    value: []const u8 = "",
    /// The compiled pattern of `=~` and `!=~` (it checks the pattern, and matches live).
    regex: ?*const Regex = null,
};

/// An event as it happens (a replay's, before any database has it): its JSON and its place.
pub const Event = struct { value: std.json.Value, vtime_ns: u64, branch: u32 = 0, seq: u64 };

/// Alternatives (or) of conjunctions (and).
pub const Condition = struct {
    alternatives: []const []const Term,

    /// Whether the event matches, live.
    pub fn matches(condition: *const Condition, event: Event) bool {
        for (condition.alternatives) |terms| {
            const all = for (terms) |*term| {
                if (!term_matches(term, event)) break false;
            } else true;
            if (all) return true;
        }
        return false;
    }

    /// Whether the event's line has the text some alternative needs: a term `path=value` or
    /// `path~value` needs `value` in it (as JSON writes strings, numbers and booleans, when it
    /// has no characters JSON escapes); other terms need nothing. Most lines are told apart on
    /// it, without parsing their JSON.
    pub fn may_match(condition: *const Condition, line: []const u8) bool {
        for (condition.alternatives) |terms| {
            const possible = for (terms) |*term| {
                if (term_needs(term)) |needed| {
                    if (std.mem.indexOf(u8, line, needed) == null) break false;
                }
            } else true;
            if (possible) return true;
        }
        return false;
    }

    /// The condition as SQL: a boolean (never NULL) over a row with the columns `event` (JSON),
    /// `vtime_ns`, `timeline` and `seq`; with `indexed`, also store.indexed_paths' columns (a
    /// row of `timeline_events`), read instead of the JSON.
    pub fn sql(condition: *const Condition, out: *std.Io.Writer, indexed: bool) !void {
        try out.writeAll("(");
        for (condition.alternatives, 0..) |terms, alternative| {
            if (alternative > 0) try out.writeAll(" OR ");
            try out.writeAll("(");
            for (terms, 0..) |*term, at| {
                if (at > 0) try out.writeAll(" AND ");
                try term_sql(term, out, indexed);
            }
            try out.writeAll(")");
        }
        try out.writeAll(")");
    }
};

fn term_needs(term: *const Term) ?[]const u8 {
    if (term.operator != .equal and term.operator != .contains) return null;
    if (pseudo_of(term.path) != null) return null; // Not in the event's JSON.
    if (term.value.len == 0) return null;
    // A number equals others written otherwise (300 and 300.0; 1 and true).
    const number = if (std.fmt.parseFloat(f64, term.value)) |_| true else |_| false;
    if (term.operator == .equal and number) return null;
    for (term.value) |byte| if (byte == '"' or byte == '\\' or byte < 0x20 or byte >= 0x80) {
        return null; // Written escaped.
    };
    return term.value;
}

/// Fields that are the event's place, not its JSON.
const Pseudo = enum { vtime, branch, seq };

fn pseudo_of(path: []const []const u8) ?Pseudo {
    if (path.len != 1) return null;
    return std.meta.stringToEnum(Pseudo, path[0]);
}

pub fn parse(arena: std.mem.Allocator, text: []const u8) !Condition {
    var tokens = try tokenize(arena, text);
    var alternatives: std.ArrayList([]const Term) = .empty;
    var terms: std.ArrayList(Term) = .empty;
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, "or")) {
            if (terms.items.len == 0) return error.EmptyAlternative;
            try alternatives.append(arena, try terms.toOwnedSlice(arena));
            continue;
        }
        if (std.mem.eql(u8, token, "and")) continue;
        if (terms.items.len == terms_max) return error.TooManyTerms;
        try terms.append(arena, try term_parse(arena, token, &tokens));
    }
    if (terms.items.len == 0) return error.EmptyCondition;
    try alternatives.append(arena, try terms.toOwnedSlice(arena));
    return .{ .alternatives = alternatives.items };
}

const operators = [_]struct { []const u8, Operator }{
    // Longest first, so that `<=` is not read as `<`.
    .{ "!=~", .not_matches }, .{ "=~", .matches },
    .{ "!=", .not_equal },    .{ "!~", .excludes },
    .{ "<=", .less_equal },   .{ ">=", .greater_equal },
    .{ "!?", .absent },       .{ "=", .equal },
    .{ "~", .contains },      .{ "<", .less },
    .{ ">", .greater },       .{ "?", .present },
};

/// `path op value`, written as one token (`a.b=c`) or as several (`a.b = "c d"`).
fn term_parse(arena: std.mem.Allocator, first: []const u8, tokens: *Tokens) !Term {
    for (first, 0..) |_, at| {
        for (operators) |entry| {
            if (!std.mem.startsWith(u8, first[at..], entry[0])) continue;
            const path_text = first[0..at];
            if (path_text.len == 0) return error.TermWithoutPath;
            var value = first[at + entry[0].len ..];
            if (value_needed(entry[1]) and value.len == 0) {
                value = tokens.next() orelse return error.TermWithoutValue;
            }
            return term_make(arena, try path_split(arena, path_text), entry[1], value);
        }
    }
    // The operator in the next token: `path = value`.
    const operator_text = tokens.next() orelse return error.TermWithoutOperator;
    for (operators) |entry| {
        if (!std.mem.eql(u8, operator_text, entry[0])) continue;
        const value = if (value_needed(entry[1]))
            tokens.next() orelse return error.TermWithoutValue
        else
            "";
        return term_make(arena, try path_split(arena, first), entry[1], value);
    }
    return error.UnknownOperator;
}

fn term_make(
    arena: std.mem.Allocator,
    path: []const []const u8,
    operator: Operator,
    value: []const u8,
) !Term {
    var term = Term{ .path = path, .operator = operator, .value = value };
    if (operator == .matches or operator == .not_matches) {
        const regex = try arena.create(Regex);
        regex.* = try Regex.compile(arena, value);
        term.regex = regex;
    }
    return term;
}

fn value_needed(operator: Operator) bool {
    return operator != .present and operator != .absent;
}

fn path_split(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var pieces = std.mem.splitScalar(u8, text, '.');
    while (pieces.next()) |piece| {
        if (piece.len == 0) return error.BadPath;
        try parts.append(arena, piece);
    }
    return parts.items;
}

const Tokens = struct {
    items: []const []const u8,
    index: usize = 0,

    fn next(tokens: *Tokens) ?[]const u8 {
        if (tokens.index == tokens.items.len) return null;
        tokens.index += 1;
        return tokens.items[tokens.index - 1];
    }
};

/// Words and "quoted strings" (backslash escapes the next character); a quote may follow an
/// operator in the same word (`output.text~"connection refused"`).
fn tokenize(arena: std.mem.Allocator, text: []const u8) !Tokens {
    var items: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var quoted = false;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (quoted) {
            if (byte == '"') {
                quoted = false;
            } else if (byte == '\\' and index + 1 < text.len) {
                index += 1;
                try word.append(arena, text[index]);
            } else try word.append(arena, byte);
            continue;
        }
        switch (byte) {
            ' ', '\t', '\n' => if (in_word) {
                try items.append(arena, try word.toOwnedSlice(arena));
                in_word = false;
            },
            '"' => {
                quoted = true;
                in_word = true;
            },
            else => {
                try word.append(arena, byte);
                in_word = true;
            },
        }
    }
    if (quoted) return error.UnterminatedQuote;
    if (in_word) try items.append(arena, try word.toOwnedSlice(arena));
    return .{ .items = items.items };
}

fn term_matches(term: *const Term, event: Event) bool {
    const field = field_get(event, term.path);
    switch (term.operator) {
        .present => return field != null,
        .absent => return field == null,
        else => {},
    }
    // Events without the field never match, negative operators included (as in Antithesis).
    const value = field orelse return false;
    return switch (term.operator) {
        .equal => equals(value, term.value),
        .not_equal => !equals(value, term.value),
        .matches => if (text_of(value)) |text| term.regex.?.matches(text) else false,
        .not_matches => if (text_of(value)) |text| !term.regex.?.matches(text) else false,
        .contains => contains(value, term.value) orelse false,
        .excludes => if (contains(value, term.value)) |found| !found else false,
        .less, .less_equal, .greater, .greater_equal => compare(value, term.operator, term.value),
        .present, .absent => unreachable,
    };
}

const Field = union(enum) { json: std.json.Value, number: f64 };

fn field_get(event: Event, path: []const []const u8) ?Field {
    assert(path.len > 0);
    if (pseudo_of(path)) |pseudo| return .{ .number = switch (pseudo) {
        .vtime => @as(f64, @floatFromInt(event.vtime_ns)) / std.time.ns_per_s,
        .branch => @floatFromInt(event.branch),
        .seq => @floatFromInt(event.seq),
    } };
    var value = event.value;
    for (path) |key| {
        if (value != .object) return null;
        value = value.object.get(key) orelse return null;
    }
    return .{ .json = value };
}

fn contains(field: Field, wanted: []const u8) ?bool {
    const text = text_of(field) orelse return null;
    return std.mem.indexOf(u8, text, wanted) != null;
}

fn text_of(field: Field) ?[]const u8 {
    return switch (field) {
        .json => |value| if (value == .string) value.string else null,
        .number => null,
    };
}

fn number_of(field: Field) ?f64 {
    return switch (field) {
        .number => |number| number,
        .json => |value| switch (value) {
            .integer => |integer| @floatFromInt(integer),
            .float => |float| float,
            .number_string => |text| std.fmt.parseFloat(f64, text) catch null,
            .bool => |flag| if (flag) 1 else 0, // As Antithesis coerces.
            else => null,
        },
    };
}

fn equals(field: Field, expected: []const u8) bool {
    if (text_of(field)) |text| return std.mem.eql(u8, text, expected);
    if (field == .json and field.json == .bool) {
        if (std.mem.eql(u8, expected, "true")) return field.json.bool;
        if (std.mem.eql(u8, expected, "false")) return !field.json.bool;
    }
    if (field == .json and field.json == .null) return std.mem.eql(u8, expected, "null");
    const number = number_of(field) orelse return false;
    const wanted = std.fmt.parseFloat(f64, expected) catch return false;
    return number == wanted; // 17.0 matches 17.
}

fn compare(field: Field, operator: Operator, expected: []const u8) bool {
    const number = number_of(field) orelse return false;
    const wanted = std.fmt.parseFloat(f64, expected) catch return false;
    return switch (operator) {
        .less => number < wanted,
        .less_equal => number <= wanted,
        .greater => number > wanted,
        .greater_equal => number >= wanted,
        else => unreachable,
    };
}

// SQL: each term as the live matcher judges it, NULL-free (a missing field matches nothing).

const json_numbers = "('BIGINT', 'UBIGINT', 'HUGEINT', 'DOUBLE')";

/// How SQL reads a term's field: its text (`->>`) and its JSON type (NULL when absent).
const Fields = struct { text: []const u8, type: []const u8 };

/// The columns of an indexed path (store.indexed_paths), when the row has them.
fn indexed_fields(path: []const []const u8, indexed: bool) ?Fields {
    if (!indexed) return null;
    entries: for (store.indexed_paths) |entry| {
        var keys = std.mem.splitScalar(u8, entry.path, '.');
        for (path) |key| {
            const expected = keys.next() orelse continue :entries;
            if (!std.mem.eql(u8, key, expected)) continue :entries;
        }
        if (keys.next() != null) continue;
        return .{ .text = entry.column, .type = entry.type_column };
    }
    return null;
}

fn term_sql(term: *const Term, out: *std.Io.Writer, indexed: bool) !void {
    if (pseudo_of(term.path)) |pseudo| return pseudo_sql(term, pseudo, out);
    var text_buffer: [1200]u8 = undefined;
    var type_buffer: [1200]u8 = undefined;
    const fields: Fields = indexed_fields(term.path, indexed) orelse fields: {
        var path_buffer: [1024]u8 = undefined;
        var path_writer: std.Io.Writer = .fixed(&path_buffer);
        try path_writer.writeAll("$");
        for (term.path) |key| {
            // A key with a quote or backslash cannot be written in a JSON path.
            for (key) |byte| if (byte == '"' or byte == '\\') return error.BadPath;
            try path_writer.print(".\"{s}\"", .{key});
        }
        var literal_buffer: [1100]u8 = undefined;
        var literal_writer: std.Io.Writer = .fixed(&literal_buffer);
        try string_literal(&literal_writer, path_writer.buffered());
        const path = literal_writer.buffered();
        break :fields .{
            .text = try std.fmt.bufPrint(&text_buffer, "(event ->> {s})", .{path}),
            .type = try std.fmt.bufPrint(&type_buffer, "json_type(event, {s})", .{path}),
        };
    };
    const text = fields.text;
    const kind = fields.type;
    // Columns are cheap to read; the JSON is not: most events are told apart by their text.
    const needed = if (indexed_fields(term.path, indexed) == null) term_needs(term) else null;
    if (needed) |value| {
        try out.writeAll("(contains(event::VARCHAR, ");
        try string_literal(out, value);
        try out.writeAll(") AND ");
    } else try out.writeAll("(");
    switch (term.operator) {
        .present => try out.print("{s} IS NOT NULL", .{kind}),
        .absent => try out.print("{s} IS NULL", .{kind}),
        .equal => try equal_sql(term.value, fields, out),
        .not_equal => {
            try out.print("{s} IS NOT NULL AND NOT ", .{kind});
            try equal_sql(term.value, fields, out);
        },
        .contains, .excludes => {
            try out.print("coalesce({s} = 'VARCHAR' AND {s}contains({s}, ", .{
                kind, if (term.operator == .excludes) "NOT " else "", text,
            });
            try string_literal(out, term.value);
            try out.writeAll("), false)");
        },
        .matches, .not_matches => {
            try out.print("coalesce({s} = 'VARCHAR' AND {s}regexp_matches({s}, ", .{
                kind, if (term.operator == .not_matches) "NOT " else "", text,
            });
            try string_literal(out, term.value);
            try out.writeAll("), false)");
        },
        .less, .less_equal, .greater, .greater_equal => {
            const wanted = std.fmt.parseFloat(f64, term.value) catch {
                try out.writeAll("false)");
                return;
            };
            try out.print("coalesce((CASE WHEN {s} IN {s} THEN TRY_CAST({s} AS DOUBLE) " ++
                "WHEN {s} = 'BOOLEAN' THEN CASE {s} WHEN 'true' THEN 1.0 ELSE 0.0 END END) " ++
                "{s} {e}, false)", .{
                kind, json_numbers, text, kind, text, comparison(term.operator), wanted,
            });
        },
    }
    try out.writeAll(")");
}

/// `=` as the live matcher has it: a string by its text; a boolean by `true`, `false`, or as 1
/// and 0; null by `null`; a number by its value (17.0 is 17).
fn equal_sql(value: []const u8, fields: Fields, out: *std.Io.Writer) !void {
    const number = std.fmt.parseFloat(f64, value) catch null;
    const text = fields.text;
    try out.print("coalesce(CASE {s} WHEN 'VARCHAR' THEN {s} = ", .{ fields.type, text });
    try string_literal(out, value);
    try out.writeAll(" WHEN 'BOOLEAN' THEN ");
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) {
        try out.print("{s} = '{s}'", .{ text, value });
    } else if (number) |wanted| {
        try out.print("(CASE {s} WHEN 'true' THEN 1.0 ELSE 0.0 END) = {e}", .{ text, wanted });
    } else try out.writeAll("false");
    const null_equal = std.mem.eql(u8, value, "null");
    try out.print(" WHEN 'NULL' THEN {s}", .{if (null_equal) "true" else "false"});
    if (number) |wanted| {
        for ([_][]const u8{ "BIGINT", "UBIGINT", "HUGEINT", "DOUBLE" }) |json_number| {
            try out.print(" WHEN '{s}' THEN TRY_CAST({s} AS DOUBLE) = {e}", .{
                json_number, text, wanted,
            });
        }
    }
    try out.writeAll(" ELSE false END, false)");
}

fn pseudo_sql(term: *const Term, pseudo: Pseudo, out: *std.Io.Writer) !void {
    const column = switch (pseudo) {
        .vtime => "(vtime_ns / 1e9)",
        .branch => "timeline",
        .seq => "seq",
    };
    const wanted = std.fmt.parseFloat(f64, term.value) catch null;
    switch (term.operator) {
        .present => try out.writeAll("true"),
        // A number has no text: no match, as live.
        .absent, .contains, .excludes, .matches, .not_matches => try out.writeAll("false"),
        .equal => if (wanted) |number| {
            try out.print("({s}::DOUBLE = {e})", .{ column, number });
        } else try out.writeAll("false"),
        .not_equal => if (wanted) |number| {
            try out.print("({s}::DOUBLE <> {e})", .{ column, number });
        } else try out.writeAll("true"),
        .less, .less_equal, .greater, .greater_equal => if (wanted) |number| {
            try out.print("({s}::DOUBLE {s} {e})", .{ column, comparison(term.operator), number });
        } else try out.writeAll("false"),
    }
}

fn comparison(operator: Operator) []const u8 {
    return switch (operator) {
        .less => "<",
        .less_equal => "<=",
        .greater => ">",
        .greater_equal => ">=",
        else => unreachable,
    };
}

/// A string as a SQL literal.
pub fn string_literal(out: *std.Io.Writer, text: []const u8) !void {
    try out.writeByte('\'');
    for (text) |byte| {
        if (byte == '\'') try out.writeByte('\'');
        try out.writeByte(byte);
    }
    try out.writeByte('\'');
}

/// A temporal condition: some event matching `condition` before (or after) the event, within
/// `window_ns` if set; or, negated, none.
pub const Temporal = struct {
    condition: Condition,
    direction: enum { before, after },
    negated: bool,
    window_ns: ?u64 = null,
};

pub const Output = enum { events, count, branches };

pub const Query = struct {
    condition: Condition,
    temporals: []const Temporal = &.{},
    only_branch: ?u32 = null,
    up_to_ns: ?u64 = null,
    limit: u64 = std.math.maxInt(u64),
    output: Output = .events,
};

/// A query as JSON, for the HTTP API and agents (MCP): the command's options as fields.
pub const Request = struct {
    condition: []const u8,
    preceded_by: ?[]const u8 = null,
    not_preceded_by: ?[]const u8 = null,
    followed_by: ?[]const u8 = null,
    not_followed_by: ?[]const u8 = null,
    /// Seconds of virtual time, for every temporal condition.
    within: ?f64 = null,
    branch: ?u32 = null,
    up_to_vtime: ?f64 = null,
    limit: u64 = 100,
    output: Output = .events,
};

pub fn query_of(arena: std.mem.Allocator, request: Request) !Query {
    var temporals: std.ArrayList(Temporal) = .empty;
    const window: ?u64 = if (request.within) |seconds| try seconds_to_ns_float(seconds) else null;
    const fields = [_]struct { ?[]const u8, @FieldType(Temporal, "direction"), bool }{
        .{ request.preceded_by, .before, false }, .{ request.not_preceded_by, .before, true },
        .{ request.followed_by, .after, false },  .{ request.not_followed_by, .after, true },
    };
    for (fields) |field| {
        const text = field[0] orelse continue;
        try temporals.append(arena, .{
            .condition = try parse(arena, text),
            .direction = field[1],
            .negated = field[2],
            .window_ns = window,
        });
    }
    return .{
        .condition = try parse(arena, request.condition),
        .temporals = temporals.items,
        .only_branch = request.branch,
        .up_to_ns = if (request.up_to_vtime) |seconds| try seconds_to_ns_float(seconds) else null,
        .limit = request.limit,
        .output = request.output,
    };
}

/// The query's matches as SQL (`timeline`, `seq`, `vtime_ns`, `event`): the condition over each
/// timeline's events; each temporal condition as the nearest earlier (or later) matching event
/// of the timeline, a window function.
pub fn matches_sql(arena: std.mem.Allocator, query: *const Query) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("WITH flagged AS (SELECT timeline, seq, vtime_ns, event, ");
    try query.condition.sql(w, true);
    try w.writeAll(" AS hit");
    for (query.temporals, 0..) |*temporal, index| {
        try w.writeAll(switch (temporal.direction) {
            .before => ", max(CASE WHEN ",
            .after => ", min(CASE WHEN ",
        });
        try temporal.condition.sql(w, true);
        try w.print(" THEN vtime_ns END) OVER (PARTITION BY timeline ORDER BY vtime_ns, seq {s})" ++
            " AS near_{d}", .{
            switch (temporal.direction) {
                .before => "ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING",
                .after => "ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING",
            },
            index,
        });
    }
    try w.writeAll(" FROM timeline_events");
    if (query.only_branch) |branch| try w.print(" WHERE timeline = {d}", .{branch});
    try w.writeAll(") SELECT timeline, seq, vtime_ns, event FROM flagged WHERE hit");
    if (query.up_to_ns) |end| try w.print(" AND vtime_ns <= {d}", .{end});
    for (query.temporals, 0..) |*temporal, index| {
        const negation = if (temporal.negated) "NOT " else "";
        try w.print(" AND {s}(near_{d} IS NOT NULL", .{ negation, index });
        if (temporal.window_ns) |window| try w.print(" AND {s} <= {d}", .{
            switch (temporal.direction) {
                .before => try std.fmt.allocPrint(arena, "vtime_ns - near_{d}", .{index}),
                .after => try std.fmt.allocPrint(arena, "near_{d} - vtime_ns", .{index}),
            },
            window,
        });
        try w.writeAll(")");
    }
    return out.written();
}

/// Runs `query` on a run's events database; writes its answer as JSON lines (the HTTP API and
/// agents) or as text, and returns how many it found.
pub fn answer(
    connection: *duckdb.Connection,
    arena: std.mem.Allocator,
    query: *const Query,
    out: *std.Io.Writer,
    json: bool,
) !u64 {
    const matched = try matches_sql(arena, query);
    switch (query.output) {
        .events => {
            const sql = try std.fmt.allocPrintSentinel(arena,
                \\{s} ORDER BY timeline, vtime_ns, seq LIMIT {d}
            , .{ matched, @min(query.limit, std.math.maxInt(i64)) }, 0);
            const Row = struct { branch: u32, seq: u64, vtime_ns: u64, event: []const u8 };
            const rows = try connection.rows(Row, arena, sql, .{});
            for (rows) |row| {
                if (json) {
                    const format = "{{\"branch\":{d},\"seq\":{d},\"vtime_ns\":{d}," ++
                        "\"event\":{s}}}\n";
                    try out.print(format, .{
                        row.branch, row.seq, row.vtime_ns, row.event,
                    });
                } else {
                    const format = "branch {d} vtime {d}.{d:0>6}s  {s}  " ++
                        "(--from-branch {d} --from-vtime-ms {d})\n";
                    try out.print(format, .{
                        row.branch,                              row.vtime_ns / std.time.ns_per_s,
                        row.vtime_ns % std.time.ns_per_s / 1000, row.event,
                        row.branch,                              row.vtime_ns / std.time.ns_per_ms,
                    });
                }
            }
            return rows.len;
        },
        .branches => {
            const sql = try std.fmt.allocPrintSentinel(arena,
                \\SELECT timeline, count(*), min(vtime_ns) FROM ({s})
                \\GROUP BY timeline ORDER BY timeline
            , .{matched}, 0);
            const Row = struct { branch: u32, matches: u64, first_vtime_ns: u64 };
            const rows = try connection.rows(Row, arena, sql, .{});
            for (rows) |row| {
                if (json) {
                    try out.print("{{\"branch\":{d},\"matches\":{d},\"first_vtime_ns\":{d}}}\n", .{
                        row.branch, row.matches, row.first_vtime_ns,
                    });
                } else {
                    const ms = row.first_vtime_ns / std.time.ns_per_ms;
                    try out.print("branch {d}: {d} matches, first at vtime {d}ms " ++
                        "(--from-branch {d} " ++
                        "--from-vtime-ms {d})\n", .{ row.branch, row.matches, ms, row.branch, ms });
                }
            }
            return rows.len;
        },
        .count => {
            const scope = if (query.only_branch) |branch|
                try std.fmt.allocPrint(arena, " WHERE branch = {d}", .{branch})
            else
                "";
            const sql = try std.fmt.allocPrintSentinel(arena,
                \\SELECT (SELECT count(*) FROM ({s})), (SELECT count(DISTINCT timeline) FROM ({s})),
                \\    (SELECT count(*) FROM timelines{s})
            , .{ matched, matched, scope }, 0);
            const Row = struct { events: u64, branches: u64, timelines: u64 };
            const row = (try connection.row(Row, arena, sql, .{})).?;
            if (json) {
                try out.print("{{\"events\":{d},\"branches\":{d},\"timelines\":{d}}}\n", .{
                    row.events, row.branches, row.timelines,
                });
            } else {
                try out.print("{d} events in {d} of {d} timelines\n", .{
                    row.events, row.branches, row.timelines,
                });
            }
            return row.events;
        },
    }
}

fn seconds_to_ns_float(seconds: f64) !u64 {
    if (seconds < 0) return error.NegativeTime;
    return @trunc(seconds * std.time.ns_per_s);
}

/// The command: arguments after `query`. Exit status 0 when something matched, 1 when nothing
/// did (as grep), 2 on usage errors.
pub fn run(arena: std.mem.Allocator, io: std.Io, arguments: []const [:0]const u8) !u8 {
    if (arguments.len < 2) return error.Usage;
    const directory = arguments[0];
    // `query <dir> '{"condition": ...}'`: the HTTP API's request, and its answer.
    const api = arguments.len == 2 and std.mem.startsWith(u8, arguments[1], "{");
    var json = api;
    const query = if (api) blk: {
        const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
        const asked = try std.json.parseFromSliceLeaky(Request, arena, arguments[1], options);
        break :blk try query_of(arena, asked);
    } else try arguments_parse(arena, arguments[1..], &json);
    const opened = try store.open_for_command(arena, io, directory);
    defer opened.close();
    var buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const found = answer(&opened.connection, arena, &query, &stdout.interface, json) catch |err| {
        std.debug.print("error: {s}\n", .{opened.connection.failure.text()});
        return err;
    };
    try stdout.interface.flush();
    return if (found > 0) 0 else 1;
}

fn arguments_parse(arena: std.mem.Allocator, arguments: []const [:0]const u8, json: *bool) !Query {
    var query = Query{ .condition = try parse(arena, arguments[0]) };
    var temporals: std.ArrayList(Temporal) = .empty;
    var index: usize = 1;
    while (index < arguments.len) : (index += 1) {
        const flag = arguments[index];
        const eql = std.mem.eql;
        if (eql(u8, flag, "--count")) {
            query.output = .count;
        } else if (eql(u8, flag, "--branches")) {
            query.output = .branches;
        } else if (eql(u8, flag, "--json")) {
            json.* = true;
        } else {
            index += 1;
            if (index == arguments.len) return error.Usage;
            try option_parse(arena, &query, &temporals, flag, arguments[index]);
        }
    }
    query.temporals = temporals.items;
    return query;
}

const temporal_flags = [_]struct { []const u8, @FieldType(Temporal, "direction"), bool }{
    .{ "--preceded-by", .before, false }, .{ "--not-preceded-by", .before, true },
    .{ "--followed-by", .after, false },  .{ "--not-followed-by", .after, true },
};

fn option_parse(
    arena: std.mem.Allocator,
    query: *Query,
    temporals: *std.ArrayList(Temporal),
    flag: []const u8,
    value: []const u8,
) !void {
    const eql = std.mem.eql;
    for (temporal_flags) |kind| {
        if (!eql(u8, flag, kind[0])) continue;
        if (temporals.items.len == temporal_max) return error.TooManyTemporalConditions;
        try temporals.append(arena, .{
            .condition = try parse(arena, value),
            .direction = kind[1],
            .negated = kind[2],
        });
        return;
    }
    if (eql(u8, flag, "--within")) {
        if (temporals.items.len == 0) return error.WithinWithoutTemporal;
        temporals.items[temporals.items.len - 1].window_ns = try seconds_to_ns(value);
    } else if (eql(u8, flag, "--branch")) {
        query.only_branch = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--up-to-vtime")) {
        query.up_to_ns = try seconds_to_ns(value);
    } else if (eql(u8, flag, "--limit")) {
        query.limit = try std.fmt.parseInt(u64, value, 10);
    } else return error.Usage;
}

fn seconds_to_ns(text: []const u8) !u64 {
    const seconds = try std.fmt.parseFloat(f64, text);
    if (seconds < 0) return error.NegativeTime;
    return @trunc(seconds * std.time.ns_per_s);
}

const testing = std.testing;

/// `timeline_events` for a test: the rows of `raw`, with the indexed paths' columns.
fn indexed_table(arena: std.mem.Allocator) ![:0]const u8 {
    const create = "CREATE TABLE timeline_events AS SELECT *{s} FROM raw";
    return std.fmt.allocPrintSentinel(arena, create, .{try store.indexed_select(arena)}, 0);
}

fn event_test(arena: std.mem.Allocator, vtime_ns: u64, json: []const u8) !Event {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    return .{ .value = value, .vtime_ns = vtime_ns, .seq = 1 };
}

test "a condition skips lines without the text it needs" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const condition = try parse(arena, "event=fault or output.text~refused");
    try testing.expect(condition.may_match("{\"event\":\"fault\"}"));
    try testing.expect(condition.may_match("{\"output\":{\"text\":\"refused\"}}"));
    try testing.expect(!condition.may_match("{\"output\":{\"text\":\"fine\"}}"));
    const numeric = try parse(arena, "vtime>2 and branch=3");
    try testing.expect(numeric.may_match("{}"));
}

const condition_checks = [_]struct { []const u8, bool, bool }{
    .{ "event=fault", true, false },
    .{ "event=fault details.kind=partition", true, false },
    .{ "event = fault and details.node != redis", false, false },
    .{ "details.duration_ns>=300 vtime<3", true, false },
    .{ "details.duration_ns=300.0", true, false },
    .{ "details.healed=1 details.healed=true", true, false },
    .{ "details.until=null", true, false },
    .{ "output.text~\"connection refused\"", false, true },
    .{ "output.text!~refused", false, false },
    .{ "output.text=~\"^conn.*re(f|d)used\"", false, true },
    .{ "output.text!=~\"(?i)REFUSED\"", false, false },
    .{ "event=fault or output.stream=stderr", true, true },
    .{ "output?", false, true },
    .{ "output!?", true, false },
    .{ "seq=1 branch=0 vtime>=2.5", true, true },
    .{ "details.kind!=partition", false, false },
    .{ "details.node=redis event!=decision", true, false },
    .{ "details.kind~arti details.node?", true, false },
};
const condition_events = [_]struct { u64, []const u8 }{
    .{
        2_500_000_000,
        \\{"event":"fault","details":{"kind":"partition","node":"redis","duration_ns":300,
        ++
            \\"healed":true,"until":null}}
    },
    .{
        3_000_000_000,
        \\{"output":{"source":"bank","stream":"stderr","text":"connection refused by redis"}}
    },
};

test "conditions: paths, operators, and/or, quoted values" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fault = try event_test(arena, condition_events[0][0], condition_events[0][1]);
    const output = try event_test(arena, condition_events[1][0], condition_events[1][1]);
    for (condition_checks) |check| {
        const condition = try parse(arena, check[0]);
        testing.expectEqual(check[1], condition.matches(fault)) catch |err| {
            std.debug.print("live, fault: {s}\n", .{check[0]});
            return err;
        };
        testing.expectEqual(check[2], condition.matches(output)) catch |err| {
            std.debug.print("live, output: {s}\n", .{check[0]});
            return err;
        };
    }
}

test "conditions as SQL agree with the live matcher" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 1 }, &failure);
    defer database.close();
    var connection = try database.connect(&failure);
    defer connection.close();
    try connection.exec(
        \\CREATE TABLE raw (timeline UINTEGER, seq UBIGINT, vtime_ns UBIGINT, event JSON)
    );
    for (condition_events) |event| {
        const insert = "INSERT INTO raw VALUES (0, 1, {d}, '{s}')";
        const sql = try std.fmt.allocPrintSentinel(arena, insert, .{ event[0], event[1] }, 0);
        try connection.exec(sql);
    }
    // With the indexed paths' columns, as the events database has them.
    try connection.exec(try indexed_table(arena));
    for ([_]bool{ false, true }) |indexed| for (condition_checks) |check| {
        const condition = try parse(arena, check[0]);
        var sql: std.Io.Writer.Allocating = .init(arena);
        try sql.writer.writeAll("SELECT ");
        try condition.sql(&sql.writer, indexed);
        try sql.writer.writeAll(" FROM timeline_events ORDER BY vtime_ns");
        const Row = struct { hit: bool };
        const text = try arena.dupeSentinel(u8, sql.written(), 0);
        const rows = connection.rows(Row, arena, text, .{}) catch |err| {
            std.debug.print("{s}\n{s}\n", .{ sql.written(), connection.failure.text() });
            return err;
        };
        testing.expectEqual(check[1], rows[0].hit) catch |err| {
            std.debug.print("SQL, fault: {s}\n", .{check[0]});
            return err;
        };
        testing.expectEqual(check[2], rows[1].hit) catch |err| {
            std.debug.print("SQL, output: {s}\n", .{check[0]});
            return err;
        };
    };
}

test "temporal: preceded and followed by, within windows" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 1 }, &failure);
    defer database.close();
    var connection = try database.connect(&failure);
    defer connection.close();
    try connection.exec(
        \\CREATE TABLE raw AS SELECT * FROM (VALUES
        \\    (1, 1, 1000000000, '{"event":"fault"}'::JSON),
        \\    (1, 2, 1500000000, '{"event":"ping"}'::JSON),
        \\    (1, 3, 4000000000, '{"event":"error"}'::JSON),
        \\    (2, 1, 1000000000, '{"event":"ping"}'::JSON)
        \\) t(timeline, seq, vtime_ns, event);
        \\CREATE TABLE timelines AS SELECT * FROM (VALUES (1), (2)) t(branch);
    );
    try connection.exec(try indexed_table(arena));
    const checks = [_]struct { Request, []const u8 }{
        // 0.5 s after the fault: within a second; the error, 3 s after, is not.
        .{ .{ .condition = "event!=fault", .preceded_by = "event=fault", .within = 1 }, "1:2 " },
        .{ .{ .condition = "event!=fault", .preceded_by = "event=fault" }, "1:2 1:3 " },
        // Never followed by an error: the error itself, and timeline 2's ping (another timeline).
        .{ .{ .condition = "event?", .not_followed_by = "event=error" }, "1:3 2:1 " },
        .{ .{ .condition = "event=ping", .followed_by = "event=error", .within = 2 }, "" },
        .{ .{ .condition = "event=ping", .followed_by = "event=error", .within = 3 }, "1:2 " },
        .{ .{ .condition = "event=ping", .branch = 2 }, "2:1 " },
        .{ .{ .condition = "event?", .up_to_vtime = 1.2 }, "1:1 2:1 " },
    };
    for (checks) |check| {
        const query = try query_of(arena, check[0]);
        var found: std.Io.Writer.Allocating = .init(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        _ = try answer(&connection, arena, &query, &out.writer, true);
        var lines = std.mem.tokenizeScalar(u8, out.written(), '\n');
        while (lines.next()) |line| {
            const Line = struct { branch: u32, seq: u64 };
            const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
            const parsed = try std.json.parseFromSliceLeaky(Line, arena, line, options);
            try found.writer.print("{d}:{d} ", .{ parsed.branch, parsed.seq });
        }
        testing.expectEqualStrings(check[1], found.written()) catch |err| {
            std.debug.print("{s}\n", .{check[0].condition});
            return err;
        };
    }
    const query = try query_of(arena, .{ .condition = "event=ping", .output = .count });
    var out: std.Io.Writer.Allocating = .init(arena);
    _ = try answer(&connection, arena, &query, &out.writer, true);
    const counted = "{\"events\":2,\"branches\":2,\"timelines\":2}\n";
    try testing.expectEqualStrings(counted, out.written());
}
