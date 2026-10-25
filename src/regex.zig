// SPDX-License-Identifier: MIT
//! Regular expressions for searching events (`determinismo query`'s `=~`): a small backtracking
//! matcher, enough for logs. Literals; `.`; classes `[a-z_]`, `[^0-9]`; escapes `\d \w \s` (and
//! `\D \W \S`, or any escaped character as itself); `*`, `+`, `?` after a single character, a
//! class or `.`; anchors `^`, `$`; groups `(a|b)` with alternatives (`|` also at the top);
//! `(?i)` at the start ignores case. A match anywhere in the text counts. Matching has a step
//! budget, so that no pattern runs away: past it, the text does not match.
const std = @import("std");
const assert = std.debug.assert;

const items_max = 256;
const steps_max = 1_000_000;
const unbounded = std.math.maxInt(u32);

pub const Regex = struct {
    alternatives: []const Sequence,
    ignore_case: bool,

    pub fn compile(arena: std.mem.Allocator, pattern: []const u8) !Regex {
        const flag = "(?i)";
        const ignore_case = std.mem.startsWith(u8, pattern, flag);
        var parser = Parser{
            .arena = arena,
            .pattern = if (ignore_case) pattern[flag.len..] else pattern,
        };
        const alternatives = try parser.alternatives();
        if (parser.at != parser.pattern.len) return error.BadPattern; // A stray ')'.
        return .{ .alternatives = alternatives, .ignore_case = ignore_case };
    }

    /// Whether the pattern matches somewhere in `text`.
    pub fn matches(regex: *const Regex, text: []const u8) bool {
        var matcher = Matcher{ .text = text, .ignore_case = regex.ignore_case };
        const top = Item{ .atom = .{ .group = regex.alternatives } };
        const sequence = [_]Item{top};
        for (0..text.len + 1) |start| {
            if (matcher.sequence(&sequence, 0, start, null)) return true;
            if (matcher.steps > steps_max) return false;
        }
        return false;
    }
};

const Sequence = []const Item;

const Item = struct {
    atom: Atom,
    min: u32 = 1,
    max: u32 = 1,
};

const Atom = union(enum) {
    byte: u8,
    any,
    class: Class,
    start,
    end,
    group: []const Sequence,
};

const Class = struct {
    set: std.StaticBitSet(256),
};

const Parser = struct {
    arena: std.mem.Allocator,
    pattern: []const u8,
    at: usize = 0,

    fn alternatives(parser: *Parser) error{ BadPattern, OutOfMemory }![]const Sequence {
        var list: std.ArrayList(Sequence) = .empty;
        while (true) {
            try list.append(parser.arena, try parser.sequence());
            if (parser.at < parser.pattern.len and parser.pattern[parser.at] == '|') {
                parser.at += 1;
                continue;
            }
            return list.items;
        }
    }

    fn sequence(parser: *Parser) error{ BadPattern, OutOfMemory }!Sequence {
        var items: std.ArrayList(Item) = .empty;
        while (parser.at < parser.pattern.len) {
            const byte = parser.pattern[parser.at];
            if (byte == '|' or byte == ')') break;
            if (items.items.len == items_max) return error.BadPattern;
            var item = Item{ .atom = try parser.atom() };
            if (parser.at < parser.pattern.len) {
                const bounds: ?[2]u32 = switch (parser.pattern[parser.at]) {
                    '*' => .{ 0, unbounded },
                    '+' => .{ 1, unbounded },
                    '?' => .{ 0, 1 },
                    else => null,
                };
                if (bounds) |range| {
                    // Repeating a group or an anchor is beyond this matcher.
                    switch (item.atom) {
                        .byte, .any, .class => {},
                        else => return error.BadPattern,
                    }
                    item.min = range[0];
                    item.max = range[1];
                    parser.at += 1;
                }
            }
            try items.append(parser.arena, item);
        }
        return items.items;
    }

    fn atom(parser: *Parser) error{ BadPattern, OutOfMemory }!Atom {
        const byte = parser.pattern[parser.at];
        parser.at += 1;
        switch (byte) {
            '.' => return .any,
            '^' => return .start,
            '$' => return .end,
            '*', '+', '?' => return error.BadPattern, // Nothing to repeat.
            '(' => {
                const group = try parser.alternatives();
                if (parser.at == parser.pattern.len or parser.pattern[parser.at] != ')') {
                    return error.BadPattern;
                }
                parser.at += 1;
                return .{ .group = group };
            },
            '[' => return .{ .class = try parser.class() },
            '\\' => return parser.escape(),
            else => return .{ .byte = byte },
        }
    }

    fn escape(parser: *Parser) !Atom {
        if (parser.at == parser.pattern.len) return error.BadPattern;
        const byte = parser.pattern[parser.at];
        parser.at += 1;
        var set = Class{ .set = .empty };
        const negated = std.ascii.isUpper(byte);
        switch (std.ascii.toLower(byte)) {
            'd' => class_add(&set, '0', '9'),
            'w' => {
                class_add(&set, 'a', 'z');
                class_add(&set, 'A', 'Z');
                class_add(&set, '0', '9');
                set.set.set('_');
            },
            's' => for (" \t\n\r\x0b\x0c") |space| set.set.set(space),
            else => return .{ .byte = byte },
        }
        if (negated) set.set.toggleAll();
        return .{ .class = set };
    }

    fn class(parser: *Parser) !Class {
        var result = Class{ .set = .empty };
        const negated = parser.at < parser.pattern.len and parser.pattern[parser.at] == '^';
        if (negated) parser.at += 1;
        var first = true;
        while (parser.at < parser.pattern.len) {
            var low = parser.pattern[parser.at];
            if (low == ']' and !first) break;
            first = false;
            parser.at += 1;
            if (low == '\\') {
                if (parser.at == parser.pattern.len) return error.BadPattern;
                const escaped = try parser_escape_in_class(parser, &result);
                low = escaped orelse continue;
            }
            const range = parser.at + 1 < parser.pattern.len and
                parser.pattern[parser.at] == '-' and parser.pattern[parser.at + 1] != ']';
            if (range) {
                const high = parser.pattern[parser.at + 1];
                if (high < low) return error.BadPattern;
                parser.at += 2;
                class_add(&result, low, high);
            } else result.set.set(low);
        } else return error.BadPattern; // No closing ']'.
        parser.at += 1;
        if (negated) result.set.toggleAll();
        return result;
    }
};

/// `\d`, `\w` and `\s` inside a class add their sets (null); another escaped byte is itself.
fn parser_escape_in_class(parser: *Parser, class: *Class) !?u8 {
    const before = parser.at;
    const escaped = try parser.escape();
    switch (escaped) {
        .byte => |byte| return byte,
        .class => |set| {
            class.set.setUnion(set.set);
            return null;
        },
        else => {
            parser.at = before;
            return error.BadPattern;
        },
    }
}

fn class_add(class: *Class, low: u8, high: u8) void {
    assert(low <= high);
    var byte: u16 = low;
    while (byte <= high) : (byte += 1) class.set.set(byte);
}

/// What comes after the sequence being matched: the rest of each enclosing sequence.
const Continuation = struct {
    items: Sequence,
    index: usize,
    next: ?*const Continuation,
};

const Matcher = struct {
    text: []const u8,
    ignore_case: bool,
    steps: u32 = 0,

    fn sequence(
        matcher: *Matcher,
        items: Sequence,
        index: usize,
        position: usize,
        continuation: ?*const Continuation,
    ) bool {
        matcher.steps += 1;
        if (matcher.steps > steps_max) return false;
        if (index == items.len) {
            const rest = continuation orelse return true;
            return matcher.sequence(rest.items, rest.index, position, rest.next);
        }
        const item = items[index];
        switch (item.atom) {
            .start => return position == 0 and
                matcher.sequence(items, index + 1, position, continuation),
            .end => return position == matcher.text.len and
                matcher.sequence(items, index + 1, position, continuation),
            .group => |group| {
                const after = Continuation{
                    .items = items,
                    .index = index + 1,
                    .next = continuation,
                };
                for (group) |alternative| {
                    if (matcher.sequence(alternative, 0, position, &after)) return true;
                }
                return false;
            },
            .byte, .any, .class => {
                // Greedy: as many as fit, then fewer until the rest matches.
                var count: usize = 0;
                while (count < item.max and position + count < matcher.text.len and
                    matcher.single(item.atom, matcher.text[position + count])) count += 1;
                while (count + 1 > item.min) : (count -= 1) {
                    if (matcher.sequence(items, index + 1, position + count, continuation)) {
                        return true;
                    }
                    if (count == 0) break;
                }
                return false;
            },
        }
    }

    fn single(matcher: *const Matcher, atom: Atom, byte: u8) bool {
        return switch (atom) {
            .any => byte != '\n',
            .byte => |wanted| wanted == byte or (matcher.ignore_case and
                std.ascii.toLower(wanted) == std.ascii.toLower(byte)),
            .class => |class| class.set.isSet(byte) or (matcher.ignore_case and
                (class.set.isSet(std.ascii.toLower(byte)) or
                    class.set.isSet(std.ascii.toUpper(byte)))),
            else => unreachable,
        };
    }
};

fn expect_match(pattern: []const u8, text: []const u8, expected: bool) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const regex = try Regex.compile(arena_state.allocator(), pattern);
    try std.testing.expectEqual(expected, regex.matches(text));
}

test Regex {
    try expect_match("refused", "connection refused by peer", true);
    try expect_match("^conn", "connection", true);
    try expect_match("^onn", "connection", false);
    try expect_match("ion$", "connection", true);
    try expect_match("c.n+e", "connection", true);
    try expect_match("timeout (after|in) \\d+ ?ms", "timeout after 30ms", true);
    try expect_match("timeout (after|in) \\d+ ?ms", "timeout in 7 ms", true);
    try expect_match("timeout (after|in) \\d+ ?ms", "timeout at 7 ms", false);
    try expect_match("[A-Z]+_ERR", "got DISK_ERR here", true);
    try expect_match("[^a-z ]", "only lower case", false);
    try expect_match("(?i)panic", "PANIC: boom", true);
    try expect_match("a|b", "xxb", true);
    try expect_match("x*", "", true);
    try expect_match("\\.\\w+$", "file.zig", true);
    try expect_match("[\\d.]+", "v1.2", true);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "(a", "a)", "*a", "[a", "(ab)+", "\\" }) |bad| {
        try std.testing.expectError(error.BadPattern, Regex.compile(arena, bad));
    }
    // Catastrophic backtracking stops at the step budget instead of running away.
    const slow = try Regex.compile(arena, "a*a*a*a*a*a*a*a*a*b");
    const many: [64]u8 = @splat('a');
    try std.testing.expect(!slow.matches(&many));
}
