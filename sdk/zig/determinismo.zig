// SPDX-License-Identifier: MIT
//! determinismo SDK for Zig: assertions, platform randomness, lifecycle, and test commands
//! written as plain handler functions.
//!
//! Inside determinismo everything goes through /dev/determinismo: events are recorded with their
//! moment, and every random value is a decision the platform can steer and replay. Outside it
//! (local runs) randomness comes from the OS and events go to stderr, so the same test binary
//! works everywhere.
//!
//! A test program describes the system (typed nodes, built from profiles) and its scenarios,
//! each a plain function that lists test commands:
//!
//!     const Nodes = struct { redis: sdk.Node };
//!     const System = sdk.System(Nodes);
//!
//!     fn describe(d: *System.Describe) !void {
//!         const profile = try d.profile("default");
//!         profile.node(.redis, .{ .image = "redis:7.4", .ready = .{ .tcp = 6379 } });
//!     }
//!     fn bank(s: *System.Scenario) void {
//!         s.setup("accounts", create_accounts);
//!         s.parallel_driver("transfer", transfer); // fn transfer(ctx: *System.Context) !void
//!         s.finally("conserved", check_total);
//!     }
//!     pub fn main(init: std.process.Init) !void {
//!         return System.main(init, .{ .describe = describe, .scenarios = .{ .bank = bank } });
//!     }
//!
//! Drivers are ordinary functions: share them between scenarios and programs like any code.
//! See schema.zig for the two commands every test program answers.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub const schema = @import("schema.zig");
const system = @import("system.zig");
pub const System = system.System;
pub const Node = system.Node;
pub const Output = system.Output;
/// TCP connections with timeouts, for protocol clients (see tcp.zig).
pub const tcp = @import("tcp");

pub const device_path = "/dev/determinismo";
/// One event or one randomness pull per device call (the guest module's page size limit).
pub const message_size_max = 4096 - 16;

/// The device, opened on first use. Not thread-safe: test commands are processes.
var device: Device = .unopened;

const Device = union(enum) { unopened, local, fd: linux.fd_t };

pub fn random_u64() u64 {
    var bytes: [8]u8 = undefined;
    random_bytes(&bytes);
    return std.mem.readInt(u64, &bytes, .little);
}

/// A uniformly random integer in [0, count).
pub fn random_below(count: u64) u64 {
    assert(count > 0);
    const value = random_u64() % count; // Bias is below 2^-32 for counts below 2^32.
    assert(value < count);
    return value;
}

/// A named decision among options, for strategies that reason about what they steer (which
/// fault, which account, which node): the platform sees the name and the options' names, then
/// picks the index, a decision like any other (replayed, steerable).
pub fn decide(name: []const u8, options: []const []const u8) usize {
    assert(options.len > 0);
    decision_announce(name, .{ .options = options });
    return @intCast(random_below(options.len));
}

/// `random_below`, named for strategies: "fault.duration_ns", "retry.jitter_ms".
pub fn random_below_named(name: []const u8, count: u64) u64 {
    decision_announce(name, .{ .range = count });
    return random_below(count);
}

fn decision_announce(name: []const u8, what: anytype) void {
    if (device_get() != .fd) return; // Only the platform's strategies read labels.
    var buffer: [message_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.writeAll("{\"decision\":{\"name\":") catch unreachable;
    json_write(&writer, name);
    inline for (@typeInfo(@TypeOf(what)).@"struct".field_names) |field| {
        writer.writeAll(",\"" ++ field ++ "\":") catch return;
        json_write(&writer, @field(what, field));
    }
    writer.writeAll("}}") catch return;
    emit_raw(writer.buffered());
}

pub fn random_choice(comptime T: type, items: []const T) T {
    assert(items.len > 0);
    return items[@intCast(random_below(items.len))];
}

pub fn random_bytes(target: []u8) void {
    assert(target.len > 0);
    assert(target.len <= message_size_max);
    switch (device_get()) {
        .fd => |fd| {
            const result = linux.read(fd, target.ptr, target.len);
            assert(linux.errno(result) == .SUCCESS); // The module never fails a sized read.
            assert(result == target.len);
        },
        .local => {
            const result = linux.getrandom(target.ptr, target.len, 0);
            assert(linux.errno(result) == .SUCCESS);
            assert(result == target.len); // Reads of at most 256 bytes are never short.
        },
        .unopened => unreachable,
    }
}

/// A `std.Random` whose every draw is a platform decision, for code that takes an RNG: what it
/// draws is steerable by strategies and replays from tapes. Each draw is one request to the
/// platform; for hot loops, `prng`.
pub fn rng() std.Random {
    return .{ .ptr = &rng_context, .fillFn = rng_fill };
}

var rng_context: u8 = 0;

fn rng_fill(_: *anyopaque, target: []u8) void {
    var rest = target;
    while (rest.len > 0) {
        const size = @min(rest.len, message_size_max);
        random_bytes(rest[0..size]);
        rest = rest[size..];
    }
}

/// A fast generator seeded from one platform decision: deterministic and different in every
/// branch, steered only through its seed. For drawing many values cheaply.
pub fn prng() std.Random.DefaultPrng {
    return .init(random_u64());
}

// Assertions ------------------------------------------------------------------------------
// Messages are literals (comptime): each call site is in the program's assertion catalog, which
// it announces as it starts, before any assertion runs (Antithesis's catalog). An assertion no
// timeline reaches is then judged too: a `sometimes` or `reachable` never hit fails, as does an
// `always` that never ran. `assert_computed` takes a message computed at run time, outside the
// catalog.

/// Which evaluations become events: every one (the default: queries see each), or, as
/// Antithesis's SDKs do, an assertion's first pass and first failure in each process (for hot
/// paths: the verdict is the same, the event stream far smaller). Set it once, at the start.
pub var assertion_events: enum { every, first } = .every;

pub noinline fn always(condition: bool, comptime message: []const u8, details: anytype) void {
    assert_at("always", condition, message, details, @returnAddress());
}

pub noinline fn always_or_unreachable(
    condition: bool,
    comptime message: []const u8,
    details: anytype,
) void {
    assert_at("always_or_unreachable", condition, message, details, @returnAddress());
}

pub noinline fn sometimes(condition: bool, comptime message: []const u8, details: anytype) void {
    assert_at("sometimes", condition, message, details, @returnAddress());
}

pub noinline fn reachable(comptime message: []const u8, details: anytype) void {
    assert_at("reachable", true, message, details, @returnAddress());
}

pub noinline fn assert_unreachable(comptime message: []const u8, details: anytype) void {
    assert_at("unreachable", true, message, details, @returnAddress());
}

/// (The public assertions are `noinline`: inlined, their `@returnAddress()` would be the return
/// address of the function they were inlined into, one frame too far.)
/// `caller`: the return address into the code that asserted; its source place goes with the
/// assertion's first event (as the other SDKs send theirs), from the program's debug info.
fn assert_at(
    comptime kind: [:0]const u8,
    condition: bool,
    comptime message: []const u8,
    details: anytype,
    caller: usize,
) void {
    const site = catalog_site(kind, message);
    if (site.repeated(condition)) return;
    const locate = !site.located;
    site.located = true;
    const assertion = Assertion{ .condition = condition, .message = message };
    emit_assertion(kind, assertion, details, if (locate) caller else null);
}

// Guidance assertions -----------------------------------------------------------------------
// As Antithesis's: a comparison's values go in the details (`left`, `right`), and a guidance
// event tells strategies how far the timeline is from the interesting outcome (an `always`
// violated, a `sometimes` true): `distance`, lower is closer, 0 or less is there. Strategies keep
// timelines that come closer (det-strategy-mutate does).

pub noinline fn always_greater_than(
    left: anytype,
    right: anytype,
    comptime message: []const u8,
    details: anytype,
) void {
    compare(.always, .greater, left, right, message, details, @returnAddress());
}
pub noinline fn always_greater_than_or_equal(
    left: anytype,
    right: anytype,
    comptime message: []const u8,
    details: anytype,
) void {
    compare(.always, .greater_or_equal, left, right, message, details, @returnAddress());
}
pub noinline fn always_less_than(
    left: anytype,
    right: anytype,
    comptime message: []const u8,
    details: anytype,
) void {
    compare(.always, .less, left, right, message, details, @returnAddress());
}
pub noinline fn always_less_than_or_equal(
    left: anytype,
    right: anytype,
    comptime message: []const u8,
    details: anytype,
) void {
    compare(.always, .less_or_equal, left, right, message, details, @returnAddress());
}
pub noinline fn sometimes_greater_than(
    left: anytype,
    right: anytype,
    comptime message: []const u8,
    details: anytype,
) void {
    compare(.sometimes, .greater, left, right, message, details, @returnAddress());
}
pub noinline fn sometimes_greater_than_or_equal(
    left: anytype,
    right: anytype,
    comptime message: []const u8,
    details: anytype,
) void {
    compare(.sometimes, .greater_or_equal, left, right, message, details, @returnAddress());
}
pub noinline fn sometimes_less_than(
    left: anytype,
    right: anytype,
    comptime message: []const u8,
    details: anytype,
) void {
    compare(.sometimes, .less, left, right, message, details, @returnAddress());
}
pub noinline fn sometimes_less_than_or_equal(
    left: anytype,
    right: anytype,
    comptime message: []const u8,
    details: anytype,
) void {
    compare(.sometimes, .less_or_equal, left, right, message, details, @returnAddress());
}

/// At least one of the named conditions holds, every time (all are evaluated: no short
/// circuit). `conditions` is a struct of bools: `.{ .leader = a, .follower = b }`.
pub noinline fn always_some(
    conditions: anytype,
    comptime message: []const u8,
    details: anytype,
) void {
    const held = conditions_held(conditions);
    const merged = .{ .conditions = conditions, .details = details };
    assert_at("always", held > 0, message, merged, @returnAddress());
    // Violated when none holds.
    catalog_site("always", message).guide(message, @floatFromInt(held));
}

/// All the named conditions hold together, at least once.
pub noinline fn sometimes_all(
    conditions: anytype,
    comptime message: []const u8,
    details: anytype,
) void {
    const total = @typeInfo(@TypeOf(conditions)).@"struct".field_names.len;
    const held = conditions_held(conditions);
    const merged = .{ .conditions = conditions, .details = details };
    assert_at("sometimes", held == total, message, merged, @returnAddress());
    // Conditions still missing.
    catalog_site("sometimes", message).guide(message, @floatFromInt(total - held));
}

const Relation = enum { greater, greater_or_equal, less, less_or_equal };

fn compare(
    comptime kind: enum { always, sometimes },
    comptime relation: Relation,
    left: anytype,
    right: anytype,
    comptime message: []const u8,
    details: anytype,
    caller: usize,
) void {
    const a = number(left);
    const b = number(right);
    const holds = switch (relation) {
        .greater => a > b,
        .greater_or_equal => a >= b,
        .less => a < b,
        .less_or_equal => a <= b,
    };
    // How much the relation holds by (negative: it does not).
    const margin = switch (relation) {
        .greater, .greater_or_equal => a - b,
        .less, .less_or_equal => b - a,
    };
    const merged = .{ .left = left, .right = right, .details = details };
    assert_at(@tagName(kind), holds, message, merged, caller);
    // An `always` is interesting where it breaks, a `sometimes` where it holds.
    const site = catalog_site(@tagName(kind), message);
    site.guide(message, if (kind == .always) margin else -margin);
}

fn number(value: anytype) f64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError("guidance assertions compare numbers"),
    };
}

fn conditions_held(conditions: anytype) u32 {
    const info = @typeInfo(@TypeOf(conditions)).@"struct";
    var held: u32 = 0;
    inline for (info.field_names, info.field_types) |name, Type| {
        comptime assert(Type == bool);
        held += @intFromBool(@field(conditions, name));
    }
    return held;
}

/// `{"guidance":{"message":M,"distance":D}}`: how far this timeline is from the assertion's
/// interesting outcome, for strategies.
fn guidance(message: []const u8, distance: f64) void {
    var buffer: [message_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.writeAll("{\"guidance\":{\"message\":") catch unreachable;
    json_write(&writer, message);
    writer.print(",\"distance\":{d}}}}}", .{distance}) catch unreachable;
    emit_raw(writer.buffered());
}

test "guidance assertions compute their distance" {
    try std.testing.expectEqual(@as(f64, 3), number(@as(u8, 3)));
    const conditions = .{ .a = true, .b = false, .c = true };
    try std.testing.expectEqual(@as(u32, 2), conditions_held(conditions));
}

pub const Kind = enum { always, always_or_unreachable, sometimes, reachable, @"unreachable" };

/// An assertion whose message is computed at run time: known to the platform only once it runs
/// (declare it with `declare` to have it judged before).
pub fn assert_computed(kind: Kind, condition: bool, message: []const u8, details: anytype) void {
    const value = Assertion{ .condition = condition, .message = message };
    switch (kind) {
        inline else => |known| emit_assertion(@tagName(known), value, details, null),
    }
}

/// One catalog entry, in the det_catalog section: every assertion call site compiled into the
/// program has one (the magic tells entries from the linker's padding between them).
pub const CatalogEntry = extern struct {
    magic: u64 = catalog_magic,
    kind: [*:0]const u8,
    message: [*:0]const u8,
    message_size: u64,
};
const catalog_magic: u64 = 0x676f_6c61_7461_6364; // "dcatalog"

/// What one assertion has sent in this process: for first-pass-first-failure events, and to
/// send guidance only when it improves (all a strategy needs).
const SiteState = struct {
    passed: bool = false,
    failed: bool = false,
    located: bool = false,
    best: f64 = std.math.inf(f64),

    /// Whether this evaluation adds nothing the platform does not have (assertion_events = first).
    fn repeated(site: *SiteState, condition: bool) bool {
        if (assertion_events == .every) return false;
        const seen = if (condition) &site.passed else &site.failed;
        if (seen.*) return true;
        seen.* = true;
        return false;
    }

    fn guide(site: *SiteState, message: []const u8, distance: f64) void {
        if (!(distance < site.best)) return;
        site.best = distance;
        guidance(message, distance);
    }
};

fn catalog_site(comptime kind: [:0]const u8, comptime message: []const u8) *SiteState {
    comptime assert(message.len > 0);
    const Site = struct {
        const entry: CatalogEntry linksection("det_catalog") = .{
            .kind = kind,
            .message = message ++ "",
            .message_size = message.len,
        };
        var state: SiteState = .{};
    };
    // A reference from the call site keeps its entry (and the section) in the linked program.
    std.mem.doNotOptimizeAway(&Site.entry);
    return &Site.state;
}

extern const __start_det_catalog: u8;
extern const __stop_det_catalog: u8;
/// Keeps the section in every program that uses the SDK, assertions or not.
const catalog_sentinel: CatalogEntry linksection("det_catalog") = .{
    .kind = "",
    .message = "",
    .message_size = 0,
};

/// Announces the catalog: run before main (.init_array), so a program that never calls the SDK
/// still declares its assertions. Only inside determinismo, and once per program file on each
/// machine or node: a test program runs as many processes, one per command.
fn catalog_announce() callconv(.c) void {
    std.mem.doNotOptimizeAway(&catalog_sentinel);
    // Probed, not cached when absent: det-init starts before /dev is mounted.
    if (device == .unopened) {
        const result = linux.open(device_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        if (linux.errno(result) != .SUCCESS) return;
        device = .{ .fd = @intCast(result) };
    }
    if (device != .fd) return;
    if (!catalog_first()) return;
    const start = @intFromPtr(&__start_det_catalog);
    const stop = @intFromPtr(&__stop_det_catalog);
    var at = std.mem.alignForward(usize, start, @alignOf(CatalogEntry));
    while (at + @sizeOf(CatalogEntry) <= stop) {
        const entry: *const CatalogEntry = @ptrFromInt(at);
        if (entry.magic != catalog_magic) {
            at += @alignOf(CatalogEntry);
            continue;
        }
        at += @sizeOf(CatalogEntry);
        if (entry.message_size == 0) continue; // The sentinel.
        const message = entry.message[0..entry.message_size];
        declare_runtime(std.mem.span(entry.kind), message);
    }
}

const Hook = *const fn () callconv(.c) void;
export const determinismo_catalog_announce: Hook linksection(".init_array") = &catalog_announce;

/// Whether this is the first process of this program file to announce its catalog here: a
/// marker named after the file (device and inode) is created once.
fn catalog_first() bool {
    var status: linux.Statx = undefined;
    const statted = linux.statx(linux.AT.FDCWD, "/proc/self/exe", 0, .{ .INO = true }, &status);
    if (linux.errno(statted) != .SUCCESS) return true;
    var path_buffer: [96]u8 = undefined;
    const format = "/tmp/.determinismo-catalog-{x}-{x}-{x}";
    const path = std.fmt.bufPrintSentinel(&path_buffer, format, .{
        status.dev_major, status.dev_minor, status.ino,
    }, 0) catch return true;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true };
    const result = linux.open(path, flags, 0o444);
    switch (linux.errno(result)) {
        .SUCCESS => {
            _ = linux.close(@intCast(result));
            return true;
        },
        .EXIST => return false,
        else => return true, // No /tmp to mark: announcing twice is harmless.
    }
}

/// Declares an assertion without evaluating it (Antithesis's catalog): a `reachable` or
/// `sometimes` declared and never reached (or never true) in any timeline fails, as an
/// `always` never hit does. Assertions with literal messages are declared already.
pub fn declare(comptime kind: []const u8, message: []const u8) void {
    declare_runtime(kind, message);
}

fn declare_runtime(kind: []const u8, message: []const u8) void {
    assert(message.len > 0);
    var buffer: [message_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print("{{\"assert\":{{\"type\":\"{s}\",\"message\":", .{kind}) catch unreachable;
    json_write(&writer, message);
    writer.writeAll(",\"hit\":false}}") catch unreachable;
    emit_raw(writer.buffered());
}

/// The system is ready: the platform snapshots here and starts exploring.
pub fn setup_complete(details: anytype) void {
    lifecycle("setup_complete", details);
}

/// A lifecycle point the platform acts on (`setup_complete`; `guest_done` from the runtime).
pub fn lifecycle(comptime name: []const u8, details: anytype) void {
    var buffer: [message_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.writeAll("{\"lifecycle\":\"" ++ name ++ "\",\"details\":") catch unreachable;
    json_write(&writer, details);
    writer.writeAll("}") catch unreachable;
    emit_raw(writer.buffered());
}

/// A structured event: `{"event": name, "details": details}`.
pub fn event(name: []const u8, details: anytype) void {
    assert(name.len > 0);
    var buffer: [message_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.writeAll("{\"event\":") catch unreachable;
    json_write(&writer, name);
    writer.writeAll(",\"details\":") catch unreachable;
    json_write(&writer, details);
    writer.writeAll("}") catch unreachable;
    emit_raw(writer.buffered());
}

/// Sleeps for `duration_ms` of (virtual) time.
pub fn sleep_ms(duration_ms: u64) void {
    const request = linux.timespec{
        .sec = @intCast(duration_ms / std.time.ms_per_s),
        .nsec = @intCast((duration_ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    _ = linux.nanosleep(&request, null);
}

/// A quiet period (Antithesis's ANTITHESIS_STOP_FAULTS, as det-stop-faults): faults stop (the
/// one under way is undone) for `duration_ns`, except clock skips; 0 ends it now. For checks a
/// fault would explain away: what fails in a quiet period is the system's own doing. Does
/// nothing without a running fault injector.
pub fn stop_faults(duration_ns: u64) void {
    const control_path = "/opt/determinismo/faults-control"; // faults.zig's control_path.
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true };
    const fd = linux.open(control_path, flags, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    const request = std.mem.toBytes(std.mem.nativeToLittle(u64, duration_ns));
    _ = linux.write(@intCast(fd), &request, request.len); // Atomic: under PIPE_BUF.
}

/// A fault now, from the scenario (as `det-faults inject`): the injector applies it, logs it
/// and undoes it like one it drew. `request` is written as JSON: `.{ .kind = "pause", .node =
/// "db", .duration_ms = 2000 }`, `.{ .kind = "partition_groups", .groups = .{ .{ "runner", "a"
/// }, .{"b"} }, .disruption = "stopped", .direction = "both" }`, `.{ .kind = "degrade", .node =
/// "a", .peer = "b", .flavor = "delay_loss" }`; guest/runtime/faults.zig lists them all. Only
/// while the injector runs (the drivers); otherwise nothing happens.
pub fn fault(request: anytype) void {
    const control_path = "/opt/determinismo/faults-control"; // faults.zig's control_path.
    var message: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(message[8..]);
    std.json.Stringify.value(request, .{}, &writer) catch return; // Too large: not sent.
    const length = writer.buffered().len;
    std.mem.writeInt(u64, message[0..8], (@as(u64, 1) << 63) | length, .little);
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true };
    const fd = linux.open(control_path, flags, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    _ = linux.write(@intCast(fd), &message, length + 8); // Atomic: under PIPE_BUF.
}

fn Result(comptime Function: type) type {
    return @typeInfo(Function).@"fn".return_type.?;
}

/// Calls `function` with `arguments` until it succeeds, at most `attempts` times and
/// `interval_ms` apart: what checks need while a system recovers (after faults, a restart).
/// Returns its value, or its last error.
pub fn retry(
    attempts: u32,
    interval_ms: u64,
    function: anytype,
    arguments: anytype,
) Result(@TypeOf(function)) {
    assert(attempts > 0);
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        if (@call(.auto, function, arguments)) |value| {
            return value;
        } else |err| {
            if (attempt == attempts) return err;
            sleep_ms(interval_ms);
        }
    }
}

const Assertion = struct { condition: bool, message: []const u8 };

fn emit_assertion(
    comptime kind: []const u8,
    assertion: Assertion,
    details: anytype,
    caller: ?usize,
) void {
    assert(assertion.message.len > 0);
    var buffer: [message_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.writeAll("{\"assert\":{\"type\":\"" ++ kind ++ "\",\"message\":") catch unreachable;
    json_write(&writer, assertion.message);
    writer.print(",\"condition\":{},\"details\":", .{assertion.condition}) catch unreachable;
    json_write(&writer, details);
    if (caller) |address| location_write(&writer, address);
    writer.writeAll("}}") catch unreachable;
    emit_raw(writer.buffered());
}

/// `,"location":{"file","line","function"}` for a return address, from the program's own debug
/// info; nothing when there is none (a stripped program) or it does not fit.
fn location_write(writer: *std.Io.Writer, address: usize) void {
    const info = std.debug.getSelfDebugInfo() catch return;
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var symbols: std.ArrayList(std.debug.Symbol) = .empty;
    // The return address follows the call: one byte back is in it.
    const io = std.Options.debug_io;
    info.getSymbols(io, arena, arena, address -| 1, false, &symbols) catch return;
    if (symbols.items.len == 0) return;
    const symbol = symbols.items[0];
    const source = symbol.source_location orelse return;
    var buffer: [512]u8 = undefined;
    var location: std.Io.Writer = .fixed(&buffer);
    location.writeAll(",\"location\":{\"file\":") catch return;
    std.json.Stringify.value(source.file_name, .{}, &location) catch return;
    location.print(",\"line\":{d},\"function\":", .{source.line}) catch return;
    std.json.Stringify.value(symbol.name orelse "", .{}, &location) catch return;
    location.writeAll("}") catch return;
    // Two bytes stay for the envelope's closing braces.
    if (writer.end + location.end + 2 > writer.buffer.len) return;
    writer.writeAll(location.buffered()) catch unreachable;
}

fn json_write(writer: *std.Io.Writer, value: anytype) void {
    const start = writer.end;
    std.json.Stringify.value(value, .{}, writer) catch {
        // Details that don't fit are replaced: the assertion itself must never be lost.
        writer.end = start;
        writer.writeAll("\"<details too large>\"") catch unreachable;
    };
}

fn emit_raw(message: []const u8) void {
    assert(message.len > 0);
    assert(message.len <= message_size_max);
    switch (device_get()) {
        .fd => |fd| {
            const result = linux.write(fd, message.ptr, message.len);
            assert(linux.errno(result) == .SUCCESS);
            assert(result == message.len);
        },
        .local => {
            const stderr = 2;
            _ = linux.write(stderr, message.ptr, message.len);
            _ = linux.write(stderr, "\n", 1);
        },
        .unopened => unreachable,
    }
}

/// Code coverage for strategies: build the program with `sanitize_coverage_trace_pc_guard` set
/// on its compile step, and reference this (`comptime { _ = sdk.coverage; }`). Each edge then
/// emits a "coverage" event the first time a process runs it, which strategies such as
/// det-strategy-mutate use to keep timelines that reach new code. Same events as the C SDK's.
pub const coverage = struct {
    var next: u32 = 1;
    /// Edges the SDK runs while reporting one are reported later, when they run again.
    var busy = false;
    // Zig's instrumentation also tracks stack depth (unused here) in a thread-local the program
    // must define. In assembly: defined in Zig, LLVM's pass would not bind to it.
    comptime {
        asm (
            \\.section .tbss,"awT",@nobits
            \\.globl __sancov_lowest_stack
            \\.type __sancov_lowest_stack,@object
            \\.p2align 3
            \\__sancov_lowest_stack:
            \\.zero 8
            \\.size __sancov_lowest_stack, 8
            \\.text
        );
    }

    export fn __sanitizer_cov_trace_pc_guard_init(start: [*]u32, stop: [*]u32) void {
        @disableInstrumentation();
        const count = (@intFromPtr(stop) - @intFromPtr(start)) / @sizeOf(u32);
        if (count == 0 or start[0] != 0) return; // Already numbered.
        for (start[0..count]) |*guard| {
            guard.* = next;
            next += 1;
        }
    }

    export fn __sanitizer_cov_trace_pc_guard(guard: *u32) void {
        @disableInstrumentation();
        if (guard.* == 0 or busy) return;
        busy = true;
        defer busy = false;
        var name_buffer: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "edge {d}", .{guard.*}) catch unreachable;
        guard.* = 0;
        event("coverage", .{ .name = name });
    }
};

fn device_get() Device {
    if (device == .unopened) {
        const result = linux.open(device_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        device = switch (linux.errno(result)) {
            .SUCCESS => .{ .fd = @intCast(result) },
            else => .local, // Not inside determinismo.
        };
    }
    assert(device != .unopened);
    return device;
}

test {
    _ = schema;
    _ = system;
}

test retry {
    const Flaky = struct {
        var calls: u32 = 0;
        fn call(succeed_at: u32) !u32 {
            calls += 1;
            if (calls < succeed_at) return error.NotYet;
            return calls;
        }
    };
    try std.testing.expectEqual(@as(u32, 3), try retry(5, 0, Flaky.call, .{3}));
    Flaky.calls = 0;
    try std.testing.expectError(error.NotYet, retry(2, 0, Flaky.call, .{3}));
}

test "rng and prng draw (from the OS outside determinismo)" {
    const value = rng().intRangeLessThan(u32, 0, 10);
    try std.testing.expect(value < 10);
    var generator = prng();
    try std.testing.expect(generator.random().intRangeLessThan(u32, 0, 10) < 10);
}
