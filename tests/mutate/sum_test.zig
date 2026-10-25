// SPDX-License-Identifier: MIT
//! det-selftest-sum: a mutation campaign's smallest system (tools/e2e.zig, "mutate"). The node
//! is built from app/ (sum.sh); the driver checks its sums. mutants.jsonl patches app/: one
//! mutant the property catches, one in code nothing runs.
const std = @import("std");
const sdk = @import("determinismo");

const Nodes = struct { app: sdk.Node };
const System = sdk.System(Nodes);

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{ .sum = sum } });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.app, .{
        .build = .{ .context = "tests/mutate/app" },
        .command = &.{ "sleep", "infinity" },
    });
}

fn sum(s: *System.Scenario) void {
    s.parallel_driver("add", add);
}

/// Sums of random numbers are right.
fn add(context: *System.Context) !void {
    const a = sdk.random_below(1000);
    const b = sdk.random_below(1000);
    var text: [2][16]u8 = undefined;
    const arguments = [_][]const u8{
        "/usr/local/bin/sum.sh",
        try std.fmt.bufPrint(&text[0], "{d}", .{a}),
        try std.fmt.bufPrint(&text[1], "{d}", .{b}),
    };
    var buffer: [32]u8 = undefined;
    const result = try context.nodes.app.exec_output(&arguments, &buffer);
    const answer = std.fmt.parseInt(i64, std.mem.trim(u8, result.output, " \n"), 10) catch -1;
    sdk.always(answer == a + b, "sums are right", .{ .a = a, .b = b, .answer = answer });
}
