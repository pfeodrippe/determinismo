// SPDX-License-Identifier: MIT
//! Example test program: Flecs, an in-memory entity component system, under a stress harness
//! (examples/flecs/stress.c): one node runs rounds of random operations against Flecs, worker
//! threads included, checking each against a model and reporting through the C SDK; Flecs's own
//! sanitize checks and the build's undefined-behavior traps report too.
//!
//! What varies a library's behavior is scheduling, not the network or restarts (its state is its
//! memory): the faults are pauses of the process or of one of its threads (ptrace), CPU throttling
//! and clock skips (Flecs reads the clock for frame times), with the SDK's buggify at Flecs's own
//! synchronization points (its mutex, condition variable, thread and atomic hooks).
//!
//!   determinismo explore ... --program zig-out/bin/flecs-test --scenario stress
const std = @import("std");
const sdk = @import("determinismo");

const Nodes = struct { flecs: sdk.Node };
const System = sdk.System(Nodes);

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{ .stress = stress } });
}

fn describe(d: *System.Describe) !void {
    const profile = try d.profile("default");
    profile.node(.flecs, .{
        .binary = "zig-out/bin/flecs-stress",
        .faults = .{
            .pause = true,
            .process_pause = true, // And one of its threads alone.
            .throttle = true,
            .isolate = false,
            .partition = false,
            .degrade = false,
            .sync_stall = false,
        },
    });
}

fn stress(s: *System.Scenario) void {
    s.clock_skip = true;
    // The node works on its own; the timeline lasts while drivers wait.
    s.singleton_driver("wait", wait);
}

fn wait(_: *System.Context) !void {
    sdk.sleep_ms(1000 + sdk.random_below(9000));
}
