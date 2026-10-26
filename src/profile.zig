// SPDX-License-Identifier: MIT
//! `determinismo profile`: where a node spends its CPU from a moment of a timeline on, as
//! Antithesis's environment.profiler.
//!
//!   determinismo profile <machine and system options> --seed <s> --branch <n>
//!       (--at-vtime-ms <ms> | --until '<condition>' [--rewind-ms <ms>]) --node <node>
//!       [--ms <duration>] [--interval-us <us>] [--pid <pid>] [--all]
//!       [--svg <flame graph.svg>] [--folded <stacks.txt>]
//!
//! The branch replays to the moment; there det-profile samples the node's runnable threads
//! every interval of virtual time, for the duration, while the timeline runs on. It prints the
//! functions with the most samples; --svg writes a flame graph and --folded the folded stacks
//! (for any flame graph tool). The same moment and options give the same profile, sample for
//! sample.
//!
//!   determinismo stacks <machine and system options> --seed <s> --branch <n> (moment options)
//!       --node <node> [--pid <pid>]
//!
//! Every thread's stack at the moment, named (`thread apply all bt`, jstack): where each thread
//! of the node is, running or waiting.
const std = @import("std");
const assert = std.debug.assert;
const extract = @import("extract.zig");

const profiler_path = "/opt/determinismo/bin/det-profile";
const functions_shown = 15;

pub fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    self: []const u8,
    arguments: []const [:0]const u8,
) !u8 {
    var node: ?[]const u8 = null;
    var svg: ?[]const u8 = null;
    var folded_path: ?[]const u8 = null;
    var profiler: std.ArrayList(u8) = .empty;
    var rest: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const flag = arguments[index];
        if (std.mem.eql(u8, flag, "--all")) {
            try profiler.appendSlice(arena, " --all");
            continue;
        }
        const passed = for ([_][]const u8{ "--ms", "--interval-us", "--pid" }) |name| {
            if (std.mem.eql(u8, flag, name)) break true;
        } else false;
        const ours = passed or std.mem.eql(u8, flag, "--node") or
            std.mem.eql(u8, flag, "--svg") or std.mem.eql(u8, flag, "--folded");
        if (!ours) {
            try rest.append(arena, flag);
            continue;
        }
        index += 1;
        if (index == arguments.len) return error.Usage;
        const value = arguments[index];
        if (passed) {
            _ = std.fmt.parseInt(u64, value, 10) catch return error.Usage;
            try profiler.print(arena, " {s} {s}", .{ flag, value });
        } else if (std.mem.eql(u8, flag, "--node")) {
            node = value;
        } else if (std.mem.eql(u8, flag, "--svg")) svg = value else folded_path = value;
    }
    const target = node orelse return error.Usage;
    if (!node_valid(target)) return error.Usage;
    const command = try std.fmt.allocPrint(arena, "{s} {s}{s}", .{
        profiler_path, target, profiler.items,
    });
    const folded = try extract.exec_run(arena, io, self, rest.items, command);
    const stacks = try stacks_parse(arena, folded);
    if (stacks.samples == 0) {
        std.debug.print("[determinismo] profile: no samples (is {s} running?)\n{s}", .{
            target, folded,
        });
        return 1;
    }
    try summary_print(arena, &stacks);
    const cwd = std.Io.Dir.cwd();
    if (folded_path) |path| try cwd.writeFile(io, .{ .sub_path = path, .data = folded });
    if (svg) |path| {
        const graph = try flame_graph(arena, &stacks, target);
        try cwd.writeFile(io, .{ .sub_path = path, .data = graph });
        std.debug.print("[determinismo] flame graph: {s}\n", .{path});
    }
    return 0;
}

pub fn stacks_run(
    arena: std.mem.Allocator,
    io: std.Io,
    self: []const u8,
    arguments: []const [:0]const u8,
) !u8 {
    var node: ?[]const u8 = null;
    var pid: ?[]const u8 = null;
    var rest: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const flag = arguments[index];
        const ours = std.mem.eql(u8, flag, "--node") or std.mem.eql(u8, flag, "--pid");
        if (!ours) {
            try rest.append(arena, flag);
            continue;
        }
        index += 1;
        if (index == arguments.len) return error.Usage;
        if (std.mem.eql(u8, flag, "--node")) node = arguments[index] else pid = arguments[index];
    }
    const target = node orelse return error.Usage;
    if (!node_valid(target)) return error.Usage;
    var command: std.ArrayList(u8) = .empty;
    try command.print(arena, "{s} {s} --stacks", .{ profiler_path, target });
    if (pid) |value| {
        _ = std.fmt.parseInt(u32, value, 10) catch return error.Usage;
        try command.print(arena, " --pid {s}", .{value});
    }
    const stacks = try extract.exec_run(arena, io, self, rest.items, command.items);
    if (stacks.len == 0) {
        std.debug.print("[determinismo] stacks: no threads (is {s} running?)\n", .{target});
        return 1;
    }
    std.debug.print("{s}", .{stacks});
    return 0;
}

fn node_valid(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        const valid = std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-';
        if (!valid) return false;
    }
    return true;
}

const Stack = struct { frames: []const []const u8, count: u64 };
const Stacks = struct { items: []const Stack, samples: u64 };

/// Folded lines ("a;b;c 12"); comments and malformed lines are skipped.
fn stacks_parse(arena: std.mem.Allocator, text: []const u8) !Stacks {
    var items: std.ArrayList(Stack) = .empty;
    var samples: u64 = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const space = std.mem.lastIndexOfScalar(u8, line, ' ') orelse continue;
        const count = std.fmt.parseInt(u64, line[space + 1 ..], 10) catch continue;
        var frames: std.ArrayList([]const u8) = .empty;
        var names = std.mem.splitScalar(u8, line[0..space], ';');
        while (names.next()) |name| try frames.append(arena, name);
        try items.append(arena, .{ .frames = frames.items, .count = count });
        samples += count;
    }
    return .{ .items = items.items, .samples = samples };
}

/// The functions with the most samples of their own (the leaf of the stack), and in all.
fn summary_print(arena: std.mem.Allocator, stacks: *const Stacks) !void {
    var own: std.StringArrayHashMapUnmanaged(u64) = .empty;
    var total: std.StringArrayHashMapUnmanaged(u64) = .empty;
    for (stacks.items) |stack| {
        const leaf = try own.getOrPutValue(arena, stack.frames[stack.frames.len - 1], 0);
        leaf.value_ptr.* += stack.count;
        for (stack.frames, 0..) |frame, index| {
            // A recursive function counts once per stack.
            const seen = for (stack.frames[0..index]) |earlier| {
                if (std.mem.eql(u8, earlier, frame)) break true;
            } else false;
            if (seen) continue;
            const entry = try total.getOrPutValue(arena, frame, 0);
            entry.value_ptr.* += stack.count;
        }
    }
    std.debug.print("[determinismo] profile: {d} samples\n", .{stacks.samples});
    std.debug.print("  {s:>6}  {s:>6}  function\n", .{ "self", "total" });
    const Sort = struct {
        values: []const u64,
        pub fn lessThan(context: @This(), a: usize, b: usize) bool {
            return context.values[a] > context.values[b];
        }
    };
    own.sort(Sort{ .values = own.values() });
    for (own.keys()[0..@min(own.count(), functions_shown)], own.values()[0..]) |name, count| {
        const all = total.get(name) orelse count;
        std.debug.print("  {d:>5.1}%  {d:>5.1}%  {s}\n", .{
            percent(count, stacks.samples), percent(all, stacks.samples), name,
        });
    }
}

fn percent(part: u64, whole: u64) f64 {
    assert(whole > 0);
    return @as(f64, @floatFromInt(part)) * 100 / @as(f64, @floatFromInt(whole));
}

/// One frame of the merged stacks: its samples and its callees.
const Frame = struct {
    name: []const u8,
    count: u64 = 0,
    children: std.ArrayList(u32) = .empty,
};

const graph_width = 1200;
const frame_height = 16;
const text_width_per_char = 7;

/// A self-contained SVG flame graph: callers below callees, widths by samples.
fn flame_graph(arena: std.mem.Allocator, stacks: *const Stacks, title: []const u8) ![]const u8 {
    var frames: std.ArrayList(Frame) = .empty;
    try frames.append(arena, .{ .name = "all" });
    var depth_max: u32 = 0;
    for (stacks.items) |stack| {
        var at: u32 = 0;
        frames.items[0].count += stack.count;
        for (stack.frames) |name| {
            at = try child(arena, &frames, at, name);
            frames.items[at].count += stack.count;
        }
        depth_max = @max(depth_max, @as(u32, @intCast(stack.frames.len)));
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    const height = (depth_max + 1) * frame_height + 40;
    try writer.print(
        \\<svg xmlns="http://www.w3.org/2000/svg" width="{d}" height="{d}" font-family="monospace"
        \\ font-size="11"><rect width="100%" height="100%" fill="#fbfaf7"/>
        \\<text x="8" y="20" font-size="14">{s}: {d} samples</text>
        \\
    , .{ graph_width, height, try escape(arena, title), stacks.samples });
    const scale = @as(f64, graph_width - 16) / @as(f64, @floatFromInt(stacks.samples));
    try frame_draw(arena, writer, frames.items, 0, 8, height - frame_height, scale);
    try writer.writeAll("</svg>\n");
    return out.written();
}

fn child(
    arena: std.mem.Allocator,
    frames: *std.ArrayList(Frame),
    parent: u32,
    name: []const u8,
) !u32 {
    for (frames.items[parent].children.items) |index| {
        if (std.mem.eql(u8, frames.items[index].name, name)) return index;
    }
    const index: u32 = @intCast(frames.items.len);
    try frames.append(arena, .{ .name = name });
    try frames.items[parent].children.append(arena, index);
    return index;
}

fn frame_draw(
    arena: std.mem.Allocator,
    writer: *std.Io.Writer,
    frames: []const Frame,
    index: u32,
    x: f64,
    y: u32,
    scale: f64,
) !void {
    const frame = &frames[index];
    const width = @as(f64, @floatFromInt(frame.count)) * scale;
    if (width < 0.5) return;
    const name = try escape(arena, frame.name);
    const hash = std.hash.Wyhash.hash(0, frame.name);
    try writer.print(
        \\<g><title>{s} ({d} samples)</title><rect x="{d:.1}" y="{d}" width="{d:.1}" height="15"
        \\ fill="rgb(230,{d},{d})"/>
    , .{ name, frame.count, x, y, width, 90 + hash % 120, 40 + (hash >> 8) % 50 });
    const characters: usize = @trunc(@max(0, (width - 6) / text_width_per_char));
    if (characters >= 3) {
        const fits = frame.name.len <= characters;
        const shown = try escape(arena, if (fits) frame.name else frame.name[0 .. characters - 2]);
        try writer.print("<text x=\"{d:.1}\" y=\"{d}\">{s}{s}</text>", .{
            x + 3, y + 11, shown, if (fits) "" else "..",
        });
    }
    try writer.writeAll("</g>\n");
    var child_x = x;
    for (frame.children.items) |callee| {
        try frame_draw(arena, writer, frames, callee, child_x, y - frame_height, scale);
        child_x += @as(f64, @floatFromInt(frames[callee].count)) * scale;
    }
}

/// Text for XML content and attributes.
fn escape(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var escaped: std.ArrayList(u8) = .empty;
    for (text) |byte| {
        try escaped.appendSlice(arena, switch (byte) {
            '<' => "&lt;",
            '>' => "&gt;",
            '&' => "&amp;",
            '"' => "&quot;",
            else => &.{byte},
        });
    }
    return escaped.items;
}

test stacks_parse {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "# det-profile: 5 samples\nredis;main;aeMain;epoll_wait 3\nredis;main;fsync 2\n";
    const stacks = try stacks_parse(arena, text);
    try std.testing.expectEqual(@as(u64, 5), stacks.samples);
    try std.testing.expectEqual(@as(usize, 2), stacks.items.len);
    try std.testing.expectEqualStrings("epoll_wait", stacks.items[0].frames[3]);
    const graph = try flame_graph(arena, &stacks, "redis");
    try std.testing.expect(std.mem.indexOf(u8, graph, "aeMain (3 samples)") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph, "main (5 samples)") != null);
}
