// SPDX-License-Identifier: MIT
//! Elle (Jepsen's checker, checkers/elle) as a host check: drivers record a history of
//! transactions as they happen, and `check` is a check (System.main's `.checks`) that hands each
//! timeline's history to Elle on the host and asserts its verdict. Elle finds every anomaly of
//! the history (G0, G1a/b/c, G-single, G2, and real-time order for strict serializability); the
//! guest pays nothing, and a replay records the same history, so it gets the same verdict, with
//! every operation of an anomaly at its moment.
//!
//!   // The program's checks: Elle on every timeline's history.
//!   return System.main(init, .{ .describe = ..., .scenarios = ...,
//!       .checks = .{ .elle = sdk.elle.check(.{ .consistency = "strict-serializable" }) } });
//!
//!   // A driver: one operation at a time per process.
//!   const history: sdk.elle.History = .{};
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
//! Models: list-append (`append` and `read` of lists) and rw-register (`write` and
//! `read_register`). Lines are appended with one write each, so parallel drivers never interleave
//! inside one; an invocation left open (its driver stopped mid-call) is closed as info.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo.zig");
const schema = @import("schema.zig");
const tcp = @import("tcp");

/// The service, on the host: one for every run there, started by the first check that needs it.
pub const port = 7700;
const address = [4]u8{ 127, 0, 0, 1 };
const image = "determinismo-elle";
const dockerfile = "checkers/elle/Dockerfile";
const start_lock = "/tmp/determinismo-elle.lock";
/// Elle reads a timeline's whole history at once: seconds, more for long ones.
const timeout_ms = 600 * std.time.ms_per_s;
const anomalies_size_max = 2500;

pub const ScenarioConsistency = struct { scenario: []const u8, consistency: []const u8 };

pub const CheckOptions = struct {
    /// list-append or rw-register.
    model: []const u8 = "list-append",
    /// One of Elle's models: strict-serializable, serializable, snapshot-isolation,
    /// read-committed, ...
    consistency: []const u8 = "strict-serializable",
    /// Another consistency model for some scenarios' timelines.
    by_scenario: []const ScenarioConsistency = &.{},
    message: []const u8 = "Elle finds no anomaly in the history",
};

/// The check to put in the program's `.checks`: Elle on every timeline's history (the records of
/// the check's name: History records under "elle", the usual name).
pub fn check(comptime options: CheckOptions) fn (*sdk.Check, []const u8) anyerror!void {
    return struct {
        fn run(context: *sdk.Check, history: []const u8) anyerror!void {
            if (history.len == 0) return;
            const consistency = for (options.by_scenario) |entry| {
                if (std.mem.eql(u8, entry.scenario, context.scenario)) break entry.consistency;
            } else options.consistency;
            const verdict = try judge(context, history, options.model, consistency);
            const anomalies = verdict.anomalies[0..@min(verdict.anomalies.len, anomalies_size_max)];
            sdk.always(verdict.valid != false, options.message, .{
                .model = options.model,
                .consistency = consistency,
                .ops = verdict.ops,
                .anomaly_types = verdict.anomaly_types,
                .anomalies = anomalies,
            });
            sdk.sometimes(verdict.valid == true, "Elle checked a history and found it valid", .{
                .ops = verdict.ops,
            });
        }
    }.run;
}

pub const Verdict = struct {
    /// Null: Elle could not tell (too little to go on).
    valid: ?bool,
    anomaly_types: []const []const u8,
    ops: u64,
    /// As Elle prints them.
    anomalies: []const u8,
};

/// Elle's verdict on a history (JSON lines), from the service on the host.
pub fn judge(context: *sdk.Check, history: []const u8, model: []const u8, consistency: []const u8) !Verdict {
    try service_ensure(context);
    var path_buffer: [192]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/check?model={s}&consistency={s}", .{
        model, consistency,
    });
    const buffer = try context.arena.alloc(u8, tcp.buffer_size);
    const response = try tcp.http_with(address, port, "POST", path, history, buffer, .{
        .timeout_ms = timeout_ms,
    });
    const Answer = struct {
        valid: std.json.Value = .null,
        anomaly_types: []const []const u8 = &.{},
        ops: u64 = 0,
        anomalies: []const u8 = "",
        @"error": []const u8 = "",
    };
    const answer = try std.json.parseFromSliceLeaky(Answer, context.arena, response.body, .{
        .ignore_unknown_fields = true,
    });
    if (response.status != 200) {
        std.debug.print("elle: {s}\n", .{answer.@"error"});
        return error.ElleFailed;
    }
    return .{
        .valid = if (answer.valid == .bool) answer.valid.bool else null,
        .anomaly_types = answer.anomaly_types,
        .ops = answer.ops,
        .anomalies = answer.anomalies,
    };
}

/// The service answers, or is started (built from checkers/elle with podman, relative to where
/// determinismo runs): once per host, whichever check gets the lock first.
fn service_ensure(context: *sdk.Check) !void {
    if (answers()) return;
    const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
    const lock = linux.open(start_lock, flags, 0o600);
    if (linux.errno(lock) != .SUCCESS) return error.LockFailed;
    defer _ = linux.close(@intCast(lock));
    while (linux.errno(linux.flock(@intCast(lock), std.posix.LOCK.EX)) == .INTR) {}
    if (answers()) return; // Another check started it meanwhile.
    std.debug.print("elle: starting the service on port {d} ({s})\n", .{ port, dockerfile });
    try command(context, &.{ "podman", "build", "-q", "-t", image, "-f", dockerfile, "." });
    _ = std.process.run(context.arena, context.io, .{ .argv = &.{ "podman", "rm", "-f", image } }) catch {};
    try command(context, &.{ "podman", "run", "-d", "--name", image, "--network", "host", image });
    for (0..120) |_| {
        if (answers()) return;
        const pause: linux.timespec = .{ .sec = 1, .nsec = 0 };
        _ = linux.nanosleep(&pause, null);
    }
    return error.ElleNotAnswering;
}

fn answers() bool {
    var connection: tcp.Connection = undefined;
    connection.open(address, port, .{ .timeout_ms = 1000 }) catch return false;
    connection.close();
    return true;
}

fn command(context: *sdk.Check, argv: []const []const u8) !void {
    const result = try std.process.run(context.arena, context.io, .{ .argv = argv });
    if (!result.term.success()) {
        std.debug.print("elle: {s} failed:\n{s}\n", .{ argv[0], result.stderr });
        return error.ToolFailed;
    }
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

/// The history, as records of the check named "elle" (sdk.record's file): `History.of("other")`
/// for a check of another name.
pub const History = struct {
    path: [:0]const u8 = schema.record_path("elle"),

    pub fn of(comptime name: []const u8) History {
        return .{ .path = schema.record_path(name) };
    }


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
