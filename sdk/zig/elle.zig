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
    /// Anomaly types the system is known to allow (Kafka's G0, seen by Jepsen in normal
    /// operation): found alone, they do not fail the check, and are reported instead ("Elle found
    /// only anomalies the system is known to allow"), so that the property stays free for what
    /// is not known.
    allowed: []const []const u8 = &.{},
    message: []const u8 = "Elle finds no anomaly in the history",
    /// Judged directly beside Elle: every list read lists each append acknowledged before the
    /// read began. For a system whose reads may see a write before it is acknowledged, one copy
    /// before another (OpenSearch's realtime GET: Elle at strict serializability takes that for
    /// G-single-item-realtime), checked at `serializable` with this: what it does promise.
    realtime_reads: bool = false,
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
            const known = verdict.valid == false and verdict.anomaly_types.len > 0 and
                allowed_only(verdict.anomaly_types, options.allowed);
            if (options.allowed.len > 0) {
                sdk.sometimes(known, "Elle found only anomalies the system is known to allow", .{
                    .anomaly_types = verdict.anomaly_types,
                });
            }
            sdk.always(verdict.valid != false or known, options.message, .{
                .model = options.model,
                .consistency = consistency,
                .ops = verdict.ops,
                .anomaly_types = verdict.anomaly_types,
                .anomalies = anomalies,
                .window_ns = verdict.window_ns,
            });
            sdk.sometimes(verdict.valid == true, "Elle checked a history and found it valid", .{
                .ops = verdict.ops,
            });
            if (options.realtime_reads) {
                const stale = try reads_stale(context.arena, history);
                for (stale.first[0..@min(stale.count, stale.first.len)]) |read| {
                    sdk.always(false, realtime_message, read);
                }
                if (stale.count > stale.first.len) sdk.event("reads_stale", .{ .count = stale.count });
                if (stale.count == 0) sdk.always(true, realtime_message, .{ .reads = stale.reads });
            }
        }
    }.run;
}

const realtime_message = "every append acknowledged before a read began is in it";

/// A read that missed an append acknowledged before it began.
pub const Stale = struct {
    key: u64,
    value: u64,
    /// When the append was acknowledged, and when the read began and ended (the guest's clock).
    acknowledged_ns: u64,
    read_ns: [2]u64,
    listed: usize,
};

pub const StaleReads = struct {
    count: u32 = 0,
    reads: u32 = 0,
    first: [8]Stale = undefined,
};

/// The history's (JSON lines) list reads that miss an append acknowledged before they began:
/// a process does one operation at a time, so an `ok` began at that process's last `invoke`.
pub fn reads_stale(gpa: std.mem.Allocator, text: []const u8) !StaleReads {
    const Append = struct { key: u64, value: u64, acknowledged_ns: u64 };
    const Read = struct { key: u64, list: []const u64, began_ns: u64, ended_ns: u64 };
    var invoked: std.AutoHashMapUnmanaged(u64, u64) = .empty;
    var appends: std.ArrayList(Append) = .empty;
    var reads: std.ArrayList(Read) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, gpa, line, .{}) catch
            return error.BadHistory;
        if (parsed != .object) return error.BadHistory;
        const kind = parsed.object.get("type") orelse return error.BadHistory;
        const process = parsed.object.get("process") orelse return error.BadHistory;
        const time = parsed.object.get("time") orelse return error.BadHistory;
        if (kind != .string or process != .integer or time != .integer) return error.BadHistory;
        const now: u64 = @intCast(time.integer);
        if (std.mem.eql(u8, kind.string, "invoke")) {
            try invoked.put(gpa, @intCast(process.integer), now);
            continue;
        }
        if (!std.mem.eql(u8, kind.string, "ok")) continue;
        const began = invoked.get(@intCast(process.integer)) orelse continue;
        const mops = parsed.object.get("value") orelse return error.BadHistory;
        if (mops != .array) return error.BadHistory;
        for (mops.array.items) |mop| {
            if (mop != .array or mop.array.items.len != 3) continue;
            const f = mop.array.items[0];
            const key = mop.array.items[1];
            const value = mop.array.items[2];
            if (f != .string or key != .integer) continue;
            if (std.mem.eql(u8, f.string, "append") and value == .integer) {
                try appends.append(gpa, .{ .key = @intCast(key.integer), .value = @intCast(value.integer), .acknowledged_ns = now });
            } else if (std.mem.eql(u8, f.string, "r") and value == .array) {
                const list = try gpa.alloc(u64, value.array.items.len);
                for (value.array.items, list) |item, *slot| {
                    if (item != .integer) return error.BadHistory;
                    slot.* = @intCast(item.integer);
                }
                try reads.append(gpa, .{ .key = @intCast(key.integer), .list = list, .began_ns = began, .ended_ns = now });
            }
        }
    }
    var stale: StaleReads = .{ .reads = @intCast(reads.items.len) };
    for (reads.items) |read| {
        for (appends.items) |append| {
            if (append.key != read.key or append.acknowledged_ns >= read.began_ns) continue;
            if (std.mem.indexOfScalar(u64, read.list, append.value) != null) continue;
            if (stale.count < stale.first.len) stale.first[stale.count] = .{
                .key = read.key,
                .value = append.value,
                .acknowledged_ns = append.acknowledged_ns,
                .read_ns = .{ read.began_ns, read.ended_ns },
                .listed = read.list.len,
            };
            stale.count += 1;
        }
    }
    return stale;
}

test reads_stale {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // Process 2 reads 40 before its append is acknowledged (a dirty read, allowed), process 3
    // misses it after (stale), process 4's read began before the acknowledgment (allowed).
    const history =
        \\{"process":1,"type":"invoke","f":"txn","time":10,"value":[["append",7,40]]}
        \\{"process":2,"type":"invoke","f":"txn","time":11,"value":[["r",7,null]]}
        \\{"process":2,"type":"ok","f":"txn","time":12,"value":[["r",7,[40]]]}
        \\{"process":4,"type":"invoke","f":"txn","time":13,"value":[["r",7,null]]}
        \\{"process":1,"type":"ok","f":"txn","time":14,"value":[["append",7,40]]}
        \\{"process":4,"type":"ok","f":"txn","time":15,"value":[["r",7,[]]]}
        \\{"process":3,"type":"invoke","f":"txn","time":16,"value":[["r",7,null]]}
        \\{"process":3,"type":"ok","f":"txn","time":17,"value":[["r",7,[]]]}
        \\
    ;
    const stale = try reads_stale(arena.allocator(), history);
    try std.testing.expectEqual(@as(u32, 3), stale.reads);
    try std.testing.expectEqual(@as(u32, 1), stale.count);
    try std.testing.expectEqual(@as(u64, 40), stale.first[0].value);
    try std.testing.expectEqual([2]u64{ 16, 17 }, stale.first[0].read_ns);
}

/// Whether every anomaly type found is one of `allowed`.
fn allowed_only(found: []const []const u8, allowed: []const []const u8) bool {
    for (found) |kind| {
        const listed = for (allowed) |name| {
            if (std.mem.eql(u8, kind, name)) break true;
        } else false;
        if (!listed) return false;
    }
    return true;
}

test allowed_only {
    try std.testing.expect(allowed_only(&.{"G0"}, &.{"G0"}));
    try std.testing.expect(!allowed_only(&.{ "G0", "G1a" }, &.{"G0"}));
    try std.testing.expect(!allowed_only(&.{"G1c"}, &.{}));
}

pub const Verdict = struct {
    /// Null: Elle could not tell (too little to go on).
    valid: ?bool,
    anomaly_types: []const []const u8,
    ops: u64,
    /// As Elle prints them.
    anomalies: []const u8,
    /// When the anomalies formed: the earliest and latest time (the guest's clock) of the
    /// operations they name; after it, the failure is decided (causality looks before it).
    window_ns: ?[2]u64 = null,
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
        window_ns: ?[2]u64 = null,
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
        .window_ns = answer.window_ns,
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

/// The service answers, and is this version (checkers/elle's `version`): one of another is
/// replaced (podman rm -f, then run).
fn answers() bool {
    var buffer: [4096]u8 = undefined;
    const response = tcp.http_with(address, port, "GET", "/version", "", &buffer, .{ .timeout_ms = 2000 }) catch return false;
    return response.status == 200 and std.mem.indexOf(u8, response.body, "\"version\":\"" ++ service_version ++ "\"") != null;
}

/// checkers/elle/src/elle_service.clj's `version`.
const service_version = "3";

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
        try line_write(&line.writer, process, kind, mops, time_ns());
        const bytes = line.written();
        const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
        const fd = linux.open(history.path, flags, 0o644);
        if (linux.errno(fd) != .SUCCESS) return error.HistoryOpen;
        defer _ = linux.close(@intCast(fd));
        const written = linux.write(@intCast(fd), bytes.ptr, bytes.len);
        if (linux.errno(written) != .SUCCESS or written != bytes.len) return error.HistoryWrite;
    }
};

/// Each key's committed appends, from a history's `ok` lines, in the order keys first appear.
pub const Committed = std.AutoArrayHashMapUnmanaged(u64, std.ArrayList(u64));

/// The appends `history` says committed (none when nothing was recorded).
pub fn appends_committed(gpa: std.mem.Allocator, history: *const History) !Committed {
    return appends_parse(gpa, try file_read(gpa, history.path));
}

pub fn appends_parse(gpa: std.mem.Allocator, text: []const u8) !Committed {
    var committed: Committed = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, gpa, line, .{}) catch
            return error.BadHistory;
        if (parsed != .object) return error.BadHistory;
        const kind = parsed.object.get("type") orelse return error.BadHistory;
        if (kind != .string or !std.mem.eql(u8, kind.string, "ok")) continue;
        const mops = parsed.object.get("value") orelse return error.BadHistory;
        if (mops != .array) return error.BadHistory;
        for (mops.array.items) |mop| {
            if (mop != .array or mop.array.items.len != 3) continue;
            const f = mop.array.items[0];
            if (f != .string or !std.mem.eql(u8, f.string, "append")) continue;
            const key = mop.array.items[1];
            const value = mop.array.items[2];
            if (key != .integer or value != .integer) return error.BadHistory;
            const entry = try committed.getOrPut(gpa, @intCast(key.integer));
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(gpa, @intCast(value.integer));
        }
    }
    return committed;
}

/// A whole file ("" when there is none).
fn file_read(gpa: std.mem.Allocator, path: [:0]const u8) ![]const u8 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) == .NOENT) return "";
    if (linux.errno(fd) != .SUCCESS) return error.HistoryOpen;
    defer _ = linux.close(@intCast(fd));
    var bytes: std.ArrayList(u8) = .empty;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = linux.read(@intCast(fd), &buffer, buffer.len);
        if (linux.errno(count) == .INTR) continue;
        if (linux.errno(count) != .SUCCESS) return error.HistoryRead;
        if (count == 0) break;
        try bytes.appendSlice(gpa, buffer[0..count]);
    }
    return bytes.items;
}

/// Lost appends asserted one by one; past these, counted in an event.
const lost_reported_max = 8;

/// Once faults stop (a `finally` command, the drivers done): every append the history says
/// committed must be in its key's list as `reader` reads it, `reader.read_list(gpa, key)`: the
/// list, or null once it can read no more (a cluster may wait for an operator, as Galera does
/// after losing every node), the rest of the keys then unjudged. A lost append fails "every
/// committed append is in the final read"; each read goes into the history, for Elle. Elle below
/// strict serializability takes a read missing a committed append for an older snapshot, and a
/// workload's own reads may never read a key again (Galera run 123: a committed row lost, Elle's
/// 58 operations none the wiser).
pub fn final_reads(gpa: std.mem.Allocator, history: *const History, reader: anytype) !void {
    const committed = try appends_committed(gpa, history);
    if (committed.count() == 0) return;
    var judged: u32 = 0;
    var lost: u32 = 0;
    for (committed.keys(), committed.values()) |key, values| {
        const asked = [_]Mop{.{ .read = .{ .key = key, .list = null } }};
        const process = process_new();
        try history.invoke(gpa, process, &asked);
        const seen = reader.read_list(gpa, key) orelse {
            try history.fail(gpa, process, &asked);
            break; // Out of attempts: the rest unjudged.
        };
        try history.ok(gpa, process, &.{.{ .read = .{ .key = key, .list = seen } }});
        judged += 1;
        for (values.items) |value| {
            if (std.mem.indexOfScalar(u64, seen, value) != null) continue;
            lost += 1;
            if (lost > lost_reported_max) continue;
            sdk.always(false, "every committed append is in the final read", .{
                .key = key,
                .value = value,
                .read = seen.len,
                .committed = values.items.len,
            });
        }
    }
    sdk.sometimes(judged > 0, "the final reads reach a node once faults stop", .{
        .keys = committed.count(),
        .judged = judged,
    });
    if (judged > 0 and lost == 0) {
        sdk.always(true, "every committed append is in the final read", .{ .keys = judged });
    }
    if (lost > lost_reported_max) sdk.event("final_reads_lost", .{ .lost = lost, .keys = judged });
}

/// The guest's clock (virtual, the same in every replay): when an operation was recorded, which
/// Elle reports with the operations of an anomaly (the window the anomaly formed in).
fn time_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

/// `{"process":7,"type":"ok","f":"txn","time":5000000,"value":[["append",3,17],["r",4,[2,9]]]}`
/// and a newline.
pub fn line_write(writer: *std.Io.Writer, process: u64, kind: Kind, mops: []const Mop, time: u64) !void {
    try writer.print("{{\"process\":{d},\"type\":\"{s}\",\"f\":\"txn\",\"time\":{d},\"value\":[", .{
        process, @tagName(kind), time,
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

test appends_parse {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const history =
        \\{"process":1,"type":"invoke","f":"txn","time":1,"value":[["append",7,70],["r",8,null]]}
        \\{"process":1,"type":"ok","f":"txn","time":2,"value":[["append",7,70],["r",8,[1]]]}
        \\{"process":2,"type":"info","f":"txn","time":3,"value":[["append",7,71]]}
        \\{"process":3,"type":"fail","f":"txn","time":4,"value":[["append",9,90]]}
        \\{"process":4,"type":"ok","f":"txn","time":5,"value":[["append",9,91],["append",7,72]]}
        \\
    ;
    const committed = try appends_parse(arena.allocator(), history);
    try std.testing.expectEqualSlices(u64, &.{ 7, 9 }, committed.keys());
    try std.testing.expectEqualSlices(u64, &.{ 70, 72 }, committed.get(7).?.items);
    try std.testing.expectEqualSlices(u64, &.{91}, committed.get(9).?.items);
    try std.testing.expectError(error.BadHistory, appends_parse(arena.allocator(), "{\"type\":\"ok\"}\n"));
}

test line_write {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const asked = [_]Mop{ .{ .append = .{ .key = 3, .value = 17 } }, .{ .read = .{ .key = 4 } } };
    try line_write(&writer, 7, .invoke, &asked, 5);
    const done = [_]Mop{ asked[0], .{ .read = .{ .key = 4, .list = &.{ 2, 9 } } } };
    try line_write(&writer, 7, .ok, &done, 9);
    const registers = [_]Mop{
        .{ .write = .{ .key = 1, .value = 5 } },
        .{ .read_register = .{ .key = 2 } },
        .{ .read_register = .{ .key = 1, .value = 5 } },
    };
    try line_write(&writer, 8, .info, &registers, 12);
    try std.testing.expectEqualStrings(
        \\{"process":7,"type":"invoke","f":"txn","time":5,"value":[["append",3,17],["r",4,null]]}
        \\{"process":7,"type":"ok","f":"txn","time":9,"value":[["append",3,17],["r",4,[2,9]]]}
        \\{"process":8,"type":"info","f":"txn","time":12,"value":[["w",1,5],["r",2,null],["r",1,5]]}
        \\
    , writer.buffered());
}
