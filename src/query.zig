// SPDX-License-Identifier: MIT
//! `determinismo query`: searching the events of a multiverse, as Antithesis's Logs Explorer
//! search and event sets do (docs/ANTITHESIS.md).
//!
//!   determinismo query <events-dir> '<condition>'
//!       [--preceded-by '<condition>' [--within <s>]] [--not-preceded-by ...]
//!       [--followed-by '<condition>' [--within <s>]] [--not-followed-by ...]
//!       [--branch <n>] [--up-to-vtime <s>] [--limit <n>] [--count | --branches] [--json]
//!
//! The directory is what `explore --events-dir` writes: setup.jsonl (shared by every branch),
//! fork.jsonl (when branching from a moment), branch-<n>.jsonl. A timeline is their
//! concatenation, in order: events are totally ordered within it.
//!
//! A condition is terms joined by `and` and `or` (`or` binds loosest). A term is `path op value`
//! over the event's JSON (`event=fault`, `details.kind=partition`, `output.text~refused`,
//! `assert.condition=false`), or over `vtime` (seconds), `branch` and `seq`. Operators: `=`,
//! `!=`, `~` (contains), `!~`, `=~` (matches a regular expression, see regex.zig), `!=~`, `<`,
//! `<=`, `>`, `>=`, `?` (present), `!?` (absent). Values are words or "quoted strings" (where a
//! backslash escapes the next character: `\\d` for a regex's `\d`); numbers and booleans compare
//! as such.
//!
//! Temporal conditions look in the same timeline: before the event (preceded by), or after it
//! (followed by), within a window of virtual seconds if given. Every match comes with its moment
//! (`--from-branch <n> --from-vtime-ms <ms>`), to branch from or look at.
const std = @import("std");
const assert = std.debug.assert;
const Regex = @import("regex.zig").Regex;

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
    /// The compiled pattern of `=~` and `!=~`.
    regex: ?*const Regex = null,
};

/// Alternatives (or) of conjunctions (and).
pub const Condition = struct {
    alternatives: []const []const Term,

    pub fn matches(condition: *const Condition, event: *const Event) bool {
        for (condition.alternatives) |terms| {
            const all = for (terms) |*term| {
                if (!term_matches(term, event)) break false;
            } else true;
            if (all) return true;
        }
        return false;
    }
};

/// One event of a timeline: its JSON, where it happened.
pub const Event = struct {
    branch: u32,
    seq: u64,
    vtime_ns: u64,
    value: std.json.Value,
    line: []const u8,
};

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

fn term_matches(term: *const Term, event: *const Event) bool {
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

fn field_get(event: *const Event, path: []const []const u8) ?Field {
    assert(path.len > 0);
    if (path.len == 1) {
        const eql = std.mem.eql;
        if (eql(u8, path[0], "vtime")) {
            return .{ .number = @as(f64, @floatFromInt(event.vtime_ns)) / std.time.ns_per_s };
        }
        if (eql(u8, path[0], "branch")) return .{ .number = @floatFromInt(event.branch) };
        if (eql(u8, path[0], "seq")) return .{ .number = @floatFromInt(event.seq) };
    }
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

/// A temporal condition: some event matching `condition` before (or after) the event, within
/// `window_ns` if set; or, negated, none.
pub const Temporal = struct {
    condition: Condition,
    direction: enum { before, after },
    negated: bool,
    window_ns: ?u64 = null,
};

/// The events of one timeline, in order.
pub const Timeline = struct { branch: u32, events: []const Event };

/// Reads the timelines of an events directory (all branches, or one).
pub fn timelines_read(
    arena: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    only_branch: ?u32,
) ![]const Timeline {
    const cwd = std.Io.Dir.cwd();
    var prefix: std.ArrayList(Event) = .empty;
    for ([_][]const u8{ "setup.jsonl", "fork.jsonl" }) |name| {
        const path = try std.fs.path.join(arena, &.{ directory, name });
        const source = cwd.readFileAlloc(io, path, arena, .unlimited) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        try events_parse(arena, source, 0, &prefix);
    }
    var branches: std.ArrayList(u32) = .empty;
    var dir = try cwd.openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "branch-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const number = entry.name["branch-".len .. entry.name.len - ".jsonl".len];
        const branch = std.fmt.parseInt(u32, number, 10) catch continue;
        if (only_branch) |wanted| if (branch != wanted) continue;
        try branches.append(arena, branch);
    }
    std.mem.sort(u32, branches.items, {}, std.sort.asc(u32));
    var own: Own = .{ .arena = arena, .io = io, .directory = directory };
    const timelines = try arena.alloc(Timeline, branches.items.len);
    for (branches.items, timelines) |branch, *timeline| {
        const mine = try own.get(branch);
        var events: std.ArrayList(Event) = .empty;
        try events.ensureTotalCapacity(arena, prefix.items.len + mine.events.len);
        for (prefix.items) |event| {
            var shared = event;
            shared.branch = branch;
            events.appendAssumeCapacity(shared);
        }
        // A tree explorer's timeline: each ancestor's own events from where it began to where
        // the next one branched from it, then its own.
        var from: u64 = 0;
        for (mine.path) |step| {
            const ancestor = try own.get(step.branch);
            for (ancestor.events) |event| {
                if (event.vtime_ns < from or event.vtime_ns > step.vtime_ns) continue;
                var shared = event;
                shared.branch = branch;
                try events.append(arena, shared);
            }
            from = step.vtime_ns;
        }
        try events.appendSlice(arena, mine.events);
        timeline.* = .{ .branch = branch, .events = events.items };
    }
    return timelines;
}

/// Each branch's own events (its file), and its path when it began inside others; read once.
const Own = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    read: std.AutoHashMapUnmanaged(u32, Branch) = .empty,

    const Step = struct { branch: u32, vtime_ns: u64 };
    const Branch = struct { path: []const Step, events: []const Event };

    fn get(own: *Own, branch: u32) !Branch {
        if (own.read.get(branch)) |known| return known;
        const name = try std.fmt.allocPrint(own.arena, "branch-{d}.jsonl", .{branch});
        const path = try std.fs.path.join(own.arena, &.{ own.directory, name });
        const cwd = std.Io.Dir.cwd();
        const source = cwd.readFileAlloc(own.io, path, own.arena, .unlimited) catch |err|
            switch (err) {
                error.FileNotFound => "", // An ancestor not recorded: its part is missing.
                else => return err,
            };
        var events: std.ArrayList(Event) = .empty;
        try events_parse(own.arena, source, branch, &events);
        var steps: []const Step = &.{};
        const first_end = std.mem.indexOfScalar(u8, source, '\n') orelse source.len;
        if (std.mem.startsWith(u8, source, "{\"path\":")) {
            const Header = struct { path: []const Step };
            const line = source[0..first_end];
            const header = try std.json.parseFromSliceLeaky(Header, own.arena, line, .{
                .ignore_unknown_fields = true,
            });
            steps = header.path;
        }
        const known = Branch{ .path = steps, .events = events.items };
        try own.read.put(own.arena, branch, known);
        return known;
    }
};

const Line = struct { seq: u64, vtime_ns: u64, event: std.json.Value };

fn events_parse(
    arena: std.mem.Allocator,
    source: []const u8,
    branch: u32,
    events: *std.ArrayList(Event),
) !void {
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    while (lines.next()) |text| {
        const line = std.json.parseFromSliceLeaky(Line, arena, text, .{
            .ignore_unknown_fields = true,
        }) catch continue; // Lines that are not JSON events (plain logs) carry nothing to query.
        try events.append(arena, .{
            .branch = branch,
            .seq = line.seq,
            .vtime_ns = line.vtime_ns,
            .value = line.event,
            .line = text,
        });
    }
}

/// New behavior discovery (Antithesis's utilization chart): after each branch, in index order,
/// how many distinct behaviors the exploration has seen. A behavior is an assertion with its
/// outcome, an event with its categorical details (a code coverage edge or line included);
/// not numbers, not what determinismo itself reports (commands, faults, lifecycle).
pub fn discovery(arena: std.mem.Allocator, timelines: []const Timeline) ![]const [2]u64 {
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    const points = try arena.alloc([2]u64, timelines.len);
    for (timelines, points, 1..) |timeline, *point, count| {
        for (timeline.events) |*event| {
            const behavior = behavior_hash(event.value) orelse continue;
            try seen.put(arena, behavior, {});
        }
        point.* = .{ count, seen.count() };
    }
    return points;
}

const runtime_events = [_][]const u8{
    "composer_start", "composer_done", "command_start", "command_exit", "faults_phase",
    "faults_start",   "faults_stop",   "fault",         "nodes_up",     "node_start",
    "node_ready",     "node_kill",     "exec_start",    "exec_output",  "exec_done",
};
const behavior_keys = [_][]const u8{ "kind", "flavor", "mode", "name", "node", "peer", "state" };

pub fn behavior_hash(value: std.json.Value) ?u64 {
    if (value != .object) return null;
    var hasher = std.hash.Wyhash.init(0x6265686176696f72);
    if (value.object.get("assert")) |assertion| {
        if (assertion != .object) return null;
        for ([_][]const u8{ "type", "message", "condition" }) |key| {
            hash_field(&hasher, assertion.object, key);
        }
        return hasher.final();
    }
    const name = value.object.get("event") orelse return null;
    if (name != .string) return null;
    for (runtime_events) |runtime| if (std.mem.eql(u8, name.string, runtime)) return null;
    hasher.update(name.string);
    if (value.object.get("details")) |details| {
        if (details == .object) for (behavior_keys) |key| hash_field(&hasher, details.object, key);
    }
    return hasher.final();
}

fn hash_field(hasher: *std.hash.Wyhash, object: std.json.ObjectMap, key: []const u8) void {
    const value = object.get(key) orelse return;
    hasher.update(key);
    switch (value) {
        .string => |text| hasher.update(text),
        .bool => |flag| hasher.update(if (flag) "true" else "false"),
        else => {}, // Numbers and structures: not behaviors.
    }
}

/// Whether every temporal condition holds for event `index` of the timeline.
pub fn temporal_holds(temporals: []const Temporal, events: []const Event, index: usize) bool {
    const event = &events[index];
    for (temporals) |*temporal| {
        const found = switch (temporal.direction) {
            .before => found: {
                var at = index;
                while (at > 0) {
                    at -= 1;
                    const other = &events[at];
                    if (temporal.window_ns) |window| {
                        if (event.vtime_ns - other.vtime_ns > window) break :found false;
                    }
                    if (temporal.condition.matches(other)) break :found true;
                }
                break :found false;
            },
            .after => found: {
                for (events[index + 1 ..]) |*other| {
                    if (temporal.window_ns) |window| {
                        if (other.vtime_ns - event.vtime_ns > window) break :found false;
                    }
                    if (temporal.condition.matches(other)) break :found true;
                }
                break :found false;
            },
        };
        if (found == temporal.negated) return false;
    }
    return true;
}

pub const Output = enum { events, count, branches };

pub const Query = struct {
    directory: []const u8,
    condition: Condition,
    temporals: []const Temporal,
    only_branch: ?u32 = null,
    up_to_ns: ?u64 = null,
    limit: u64 = std.math.maxInt(u64),
    output: Output = .events,
    json: bool = false,
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

/// Runs `request` on an events directory; its answer, as JSON lines.
pub fn answer(
    arena: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    request: Request,
) ![]const u8 {
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
    const query = Query{
        .directory = directory,
        .condition = try parse(arena, request.condition),
        .temporals = temporals.items,
        .only_branch = request.branch,
        .up_to_ns = if (request.up_to_vtime) |seconds| try seconds_to_ns_float(seconds) else null,
        .limit = request.limit,
        .output = request.output,
        .json = true,
    };
    const timelines = try timelines_read(arena, io, directory, request.branch);
    var out: std.Io.Writer.Allocating = .init(arena);
    _ = try search(&query, timelines, &out.writer);
    return out.written();
}

fn seconds_to_ns_float(seconds: f64) !u64 {
    if (seconds < 0) return error.NegativeTime;
    return @intFromFloat(seconds * std.time.ns_per_s);
}

/// The command: arguments after `query`. Exit status 0 when something matched, 1 when nothing
/// did (as grep), 2 on usage errors.
pub fn run(arena: std.mem.Allocator, io: std.Io, arguments: []const [:0]const u8) !u8 {
    // `query <dir> '{"condition": ...}'`: the HTTP API's request, and its answer.
    if (arguments.len == 2 and std.mem.startsWith(u8, arguments[1], "{")) {
        const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
        const asked = try std.json.parseFromSliceLeaky(Request, arena, arguments[1], options);
        try std.Io.File.stdout().writeStreamingAll(io, try answer(arena, io, arguments[0], asked));
        return 0;
    }
    const request = try arguments_parse(arena, arguments);
    const timelines = try timelines_read(arena, io, request.directory, request.only_branch);
    var buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const total = try search(&request, timelines, &stdout.interface);
    try stdout.interface.flush();
    return if (total > 0) 0 else 1;
}

fn arguments_parse(arena: std.mem.Allocator, arguments: []const [:0]const u8) !Query {
    if (arguments.len < 2) return error.Usage;
    var request = Query{
        .directory = arguments[0],
        .condition = try parse(arena, arguments[1]),
        .temporals = &.{},
    };
    var temporals: std.ArrayList(Temporal) = .empty;
    var index: usize = 2;
    while (index < arguments.len) : (index += 1) {
        const flag = arguments[index];
        const eql = std.mem.eql;
        if (eql(u8, flag, "--count")) {
            request.output = .count;
        } else if (eql(u8, flag, "--branches")) {
            request.output = .branches;
        } else if (eql(u8, flag, "--json")) {
            request.json = true;
        } else {
            index += 1;
            if (index == arguments.len) return error.Usage;
            try option_parse(arena, &request, &temporals, flag, arguments[index]);
        }
    }
    request.temporals = temporals.items;
    return request;
}

const temporal_flags = [_]struct { []const u8, @FieldType(Temporal, "direction"), bool }{
    .{ "--preceded-by", .before, false }, .{ "--not-preceded-by", .before, true },
    .{ "--followed-by", .after, false },  .{ "--not-followed-by", .after, true },
};

fn option_parse(
    arena: std.mem.Allocator,
    request: *Query,
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
        request.only_branch = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--up-to-vtime")) {
        request.up_to_ns = try seconds_to_ns(value);
    } else if (eql(u8, flag, "--limit")) {
        request.limit = try std.fmt.parseInt(u64, value, 10);
    } else return error.Usage;
}

/// Writes what the query asks for; returns how many events matched.
pub fn search(request: *const Query, timelines: []const Timeline, out: *std.Io.Writer) !u64 {
    var total: u64 = 0;
    var branches_matching: u64 = 0;
    for (timelines) |timeline| {
        var in_timeline: u64 = 0;
        var first: ?*const Event = null;
        for (timeline.events, 0..) |*event, at| {
            if (request.up_to_ns) |end| if (event.vtime_ns > end) break;
            if (!request.condition.matches(event)) continue;
            if (!temporal_holds(request.temporals, timeline.events, at)) continue;
            in_timeline += 1;
            if (first == null) first = event;
            const shown = request.output == .events and total + in_timeline <= request.limit;
            if (shown) try event_print(out, event, request.json);
        }
        total += in_timeline;
        if (in_timeline > 0) branches_matching += 1;
        if (request.output != .branches) continue;
        if (first) |event| try branch_print(out, event, in_timeline, request.json);
    }
    if (request.output == .count) {
        const counts = .{ total, branches_matching, timelines.len };
        if (request.json) {
            try out.print("{{\"events\":{d},\"branches\":{d},\"timelines\":{d}}}\n", counts);
        } else {
            try out.print("{d} events in {d} of {d} timelines\n", counts);
        }
    }
    return total;
}

fn seconds_to_ns(text: []const u8) !u64 {
    const seconds = try std.fmt.parseFloat(f64, text);
    if (seconds < 0) return error.NegativeTime;
    return @intFromFloat(seconds * std.time.ns_per_s);
}

/// The event, where it happened, and how to branch from there.
fn event_print(out: *std.Io.Writer, event: *const Event, json: bool) !void {
    const ms = event.vtime_ns / std.time.ns_per_ms;
    if (json) {
        try out.print("{{\"branch\":{d},\"seq\":{d},\"vtime_ns\":{d},\"event\":{f}}}\n", .{
            event.branch, event.seq, event.vtime_ns, std.json.fmt(event.value, .{}),
        });
        return;
    }
    const format = "branch {d} vtime {d}.{d:0>6}s  {f}  (--from-branch {d} --from-vtime-ms {d})\n";
    try out.print(format, .{
        event.branch,
        event.vtime_ns / std.time.ns_per_s,
        event.vtime_ns % std.time.ns_per_s / 1000,
        std.json.fmt(event.value, .{}),
        event.branch,
        ms,
    });
}

fn branch_print(out: *std.Io.Writer, first: *const Event, count: u64, json: bool) !void {
    const ms = first.vtime_ns / std.time.ns_per_ms;
    if (json) {
        try out.print("{{\"branch\":{d},\"matches\":{d},\"first_vtime_ns\":{d}}}\n", .{
            first.branch, count, first.vtime_ns,
        });
        return;
    }
    try out.print("branch {d}: {d} matches, first at vtime {d}ms (--from-branch {d} " ++
        "--from-vtime-ms {d})\n", .{ first.branch, count, ms, first.branch, ms });
}

fn event_test(arena: std.mem.Allocator, vtime_ns: u64, json: []const u8) !Event {
    return .{
        .branch = 0,
        .seq = 1,
        .vtime_ns = vtime_ns,
        .value = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}),
        .line = json,
    };
}

test "conditions: paths, operators, and/or, quoted values" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fault = try event_test(arena, 2_500_000_000,
        \\{"event":"fault","details":{"kind":"partition","node":"redis","duration_ns":300}}
    );
    const output = try event_test(arena, 3_000_000_000,
        \\{"output":{"source":"bank","stream":"stderr","text":"connection refused by redis"}}
    );
    const checks = [_]struct { []const u8, bool, bool }{
        .{ "event=fault", true, false },
        .{ "event=fault details.kind=partition", true, false },
        .{ "event = fault and details.node != redis", false, false },
        .{ "details.duration_ns>=300 vtime<3", true, false },
        .{ "output.text~\"connection refused\"", false, true },
        .{ "output.text!~refused", false, false },
        .{ "event=fault or output.stream=stderr", true, true },
        .{ "output?", false, true },
        .{ "output!?", true, false },
    };
    for (checks) |check| {
        const condition = try parse(arena, check[0]);
        try std.testing.expectEqual(check[1], condition.matches(&fault));
        try std.testing.expectEqual(check[2], condition.matches(&output));
    }
}

test "temporal: preceded and followed by, within windows" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const events = [_]Event{
        try event_test(arena, 1_000_000_000, "{\"event\":\"fault\"}"),
        try event_test(arena, 1_500_000_000, "{\"event\":\"ping\"}"),
        try event_test(arena, 4_000_000_000, "{\"event\":\"error\"}"),
    };
    const fault = try parse(arena, "event=fault");
    const failure = try parse(arena, "event=error");
    const near = [_]Temporal{.{
        .condition = fault,
        .direction = .before,
        .negated = false,
        .window_ns = 1_000_000_000,
    }};
    try std.testing.expect(temporal_holds(&near, &events, 1)); // 0.5s after the fault.
    try std.testing.expect(!temporal_holds(&near, &events, 2)); // 3s after: outside the window.
    const anywhere = [_]Temporal{.{ .condition = fault, .direction = .before, .negated = false }};
    try std.testing.expect(temporal_holds(&anywhere, &events, 2));
    const never_after = [_]Temporal{
        .{ .condition = failure, .direction = .after, .negated = true },
    };
    try std.testing.expect(!temporal_holds(&never_after, &events, 0));
    try std.testing.expect(temporal_holds(&never_after, &events, 2));
}
