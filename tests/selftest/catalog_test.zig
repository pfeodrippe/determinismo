// SPDX-License-Identifier: MIT
//! det-selftest-catalog: the assertion catalog (Antithesis's). One scenario, one driver, and a
//! `sometimes` in a branch no timeline can take: no timeline evaluates it, yet the exploration
//! knows it from the catalog the program announced as it started, and fails it as never true.
//! The C node (det-selftest-c) announces its own catalog the same way.
const std = @import("std");
const sdk = @import("determinismo");

const Nodes = struct { csdk: sdk.Node };
const System = sdk.System(Nodes);

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{ .catalog = catalog } });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.csdk, .{ .binary = "zig-out/bin/det-selftest-c" });
}

fn catalog(s: *System.Scenario) void {
    s.singleton_driver("never", never);
}

fn never(_: *System.Context) !void {
    sdk.reachable("catalog: the driver ran", .{});
    // Never true, but opaque to the compiler: code it can prove dead is removed, catalog entry
    // and all (it could never run anyway).
    var taken = false;
    std.mem.doNotOptimizeAway(&taken);
    if (taken) sdk.sometimes(true, "catalog: a branch no timeline takes", .{});
}
