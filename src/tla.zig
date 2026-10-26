// SPDX-License-Identifier: MIT
//! `determinismo tla`: trace validation (ARCHITECTURE.md §11.4). A branch's abstract states,
//! emitted by the system as `{"event":"tla","details":{"state":{<variable>: <value>, ...}}}`,
//! must be a behavior of a TLA+ spec: TLC looks for steps of the spec's `Next` that go through
//! exactly those states, in order.
//!
//!   determinismo tla --spec <Spec.tla> --events <events.jsonl> [--tla2tools <jar>]
//!
//! Events of a branch are totally ordered (one vCPU, virtual time), so the trace is the
//! system's history as it happened. The spec defines `Next` over variables named like the
//! state's keys; JSON objects become records, arrays sequences. Exit status: 0 the trace is a
//! behavior of the spec, 3 it is not (the first state the spec cannot reach is reported).
const std = @import("std");
const assert = std.debug.assert;

const trace_states_max = 1 << 20;

pub fn check(arena: std.mem.Allocator, io: std.Io, arguments: []const [:0]const u8) !u8 {
    var spec: ?[]const u8 = null;
    var events: ?[]const u8 = null;
    var jar: []const u8 = "tla2tools.jar";
    var index: usize = 0;
    while (index + 1 < arguments.len) : (index += 2) {
        const flag = arguments[index];
        const value = arguments[index + 1];
        if (std.mem.eql(u8, flag, "--spec")) {
            spec = value;
        } else if (std.mem.eql(u8, flag, "--events")) {
            events = value;
        } else if (std.mem.eql(u8, flag, "--tla2tools")) {
            jar = value;
        } else return error.Usage;
    }
    const spec_path = spec orelse return error.Usage;
    const trace = try trace_read(arena, io, events orelse return error.Usage);
    if (trace.states.len == 0) {
        std.debug.print("[determinismo] no \"tla\" events in the trace\n", .{});
        return 1;
    }
    const pid = std.os.linux.getpid();
    const work = try std.fmt.allocPrint(arena, "/tmp/determinismo-tla-{d}", .{pid});
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, work);
    const module = std.fs.path.stem(spec_path);
    const spec_copy = try std.fs.path.join(arena, &.{ work, std.fs.path.basename(spec_path) });
    try cwd.copyFile(spec_path, cwd, spec_copy, io, .{});
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ work, "TraceCheck.tla" }),
        .data = try trace_module(arena, module, &trace),
    });
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ work, "TraceCheck.cfg" }),
        .data = "INIT TraceInit\nNEXT TraceNext\n",
    });
    const jar_absolute = try std.fs.path.resolve(arena, &.{jar});
    const result = try std.process.run(arena, io, .{
        .argv = &.{
            "java",    "-XX:+UseParallelGC", "-cp",      jar_absolute, "tlc2.TLC",
            "-config", "TraceCheck.cfg",     "-workers", "1",          "-metadir",
            "states",  "TraceCheck.tla",
        },
        .cwd = .{ .path = work },
    });
    return verdict(&trace, result.stdout);
}

const Trace = struct { states: []const std.json.Value, variables: []const []const u8 };

fn trace_read(arena: std.mem.Allocator, io: std.Io, path: []const u8) !Trace {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 30));
    var states: std.ArrayList(std.json.Value) = .empty;
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    while (lines.next()) |text| {
        if (std.mem.indexOf(u8, text, "\"event\":\"tla\"") == null) continue;
        const line = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
        const event = line.object.get("event") orelse continue;
        const details = event.object.get("details") orelse continue;
        const state = details.object.get("state") orelse continue;
        if (state != .object) return error.StateNotAnObject;
        if (states.items.len == trace_states_max) return error.TraceTooLong;
        try states.append(arena, state);
    }
    if (states.items.len == 0) return .{ .states = &.{}, .variables = &.{} };
    return .{ .states = states.items, .variables = states.items[0].object.keys() };
}

/// The trace as a sequence of records, and a spec that must walk it with the user's `Next`.
fn trace_module(arena: std.mem.Allocator, module: []const u8, trace: *const Trace) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const header = "---- MODULE TraceCheck ----\nEXTENDS {s}, Naturals, Sequences\n\n";
    try out.print(arena, header, .{module});
    try out.appendSlice(arena, "Trace == <<\n");
    for (trace.states, 0..) |state, index| {
        try out.appendSlice(arena, if (index == 0) "  " else ", ");
        try value_write(arena, &out, state);
        try out.append(arena, '\n');
    }
    try out.appendSlice(arena, ">>\n\nVARIABLE trace_position\n\n");
    try out.appendSlice(arena, "TraceInit ==\n  /\\ trace_position = 1\n");
    for (trace.variables) |variable| {
        try out.print(arena, "  /\\ {s} = Trace[1].{s}\n", .{ variable, variable });
    }
    // [Next]_vars: a step of the spec, or one that changes nothing (stuttering).
    try out.appendSlice(arena, "\nTraceNext ==\n  \\/ /\\ trace_position < Len(Trace)\n" ++
        "     /\\ trace_position' = trace_position + 1\n     /\\ \\/ Next\n" ++
        "        \\/ UNCHANGED <<");
    for (trace.variables, 0..) |variable, index| {
        if (index > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, variable);
    }
    try out.appendSlice(arena, ">>\n");
    for (trace.variables) |variable| {
        const step = "     /\\ {s}' = Trace[trace_position'].{s}\n";
        try out.print(arena, step, .{ variable, variable });
    }
    try out.appendSlice(arena, "  \\/ /\\ trace_position = Len(Trace)\n" ++
        "     /\\ UNCHANGED <<trace_position");
    for (trace.variables) |variable| try out.print(arena, ", {s}", .{variable});
    try out.appendSlice(arena, ">>\n====\n");
    return out.items;
}

fn value_write(arena: std.mem.Allocator, out: *std.ArrayList(u8), value: std.json.Value) !void {
    switch (value) {
        .integer => |number| try out.print(arena, "{d}", .{number}),
        .bool => |flag| try out.appendSlice(arena, if (flag) "TRUE" else "FALSE"),
        .string => |text| try out.print(arena, "{f}", .{std.json.fmt(text, .{})}),
        .array => |items| {
            try out.appendSlice(arena, "<<");
            for (items.items, 0..) |item, index| {
                if (index > 0) try out.appendSlice(arena, ", ");
                try value_write(arena, out, item);
            }
            try out.appendSlice(arena, ">>");
        },
        .object => |fields| {
            try out.append(arena, '[');
            var first = true;
            var iterator = fields.iterator();
            while (iterator.next()) |field| {
                if (!identifier(field.key_ptr.*)) return error.FieldNotAnIdentifier;
                if (!first) try out.appendSlice(arena, ", ");
                first = false;
                try out.print(arena, "{s} |-> ", .{field.key_ptr.*});
                try value_write(arena, out, field.value_ptr.*);
            }
            try out.append(arena, ']');
        },
        else => return error.UnsupportedValue, // Floats and nulls have no TLA+ counterpart here.
    }
}

fn identifier(text: []const u8) bool {
    if (text.len == 0 or !std.ascii.isAlphabetic(text[0])) return false;
    for (text) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

/// TLC's answer: no error (a behavior of the spec), or a deadlock where the trace left it.
fn verdict(trace: *const Trace, output: []const u8) u8 {
    if (std.mem.indexOf(u8, output, "Model checking completed. No error has been found.") != null) {
        std.debug.print("[determinismo] the trace ({d} states) is a behavior of the spec\n", .{
            trace.states.len,
        });
        return 0;
    }
    if (std.mem.indexOf(u8, output, "Deadlock reached") != null) {
        const position = last_position(output);
        std.debug.print("[determinismo] the spec cannot reach state {d} of {d} from state {d}\n", .{
            position + 1, trace.states.len, position,
        });
        return 3;
    }
    std.debug.print("[determinismo] TLC did not finish:\n{s}\n", .{output});
    return 1;
}

/// The highest trace_position TLC printed in its error trace.
fn last_position(output: []const u8) u64 {
    const key = "trace_position = ";
    var highest: u64 = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, output, start, key)) |at| {
        var end = at + key.len;
        while (end < output.len and std.ascii.isDigit(output[end])) end += 1;
        highest = @max(highest, std.fmt.parseInt(u64, output[at + key.len .. end], 10) catch 0);
        start = end;
    }
    return highest;
}

test value_write {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"accounts":[100,90],"open":true,"name":"x"}
    , .{});
    var out: std.ArrayList(u8) = .empty;
    try value_write(arena, &out, value);
    const expected = "[accounts |-> <<100, 90>>, open |-> TRUE, name |-> \"x\"]";
    try std.testing.expectEqualStrings(expected, out.items);
}
