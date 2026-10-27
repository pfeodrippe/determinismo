// SPDX-License-Identifier: MIT
//! `determinismo causality`: how likely a bug was at each moment of a timeline where it
//! happened, as Antithesis's causality analysis (docs/ANTITHESIS.md).
//!
//!   determinismo causality <machine and system options> --seed <s> --branch <n>
//!       [--tape <branch n's tape>] --property '<message>' [--points <k>] [--futures <m>] [--json]
//!
//! With its tape, branch n is the one explored (a tree's branch starts inside its ancestors:
//! the tape has its path); without, the n-th branch from the setup snapshot.
//!
//! First it finds when the property first failed in branch n (`--until`). Then, at k moments
//! from the snapshot to that failure, it branches m futures from branch n (`--from-branch
//! --from-vtime-ms`) and counts how many fail the property. The probability rises where the
//! timeline made the bug likely: look at the logs just before each jump (`determinismo query
//! ... --branch <n> --up-to-vtime <s>`). A coin-flip bug (two heads) reads 25%, then 50% after
//! the first flip, then 100% after the second.
const std = @import("std");
const assert = std.debug.assert;

const points_max = 64;

const Request = struct {
    branch: u32,
    property: []const u8,
    points: u32 = 8,
    futures: u32 = 16,
    json: bool = false,
    /// Branch n's tape: the timeline replayed and branched from (a tree's branch).
    tape: ?[]const u8 = null,
    /// Everything else: machine and system options, the seed; passed to every explore.
    rest: []const []const u8,
};

pub fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    self: []const u8,
    arguments: []const [:0]const u8,
) !u8 {
    const request = try arguments_parse(arena, arguments);
    const failure = try failure_find(arena, io, self, &request) orelse {
        std.debug.print("[determinismo] causality: '{s}' does not fail in branch {d}\n", .{
            request.property, request.branch,
        });
        return 1;
    };
    var buffer: [16 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;
    if (!request.json) {
        try out.print("'{s}' in branch {d}: first failure at {d}ms (snapshot at {d}ms); " ++
            "{d} futures per moment\n", .{
            request.property, request.branch, failure.failure_ms, failure.snapshot_ms,
            request.futures,
        });
        try out.flush();
    }
    // Moments from just after the snapshot to the failure, the last one at it.
    const span = failure.failure_ms - failure.snapshot_ms;
    for (0..request.points) |index| {
        const step = span * (index + 1) / request.points;
        const moment_ms = failure.snapshot_ms + @max(step, 1);
        const failing = try futures_failing(arena, io, self, &request, moment_ms);
        const futures: f64 = @floatFromInt(request.futures);
        const probability = @as(f64, @floatFromInt(failing)) / futures;
        if (request.json) {
            const format = "{{\"vtime_ms\":{d},\"futures\":{d},\"failing\":{d}," ++
                "\"probability\":{d:.3}}}\n";
            try out.print(format, .{ moment_ms, request.futures, failing, probability });
        } else {
            var bar: [40]u8 = @splat(' ');
            const filled: usize = @trunc(probability * bar.len);
            @memset(bar[0..filled], '#');
            try out.print("  {d:>8}ms  {d:>5.1}%  |{s}|  ({d}/{d})\n", .{
                moment_ms, probability * 100, &bar, failing, request.futures,
            });
        }
        try out.flush();
    }
    return 0;
}

fn arguments_parse(arena: std.mem.Allocator, arguments: []const [:0]const u8) !Request {
    var request = Request{ .branch = 0, .property = "", .rest = &.{} };
    var branch: ?u32 = null;
    var rest: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const flag = arguments[index];
        const eql = std.mem.eql;
        if (eql(u8, flag, "--json")) {
            request.json = true;
            continue;
        }
        const ours = eql(u8, flag, "--branch") or eql(u8, flag, "--property") or
            eql(u8, flag, "--points") or eql(u8, flag, "--futures") or eql(u8, flag, "--tape");
        if (!ours) {
            try rest.append(arena, flag);
            continue;
        }
        index += 1;
        if (index == arguments.len) return error.Usage;
        const value = arguments[index];
        if (eql(u8, flag, "--branch")) {
            branch = try std.fmt.parseInt(u32, value, 10);
        } else if (eql(u8, flag, "--property")) {
            request.property = value;
        } else if (eql(u8, flag, "--tape")) {
            request.tape = value;
        } else if (eql(u8, flag, "--points")) {
            request.points = try std.fmt.parseInt(u32, value, 10);
        } else {
            request.futures = try std.fmt.parseInt(u32, value, 10);
        }
    }
    request.branch = branch orelse return error.Usage;
    if (request.property.len == 0) return error.Usage;
    if (request.points == 0 or request.points > points_max) return error.Usage;
    if (request.futures == 0) return error.Usage;
    request.rest = rest.items;
    return request;
}

const Failure = struct { snapshot_ms: u64, failure_ms: u64 };

/// Replays the branch until the property's first failure (`--until`).
fn failure_find(
    arena: std.mem.Allocator,
    io: std.Io,
    self: []const u8,
    request: *const Request,
) !?Failure {
    const message = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(request.property, .{})});
    // A failing evaluation (declarations, `hit` false, are not): an always kind false, an
    // unreachable reached.
    const until = try std.fmt.allocPrint(arena, "assert.message={s} assert.condition=false or " ++
        "assert.message={s} assert.type=unreachable assert.condition=true or " ++
        "antithesis_assert.message={s} antithesis_assert.hit=true antithesis_assert.condition=false or " ++
        "antithesis_assert.message={s} antithesis_assert.hit=true antithesis_assert.display_type=Unreachable", .{
        message, message, message, message,
    });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ self, "explore" });
    try argv.appendSlice(arena, request.rest);
    if (request.tape) |path| {
        try argv.appendSlice(arena, &.{ "--tape", path, "--until", until });
    } else try argv.appendSlice(arena, &.{
        "--branch", try std.fmt.allocPrint(arena, "{d}", .{request.branch}), "--until", until,
    });
    const result = try std.process.run(arena, io, .{ .argv = argv.items });
    const snapshot_s = number_after(result.stderr, "snapshot at setup_complete: vtime=") orelse
        return error.NoSnapshot;
    // The last moment: a tree's branch replays along its path first (a moment per ancestor).
    const moment_ns = number_after_last(result.stderr, "at moment vtime=") orelse return null;
    return .{
        .snapshot_ms = @trunc(snapshot_s * 1000),
        .failure_ms = @trunc(moment_ns / std.time.ns_per_ms),
    };
}

/// The tape of the timeline that was running at a moment: a tree's branch starts inside its
/// ancestors (its tape's chain: each ancestor and where the next branched from it), so a moment
/// before its start is an ancestor's, whose tape is beside it.
fn tape_at(arena: std.mem.Allocator, io: std.Io, tape: []const u8, moment_ms: u64) ![]const u8 {
    const Header = struct { chain: []const struct { branch: u32, vtime_ns: u64 } = &.{} };
    const text = try std.Io.Dir.cwd().readFileAlloc(io, tape, arena, .limited(1 << 24));
    const first = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    const header = try std.json.parseFromSliceLeaky(Header, arena, first, .{ .ignore_unknown_fields = true });
    for (header.chain) |segment| {
        if (moment_ms * std.time.ns_per_ms >= segment.vtime_ns) continue;
        const directory = std.fs.path.dirname(tape) orelse ".";
        return std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ directory, segment.branch });
    }
    return tape;
}

/// How many of the futures from that moment fail the property.
fn futures_failing(
    arena: std.mem.Allocator,
    io: std.Io,
    self: []const u8,
    request: *const Request,
    moment_ms: u64,
) !u32 {
    const record = try std.fmt.allocPrint(arena, "/tmp/determinismo-causality-{d}-{d}.jsonl", .{
        std.os.linux.getpid(), moment_ms,
    });
    defer std.Io.Dir.cwd().deleteFile(io, record) catch {};
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ self, "explore" });
    try argv.appendSlice(arena, request.rest);
    if (request.tape) |path| {
        try argv.appendSlice(arena, &.{ "--tape", try tape_at(arena, io, path, moment_ms) });
    } else try argv.appendSlice(arena, &.{
        "--from-branch", try std.fmt.allocPrint(arena, "{d}", .{request.branch}),
    });
    try argv.appendSlice(arena, &.{
        "--from-vtime-ms", try std.fmt.allocPrint(arena, "{d}", .{moment_ms}),
        "--branches",      try std.fmt.allocPrint(arena, "{d}", .{request.futures}),
        "--record",        record,
    });
    _ = try std.process.run(arena, io, .{ .argv = argv.items });
    const source = try std.Io.Dir.cwd().readFileAlloc(io, record, arena, .limited(1 << 24));
    return property_failing(arena, source, request.property);
}

const Summary = struct {
    summary: struct {
        properties: []const struct { message: []const u8, branches_failing: u32 },
    },
};

fn property_failing(arena: std.mem.Allocator, record: []const u8, property: []const u8) !u32 {
    var lines = std.mem.tokenizeScalar(u8, record, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "{\"summary\":")) continue;
        const summary = try std.json.parseFromSliceLeaky(Summary, arena, line, .{
            .ignore_unknown_fields = true,
        });
        for (summary.summary.properties) |entry| {
            if (std.mem.eql(u8, entry.message, property)) return entry.branches_failing;
        }
        return 0; // Never evaluated in these futures: not failing.
    }
    return error.NoSummary;
}

/// The number right after `key` in `text` (as "1.017s" or "1053000000ns": digits and a dot).
fn number_after(text: []const u8, key: []const u8) ?f64 {
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    return number_at(text, at + key.len);
}

/// The number right after the last `key` in `text`.
fn number_after_last(text: []const u8, key: []const u8) ?f64 {
    const at = std.mem.lastIndexOf(u8, text, key) orelse return null;
    return number_at(text, at + key.len);
}

fn number_at(text: []const u8, start: usize) ?f64 {
    var end = start;
    while (end < text.len and (std.ascii.isDigit(text[end]) or text[end] == '.')) end += 1;
    return std.fmt.parseFloat(f64, text[start..end]) catch null;
}

test number_after {
    const output = "[determinismo] snapshot at setup_complete: vtime=1.017s branches=3\n" ++
        "[determinismo] at moment vtime=1053000000ns branches=4\n";
    try std.testing.expectEqual(@as(f64, 1.017), number_after(output, "setup_complete: vtime=").?);
    try std.testing.expectEqual(@as(f64, 1053000000), number_after(output, "at moment vtime=").?);
    const chain = output ++ "[determinismo] at moment vtime=2053000000ns branches=5\n";
    try std.testing.expectEqual(@as(f64, 2053000000), number_after_last(chain, "at moment vtime=").?);
}
