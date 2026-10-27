// SPDX-License-Identifier: MIT
//! The events database (ARCHITECTURE.md §12): a run's events and timelines in DuckDB
//! (duckdb.zig), where every question about a run is asked. The UI's panels, searches (query.zig
//! compiles them to SQL), event sets and notebooks are queries over it.
//!
//! The events directory holds what the VMM writes, one JSON line per event: setup.jsonl (boot
//! and setup, shared by every timeline), fork.jsonl (a fork's history), branch-<n>.jsonl (each
//! timeline's own events, after a `{"path": ...}` line when it began inside others), and
//! timelines.jsonl (a line per timeline once it finished, written after its events). `ingest`
//! brings in the timelines that finished since it last did, in one transaction: readers see
//! whole timelines only. The database is the directory's events.duckdb, opened by one process
//! at a time (serve, for its runs; else the command asking).
//!
//! Tables (and what the panels read):
//!   events     every event once: `branch` is the timeline whose file it is in (NULL: the
//!              setup's), `kind` its top key (assert, event, output, decision, lifecycle,
//!              guidance, antithesis_assert, antithesis_sdk, raw), and typed columns for what
//!              is filtered on (name, type, condition, node, text, behavior); `event` as written.
//!   timelines  a row per finished timeline, as timelines.jsonl has it.
//!   steps      where a tree timeline begins: the ancestors' parts it shares.
//!   timeline_events (view): each timeline's events, from the setup through its ancestors' parts
//!              to its own, as `timeline`, `origin` (the file's branch) and the event columns.
const std = @import("std");
const assert = std.debug.assert;
pub const duckdb = @import("duckdb.zig");

pub const file_name = "events.duckdb";
/// The tables' shape: a database of another version is rebuilt from the files.
const schema_version = 2;

/// Paths of the events' JSON that searches read most (the UI's): kept as columns, their text
/// (`->>`) and their JSON type, which a condition reads instead of parsing every event
/// (query.zig). The same expressions, so the same answers.
pub const indexed_paths = [_]Indexed{
    .of("event", "path_event"),
    .of("assert.message", "path_assert_message"),
    .of("assert.condition", "path_assert_condition"),
    .of("antithesis_assert.message", "path_antithesis_assert_message"),
    .of("antithesis_assert.condition", "path_antithesis_assert_condition"),
    .of("details.node", "path_details_node"),
    .of("details.kind", "path_details_kind"),
};

pub const Indexed = struct {
    path: []const u8,
    column: []const u8,
    type_column: []const u8,

    fn of(comptime path: []const u8, comptime column: []const u8) Indexed {
        return .{ .path = path, .column = column, .type_column = column ++ "_type" };
    }
};

/// A JSON path (`a.b`) as JSON path syntax (`$."a"."b"`).
pub fn json_path(arena: std.mem.Allocator, dotted: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("$");
    var keys = std.mem.splitScalar(u8, dotted, '.');
    while (keys.next()) |key| try out.writer.print(".\"{s}\"", .{key});
    return out.written();
}

/// The indexed paths' columns as a SELECT list over `event`: `<column>, <column>_type`.
pub fn indexed_select(arena: std.mem.Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (indexed_paths) |indexed| {
        const path = try sql_string(arena, try json_path(arena, indexed.path));
        try out.writer.print(", event ->> {s} AS {s}, json_type(event, {s}) AS {s}", .{
            path, indexed.column, path, indexed.type_column,
        });
    }
    return out.written();
}

/// A run's events database, attached to a DuckDB instance under `name` (serve attaches every
/// run's to one instance; a command attaches the one it reads).
pub const Store = struct {
    /// The events directory.
    directory: []const u8,
    /// As SQL names the database: `run_<id>`, or `events`.
    name: []const u8,

    /// Attaches (or creates) the events database of `directory`, its tables made current.
    pub fn attach(
        database: *duckdb.Database,
        arena: std.mem.Allocator,
        directory: []const u8,
        name: []const u8,
        failure: *duckdb.Failure,
    ) !Store {
        const store: Store = .{
            .directory = try arena.dupe(u8, directory),
            .name = try arena.dupe(u8, name),
        };
        const path = try std.fs.path.join(arena, &.{ directory, file_name });
        try database.attach(path, name, failure);
        errdefer database.detach(name, failure) catch {};
        var connection = try store.connect(database, arena, failure);
        defer connection.close();
        try schema_ensure(&connection, arena);
        return store;
    }

    /// A connection whose tables are this store's.
    pub fn connect(
        store: Store,
        database: *duckdb.Database,
        arena: std.mem.Allocator,
        failure: *duckdb.Failure,
    ) !duckdb.Connection {
        var connection = try database.connect(failure);
        errdefer connection.close();
        try connection.exec(try std.fmt.allocPrintSentinel(arena, "USE {s}", .{store.name}, 0));
        return connection;
    }
};

/// An events directory's database for a command (query, events, MCP): attached on its own
/// and brought up to date. Serve holds the databases of its runs: a command reaching one of
/// those is told so (DuckDB locks the file).
pub const Opened = struct {
    database: duckdb.Database,
    connection: duckdb.Connection,
    failure: duckdb.Failure,

    pub fn close(opened: *Opened) void {
        opened.connection.close();
        opened.database.close();
    }
};

pub fn open_for_command(arena: std.mem.Allocator, io: std.Io, directory: []const u8) !*Opened {
    const opened = try arena.create(Opened);
    opened.failure = .{};
    opened.database = duckdb.Database.open(":memory:", .{}, &opened.failure) catch |err| {
        std.debug.print("error: {s}\n", .{opened.failure.text()});
        return err;
    };
    errdefer opened.database.close();
    const failure = &opened.failure;
    const events = Store.attach(&opened.database, arena, directory, "events", failure) catch |err| {
        std.debug.print("error: {s}\n", .{opened.failure.text()});
        if (std.mem.indexOf(u8, opened.failure.text(), "lock") != null) {
            std.debug.print("(a `determinismo serve` holds this run's events: ask it, " ++
                "POST /runs/<id>/query)\n", .{});
        }
        return err;
    };
    opened.connection = try events.connect(&opened.database, arena, &opened.failure);
    errdefer opened.connection.close();
    _ = ingest(&opened.connection, arena, io, directory) catch |err| {
        std.debug.print("error: {s}\n", .{opened.connection.failure.text()});
        return err;
    };
    return opened;
}

fn schema_ensure(connection: *duckdb.Connection, arena: std.mem.Allocator) !void {
    const Version = struct { version: u32 };
    const asked = "SELECT version FROM schema_version";
    const known = connection.row(Version, arena, asked, .{}) catch null;
    if (known) |found| if (found.version == schema_version) return;
    // Another version (or none): rebuilt, then ingested again from the files.
    try connection.exec(
        \\DROP VIEW IF EXISTS timeline_events;
        \\DROP TABLE IF EXISTS events; DROP TABLE IF EXISTS timelines; DROP TABLE IF EXISTS steps;
        \\DROP TABLE IF EXISTS schema_version; DROP MACRO IF EXISTS categorical;
    );
    try connection.exec(schema_sql);
}

const schema_sql =
    \\CREATE TABLE schema_version AS SELECT 2 AS version;
    \\CREATE MACRO categorical(j, path) AS
    \\    CASE WHEN json_type(j, path) IN ('VARCHAR', 'BOOLEAN') THEN j ->> path END;
    \\CREATE TABLE events (
    \\    branch UINTEGER,
    \\    seq UBIGINT NOT NULL,
    \\    vtime_ns UBIGINT NOT NULL,
    \\    branches UBIGINT,
    \\    kind VARCHAR,
    \\    name VARCHAR,
    \\    type VARCHAR,
    \\    condition BOOLEAN,
    \\    node VARCHAR,
    \\    text VARCHAR,
    \\    behavior UBIGINT,
    \\    event JSON NOT NULL,
    \\    path_event VARCHAR, path_event_type VARCHAR,
    \\    path_assert_message VARCHAR, path_assert_message_type VARCHAR,
    \\    path_assert_condition VARCHAR, path_assert_condition_type VARCHAR,
    \\    path_antithesis_assert_message VARCHAR, path_antithesis_assert_message_type VARCHAR,
    \\    path_antithesis_assert_condition VARCHAR, path_antithesis_assert_condition_type VARCHAR,
    \\    path_details_node VARCHAR, path_details_node_type VARCHAR,
    \\    path_details_kind VARCHAR, path_details_kind_type VARCHAR
    \\);
    \\CREATE TABLE timelines (
    \\    branch UINTEGER PRIMARY KEY,
    \\    seed VARCHAR,
    \\    outcome VARCHAR,
    \\    vtime_ns UBIGINT,
    \\    wall_ns UBIGINT,
    \\    events UBIGINT,
    \\    events_hash VARCHAR,
    \\    generation UINTEGER,
    \\    why VARCHAR,
    \\    parent UINTEGER,
    \\    start_ns UBIGINT,
    \\    path JSON
    \\);
    \\CREATE TABLE steps (
    \\    branch UINTEGER, step UINTEGER, ancestor UINTEGER, from_ns UBIGINT, to_ns UBIGINT
    \\);
    \\CREATE VIEW timeline_events AS
    \\    SELECT t.branch AS timeline, NULL::UINTEGER AS origin, e.* EXCLUDE (branch)
    \\        FROM timelines t, events e WHERE e.branch IS NULL
    \\    UNION ALL
    \\    SELECT s.branch AS timeline, e.branch AS origin, e.* EXCLUDE (branch)
    \\        FROM steps s JOIN events e
    \\        ON e.branch = s.ancestor AND e.vtime_ns >= s.from_ns AND e.vtime_ns <= s.to_ns
    \\    UNION ALL
    \\    SELECT e.branch AS timeline, e.branch AS origin, e.* EXCLUDE (branch)
    \\        FROM events e WHERE e.branch IS NOT NULL;
;

/// Events read from their files, with their typed columns: `files` is a SQL list of paths.
/// What a behavior is (discovery): an assertion with its outcome; an event with its categorical
/// details (strings and booleans of kind, flavor, mode, name, node, peer, state), not the
/// runtime's own (commands, faults, lifecycle).
fn events_select(
    arena: std.mem.Allocator,
    files: []const u8,
    branch_sql: []const u8,
) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(arena,
        \\WITH lines AS (
        \\    SELECT {s} AS branch, seq, vtime_ns, branches, event, json_keys(event)[1] AS kind
        \\    FROM read_json({s}, format = 'newline_delimited', filename = true,
        \\        columns = {{
        \\            seq: 'UBIGINT', vtime_ns: 'UBIGINT', branches: 'UBIGINT', event: 'JSON'
        \\        }})
        \\    WHERE seq IS NOT NULL
        \\), typed AS (
        \\    SELECT *,
        \\        CASE kind WHEN 'assert' THEN event -> '$.assert'
        \\            WHEN 'antithesis_assert' THEN event -> '$.antithesis_assert' END AS assertion
        \\    FROM lines
        \\), columns AS (
        \\    SELECT branch, seq, vtime_ns, branches, kind,
        \\        CASE kind
        \\            WHEN 'assert' THEN assertion ->> '$.message'
        \\            WHEN 'antithesis_assert' THEN assertion ->> '$.message'
        \\            WHEN 'guidance' THEN event ->> '$.guidance.message'
        \\            WHEN 'event' THEN event ->> '$.event'
        \\            WHEN 'lifecycle' THEN event ->> '$.lifecycle'
        \\            WHEN 'decision' THEN event ->> '$.decision.name'
        \\            WHEN 'output' THEN event ->> '$.output.stream'
        \\        END AS name,
        \\        CASE kind
        \\            WHEN 'assert' THEN assertion ->> '$.type'
        \\            WHEN 'antithesis_assert' THEN CASE assertion ->> '$.display_type'
        \\                WHEN 'Always' THEN 'always'
        \\                WHEN 'AlwaysOrUnreachable' THEN 'always_or_unreachable'
        \\                WHEN 'Sometimes' THEN 'sometimes' WHEN 'Reachable' THEN 'reachable'
        \\                WHEN 'Unreachable' THEN 'unreachable' END
        \\        END AS type,
        \\        CASE WHEN assertion IS NULL THEN NULL
        \\            WHEN json_type(assertion, '$.hit') = 'BOOLEAN'
        \\                AND NOT (assertion ->> '$.hit')::BOOLEAN THEN NULL
        \\            WHEN json_type(assertion, '$.condition') IS NULL THEN true
        \\            WHEN json_type(assertion, '$.condition') = 'BOOLEAN'
        \\                THEN (assertion ->> '$.condition')::BOOLEAN
        \\        END AS condition,
        \\        CASE kind
        \\            WHEN 'event' THEN event ->> '$.details.node'
        \\            WHEN 'output' THEN event ->> '$.output.source'
        \\        END AS node,
        \\        CASE kind
        \\            WHEN 'output' THEN event ->> '$.output.text'
        \\            WHEN 'raw' THEN event ->> '$.raw'
        \\        END AS text,
        \\        CASE
        \\            WHEN kind = 'assert' THEN hash('assert',
        \\                categorical(assertion, '$.type'), categorical(assertion, '$.message'),
        \\                categorical(assertion, '$.condition'))
        \\            WHEN kind = 'event' AND json_type(event, '$.event') = 'VARCHAR'
        \\                AND event ->> '$.event' NOT IN ('composer_start', 'composer_done',
        \\                    'command_start', 'command_exit', 'faults_phase', 'faults_start',
        \\                    'faults_stop', 'fault', 'nodes_up', 'node_start', 'node_ready',
        \\                    'node_kill', 'exec_start', 'exec_output', 'exec_done')
        \\            THEN hash('event', event ->> '$.event',
        \\                categorical(event, '$.details.kind'),
        \\                categorical(event, '$.details.flavor'),
        \\                categorical(event, '$.details.mode'),
        \\                categorical(event, '$.details.name'),
        \\                categorical(event, '$.details.node'),
        \\                categorical(event, '$.details.peer'),
        \\                categorical(event, '$.details.state'))
        \\        END AS behavior,
        \\        event{s}
        \\    FROM typed
        \\)
        \\SELECT * FROM columns
    , .{ branch_sql, files, try indexed_select(arena) }, 0);
}

/// Brings in the timelines that finished since the last ingest (and the setup's events with the
/// first): how many.
pub fn ingest(
    connection: *duckdb.Connection,
    arena: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
) !u32 {
    const timelines_path = try std.fs.path.join(arena, &.{ directory, "timelines.jsonl" });
    std.Io.Dir.cwd().access(io, timelines_path, .{}) catch return 0; // No timeline finished yet.
    const timelines = try sql_string(arena, timelines_path);
    const timelines_read = try std.fmt.allocPrint(arena,
        \\read_json({s}, format = 'newline_delimited', columns = {{
        \\    "index": 'UINTEGER', seed: 'VARCHAR', outcome: 'VARCHAR', vtime_ns: 'UBIGINT',
        \\    wall_ns: 'UBIGINT', events: 'UBIGINT', events_hash: 'VARCHAR', generation: 'UINTEGER',
        \\    why: 'VARCHAR', path: 'STRUCT(branch UINTEGER, seed UBIGINT, vtime_ns UBIGINT)[]'}})
    , .{timelines});
    const Arrived = struct { index: u32 };
    const arrived = try connection.rows(Arrived, arena, try std.fmt.allocPrintSentinel(arena,
        \\SELECT DISTINCT "index" FROM {s}
        \\WHERE "index" NOT IN (SELECT branch FROM timelines) ORDER BY 1
    , .{timelines_read}, 0), .{});
    if (arrived.len == 0) return 0;

    var files: std.Io.Writer.Allocating = .init(arena);
    var indices: std.Io.Writer.Allocating = .init(arena);
    var count: usize = 0;
    for (arrived, 0..) |timeline, at| {
        try indices.writer.print("{s}{d}", .{ if (at == 0) "" else ",", timeline.index });
        const name = try std.fmt.allocPrint(arena, "branch-{d}.jsonl", .{timeline.index});
        const path = try std.fs.path.join(arena, &.{ directory, name });
        std.Io.Dir.cwd().access(io, path, .{}) catch continue; // A timeline that wrote no events.
        const quoted = try sql_string(arena, path);
        try files.writer.print("{s}{s}", .{ if (count == 0) "" else ",", quoted });
        count += 1;
    }

    try connection.exec("BEGIN TRANSACTION");
    errdefer connection.exec("ROLLBACK") catch {};
    const Count = struct { count: u64 };
    const prefix_sql = "SELECT count(*) FROM events WHERE branch IS NULL";
    const prefix = (try connection.row(Count, arena, prefix_sql, .{})).?;
    const known_sql = "SELECT count(*) FROM timelines";
    const timelines_known = (try connection.row(Count, arena, known_sql, .{})).?;
    if (prefix.count == 0 and timelines_known.count == 0) {
        var shared: std.Io.Writer.Allocating = .init(arena);
        var shared_count: usize = 0;
        for ([_][]const u8{ "setup.jsonl", "fork.jsonl" }) |name| {
            const path = try std.fs.path.join(arena, &.{ directory, name });
            std.Io.Dir.cwd().access(io, path, .{}) catch continue;
            const quoted = try sql_string(arena, path);
            try shared.writer.print("{s}{s}", .{ if (shared_count == 0) "" else ",", quoted });
            shared_count += 1;
        }
        if (shared_count > 0) {
            const list = try std.fmt.allocPrint(arena, "[{s}]", .{shared.written()});
            const select = try events_select(arena, list, "NULL::UINTEGER");
            try connection.exec(try std.fmt.allocPrintSentinel(arena, "INSERT INTO events {s}", .{
                select,
            }, 0));
        }
    }
    if (count > 0) {
        const branch = "regexp_extract(filename, 'branch-([0-9]+)\\.jsonl$', 1)::UINTEGER";
        const list = try std.fmt.allocPrint(arena, "[{s}]", .{files.written()});
        const select = try events_select(arena, list, branch);
        try connection.exec(try std.fmt.allocPrintSentinel(arena, "INSERT INTO events {s}", .{
            select,
        }, 0));
    }
    try connection.exec(try std.fmt.allocPrintSentinel(arena,
        \\INSERT INTO steps
        \\    SELECT "index", step, (step_path).branch,
        \\        coalesce(lag((step_path).vtime_ns) OVER (PARTITION BY "index" ORDER BY step), 0),
        \\        (step_path).vtime_ns
        \\    FROM (SELECT "index", unnest(path) AS step_path, generate_subscripts(path, 1) AS step
        \\          FROM {s} WHERE "index" IN ({s}));
        \\INSERT INTO timelines
        \\    SELECT "index", any_value(seed), any_value(outcome), any_value(vtime_ns),
        \\        any_value(wall_ns),
        \\        any_value(events), any_value(events_hash), any_value(generation), any_value(why),
        \\        any_value(path[-1].branch), coalesce(any_value(path[-1].vtime_ns), 0),
        \\        any_value(path)::JSON
        \\    FROM {s} WHERE "index" IN ({s}) GROUP BY "index";
    , .{ timelines_read, indices.written(), timelines_read, indices.written() }, 0));
    try connection.exec("COMMIT");
    return @intCast(arrived.len);
}

/// A string as a SQL literal.
fn sql_string(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeByte('\'');
    for (text) |byte| {
        if (byte == '\'') try out.writer.writeByte('\'');
        try out.writer.writeByte(byte);
    }
    try out.writer.writeByte('\'');
    return out.written();
}

/// Each property (an assertion, by its type and message) across the timelines, with its
/// verdict, as Antithesis judges it (report.property_failing): an `always` fails where a
/// timeline made it false, `always_or_unreachable` and `unreachable` where a timeline violated
/// them, a `sometimes` that no timeline made true; one that must be reached and was not
/// (`always`, `sometimes`, `reachable`) is "unreached" (judged across scenarios).
pub const properties_sql =
    \\WITH per AS (
    \\    SELECT timeline, type, name AS message,
    \\        count(condition) AS hits,
    \\        count(*) FILTER (WHERE condition) AS trues,
    \\        min(vtime_ns) FILTER (WHERE
    \\            (type IN ('always', 'always_or_unreachable') AND NOT condition)
    \\            OR (type = 'unreachable' AND condition IS NOT NULL)) AS failed_ns,
    \\        min(vtime_ns) FILTER (WHERE condition IS NOT NULL) AS hit_ns,
    \\        any_value(CASE kind WHEN 'assert' THEN event -> '$.assert.location'
    \\            ELSE event -> '$.antithesis_assert.location' END) AS place
    \\    FROM timeline_events
    \\    WHERE kind IN ('assert', 'antithesis_assert') AND type IS NOT NULL AND name IS NOT NULL
    \\    GROUP BY ALL
    \\), judged AS (
    \\    SELECT type, message,
    \\        count(*) FILTER (WHERE hits > 0) AS timelines_hit,
    \\        count(*) FILTER (WHERE trues > 0) AS timelines_true,
    \\        count(*) FILTER (WHERE failed_ns IS NOT NULL) AS timelines_failing,
    \\        min(timeline) FILTER (WHERE failed_ns IS NOT NULL) AS first_failing_timeline,
    \\        arg_min(failed_ns, timeline) FILTER (WHERE failed_ns IS NOT NULL) AS first_failure_ns,
    \\        min(timeline) FILTER (WHERE hits > 0) AS first_hit_timeline,
    \\        sum(hits) AS hits, sum(trues) AS trues, any_value(place) AS place
    \\    FROM per GROUP BY ALL
    \\)
    \\SELECT type, message,
    \\    CASE
    \\        WHEN timelines_failing > 0 THEN 'failing'
    \\        WHEN type IN ('always', 'sometimes', 'reachable') AND timelines_hit = 0
    \\            THEN 'unreached'
    \\        WHEN type = 'sometimes' AND timelines_true = 0 THEN 'failing'
    \\        ELSE 'passing'
    \\    END AS status,
    \\    timelines_hit, timelines_true, timelines_failing, first_failing_timeline,
    \\    first_failure_ns,
    \\    first_hit_timeline, hits, trues,
    \\    regexp_extract(coalesce(place ->> '$.file', place ->> '$.file_name'), '[^/]*$') || ':'
    \\        || coalesce(place ->> '$.line', place ->> '$.begin_line', '0')
    \\        || coalesce(' ' || coalesce(place ->> '$.function', place ->> '$.function_name'), '')
    \\        AS location
    \\FROM judged
    \\ORDER BY status = 'failing' DESC, timelines_failing DESC, message
;

/// The timelines, each with the properties it violates (Events.Property.passing): an `always`
/// made false, an `unreachable` reached.
/// Each failing property's first failing timeline (the lowest index; the failing evaluations
/// of timelines_sql): what serve snapshots as soon as it is found.
pub const first_failures_sql =
    \\SELECT name AS property, min(timeline) AS branch
    \\FROM timeline_events
    \\WHERE kind IN ('assert', 'antithesis_assert')
    \\    AND ((type IN ('always', 'always_or_unreachable') AND NOT condition)
    \\        OR (type = 'unreachable' AND condition IS NOT NULL))
    \\GROUP BY name
    \\ORDER BY branch
;

pub const timelines_sql =
    \\WITH failing AS (
    \\    SELECT timeline, list(DISTINCT name ORDER BY name) AS failing
    \\    FROM timeline_events
    \\    WHERE kind IN ('assert', 'antithesis_assert')
    \\        AND ((type IN ('always', 'always_or_unreachable') AND NOT condition)
    \\            OR (type = 'unreachable' AND condition IS NOT NULL))
    \\    GROUP BY timeline
    \\)
    \\SELECT t.branch AS "index", t.seed, t.outcome, t.vtime_ns, t.wall_ns, t.events, t.events_hash,
    \\    t.generation, t.why, t.parent, t.start_ns, t.path,
    \\    to_json(coalesce(f.failing, []::VARCHAR[])) AS failing
    \\FROM timelines t LEFT JOIN failing f ON f.timeline = t.branch
    \\ORDER BY t.branch
;

/// New behavior discovery (Antithesis's utilization chart): after each timeline, in index order,
/// how many distinct behaviors the exploration has seen. A timeline's ancestors finished before
/// it began, so a behavior is first seen at the lowest index whose own events (or the setup's,
/// for every timeline) have it.
pub const discovery_sql =
    \\WITH ordered AS (
    \\    SELECT branch, row_number() OVER (ORDER BY branch) AS n FROM timelines
    \\), first_seen AS (
    \\    SELECT behavior, min(n) AS n FROM (
    \\        SELECT e.behavior, o.n FROM events e JOIN ordered o ON e.branch = o.branch
    \\        WHERE e.behavior IS NOT NULL
    \\        UNION ALL
    \\        SELECT behavior, 1 FROM events WHERE branch IS NULL AND behavior IS NOT NULL
    \\    ) GROUP BY behavior
    \\), new AS (SELECT n, count(*) AS new FROM first_seen GROUP BY n)
    \\SELECT o.n AS timelines, sum(coalesce(new.new, 0)) OVER (ORDER BY o.n) AS behaviors
    \\FROM ordered o LEFT JOIN new USING (n)
    \\ORDER BY o.n
;

/// The run at a glance: its timelines, those failing a property, virtual and wall time, and
/// distinct behaviors.
pub const stats_sql =
    \\SELECT
    \\    (SELECT count(*) FROM timelines) AS timelines,
    \\    (SELECT count(DISTINCT timeline) FROM timeline_events
    \\        WHERE kind IN ('assert', 'antithesis_assert')
    \\            AND ((type IN ('always', 'always_or_unreachable') AND NOT condition)
    \\                OR (type = 'unreachable' AND condition IS NOT NULL))) AS failing_timelines,
    \\    (SELECT coalesce(sum(vtime_ns), 0) FROM timelines) AS vtime_ns,
    \\    (SELECT coalesce(sum(wall_ns), 0) FROM timelines) AS wall_ns,
    \\    (SELECT count(DISTINCT behavior) FROM events) AS behaviors,
    \\    (SELECT count(*) FROM events) AS events
;

const testing = std.testing;

/// An event line as the VMM writes it.
fn line(comptime seq: u64, comptime vtime_ns: u64, comptime event: []const u8) []const u8 {
    return std.fmt.comptimePrint("{{\"seq\":{d},\"vtime_ns\":{d},\"event\":{s}}}\n", .{
        seq, vtime_ns, event,
    });
}

/// A timelines.jsonl line as the explorer writes it (the fields the database reads).
fn timeline_line(
    comptime index: u32,
    comptime vtime_ns: u64,
    comptime path: []const u8,
) []const u8 {
    return std.fmt.comptimePrint(
        "{{\"index\":{d},\"outcome\":\"shutdown\",\"vtime_ns\":{d},\"wall_ns\":10,\"path\":{s}}}\n",
        .{ index, vtime_ns, path },
    );
}

const fixture_timelines = timeline_line(1, 700, "[]") ++ timeline_line(2, 470, "[]");
const fixture_path = "[{\"branch\":1,\"seed\":7,\"vtime_ns\":550}]";

/// An events directory as an exploration writes it: a setup, two timelines from the setup
/// snapshot, and a third that began inside the first.
fn fixture_write(io: std.Io, directory: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, directory);
    const files = comptime [_]struct { []const u8, []const u8 }{
        .{
            "setup.jsonl",
            line(1, 100,
                \\{"event":"node_start","details":{"node":"db"}}
            ) ++ line(2, 200,
                \\{"assert":{"type":"sometimes","message":"leader elected","hit":false}}
            ) ++ line(3, 300,
                \\{"assert":{"type":"always","message":"log matches","condition":true}}
            ),
        },
        .{
            "branch-1.jsonl",
            line(4, 400,
                \\{"output":{"source":"db","stream":"stdout","text":"became leader"}}
            ) ++ line(5, 500,
                \\{"assert":{"type":"sometimes","message":"leader elected","condition":true}}
            ) ++ line(6, 600,
                \\{"event":"partition","details":{"node":"db","kind":"split"}}
            ),
        },
        .{
            "branch-2.jsonl",
            line(4, 450,
                \\{"assert":{"type":"always","message":"log matches","condition":false}}
            ) ++ line(5, 460,
                \\{"raw":"not json"}
            ),
        },
        .{
            "branch-3.jsonl",
            "{\"path\":" ++ fixture_path ++ "}\n" ++ line(6, 560,
                \\{"antithesis_assert":{"display_type":"Unreachable","message":"split brain",
            ++
                \\"condition":true,"hit":true}}
            ),
        },
        .{ "timelines.jsonl", fixture_timelines },
    };
    for (files) |file| {
        const path = try std.fs.path.join(testing.allocator, &.{ directory, file[0] });
        defer testing.allocator.free(path);
        try cwd.writeFile(io, .{ .sub_path = path, .data = file[1] });
    }
}

test "ingest brings whole timelines; properties, timelines and discovery read them" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/events", .{&tmp.sub_path});
    try fixture_write(io, directory);

    var failure: duckdb.Failure = .{};
    var database = try duckdb.Database.open(":memory:", .{ .threads = 2 }, &failure);
    defer database.close();
    const store = try Store.attach(&database, arena, directory, "run_1", &failure);
    var connection = try store.connect(&database, arena, &failure);
    defer connection.close();
    try testing.expectEqual(2, try ingest(&connection, arena, io, directory));
    try testing.expectEqual(0, try ingest(&connection, arena, io, directory)); // Nothing new.

    // The third finishes: ingested on its own, the setup's events not again.
    const timelines_path = try std.fs.path.join(arena, &.{ directory, "timelines.jsonl" });
    const more = comptime fixture_timelines ++ timeline_line(3, 580, fixture_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = timelines_path, .data = more });
    try testing.expectEqual(1, try ingest(&connection, arena, io, directory));

    const Count = struct { events: u64, setup: u64, raw: u64 };
    const counted = (try connection.row(Count, arena,
        \\SELECT count(*), count(*) FILTER (WHERE branch IS NULL),
        \\    count(*) FILTER (WHERE kind = 'raw')
        \\FROM events
    , .{})).?;
    try testing.expectEqual(Count{ .events = 9, .setup = 3, .raw = 1 }, counted);

    // Timeline 3: the setup, timeline 1 up to 550 ns, then its own.
    const Event = struct { seq: u64, origin: ?u32 };
    const third = try connection.rows(Event, arena,
        \\SELECT seq, origin FROM timeline_events WHERE timeline = 3 ORDER BY vtime_ns, seq
    , .{});
    try testing.expectEqual(6, third.len);
    try testing.expectEqual(Event{ .seq = 5, .origin = 1 }, third[4]);
    try testing.expectEqual(Event{ .seq = 6, .origin = 3 }, third[5]);

    const Property = struct {
        type: []const u8,
        message: []const u8,
        status: []const u8,
        failing: u64,
        first: ?u32,
    };
    const properties = try connection.rows(Property, arena,
        \\SELECT type, message, status, timelines_failing, first_failing_timeline
        \\FROM (
    ++ properties_sql ++
        \\) ORDER BY message
    , .{});
    try testing.expectEqual(3, properties.len);
    try testing.expectEqualStrings("leader elected", properties[0].message);
    try testing.expectEqualStrings("passing", properties[0].status); // True in timelines 1 and 3.
    try testing.expectEqualStrings("log matches", properties[1].message);
    try testing.expectEqualStrings("failing", properties[1].status);
    try testing.expectEqual(1, properties[1].failing);
    try testing.expectEqual(2, properties[1].first.?);
    try testing.expectEqualStrings("unreachable", properties[2].type);
    try testing.expectEqualStrings("failing", properties[2].status);

    const Timeline = struct { index: u32, failing: []const u8, parent: ?u32 };
    const timelines = try connection.rows(Timeline, arena,
        \\SELECT "index", failing::VARCHAR, parent FROM (
    ++ timelines_sql ++
        \\)
    , .{});
    try testing.expectEqual(3, timelines.len);
    try testing.expectEqualStrings("[]", timelines[0].failing);
    try testing.expectEqualStrings("[\"log matches\"]", timelines[1].failing);
    try testing.expectEqualStrings("[\"split brain\"]", timelines[2].failing);
    try testing.expectEqual(1, timelines[2].parent.?);

    // Behaviors: the setup's two assertions (the declaration and the evaluation) and node_start
    // is the runtime's; timeline 1 adds its sometimes and the partition; 2 its false always; 3
    // shares 1's (antithesis assertions are not behaviors).
    const Point = struct { timelines: u64, behaviors: i128 };
    const points = try connection.rows(Point, arena, discovery_sql, .{});
    try testing.expectEqual(3, points.len);
    try testing.expectEqual(Point{ .timelines = 1, .behaviors = 4 }, points[0]);
    try testing.expectEqual(Point{ .timelines = 2, .behaviors = 5 }, points[1]);
    try testing.expectEqual(Point{ .timelines = 3, .behaviors = 5 }, points[2]);
}
