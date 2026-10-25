// SPDX-License-Identifier: MIT
//! `determinismo script <events.jsonl>`: the shape of a timeline as a script (JSON on stdout).
//!
//! A tape replays a branch exactly, on the same build only. A script survives code changes: it
//! is what the composer and the fault injector decided (which test commands started when, and
//! how; which faults hit what, when, for how long), by offsets in virtual time. With
//! `explore --script <file>`, they follow it instead of choosing; everything inside (scheduling,
//! test inputs) is still decided by the seed. Scripts are meant to be read and edited: remove
//! entries and re-run to find what a failure needs.
//!
//! Input: the events of one branch (`explore --branch N --events <file>`).
const std = @import("std");
const assert = std.debug.assert;

const Line = struct {
    vtime_ns: u64,
    event: std.json.Value,
};

pub fn extract(arena: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 30));
    var composer_start: ?u64 = null;
    var faults_start: ?u64 = null;
    var faults_phase_start: ?u64 = null;
    var faults_phase_stop: ?u64 = null;
    var commands: std.ArrayList(u8) = .empty;
    var faults: std.ArrayList(u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    while (lines.next()) |text| {
        const line = std.json.parseFromSliceLeaky(Line, arena, text, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        if (line.event != .object) continue;
        const name_value = line.event.object.get("event") orelse continue;
        if (name_value != .string) continue;
        const name = name_value.string;
        const details = line.event.object.get("details") orelse continue;
        const eql = std.mem.eql;
        if (eql(u8, name, "composer_start")) composer_start = line.vtime_ns;
        const start = composer_start orelse continue;
        if (eql(u8, name, "command_start")) {
            try separator(arena, &commands);
            try commands.print(arena, "{{\"at_ns\":{d},\"name\":{f},\"mode\":{f}}}", .{
                line.vtime_ns - start,
                std.json.fmt(details.object.get("name").?, .{}),
                std.json.fmt(details.object.get("mode").?, .{}),
            });
        } else if (eql(u8, name, "faults_phase")) {
            const state = details.object.get("state").?.string;
            if (eql(u8, state, "start")) faults_phase_start = line.vtime_ns - start;
            if (eql(u8, state, "stop")) faults_phase_stop = line.vtime_ns - start;
        } else if (eql(u8, name, "faults_start")) {
            faults_start = line.vtime_ns;
        } else if (eql(u8, name, "fault")) {
            const offset = line.vtime_ns - (faults_start orelse continue);
            var fault = details;
            try fault.object.put(arena, "at_ns", .{ .integer = @intCast(offset) });
            try separator(arena, &faults);
            try faults.print(arena, "{f}", .{std.json.fmt(fault, .{})});
        }
    }
    if (composer_start == null) return error.NoComposerStart;
    var buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;
    try out.print("{{\"script\":1,\"commands\":[{s}],", .{commands.items});
    if (faults_phase_start) |at| try out.print("\"faults_start_ns\":{d},", .{at});
    if (faults_phase_stop) |at| try out.print("\"faults_stop_ns\":{d},", .{at});
    try out.print("\"faults\":[{s}]}}\n", .{faults.items});
    try out.flush();
}

fn separator(arena: std.mem.Allocator, list: *std.ArrayList(u8)) !void {
    if (list.items.len > 0) try list.append(arena, ',');
}
