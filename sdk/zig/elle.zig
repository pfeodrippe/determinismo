// SPDX-License-Identifier: MIT
//! Elle (checkers/elle, Jepsen's checker) from test programs: a history of transactions recorded
//! as they happen, then Elle's verdict on it as a property. Elle finds every anomaly of the
//! history (G0, G1a/b/c, G-single, G2, and real-time order for strict serializability); recorded
//! inside the timeline, an anomaly replays to the moment of every operation in its cycle.
//!
//!   // The checker, a node without faults:
//!   default.node(.elle, sdk.elle.node(System.Spec, .{}));
//!
//!   // A driver: one operation at a time per process.
//!   var history: sdk.elle.History = .{};
//!   var process = sdk.elle.process_new();
//!   const asked = [_]sdk.elle.Mop{
//!       .{ .append = .{ .key = 3, .value = 17 } }, // Values unique per key.
//!       .{ .read = .{ .key = 4 } },
//!   };
//!   try history.invoke(arena, process, &asked);
//!   // ... the transaction, then with what the reads saw:
//!   const done = [_]sdk.elle.Mop{ asked[0], .{ .read = .{ .key = 4, .list = &.{ 2, 9 } } } };
//!   try history.ok(arena, process, &done); // Or fail (it did not happen), or info (unknown:
//!   process = sdk.elle.process_new();      // the process then goes on as another).
//!
//!   // A `finally` command, once drivers are done:
//!   try sdk.elle.check_assert(context.init.io, arena, context.nodes.elle.address, .{});
//!
//! Models: list-append (`append` and `read` of lists) and rw-register (`write` and
//! `read_register`). Lines are appended with one write each, so parallel drivers never interleave
//! inside one; an invocation left open (its driver stopped mid-call) is closed as info.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo.zig");
const schema = @import("schema.zig");
const tcp = @import("tcp");

pub const port = 7700;
/// In the runner, where every test command runs.
pub const history_path_default = "/tmp/elle-history.jsonl";

pub const NodeOptions = struct {
    /// Paths are relative to where determinismo runs (its repository by default).
    context: []const u8 = ".",
    dockerfile: []const u8 = "checkers/elle/Dockerfile",
    memory_max_mib: ?u32 = null,
};

/// The checker as a node: it judges, it is not under test, so it has no faults.
pub fn node(comptime Spec: type, options: NodeOptions) Spec {
    return .{
        .build = .{ .context = options.context, .dockerfile = options.dockerfile },
        .ready = .{ .tcp = port },
        .memory_max_mib = options.memory_max_mib,
        .faults = .{
            .pause = false,
            .isolate = false,
            .partition = false,
            .degrade = false,
            .throttle = false,
            .process_pause = false,
            .sync_stall = false,
        },
    };
}

/// A micro-operation. In an invocation reads have no value yet (null); in an `ok`, what they
/// saw (null for a key never written, in rw-register).
pub const Mop = union(enum) {
    append: struct { key: u64, value: u64 },
    read: struct { key: u64, list: ?[]const u64 = null },
    write: struct { key: u64, value: u64 },
    read_register: struct { key: u64, value: ?u64 = null },
};

pub const Kind = enum { invoke, ok, fail, info };

/// A process id for Elle: a driver takes a new one after an unknown outcome.
pub fn process_new() u64 {
    return sdk.random_below(1 << 48);
}

pub const History = struct {
    path: [:0]const u8 = history_path_default,

    pub fn invoke(history: *const History, gpa: std.mem.Allocator, process: u64, mops: []const Mop) !void {
        return history.note(gpa, process, .invoke, mops);
    }
    pub fn ok(history: *const History, gpa: std.mem.Allocator, process: u64, mops: []const Mop) !void {
        return history.note(gpa, process, .ok, mops);
    }
    pub fn fail(history: *const History, gpa: std.mem.Allocator, process: u64, mops: []const Mop) !void {
        return history.note(gpa, process, .fail, mops);
    }
    pub fn info(history: *const History, gpa: std.mem.Allocator, process: u64, mops: []const Mop) !void {
        return history.note(gpa, process, .info, mops);
    }

    /// One line, appended with one write.
    pub fn note(
        history: *const History,
        gpa: std.mem.Allocator,
        process: u64,
        kind: Kind,
        mops: []const Mop,
    ) !void {
        var line: std.Io.Writer.Allocating = .init(gpa);
        defer line.deinit();
        try line_write(&line.writer, process, kind, mops);
        const bytes = line.written();
        const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
        const fd = linux.open(history.path, flags, 0o644);
        if (linux.errno(fd) != .SUCCESS) return error.HistoryOpen;
        defer _ = linux.close(@intCast(fd));
        const written = linux.write(@intCast(fd), bytes.ptr, bytes.len);
        if (linux.errno(written) != .SUCCESS or written != bytes.len) return error.HistoryWrite;
    }
};

/// `{"process":7,"type":"ok","f":"txn","value":[["append",3,17],["r",4,[2,9]]]}` and a newline.
pub fn line_write(writer: *std.Io.Writer, process: u64, kind: Kind, mops: []const Mop) !void {
    try writer.print("{{\"process\":{d},\"type\":\"{s}\",\"f\":\"txn\",\"value\":[", .{
        process, @tagName(kind),
    });
    for (mops, 0..) |mop, index| {
        if (index > 0) try writer.writeByte(',');
        switch (mop) {
            .append => |a| try writer.print("[\"append\",{d},{d}]", .{ a.key, a.value }),
            .write => |w| try writer.print("[\"w\",{d},{d}]", .{ w.key, w.value }),
            .read => |r| {
                try writer.print("[\"r\",{d},", .{r.key});
                if (r.list) |list| {
                    try writer.writeByte('[');
                    for (list, 0..) |value, at| {
                        if (at > 0) try writer.writeByte(',');
                        try writer.print("{d}", .{value});
                    }
                    try writer.writeAll("]]");
                } else try writer.writeAll("null]");
            },
            .read_register => |r| {
                if (r.value) |value| {
                    try writer.print("[\"r\",{d},{d}]", .{ r.key, value });
                } else try writer.print("[\"r\",{d},null]", .{r.key});
            },
        }
    }
    try writer.writeAll("]}\n");
}

pub const Model = enum {
    list_append,
    rw_register,

    fn name(model: Model) []const u8 {
        return switch (model) {
            .list_append => "list-append",
            .rw_register => "rw-register",
        };
    }
};

pub const CheckOptions = struct {
    model: Model = .list_append,
    /// One of Elle's models: strict-serializable, serializable, snapshot-isolation,
    /// read-committed, ...
    consistency: []const u8 = "strict-serializable",
    history_path: []const u8 = history_path_default,
    /// Elle reads the whole history at once: seconds, more for long ones.
    timeout_ms: u32 = 600 * std.time.ms_per_s,
};

pub const Verdict = struct {
    /// Null: Elle could not tell (too little to go on).
    valid: ?bool,
    anomaly_types: []const []const u8,
    ops: u64,
    /// As Elle prints them, cut short.
    anomalies: []const u8,
};

/// Posts the history to the checker: its verdict, or null when no history was recorded.
pub fn check(io: std.Io, arena: std.mem.Allocator, address: [4]u8, options: CheckOptions) !?Verdict {
    const history = std.Io.Dir.cwd().readFileAlloc(io, options.history_path, arena, .limited(1 << 30)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/check?model={s}&consistency={s}", .{
        options.model.name(), options.consistency,
    });
    const buffer = try arena.alloc(u8, tcp.buffer_size);
    const response = try tcp.http_with(address, port, "POST", path, history, buffer, .{
        .timeout_ms = options.timeout_ms,
    });
    const Answer = struct {
        valid: std.json.Value = .null,
        anomaly_types: []const []const u8 = &.{},
        ops: u64 = 0,
        anomalies: []const u8 = "",
        @"error": []const u8 = "",
    };
    const answer = try std.json.parseFromSliceLeaky(Answer, arena, response.body, .{
        .ignore_unknown_fields = true,
    });
    if (response.status != 200) {
        sdk.event("elle_failed", .{ .status = response.status, .err = answer.@"error" });
        return error.ElleFailed;
    }
    return .{
        .valid = if (answer.valid == .bool) answer.valid.bool else null,
        .anomaly_types = answer.anomaly_types,
        .ops = answer.ops,
        .anomalies = answer.anomalies,
    };
}

/// `check`, with its verdict as properties: `always` that Elle found no anomaly, and `sometimes`
/// that it checked a valid history.
pub fn check_assert(io: std.Io, arena: std.mem.Allocator, address: [4]u8, options: CheckOptions) !void {
    const verdict = (try check(io, arena, address, options)) orelse return;
    const details = .{
        .model = options.model.name(),
        .consistency = options.consistency,
        .anomaly_types = verdict.anomaly_types,
        .ops = verdict.ops,
        .anomalies = verdict.anomalies,
    };
    sdk.always(verdict.valid != false, "Elle finds no anomaly in the history", details);
    sdk.sometimes(verdict.valid == true, "Elle checked a history and found it valid", .{
        .ops = verdict.ops,
    });
}

test line_write {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const asked = [_]Mop{ .{ .append = .{ .key = 3, .value = 17 } }, .{ .read = .{ .key = 4 } } };
    try line_write(&writer, 7, .invoke, &asked);
    const done = [_]Mop{ asked[0], .{ .read = .{ .key = 4, .list = &.{ 2, 9 } } } };
    try line_write(&writer, 7, .ok, &done);
    const registers = [_]Mop{
        .{ .write = .{ .key = 1, .value = 5 } },
        .{ .read_register = .{ .key = 2 } },
        .{ .read_register = .{ .key = 1, .value = 5 } },
    };
    try line_write(&writer, 8, .info, &registers);
    try std.testing.expectEqualStrings(
        \\{"process":7,"type":"invoke","f":"txn","value":[["append",3,17],["r",4,null]]}
        \\{"process":7,"type":"ok","f":"txn","value":[["append",3,17],["r",4,[2,9]]]}
        \\{"process":8,"type":"info","f":"txn","value":[["w",1,5],["r",2,null],["r",1,5]]}
        \\
    , writer.buffered());
}
