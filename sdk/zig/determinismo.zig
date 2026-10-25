// SPDX-License-Identifier: MIT
//! determinismo SDK for Zig: assertions, platform randomness, lifecycle, and test commands
//! written as plain handler functions.
//!
//! Inside determinismo everything goes through /dev/determinismo: events are recorded with their
//! moment, and every random value is a decision the platform can steer and replay. Outside it
//! (local runs) randomness comes from the OS and events go to stderr, so the same test binary
//! works everywhere.
//!
//! A test is a struct of handlers named after test-command prefixes:
//!
//!     const Test = struct {
//!         pub fn setup(init: std.process.Init) !void { ... sdk.setup_complete(.{}); }
//!         pub fn parallel_driver_transfer(init: std.process.Init) !void { ... }
//!         pub fn finally_check(init: std.process.Init) !void { sdk.always(ok, "...", .{}); }
//!     };
//!     pub fn main(init: std.process.Init) !void { return sdk.run(Test, init); }
//!
//! The runtime invokes `binary <handler>` (or a symlink named after the handler).
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub const device_path = "/dev/determinismo";
/// One event or one randomness pull per device call (the guest module's page size limit).
pub const message_size_max = 4096 - 16;

pub const command_prefixes = [_][]const u8{
    "setup",             "first_",   "parallel_driver_", "serial_driver_",
    "singleton_driver_", "anytime_", "eventually_",      "finally_",
};

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
    var buffer: [message_size_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.writeAll("{\"lifecycle\":\"setup_complete\",\"details\":") catch unreachable;
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

/// Runs the handler named by argv[1], or by the name the binary was invoked under. With
/// `--list`, prints the handler names, one per line, for the runtime to discover.
pub fn run(comptime Handlers: type, init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    assert(arguments.len >= 1);
    const command = if (arguments.len >= 2) arguments[1] else std.fs.path.basename(arguments[0]);
    if (std.mem.eql(u8, command, "--list")) {
        inline for (comptime handler_names(Handlers)) |name| {
            _ = linux.write(1, name ++ "\n", name.len + 1);
        }
        return;
    }
    inline for (comptime handler_names(Handlers)) |name| {
        if (std.mem.eql(u8, command, name)) return @field(Handlers, name)(init);
    }
    std.debug.print("unknown test command: {s}\n", .{command});
    return error.UnknownCommand;
}

fn handler_names(comptime Handlers: type) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        for (std.meta.declarations(Handlers)) |declaration| {
            for (command_prefixes) |prefix| {
                if (std.mem.startsWith(u8, declaration, prefix)) {
                    names = names ++ .{declaration};
                    break;
                }
            }
        }
        assert(names.len > 0); // A test needs at least one command.
        return names;
    }
}

test handler_names {
    const Handlers = struct {
        pub fn setup(_: std.process.Init) !void {}
        pub fn parallel_driver_a(_: std.process.Init) !void {}
        pub fn helper() void {}
    };
    const names = comptime handler_names(Handlers);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("setup", names[0]);
}
