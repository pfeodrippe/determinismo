// SPDX-License-Identifier: MIT
//! The subset of YAML that Compose files use, read into a tree: block mappings and sequences by
//! indentation, flow sequences `[a, b]` and mappings `{a: b}`, plain and quoted scalars, block
//! scalars (`|`, `>`), comments. No anchors, tags or multi-document streams (rejected, not
//! misread).
const std = @import("std");
const assert = std.debug.assert;

pub const Value = union(enum) {
    scalar: []const u8,
    sequence: []const Value,
    mapping: []const Entry,
    empty,

    pub const Entry = struct { key: []const u8, value: Value };

    pub fn get(value: Value, key: []const u8) ?Value {
        if (value != .mapping) return null;
        for (value.mapping) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }
};

const Line = struct { indent: u32, text: []const u8, number: u32 };

const depth_max = 64;
const lines_max = 1 << 20;

pub fn parse(arena: std.mem.Allocator, source: []const u8) !Value {
    var lines: std.ArrayList(Line) = .empty;
    var splitter = std.mem.splitScalar(u8, source, '\n');
    var number: u32 = 0;
    while (splitter.next()) |raw| {
        number += 1;
        if (lines.items.len == lines_max) return error.TooManyLines;
        const line = std.mem.trimEnd(u8, raw, " \r\t");
        const content = std.mem.trimStart(u8, line, " ");
        if (std.mem.indexOfScalar(u8, line[0 .. line.len - content.len], '\t') != null) {
            return error.TabIndentation;
        }
        if (std.mem.startsWith(u8, content, "---") or std.mem.startsWith(u8, content, "...")) {
            if (lines.items.len == 0) continue; // A leading document marker.
            return error.MultipleDocuments;
        }
        try lines.append(arena, .{
            .indent = @intCast(line.len - content.len),
            .text = content,
            .number = number,
        });
    }
    var parser = Parser{ .arena = arena, .lines = lines.items };
    parser.skip_blank();
    if (parser.index == parser.lines.len) return .empty;
    const value = try parser.block(parser.lines[parser.index].indent, 0);
    parser.skip_blank();
    if (parser.index != parser.lines.len) return error.UnexpectedIndentation;
    return value;
}

const Parser = struct {
    arena: std.mem.Allocator,
    /// Owned: a "- key: value" line is rewritten in place as "key: value", one level deeper.
    lines: []Line,
    index: usize = 0,

    fn skip_blank(parser: *Parser) void {
        while (parser.index < parser.lines.len) : (parser.index += 1) {
            const text = parser.lines[parser.index].text;
            if (text.len > 0 and text[0] != '#') return;
        }
    }

    /// A block (mapping or sequence) whose lines are indented by exactly `indent`.
    fn block(parser: *Parser, indent: u32, depth: u32) anyerror!Value {
        if (depth == depth_max) return error.TooDeep;
        parser.skip_blank();
        const first = parser.lines[parser.index];
        assert(first.indent == indent);
        if (is_sequence_item(first.text)) return parser.sequence(indent, depth);
        return parser.mapping(indent, depth);
    }

    fn sequence(parser: *Parser, indent: u32, depth: u32) anyerror!Value {
        var items: std.ArrayList(Value) = .empty;
        while (true) {
            parser.skip_blank();
            if (parser.index == parser.lines.len) break;
            const line = parser.lines[parser.index];
            if (line.indent < indent) break;
            if (line.indent > indent) return error.BadSequence;
            if (!is_sequence_item(line.text)) break; // The next key of a mapping at this level.
            const rest = std.mem.trimStart(u8, line.text[1..], " ");
            if (rest.len == 0) {
                parser.index += 1;
                try items.append(parser.arena, try parser.nested(indent, depth));
            } else if (mapping_key(rest) != null) {
                // "- key: value" starts a mapping indented where `key` is.
                const item_indent = indent + @as(u32, @intCast(line.text.len - rest.len));
                parser.lines[parser.index] = .{
                    .indent = item_indent,
                    .text = rest,
                    .number = line.number,
                };
                try items.append(parser.arena, try parser.mapping(item_indent, depth + 1));
            } else {
                parser.index += 1;
                try items.append(parser.arena, try parser.scalar_or_flow(rest, indent, depth));
            }
        }
        return .{ .sequence = items.items };
    }

    fn mapping(parser: *Parser, indent: u32, depth: u32) anyerror!Value {
        var entries: std.ArrayList(Value.Entry) = .empty;
        while (true) {
            parser.skip_blank();
            if (parser.index == parser.lines.len) break;
            const line = parser.lines[parser.index];
            if (line.indent < indent) break;
            if (line.indent > indent) return error.UnexpectedIndentation;
            const split = mapping_key(line.text) orelse return error.ExpectedKey;
            const key = try unquote(parser.arena, split.key);
            parser.index += 1;
            const value = if (split.value.len == 0)
                try parser.nested(indent, depth)
            else
                try parser.scalar_or_flow(split.value, indent, depth);
            try entries.append(parser.arena, .{ .key = key, .value = value });
        }
        return .{ .mapping = entries.items };
    }

    /// What follows "key:" or "-" on the next lines: a deeper block, or nothing. Compose also
    /// writes sequences under a key at the key's own indentation.
    fn nested(parser: *Parser, indent: u32, depth: u32) anyerror!Value {
        parser.skip_blank();
        if (parser.index == parser.lines.len) return .empty;
        const next = parser.lines[parser.index];
        if (next.indent > indent) return parser.block(next.indent, depth + 1);
        if (next.indent == indent and is_sequence_item(next.text)) {
            return parser.sequence(indent, depth + 1);
        }
        return .empty;
    }

    fn scalar_or_flow(parser: *Parser, text: []const u8, indent: u32, depth: u32) anyerror!Value {
        const value = strip_comment(text);
        if (value.len == 0) return .empty;
        if (value[0] == '&' or value[0] == '*' or value[0] == '!') return error.UnsupportedYaml;
        if (value[0] == '|' or value[0] == '>') return parser.block_scalar(value[0] == '>', indent);
        if (value[0] == '[' or value[0] == '{') {
            var flow = Flow{ .arena = parser.arena, .text = value };
            const parsed = try flow.value(depth);
            flow.skip_spaces();
            if (flow.position != flow.text.len) return error.TrailingCharacters;
            return parsed;
        }
        return .{ .scalar = try unquote(parser.arena, value) };
    }

    /// `|` keeps newlines, `>` folds them into spaces; lines deeper than the key belong to it.
    fn block_scalar(parser: *Parser, folded: bool, indent: u32) !Value {
        var text: std.ArrayList(u8) = .empty;
        var content_indent: ?u32 = null;
        while (parser.index < parser.lines.len) : (parser.index += 1) {
            const line = parser.lines[parser.index];
            if (line.text.len > 0 and line.indent <= indent) break;
            if (content_indent == null and line.text.len > 0) content_indent = line.indent;
            if (text.items.len > 0) try text.append(parser.arena, if (folded) ' ' else '\n');
            const base = content_indent orelse line.indent;
            const extra = if (line.text.len == 0) 0 else line.indent -| base;
            try text.appendNTimes(parser.arena, ' ', extra);
            try text.appendSlice(parser.arena, line.text);
        }
        return .{ .scalar = text.items };
    }
};

/// Flow collections: `[a, "b", {c: d}]`.
const Flow = struct {
    arena: std.mem.Allocator,
    text: []const u8,
    position: usize = 0,

    fn skip_spaces(flow: *Flow) void {
        while (flow.position < flow.text.len and flow.text[flow.position] == ' ') {
            flow.position += 1;
        }
    }

    fn value(flow: *Flow, depth: u32) anyerror!Value {
        if (depth == depth_max) return error.TooDeep;
        flow.skip_spaces();
        if (flow.position == flow.text.len) return error.UnexpectedEnd;
        switch (flow.text[flow.position]) {
            '[' => {
                flow.position += 1;
                var items: std.ArrayList(Value) = .empty;
                while (true) {
                    flow.skip_spaces();
                    if (flow.peek(']')) break;
                    try items.append(flow.arena, try flow.value(depth + 1));
                    flow.skip_spaces();
                    if (flow.peek(']')) break;
                    if (!flow.peek(',')) return error.ExpectedComma;
                }
                return .{ .sequence = items.items };
            },
            '{' => {
                flow.position += 1;
                var entries: std.ArrayList(Value.Entry) = .empty;
                while (true) {
                    flow.skip_spaces();
                    if (flow.peek('}')) break;
                    const key = try flow.scalar(":");
                    if (!flow.peek(':')) return error.ExpectedColon;
                    const entry_value = try flow.value(depth + 1);
                    try entries.append(flow.arena, .{ .key = key, .value = entry_value });
                    flow.skip_spaces();
                    if (flow.peek('}')) break;
                    if (!flow.peek(',')) return error.ExpectedComma;
                }
                return .{ .mapping = entries.items };
            },
            else => return .{ .scalar = try flow.scalar(",]}") },
        }
    }

    fn peek(flow: *Flow, byte: u8) bool {
        if (flow.position < flow.text.len and flow.text[flow.position] == byte) {
            flow.position += 1;
            return true;
        }
        return false;
    }

    fn scalar(flow: *Flow, comptime stops: []const u8) ![]const u8 {
        flow.skip_spaces();
        const start = flow.position;
        if (start < flow.text.len and (flow.text[start] == '"' or flow.text[start] == '\'')) {
            const quote = flow.text[start];
            flow.position += 1;
            while (flow.position < flow.text.len and flow.text[flow.position] != quote) {
                if (quote == '"' and flow.text[flow.position] == '\\') flow.position += 1;
                flow.position += 1;
            }
            if (flow.position == flow.text.len) return error.UnterminatedString;
            flow.position += 1;
            return unquote(flow.arena, flow.text[start..flow.position]);
        }
        while (flow.position < flow.text.len and
            std.mem.indexOfScalar(u8, stops, flow.text[flow.position]) == null) flow.position += 1;
        return std.mem.trim(u8, flow.text[start..flow.position], " ");
    }
};

fn is_sequence_item(text: []const u8) bool {
    return text.len > 0 and text[0] == '-' and (text.len == 1 or text[1] == ' ');
}

const Split = struct { key: []const u8, value: []const u8 };

/// `key: value` (the colon followed by a space or the end, outside quotes).
fn mapping_key(text: []const u8) ?Split {
    var quote: ?u8 = null;
    for (text, 0..) |byte, index| {
        if (quote) |open| {
            if (byte == open) quote = null;
            continue;
        }
        switch (byte) {
            '"', '\'' => if (index == 0) {
                quote = byte;
            },
            '#' => if (index > 0 and text[index - 1] == ' ') return null,
            ':' => if (index + 1 == text.len or text[index + 1] == ' ') {
                return .{
                    .key = std.mem.trim(u8, text[0..index], " "),
                    .value = std.mem.trim(u8, text[index + 1 ..], " "),
                };
            },
            '[', '{' => if (index == 0) return null,
            else => {},
        }
    }
    return null;
}

fn strip_comment(text: []const u8) []const u8 {
    var quote: ?u8 = null;
    for (text, 0..) |byte, index| {
        if (quote) |open| {
            if (byte == open) quote = null;
            continue;
        }
        if ((byte == '"' or byte == '\'') and index == 0) quote = byte;
        if (byte == '#' and (index == 0 or text[index - 1] == ' ')) {
            return std.mem.trimEnd(u8, text[0..index], " ");
        }
    }
    return text;
}

fn unquote(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (text.len >= 2 and text[0] == '\'' and text[text.len - 1] == '\'') {
        return std.mem.replaceOwned(u8, arena, text[1 .. text.len - 1], "''", "'");
    }
    if (text.len < 2 or text[0] != '"' or text[text.len - 1] != '"') return text;
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 1;
    while (index < text.len - 1) : (index += 1) {
        if (text[index] != '\\' or index + 1 == text.len - 1) {
            try out.append(arena, text[index]);
            continue;
        }
        index += 1;
        try out.append(arena, switch (text[index]) {
            'n' => '\n',
            't' => '\t',
            else => text[index],
        });
    }
    return out.items;
}

test "a compose file" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const source =
        \\# The shop.
        \\services:
        \\  postgres:
        \\    image: "postgres:17-alpine"
        \\    environment:
        \\      POSTGRES_HOST_AUTH_METHOD: trust
        \\    ports: ["5432"]
        \\  client:
        \\    build:
        \\      context: ./client
        \\    command: [sleep, infinity]   # Tests exec into it.
        \\    depends_on:
        \\    - postgres
        \\    healthcheck:
        \\      test: |
        \\        pg_isready -h postgres
        \\        echo ok
    ;
    const root = try parse(arena_state.allocator(), source);
    const services = root.get("services").?;
    const postgres = services.get("postgres").?;
    try std.testing.expectEqualStrings("postgres:17-alpine", postgres.get("image").?.scalar);
    const environment = postgres.get("environment").?;
    const method = environment.get("POSTGRES_HOST_AUTH_METHOD").?.scalar;
    try std.testing.expectEqualStrings("trust", method);
    try std.testing.expectEqualStrings("5432", postgres.get("ports").?.sequence[0].scalar);
    const client = services.get("client").?;
    try std.testing.expectEqualStrings("infinity", client.get("command").?.sequence[1].scalar);
    try std.testing.expectEqualStrings("postgres", client.get("depends_on").?.sequence[0].scalar);
    const test_script = client.get("healthcheck").?.get("test").?.scalar;
    try std.testing.expectEqualStrings("pg_isready -h postgres\necho ok", test_script);
}

test "sequences of mappings" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const source =
        \\volumes:
        \\  - type: bind
        \\    source: ./data
        \\  - name: x
    ;
    const root = try parse(arena_state.allocator(), source);
    const volumes = root.get("volumes").?.sequence;
    try std.testing.expectEqual(@as(usize, 2), volumes.len);
    try std.testing.expectEqualStrings("./data", volumes[0].get("source").?.scalar);
    try std.testing.expectEqualStrings("x", volumes[1].get("name").?.scalar);
}

test "anchors are rejected" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.UnsupportedYaml, parse(arena_state.allocator(), "a: &x 1"));
}
