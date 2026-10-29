// SPDX-License-Identifier: MIT
//! djblue/tetris (github.com/djblue/tetris), its jank frontend's game: tetris.core (the
//! .cljc the browser and raylib frontends share), AOT-compiled by jank and driven headless by
//! harness.jank, a game per connection. As Antithesis's Tetris quest drove NES Tetris: a tactic
//! plays each piece as good players do (a rotation, a column, a drop; now and then a hold, or a
//! nudge on the way down), every choice a named decision that strategies steer and replays
//! repeat, and how far a game gets (lines, level) is guidance for exploring deeper games.
//!
//! The game's rules as properties, checked after every move: lines rise by four at most, a
//! hard drop places one piece, the board and the falling piece stay in their 10x24, the falling
//! piece never overlaps the stack until the game is over, the score never goes down, the level is
//! the one the lines give, and no move throws.
const std = @import("std");
const assert = std.debug.assert;
const sdk = @import("determinismo");
const tcp = sdk.tcp;

const Nodes = struct { game: sdk.Node };
const System = sdk.System(Nodes);

const port = 7000;
const width = 10;
const height = 24;
const cells_max = width * height;
/// A game's pieces at most (a command's run): long enough to reach deep levels.
const pieces_max = 2000;
/// Moves to place one piece at most: rotations, shifts, nudges, gravity, the drop.
const moves_per_piece_max = 32;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{ .play = scenario } });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.game, .{
        .build = .{ .context = ".", .dockerfile = "examples/tetris/Dockerfile" },
        .ready = .{ .tcp = port },
    });
}

fn scenario(s: *System.Scenario) void {
    // A game, not a distributed system: what varies is the player's moves, not the network.
    s.faults = false;
    s.singleton_driver("play", play);
}

/// The game's state after a move, as harness.jank prints it.
const State = struct {
    lines: u64 = 0,
    score: u64 = 0,
    level: u64 = 0,
    over: bool = false,
    paused: bool = false,
    piece_x: i64 = 0,
    piece_y: i64 = 0,
    player: [4][2]i64 = undefined,
    player_count: u32 = 0,
    board: [cells_max][2]i64 = undefined,
    board_count: u32 = 0,
    /// A cell outside the 10x24 (the board's or the falling piece's), or a malformed line.
    off_board: bool = false,
};

fn play(context: *System.Context) !void {
    var connection: tcp.Connection = undefined;
    try connection.open(context.nodes.game.address, port, .{ .timeout_ms = 10_000 });
    defer connection.close();
    var state = try state_read(&connection);
    var pieces: u64 = 0;
    while (pieces < pieces_max and !state.over) {
        const before = state.lines;
        state = try piece_play(&connection, state);
        pieces += 1;
        milestones(pieces, before, &state);
    }
    sdk.sometimes(state.over, "a game ends", .{ .pieces = pieces, .lines = state.lines });
    sdk.sometimes_greater_than(state.lines, 40, "a game clears over 40 lines", .{ .lines = state.lines });
    sdk.sometimes_greater_than(state.level, 4, "a game reaches level 5", .{ .level = state.level });
    sdk.sometimes_greater_than(state.level, 9, "a game reaches level 10", .{ .level = state.level });
}

/// One piece, as a player places it: rotate, maybe hold, go to a column, maybe nudge on the way
/// down, drop.
fn piece_play(connection: *tcp.Connection, start: State) !State {
    var state = start;
    var moves: u32 = 0;
    if (sdk.random_below_named("tetris.hold", 8) == 0) {
        state = try move(connection, state, "hold");
        moves += 1;
        if (state.over) return state;
    }
    const rotations = [_][]const u8{ "none", "right", "twice", "left" };
    switch (sdk.decide("tetris.rotation", &rotations)) {
        0 => {},
        1 => state = try move(connection, state, "rotr"),
        2 => {
            state = try move(connection, state, "rotr");
            state = try move(connection, state, "rotr");
        },
        3 => state = try move(connection, state, "rotl"),
        else => unreachable,
    }
    const columns = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };
    const column: i64 = @intCast(sdk.decide("tetris.column", &columns));
    while (moves < moves_per_piece_max and state.piece_x != column and !state.over) : (moves += 1) {
        const before = state.piece_x;
        state = try move(connection, state, if (column < state.piece_x) "left" else "right");
        if (state.piece_x == before) break; // Against a wall or the stack.
    }
    // Gravity meanwhile: the frontend's timer ticks while a player decides.
    const ticks = sdk.random_below_named("tetris.ticks", 3);
    for (0..ticks) |_| state = try move(connection, state, "tick");
    // Now and then, slide under an overhang: down a few rows, then a step aside.
    if (sdk.random_below_named("tetris.nudge", 6) == 0) {
        for (0..1 + sdk.random_below_named("tetris.nudge_rows", 8)) |_| {
            state = try move(connection, state, "down");
        }
        const sides = [_][]const u8{ "left", "right" };
        state = try move(connection, state, sides[sdk.decide("tetris.nudge_side", &sides)]);
    }
    if (state.over) return state;
    return move(connection, state, "drop");
}

/// Sends a move, reads the state after it, and checks the game's rules across it.
fn move(connection: *tcp.Connection, before: State, name: []const u8) !State {
    try connection.write_all(name);
    try connection.write_all("\n");
    const after = try state_read(connection);
    const cleared = after.lines -| before.lines;
    sdk.always_less_than_or_equal(cleared, 4, "lines rise by four at most in a move", .{
        .move = name,
        .before = before.lines,
        .after = after.lines,
    });
    sdk.sometimes(cleared == 4, "a move clears four lines (a tetris)", .{ .lines = after.lines });
    sdk.always(after.score >= before.score, "the score never goes down", .{
        .move = name,
        .before = before.score,
        .after = after.score,
    });
    // Cells: four for each piece placed, ten fewer for each line cleared.
    const delta: i64 = @as(i64, after.board_count) - @as(i64, before.board_count) + 10 * @as(i64, @intCast(cleared));
    const placed = @divFloor(delta, 4);
    sdk.always(@mod(delta, 4) == 0 and placed >= 0, "the stack changes by whole pieces", .{
        .move = name,
        .before = before.board_count,
        .after = after.board_count,
        .cleared = cleared,
    });
    if (!before.over) {
        const one = std.mem.eql(u8, name, "drop");
        sdk.always(placed <= 1, "a move places one piece at most", .{
            .move = name,
            .placed = placed,
            .lines = after.lines,
            // Where the piece was, and where the next one is: a piece stuck at the spawn row
            // (y 1) and a new one there too keep player-drop's loop going (README).
            .x_before = before.piece_x,
            .y_before = before.piece_y,
            .y_after = after.piece_y,
        });
        if (one) sdk.always(placed == 1 or after.over, "a hard drop places its piece", .{ .placed = placed });
    }
    sdk.always(!after.off_board, "the stack and the falling piece stay on the 10x24 board", .{ .move = name });
    sdk.always(after.over or !overlaps(&after), "the falling piece never overlaps the stack in play", .{
        .move = name,
    });
    sdk.always(after.level == level_of(after.lines), "the level is the one the lines give", .{
        .move = name,
        .lines = after.lines,
        .level = after.level,
    });
    return after;
}

/// Antithesis's Tetris quest bucketed states by depth (pieces so far) and kept each bucket's
/// best (fewest bubbles, most lines). Here each depth (every 5 pieces) has a guidance assertion
/// of its own, "no holes after N pieces": its distance is the holes, and the tree takes a
/// timeline that came a power of two closer at a depth for a new behavior, returning to it and
/// branching from there. So every improvement at any depth is a rung, and deeper depths open
/// as games last. (Fixed rungs, "10 pieces in, 8 holes at most", were never reached: random
/// placement leaves more holes than that by then, run 110.) Lines cleared are milestones.
const depth_step = 5;
const depth_buckets = 60; // 300 pieces.
const line_milestones = [_]u64{ 1, 2, 3, 4, 6, 8, 10, 15, 20, 30, 40, 60, 80, 120, 160, 240 };

fn milestones(pieces: u64, lines_before: u64, state: *const State) void {
    @setEvalBranchQuota(200_000); // The messages, formatted at compile time.
    if (pieces % depth_step == 0 and pieces / depth_step <= depth_buckets) {
        const holes = holes_of(state);
        inline for (1..depth_buckets + 1) |bucket| {
            if (pieces == bucket * depth_step) {
                const message = std.fmt.comptimePrint("no holes after {d} pieces", .{bucket * depth_step});
                sdk.sometimes_less_than_or_equal(holes, 0, message, .{ .lines = state.lines });
            }
        }
    }
    inline for (line_milestones) |lines| {
        if (lines_before < lines and state.lines >= lines) {
            const message = std.fmt.comptimePrint("a game clears {d} lines", .{lines});
            sdk.reachable(message, .{ .pieces = pieces, .level = state.level });
        }
    }
}

/// Empty cells with a filled cell above them, in the same column.
fn holes_of(state: *const State) u32 {
    var top: [width]i64 = @splat(height);
    var filled: [width][height]bool = @splat(@splat(false));
    for (state.board[0..state.board_count]) |cell| {
        const x: usize = @intCast(cell[0]);
        const y: usize = @intCast(cell[1]);
        filled[x][y] = true;
        top[x] = @min(top[x], cell[1]);
    }
    var holes: u32 = 0;
    for (0..width) |x| {
        var y = top[x] + 1;
        while (y < height) : (y += 1) {
            if (!filled[x][@intCast(y)]) holes += 1;
        }
    }
    return holes;
}

/// The level the lines give, as tetris.core counts them: level L needs 5 * L * (L + 1) / 2 lines.
fn level_of(lines: u64) u64 {
    var level: u64 = 0;
    while (5 * (level + 1) * (level + 2) / 2 <= lines) level += 1;
    return level;
}

fn overlaps(state: *const State) bool {
    for (state.player[0..state.player_count]) |cell| {
        for (state.board[0..state.board_count]) |taken| {
            if (cell[0] == taken[0] and cell[1] == taken[1]) return true;
        }
    }
    return false;
}

/// The next state line; a move that threw ("error <move> <what>") is a property failing, and the
/// state that follows it is read.
fn state_read(connection: *tcp.Connection) !State {
    while (true) {
        const line = try connection.read_line();
        if (std.mem.startsWith(u8, line, "error ")) {
            sdk.assert_unreachable("no move throws", .{ .error_line = line });
            continue;
        }
        return state_parse(line);
    }
}

fn state_parse(line: []const u8) State {
    var state: State = .{};
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    while (fields.next()) |field| {
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const key = field[0..equals];
        const value = field[equals + 1 ..];
        if (std.mem.eql(u8, key, "lines")) state.lines = number(u64, value, &state);
        if (std.mem.eql(u8, key, "score")) state.score = number(u64, value, &state);
        if (std.mem.eql(u8, key, "level")) state.level = number(u64, value, &state);
        if (std.mem.eql(u8, key, "over")) state.over = std.mem.eql(u8, value, "1");
        if (std.mem.eql(u8, key, "paused")) state.paused = std.mem.eql(u8, value, "1");
        if (std.mem.eql(u8, key, "piece")) {
            var parts = std.mem.splitScalar(u8, value, ',');
            _ = parts.next(); // Its type.
            state.piece_x = number(i64, parts.next() orelse "", &state);
            state.piece_y = number(i64, parts.next() orelse "", &state);
        }
        if (std.mem.eql(u8, key, "player")) state.player_count = cells_parse(value, &state.player, &state);
        if (std.mem.eql(u8, key, "board")) state.board_count = cells_parse(value, &state.board, &state);
    }
    return state;
}

/// "x,y;x,y;...": the cells, each checked on the board.
fn cells_parse(text: []const u8, cells: [][2]i64, state: *State) u32 {
    var count: u32 = 0;
    var items = std.mem.tokenizeScalar(u8, text, ';');
    while (items.next()) |item| {
        if (count == cells.len) {
            state.off_board = true;
            break;
        }
        var parts = std.mem.splitScalar(u8, item, ',');
        const x = number(i64, parts.next() orelse "", state);
        const y = number(i64, parts.next() orelse "", state);
        if (x < 0 or x >= width or y < 0 or y >= height) state.off_board = true;
        cells[count] = .{ x, y };
        count += 1;
    }
    return count;
}

fn number(comptime T: type, text: []const u8, state: *State) T {
    return std.fmt.parseInt(T, text, 10) catch {
        state.off_board = true; // Malformed: reported with the board's property.
        return 0;
    };
}

test level_of {
    try std.testing.expectEqual(0, level_of(4));
    try std.testing.expectEqual(1, level_of(5));
    try std.testing.expectEqual(1, level_of(14));
    try std.testing.expectEqual(2, level_of(15));
}

test state_parse {
    const state = state_parse("lines=3 score=900 level=0 over=0 paused=0 held=- piece=T,5,1,0 " ++
        "player=4,1;5,0;5,1;6,1 board=0,23;1,23");
    try std.testing.expectEqual(3, state.lines);
    try std.testing.expectEqual(5, state.piece_x);
    try std.testing.expectEqual(4, state.player_count);
    try std.testing.expectEqual(2, state.board_count);
    try std.testing.expect(!state.off_board);
    try std.testing.expect(!overlaps(&state));
    const off = state_parse("lines=0 score=0 level=0 over=0 paused=0 held=- piece=I,9,1,0 " ++
        "player=8,1;9,1;10,1;11,1 board=");
    try std.testing.expect(off.off_board);
}

test holes_of {
    // Column 0 filled at rows 20 and 23: rows 21 and 22 are holes; column 1 full from 22 down.
    const state = state_parse("lines=0 score=0 level=0 over=0 paused=0 held=- piece=O,5,1,0 " ++
        "player=5,1;6,1;5,2;6,2 board=0,20;0,23;1,22;1,23");
    try std.testing.expectEqual(2, holes_of(&state));
}
