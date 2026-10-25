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

pub fn always(condition: bool, message: []const u8, details: anytype) void {
    emit_assertion("always", .{ .condition = condition, .message = message }, details);
}

pub fn always_or_unreachable(condition: bool, message: []const u8, details: anytype) void {
    const assertion = Assertion{ .condition = condition, .message = message };
    emit_assertion("always_or_unreachable", assertion, details);
}

pub fn sometimes(condition: bool, message: []const u8, details: anytype) void {
    emit_assertion("sometimes", .{ .condition = condition, .message = message }, details);
}

pub fn reachable(message: []const u8, details: anytype) void {
    emit_assertion("reachable", .{ .condition = true, .message = message }, details);
}

pub fn assert_unreachable(message: []const u8, details: anytype) void {
    emit_assertion("unreachable", .{ .condition = true, .message = message }, details);
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

const Assertion = struct { condition: bool, message: []const u8 };

fn emit_assertion(comptime kind: []const u8, assertion: Assertion, details: anytype) void {
    assert(assertion.message.len > 0);
    var buffer: [message_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.writeAll("{\"assert\":{\"type\":\"" ++ kind ++ "\",\"message\":") catch unreachable;
    json_write(&writer, assertion.message);
    writer.print(",\"condition\":{},\"details\":", .{assertion.condition}) catch unreachable;
    json_write(&writer, details);
    writer.writeAll("}}") catch unreachable;
    emit_raw(writer.buffered());
}

fn json_write(writer: *std.Io.Writer, value: anytype) void {
    std.json.Stringify.value(value, .{}, writer) catch {
        // Details that don't fit are replaced: the assertion itself must never be lost.
        writer.end = 0;
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

test "rng and prng draw (from the OS outside determinismo)" {
    const value = rng().intRangeLessThan(u32, 0, 10);
    try std.testing.expect(value < 10);
    var generator = prng();
    try std.testing.expect(generator.random().intRangeLessThan(u32, 0, 10) < 10);
}
