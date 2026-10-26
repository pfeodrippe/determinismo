// SPDX-License-Identifier: MIT
//! DuckDB 2.0, the events database (store.zig), through its C API v2 in Zig's terms: a database
//! file, connections, statements with parameters, results read chunk by chunk as typed columns,
//! and rows as Zig structs or as JSON.
//!
//! What determinismo calls of the C API is declared here, from duckdb_v2.h, and nowhere else: the
//! C API v2 is not stable yet (DuckDB 2.0 says so), so a change to it is a change to this file.
//! DuckDB and its core functions and JSON extensions are linked in statically (build.zig, from
//! infra/host/tools.sh).
const std = @import("std");
const assert = std.debug.assert;

/// What a failed call said, kept by its connection (or handed to Database.open): error.DuckDB
/// means "read this".
pub const Failure = struct {
    buffer: [2048]u8 = undefined,
    len: usize = 0,

    pub fn text(failure: *const Failure) []const u8 {
        return failure.buffer[0..failure.len];
    }

    /// Takes a C call's outcome: its code and the error slot it was given.
    fn check(failure: *Failure, code: c.Code, info: ?*c.ErrorInfo) error{DuckDB}!void {
        if (code == c.none) return;
        var view: c.Str = .{ .ptr = null, .len = 0 };
        if (info) |known| _ = c.duckdb_v2_error_info_get_text(known, &view);
        var owned = info;
        defer _ = c.duckdb_v2_error_info_destroy(&owned);
        const message = if (view.ptr) |ptr| ptr[0..view.len] else "no detail";
        failure.len = (std.fmt.bufPrint(&failure.buffer, "{s} (DuckDB error {d})", .{
            message[0..@min(message.len, failure.buffer.len - 32)], code,
        }) catch unreachable).len;
        return error.DuckDB;
    }

    fn say(failure: *Failure, comptime format: []const u8, arguments: anytype) error{DuckDB} {
        const written = std.fmt.bufPrint(&failure.buffer, format, arguments) catch
            failure.buffer[0..];
        failure.len = written.len;
        return error.DuckDB;
    }
};

pub const Database = struct {
    environment: *c.Environment,
    instance: *c.Instance,

    pub const Options = struct {
        /// DuckDB's worker threads (all the CPUs by default).
        threads: ?u32 = null,
        memory_limit_mib: ?u32 = null,
    };

    /// Opens the database file at `path` (created if missing), or ":memory:".
    pub fn open(path: []const u8, options: Options, failure: *Failure) !Database {
        extensions_register();
        var info: ?*c.ErrorInfo = null;
        var environment: ?*c.Environment = null;
        try failure.check(c.duckdb_v2_environment_create(&environment, &info), info);
        errdefer _ = c.duckdb_v2_environment_destroy(&environment);

        var names: [2]c.Str = undefined;
        var values: [2]c.Str = undefined;
        var texts: [2][16]u8 = undefined;
        var count: usize = 0;
        if (options.threads) |threads| {
            names[count] = .from("threads");
            values[count] = .from(std.fmt.bufPrint(&texts[count], "{d}", .{threads}) catch
                unreachable);
            count += 1;
        }
        if (options.memory_limit_mib) |mib| {
            names[count] = .from("memory_limit");
            values[count] = .from(std.fmt.bufPrint(&texts[count], "{d}MiB", .{mib}) catch
                unreachable);
            count += 1;
        }
        var instance: ?*c.Instance = null;
        try failure.check(c.duckdb_v2_instance_create_with_options(
            environment.?,
            &names,
            &values,
            count,
            &instance,
            &info,
        ), info);
        errdefer _ = c.duckdb_v2_instance_destroy(&instance);
        const target: c.Str = .from(path);
        const attached = c.duckdb_v2_instance_attach(instance.?, null, &target, null, true, &info);
        try failure.check(attached, info);
        return .{ .environment = environment.?, .instance = instance.? };
    }

    pub fn close(database: *Database) void {
        var instance: ?*c.Instance = database.instance;
        _ = c.duckdb_v2_instance_destroy(&instance);
        var environment: ?*c.Environment = database.environment;
        // Refused while a connection still holds the instance: connections close first.
        const code = c.duckdb_v2_environment_destroy(&environment);
        assert(code == c.none);
        database.* = undefined;
    }

    /// Attaches the database file at `path` (created if missing) as `name`: SQL reaches it as
    /// `name.table`, or unqualified after `USE name`. Its views and macros resolve in it.
    pub fn attach(
        database: *Database,
        path: []const u8,
        name: []const u8,
        failure: *Failure,
    ) !void {
        var info: ?*c.ErrorInfo = null;
        const as: c.Str = .from(name);
        const target: c.Str = .from(path);
        const code = c.duckdb_v2_instance_attach(
            database.instance,
            &as,
            &target,
            null,
            false,
            &info,
        );
        try failure.check(code, info);
    }

    pub fn detach(database: *Database, name: []const u8, failure: *Failure) !void {
        var info: ?*c.ErrorInfo = null;
        const as: c.Str = .from(name);
        try failure.check(c.duckdb_v2_instance_detach(database.instance, &as, &info), info);
    }

    /// A connection, for one thread at a time; a database takes any number of them at once.
    pub fn connect(database: *Database, failure: *Failure) !Connection {
        var info: ?*c.ErrorInfo = null;
        var handle: ?*c.ConnectionHandle = null;
        try failure.check(c.duckdb_v2_connection_create(database.instance, &handle, &info), info);
        errdefer _ = c.duckdb_v2_connection_destroy(&handle);
        var factory: ?*c.Factory = null;
        try failure.check(c.duckdb_v2_connection_get_factory(handle.?, &factory, &info), info);
        return .{ .handle = handle.?, .factory = factory.? };
    }
};

/// The extensions linked in, for every database the process opens (registering one again does
/// nothing).
fn extensions_register() void {
    // Registering a linked-in extension only fails on a mismatched build.
    assert(c.duckdb_register_static_extension(c.duckdb_extension_core_functions_describe) == 0);
    assert(c.duckdb_register_static_extension(c.duckdb_extension_json_describe) == 0);
}

pub const Connection = struct {
    handle: *c.ConnectionHandle,
    factory: *c.Factory,
    failure: Failure = .{},

    pub fn close(connection: *Connection) void {
        var handle: ?*c.ConnectionHandle = connection.handle;
        _ = c.duckdb_v2_connection_destroy(&handle);
        connection.* = undefined;
    }

    /// Runs every statement of `sql`, for what they do (rows are dropped).
    pub fn exec(connection: *Connection, sql: [:0]const u8) !void {
        var info: ?*c.ErrorInfo = null;
        var statements: ?*c.StatementIterator = null;
        const parsed = c.duckdb_v2_parse_sql(connection.handle, sql, &statements, &info);
        try connection.failure.check(parsed, info);
        defer _ = c.duckdb_v2_statement_iterator_destroy(&statements);
        while (true) {
            var statement: ?*c.Statement = null;
            const next = c.duckdb_v2_statement_iterator_next(statements.?, &statement, &info);
            try connection.failure.check(next, info);
            defer _ = c.duckdb_v2_sql_statement_destroy(&statement);
            var result = try connection.execute(statement orelse return, .{});
            defer result.deinit();
            var changed: u64 = 0;
            const drained = c.duckdb_v2_result_drain(result.handle, &changed, &info);
            try connection.failure.check(drained, info);
        }
    }

    /// Runs the one statement of `sql` with its parameters ($1, $2, ...: integers, floats,
    /// booleans and strings) and streams its rows.
    pub fn query(connection: *Connection, sql: [:0]const u8, parameters: anytype) !Result {
        var info: ?*c.ErrorInfo = null;
        var statements: ?*c.StatementIterator = null;
        const parsed = c.duckdb_v2_parse_sql(connection.handle, sql, &statements, &info);
        try connection.failure.check(parsed, info);
        defer _ = c.duckdb_v2_statement_iterator_destroy(&statements);
        var statement: ?*c.Statement = null;
        const next = c.duckdb_v2_statement_iterator_next(statements.?, &statement, &info);
        try connection.failure.check(next, info);
        defer _ = c.duckdb_v2_sql_statement_destroy(&statement);
        const one = statement orelse return connection.failure.say("no statement", .{});
        return connection.execute(one, parameters);
    }

    fn execute(connection: *Connection, statement: *c.Statement, parameters: anytype) !Result {
        const names = @typeInfo(@TypeOf(parameters)).@"struct".field_names;
        var values: [names.len]*c.Value = undefined;
        var made: usize = 0;
        defer for (values[0..made]) |made_value| {
            var owned: ?*c.Value = made_value;
            _ = c.duckdb_v2_value_destroy(&owned);
        };
        inline for (names, 0..) |name, index| {
            values[index] = try connection.parameter(@field(parameters, name));
            made += 1;
        }
        var info: ?*c.ErrorInfo = null;
        var handle: ?*c.ResultHandle = null;
        try connection.failure.check(c.duckdb_v2_statement_execute(
            connection.handle,
            statement,
            null,
            if (names.len == 0) null else &values,
            names.len,
            &handle,
            &info,
        ), info);
        errdefer _ = c.duckdb_v2_result_destroy(&handle);
        var result: Result = .{ .connection = connection, .handle = handle.? };
        try result.schema_read();
        return result;
    }

    fn parameter(connection: *Connection, given: anytype) !*c.Value {
        var info: ?*c.ErrorInfo = null;
        var made: ?*c.Value = null;
        const factory = connection.factory;
        const T = @TypeOf(given);
        const code = switch (@typeInfo(T)) {
            .comptime_int => c.duckdb_v2_value_create_bigint(factory, given, &made, &info),
            .int => |int| if (int.signedness == .unsigned)
                c.duckdb_v2_value_create_ubigint(factory, given, &made, &info)
            else
                c.duckdb_v2_value_create_bigint(factory, given, &made, &info),
            .float, .comptime_float => c.duckdb_v2_value_create_double(
                factory,
                given,
                &made,
                &info,
            ),
            .bool => c.duckdb_v2_value_create_bool(factory, given, &made, &info),
            else => blk: {
                const bytes: []const u8 = given; // Strings: slices and literals.
                const view: c.Str = .from(bytes);
                break :blk c.duckdb_v2_value_create_varchar(factory, &view, &made, &info);
            },
        };
        try connection.failure.check(code, info);
        return made.?;
    }

    /// The rows of a query as `Row`s, its fields the columns in order: integers, floats, booleans,
    /// strings (copied into `arena`) and optionals of them for columns that may be NULL.
    pub fn rows(
        connection: *Connection,
        comptime Row: type,
        arena: std.mem.Allocator,
        sql: [:0]const u8,
        parameters: anytype,
    ) ![]Row {
        var result = try connection.query(sql, parameters);
        defer result.deinit();
        const info = @typeInfo(Row).@"struct";
        if (result.column_count != info.field_names.len) {
            return connection.failure.say("{d} columns for {d} fields", .{
                result.column_count, info.field_names.len,
            });
        }
        var list: std.ArrayList(Row) = .empty;
        while (try result.next()) |chunk_| {
            var chunk = chunk_;
            defer chunk.deinit();
            var columns: [info.field_names.len]Column = undefined;
            for (&columns, 0..) |*column, index| column.* = try chunk.column(index);
            try list.ensureUnusedCapacity(arena, chunk.len);
            for (0..chunk.len) |at| {
                var decoded: Row = undefined;
                inline for (info.field_names, info.field_types, columns) |name, T, column| {
                    @field(decoded, name) = try connection.cell(T, column, at, arena);
                }
                list.appendAssumeCapacity(decoded);
            }
        }
        return list.items;
    }

    /// The first row of a query, if any.
    pub fn row(
        connection: *Connection,
        comptime Row: type,
        arena: std.mem.Allocator,
        sql: [:0]const u8,
        parameters: anytype,
    ) !?Row {
        const all = try connection.rows(Row, arena, sql, parameters);
        return if (all.len == 0) null else all[0];
    }

    fn cell(
        connection: *Connection,
        comptime T: type,
        column: Column,
        at: usize,
        arena: std.mem.Allocator,
    ) !T {
        if (@typeInfo(T) == .optional) {
            if (column.is_null(at)) return null;
            return try connection.cell(@typeInfo(T).optional.child, column, at, arena);
        }
        const failure = &connection.failure;
        const name = column.name;
        if (column.is_null(at)) return failure.say("NULL in column {s}", .{name});
        return switch (@typeInfo(T)) {
            .int => column.integer(T, at) orelse
                failure.say("column {s} does not fit in {s}", .{ name, @typeName(T) }),
            .float => column.float(at) orelse failure.say("column {s} is not a number", .{name}),
            .bool => column.boolean(at) orelse failure.say("column {s} is not a boolean", .{name}),
            else => try arena.dupe(u8, column.bytes(at) orelse
                return failure.say("column {s} is not text", .{name})),
        };
    }

    /// The rows of a query as a JSON array of objects named by its columns. JSON columns are
    /// written as they are; nested types are cast to JSON in the query.
    pub fn json(
        connection: *Connection,
        out: *std.Io.Writer,
        sql: [:0]const u8,
        parameters: anytype,
    ) !void {
        var result = try connection.query(sql, parameters);
        defer result.deinit();
        _ = try connection.json_write(out, &result, std.math.maxInt(usize));
    }

    /// Someone's SQL (an agent's, a notebook's), read-only: one SELECT (or EXPLAIN), its first
    /// `rows_max` rows as JSON; whether it had more.
    pub fn select_json(
        connection: *Connection,
        out: *std.Io.Writer,
        sql: [:0]const u8,
        rows_max: usize,
    ) !bool {
        var result = try connection.query(sql, .{});
        defer result.deinit();
        if (result.statement != .select and result.statement != .explain) {
            return connection.failure.say("only SELECT (or EXPLAIN) reads here", .{});
        }
        return connection.json_write(out, &result, rows_max);
    }

    /// Writes up to `rows_max` rows as a JSON array; whether there were more.
    fn json_write(
        connection: *Connection,
        out: *std.Io.Writer,
        result: *Result,
        rows_max: usize,
    ) !bool {
        try out.writeAll("[");
        var first = true;
        var written: usize = 0;
        while (try result.next()) |chunk_| {
            var chunk = chunk_;
            defer chunk.deinit();
            var columns: [Result.columns_max]Column = undefined;
            for (columns[0..result.column_count], 0..) |*column, index| {
                column.* = try chunk.column(index);
            }
            for (0..chunk.len) |at| {
                if (written == rows_max) {
                    try out.writeAll("]");
                    return true;
                }
                written += 1;
                try out.writeAll(if (first) "{" else ",{");
                first = false;
                for (columns[0..result.column_count], 0..) |column, index| {
                    if (index > 0) try out.writeAll(",");
                    try out.print("{f}:", .{std.json.fmt(column.name, .{})});
                    try connection.json_cell(out, column, at);
                }
                try out.writeAll("}");
            }
        }
        try out.writeAll("]");
        return false;
    }

    fn json_cell(connection: *Connection, out: *std.Io.Writer, column: Column, at: usize) !void {
        if (column.is_null(at)) return out.writeAll("null");
        switch (column.type) {
            .boolean => try out.writeAll(if (column.boolean(at).?) "true" else "false"),
            .float, .double => {
                const number = column.float(at).?;
                if (std.math.isFinite(number)) {
                    try out.print("{d}", .{number});
                } else try out.writeAll("null");
            },
            .varchar, .blob => {
                const bytes = column.bytes(at).?;
                if (column.json) {
                    try out.writeAll(bytes);
                } else try out.print("{f}", .{std.json.fmt(bytes, .{})});
            },
            else => if (column.integer(i128, at)) |number| {
                try out.print("{d}", .{number});
            } else return connection.failure.say("column {s}: {s} has no JSON form (cast it)", .{
                column.name, @tagName(column.type),
            }),
        }
    }
};

/// A query's rows as they come, a chunk (a few thousand rows) at a time.
pub const Result = struct {
    connection: *Connection,
    handle: *c.ResultHandle,
    /// What the statement is (known before any row is computed).
    statement: StatementType = .invalid,
    schema: ?*c.Schema = null,
    column_count: usize = 0,
    infos: [columns_max]ColumnInfo = undefined,

    pub const columns_max = 64;
    pub const ColumnInfo = struct { name: []const u8, type: Type, json: bool };

    fn schema_read(result: *Result) !void {
        const failure = &result.connection.failure;
        var info: ?*c.ErrorInfo = null;
        const handle = result.handle;
        const statement = c.duckdb_v2_result_get_statement_type(handle, &result.statement, &info);
        try failure.check(statement, info);
        try failure.check(c.duckdb_v2_result_get_schema(handle, &result.schema, &info), info);
        var count: u64 = 0;
        try failure.check(c.duckdb_v2_schema_get_count(result.schema.?, &count, &info), info);
        if (count > columns_max) {
            return failure.say("{d} columns, past {d}", .{ count, columns_max });
        }
        for (result.infos[0..count], 0..) |*column, index| {
            var name: c.Str = undefined;
            var logical: ?*c.LogicalType = null;
            const schema = result.schema.?;
            const field = c.duckdb_v2_schema_get_field(schema, index, &name, &logical, &info);
            try failure.check(field, info);
            var id: Type = undefined;
            try failure.check(c.duckdb_v2_logical_type_get_id(logical.?, &id, &info), info);
            var type_name: c.Str = undefined;
            const named = c.duckdb_v2_logical_type_get_name(logical.?, &type_name, &info);
            try failure.check(named, info);
            column.* = .{
                .name = name.slice(),
                .type = id,
                .json = std.ascii.eqlIgnoreCase(type_name.slice(), "JSON"),
            };
        }
        result.column_count = count;
    }

    pub fn columns(result: *const Result) []const ColumnInfo {
        return result.infos[0..result.column_count];
    }

    pub fn next(result: *Result) !?Chunk {
        var info: ?*c.ErrorInfo = null;
        var handle: ?*c.DataChunk = null;
        const failure = &result.connection.failure;
        try failure.check(c.duckdb_v2_result_fetch_chunk(result.handle, &handle, &info), info);
        const chunk = handle orelse return null;
        var size: u64 = 0;
        try failure.check(c.duckdb_v2_data_chunk_get_size(chunk, &size, &info), info);
        return .{ .result = result, .handle = chunk, .len = size };
    }

    pub fn deinit(result: *Result) void {
        _ = c.duckdb_v2_schema_destroy(&result.schema);
        var handle: ?*c.ResultHandle = result.handle;
        _ = c.duckdb_v2_result_destroy(&handle);
        result.* = undefined;
    }
};

pub const Chunk = struct {
    result: *Result,
    handle: *c.DataChunk,
    len: usize,

    /// Column `index` of the chunk, valid until the chunk goes.
    pub fn column(chunk: Chunk, index: usize) !Column {
        assert(index < chunk.result.column_count);
        const failure = &chunk.result.connection.failure;
        var info: ?*c.ErrorInfo = null;
        var vector: ?*c.Vector = null;
        const got = c.duckdb_v2_data_chunk_get_vector(chunk.handle, index, &vector, &info);
        try failure.check(got, info);
        var kind: c.VectorType = .other;
        try failure.check(c.duckdb_v2_vector_get_vector_type(vector.?, &kind, &info), info);
        if (kind == .other) {
            try failure.check(c.duckdb_v2_vector_flatten(vector.?, &info), info);
            kind = .flat;
        }
        var view: c.View = undefined;
        try failure.check(c.duckdb_v2_vector_get_view(vector.?, &view, &info), info);
        const described = chunk.result.infos[index];
        return .{
            .name = described.name,
            .type = described.type,
            .json = described.json,
            .view = view,
            .constant = kind == .constant,
        };
    }

    pub fn deinit(chunk: *Chunk) void {
        var handle: ?*c.DataChunk = chunk.handle;
        _ = c.duckdb_v2_data_chunk_destroy(&handle);
        chunk.* = undefined;
    }
};

/// A column of a chunk, read row by row: its values where its selection points (a constant
/// column has one), NULL where its validity says so.
pub const Column = struct {
    name: []const u8,
    type: Type,
    /// A JSON column (VARCHAR underneath).
    json: bool,
    view: c.View,
    constant: bool,

    fn physical(column: Column, at: usize) usize {
        if (column.constant) return 0;
        return if (column.view.sel) |sel| sel[at] else at;
    }

    pub fn is_null(column: Column, at: usize) bool {
        const validity = column.view.validity orelse return false;
        const index = column.physical(at);
        return (validity[index / 64] >> @intCast(index % 64)) & 1 == 0;
    }

    fn element(column: Column, comptime T: type, at: usize) T {
        const data: [*]const T = @ptrCast(@alignCast(column.view.data.?));
        return data[column.physical(at)];
    }

    /// The value as a `T`, when the column holds integers and the value fits.
    pub fn integer(column: Column, comptime T: type, at: usize) ?T {
        return switch (column.type) {
            .tinyint => std.math.cast(T, column.element(i8, at)),
            .smallint => std.math.cast(T, column.element(i16, at)),
            .integer => std.math.cast(T, column.element(i32, at)),
            .bigint => std.math.cast(T, column.element(i64, at)),
            .hugeint => std.math.cast(T, column.element(i128, at)),
            .utinyint => std.math.cast(T, column.element(u8, at)),
            .usmallint => std.math.cast(T, column.element(u16, at)),
            .uinteger => std.math.cast(T, column.element(u32, at)),
            .ubigint => std.math.cast(T, column.element(u64, at)),
            .uhugeint => std.math.cast(T, column.element(u128, at)),
            else => null,
        };
    }

    pub fn float(column: Column, at: usize) ?f64 {
        return switch (column.type) {
            .float => column.element(f32, at),
            .double => column.element(f64, at),
            else => if (column.integer(i128, at)) |number| @floatFromInt(number) else null,
        };
    }

    pub fn boolean(column: Column, at: usize) ?bool {
        if (column.type != .boolean) return null;
        return column.element(u8, at) != 0;
    }

    /// VARCHAR (JSON included) and BLOB values, borrowed until the chunk goes.
    pub fn bytes(column: Column, at: usize) ?[]const u8 {
        if (column.type != .varchar and column.type != .blob) return null;
        const data: [*]const c.Bytes = @ptrCast(@alignCast(column.view.data.?));
        const stored = &data[column.physical(at)];
        if (stored.length <= c.Bytes.inline_max) return stored.inlined[0..stored.length];
        return stored.pointer()[0..stored.length];
    }
};

/// DuckDB's statement types (DUCKDB_V2_STATEMENT_TYPE), those determinismo tells apart.
pub const StatementType = enum(c_int) { invalid = 0, select = 1, explain = 14, _ };

/// DuckDB's logical types (DUCKDB_V2_LOGICAL_TYPE_ID), those determinismo reads.
pub const Type = enum(c_int) {
    sqlnull = 1,
    boolean = 10,
    tinyint = 11,
    smallint = 12,
    integer = 13,
    bigint = 14,
    date = 15,
    timestamp = 19,
    float = 22,
    double = 23,
    varchar = 25,
    blob = 26,
    utinyint = 28,
    usmallint = 29,
    uinteger = 30,
    ubigint = 31,
    uhugeint = 49,
    hugeint = 50,
    @"struct" = 100,
    list = 101,
    map = 102,
    variant = 109,
    _,
};

/// The C API v2 (duckdb_v2.h, DuckDB 2.0.0), what determinismo uses of it.
const c = struct {
    const Code = c_int;
    const none: Code = 0;

    /// duckdb_v2_str: a borrowed view.
    const Str = extern struct {
        ptr: ?[*]const u8,
        len: u64,

        fn from(bytes: []const u8) Str {
            return .{ .ptr = bytes.ptr, .len = bytes.len };
        }

        fn slice(str: Str) []const u8 {
            return if (str.ptr) |ptr| ptr[0..str.len] else "";
        }
    };

    /// duckdb_v2_bytes: VARCHAR and BLOB storage, 16 bytes, inlined up to 12.
    const Bytes = extern struct {
        length: u32,
        inlined: [12]u8,

        const inline_max = 12;

        fn pointer(bytes: *const Bytes) [*]const u8 {
            // Past 12 bytes: a 4-byte prefix, then the pointer.
            const address = std.mem.readInt(usize, bytes.inlined[4..12], .little);
            return @ptrFromInt(address);
        }
    };

    /// duckdb_v2_vector_view.
    const View = extern struct {
        data: ?*const anyopaque,
        validity: ?[*]const u64,
        sel: ?[*]const u32,
        count: u64,
    };

    const VectorType = enum(c_int) { other = 0, flat = 1, constant = 2, dictionary = 3, _ };

    const Environment = opaque {};
    const Instance = opaque {};
    const ConnectionHandle = opaque {};
    const ErrorInfo = opaque {};
    const Factory = opaque {};
    const Value = opaque {};
    const StatementIterator = opaque {};
    const Statement = opaque {};
    const ResultHandle = opaque {};
    const Schema = opaque {};
    const LogicalType = opaque {};
    const DataChunk = opaque {};
    const Vector = opaque {};
    const Error = ?*ErrorInfo;
    const Describe = *const fn (?*anyopaque) callconv(.c) i32;

    extern fn duckdb_register_static_extension(describe: Describe) i32;
    extern fn duckdb_extension_core_functions_describe(?*anyopaque) callconv(.c) i32;
    extern fn duckdb_extension_json_describe(?*anyopaque) callconv(.c) i32;

    extern fn duckdb_v2_environment_create(out: *?*Environment, err: *Error) Code;
    extern fn duckdb_v2_environment_destroy(environment: *?*Environment) Code;
    extern fn duckdb_v2_instance_create_with_options(
        environment: *Environment,
        names: [*]const Str,
        values: [*]const Str,
        count: u64,
        out: *?*Instance,
        err: *Error,
    ) Code;
    extern fn duckdb_v2_instance_destroy(instance: *?*Instance) Code;
    extern fn duckdb_v2_instance_detach(instance: *Instance, name: *const Str, err: *Error) Code;
    extern fn duckdb_v2_instance_attach(
        instance: *Instance,
        name: ?*const Str,
        path: *const Str,
        options: ?*anyopaque,
        make_default: bool,
        err: *Error,
    ) Code;
    extern fn duckdb_v2_connection_create(
        instance: *Instance,
        out: *?*ConnectionHandle,
        err: *Error,
    ) Code;
    extern fn duckdb_v2_connection_destroy(connection: *?*ConnectionHandle) Code;
    extern fn duckdb_v2_connection_get_factory(
        connection: *ConnectionHandle,
        out: *?*Factory,
        err: *Error,
    ) Code;
    extern fn duckdb_v2_parse_sql(
        connection: *ConnectionHandle,
        sql: [*:0]const u8,
        out: *?*StatementIterator,
        err: *Error,
    ) Code;
    extern fn duckdb_v2_statement_iterator_next(
        iterator: *StatementIterator,
        out: *?*Statement,
        err: *Error,
    ) Code;
    extern fn duckdb_v2_statement_iterator_destroy(iterator: *?*StatementIterator) Code;
    extern fn duckdb_v2_sql_statement_destroy(statement: *?*Statement) Code;
    extern fn duckdb_v2_statement_execute(
        connection: *ConnectionHandle,
        statement: *Statement,
        names: ?[*]const Str,
        values: ?[*]const *Value,
        count: u64,
        out: *?*ResultHandle,
        err: *Error,
    ) Code;
    extern fn duckdb_v2_result_destroy(result: *?*ResultHandle) Code;
    extern fn duckdb_v2_result_fetch_chunk(
        result: *ResultHandle,
        out: *?*DataChunk,
        err: *Error,
    ) Code;
    extern fn duckdb_v2_result_drain(result: *ResultHandle, changed: *u64, err: *Error) Code;
    extern fn duckdb_v2_result_get_schema(result: *ResultHandle, out: *?*Schema, err: *Error) Code;
    extern fn duckdb_v2_result_get_statement_type(
        result: *ResultHandle,
        out: *StatementType,
        err: *Error,
    ) Code;
    extern fn duckdb_v2_schema_get_count(schema: *Schema, out: *u64, err: *Error) Code;
    extern fn duckdb_v2_schema_get_field(
        schema: *Schema,
        index: u64,
        name: *Str,
        type: *?*LogicalType,
        err: *Error,
    ) Code;
    extern fn duckdb_v2_schema_destroy(schema: *?*Schema) Code;
    extern fn duckdb_v2_logical_type_get_id(type: *LogicalType, out: *Type, err: *Error) Code;
    extern fn duckdb_v2_logical_type_get_name(type: *LogicalType, out: *Str, err: *Error) Code;
    extern fn duckdb_v2_data_chunk_get_size(chunk: *DataChunk, out: *u64, err: *Error) Code;
    extern fn duckdb_v2_data_chunk_get_vector(
        chunk: *DataChunk,
        index: u64,
        out: *?*Vector,
        err: *Error,
    ) Code;
    extern fn duckdb_v2_data_chunk_destroy(chunk: *?*DataChunk) Code;
    extern fn duckdb_v2_vector_get_vector_type(vector: *Vector, out: *VectorType, err: *Error) Code;
    extern fn duckdb_v2_vector_flatten(vector: *Vector, err: *Error) Code;
    extern fn duckdb_v2_vector_get_view(vector: *Vector, out: *View, err: *Error) Code;
    extern fn duckdb_v2_value_create_varchar(
        factory: *Factory,
        value: *const Str,
        out: *?*Value,
        err: *Error,
    ) Code;
    extern fn duckdb_v2_value_create_ubigint(
        factory: *Factory,
        value: u64,
        out: *?*Value,
        err: *Error,
    ) Code;
    extern fn duckdb_v2_value_create_bigint(
        factory: *Factory,
        value: i64,
        out: *?*Value,
        err: *Error,
    ) Code;
    extern fn duckdb_v2_value_create_double(
        factory: *Factory,
        value: f64,
        out: *?*Value,
        err: *Error,
    ) Code;
    extern fn duckdb_v2_value_create_bool(
        factory: *Factory,
        value: bool,
        out: *?*Value,
        err: *Error,
    ) Code;
    extern fn duckdb_v2_value_destroy(value: *?*Value) Code;
    extern fn duckdb_v2_error_info_get_text(info: *ErrorInfo, out: *Str) Code;
    extern fn duckdb_v2_error_info_destroy(info: *?*ErrorInfo) Code;
};

const testing = std.testing;

fn test_database(failure: *Failure) !Database {
    return Database.open(":memory:", .{ .threads = 2 }, failure);
}

test "queries with parameters, read as rows and as JSON" {
    var failure: Failure = .{};
    var database = try test_database(&failure);
    defer database.close();
    var connection = try database.connect(&failure);
    defer connection.close();
    try connection.exec(
        \\CREATE TABLE t (id UBIGINT, name VARCHAR, ok BOOLEAN, score DOUBLE, body JSON);
        \\INSERT INTO t VALUES (1, 'one', true, 0.5, '{"a":1}'),
        \\  (2, 'a name longer than twelve bytes', false, NULL, NULL), (3, NULL, NULL, 2, '[1,2]');
    );
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Row = struct { id: u32, name: ?[]const u8, ok: ?bool, score: ?f64 };
    const sql = "SELECT id, name, ok, score FROM t WHERE id >= $1 ORDER BY id";
    const all = try connection.rows(Row, arena, sql, .{2});
    try testing.expectEqual(2, all.len);
    try testing.expectEqualStrings("a name longer than twelve bytes", all[0].name.?);
    try testing.expectEqual(false, all[0].ok.?);
    try testing.expectEqual(null, all[0].score);
    try testing.expectEqual(null, all[1].name);
    try testing.expectEqual(2.0, all[1].score.?);

    const Count = struct { count: u64, total: u64 };
    const counting = "SELECT count(*), sum(id) FROM t WHERE name = $1 OR $2";
    const counted = (try connection.row(Count, arena, counting, .{ "one", false })).?;
    try testing.expectEqual(1, counted.count);
    try testing.expectEqual(1, counted.total); // sum: a HUGEINT.

    var out: std.Io.Writer.Allocating = .init(arena);
    try connection.json(&out.writer, "SELECT id, name, ok, score, body FROM t ORDER BY id", .{});
    try testing.expectEqualStrings(
        "[{\"id\":1,\"name\":\"one\",\"ok\":true,\"score\":0.5,\"body\":{\"a\":1}}," ++
            "{\"id\":2,\"name\":\"a name longer than twelve bytes\",\"ok\":false," ++
            "\"score\":null,\"body\":null}," ++
            "{\"id\":3,\"name\":null,\"ok\":null,\"score\":2,\"body\":[1,2]}]",
        out.written(),
    );
}

test "constant and dictionary columns read by their selection" {
    var failure: Failure = .{};
    var database = try test_database(&failure);
    defer database.close();
    var connection = try database.connect(&failure);
    defer connection.close();
    try connection.exec(
        \\CREATE TABLE words AS
        \\    SELECT i, ['alpha', 'beta', 'gamma'][i % 3 + 1] AS word FROM range(5000) t(i);
        \\CHECKPOINT;
    );
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Row = struct { constant: i64, word: []const u8, i: i64 };
    const all = try connection.rows(Row, arena, "SELECT 7, word, i FROM words ORDER BY i", .{});
    try testing.expectEqual(5000, all.len);
    for (all, 0..) |row, index| {
        try testing.expectEqual(7, row.constant);
        try testing.expectEqual(@as(i64, @intCast(index)), row.i);
        const expected = [_][]const u8{ "alpha", "beta", "gamma" };
        try testing.expectEqualStrings(expected[index % 3], row.word);
    }
}

test "a failing statement says why" {
    var failure: Failure = .{};
    var database = try test_database(&failure);
    defer database.close();
    var connection = try database.connect(&failure);
    defer connection.close();
    try testing.expectError(error.DuckDB, connection.exec("SELEC 1"));
    try testing.expect(std.mem.indexOf(u8, connection.failure.text(), "syntax error") != null);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const Row = struct { n: i32 };
    const cast = connection.rows(Row, arena_state.allocator(), "SELECT CAST('x' AS INTEGER)", .{});
    try testing.expectError(error.DuckDB, cast);
    try testing.expect(std.mem.indexOf(u8, connection.failure.text(), "Conversion Error") != null);
}
