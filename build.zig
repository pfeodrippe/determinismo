// SPDX-License-Identifier: MIT
const std = @import("std");

pub fn build(b: *std.Build) void {
    // The VMM and the guest tools only ever run on x86-64 Linux: cross-compile by default.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const exe = b.addExecutable(.{
        .name = "determinismo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // Guest side: the SDK for tests written in Zig, the in-guest runtime, and example tests.
    // All are static binaries that run inside the VM.
    const sdk = b.addModule("determinismo", .{
        .root_source_file = b.path("sdk/zig/determinismo.zig"),
        .target = target,
        .optimize = optimize,
    });
    const guest_programs = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "det-composer", .path = "guest/runtime/composer.zig" },
        .{ .name = "det-faults", .path = "guest/runtime/faults.zig" },
        .{ .name = "det-agent", .path = "guest/runtime/agent.zig" },
        .{ .name = "bank-test", .path = "examples/bank/bank_test.zig" },
    };
    for (guest_programs) |program| {
        const guest_exe = b.addExecutable(.{
            .name = program.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(program.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "determinismo", .module = sdk }},
            }),
        });
        b.installArtifact(guest_exe);
    }

    // Reference strategy plugins (docs/PLUGINS.md). They run on the host, next to determinismo.
    for ([_][]const u8{ "random", "mutate" }) |plugin| {
        const plugin_exe = b.addExecutable(.{
            .name = b.fmt("det-strategy-{s}", .{plugin}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("plugins/{s}.zig", .{plugin})),
                .target = target,
                .optimize = optimize,
            }),
        });
        b.installArtifact(plugin_exe);
    }

    // A plain workload with no SDK: tests can be any program, in any language.
    const resp = b.createModule(.{
        .root_source_file = b.path("examples/bank/resp.zig"),
        .target = target,
        .optimize = optimize,
    });
    const redis_workload = b.addExecutable(.{
        .name = "det-workload-redis",
        .root_module = b.createModule(.{
            .root_source_file = b.path("workload/redis.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "resp", .module = resp }},
        }),
    });
    b.installArtifact(redis_workload);

    // Style checks run on the developer's machine, not the target.
    const tidy = b.addExecutable(.{
        .name = "tidy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/tidy.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const tidy_run = b.addRunArtifact(tidy);
    tidy_run.setCwd(b.path("."));
    b.step("tidy", "Check line and function lengths, headers and whitespace").dependOn(&tidy_run.step);

    // Unit tests run natively on the developer's machine.
    const test_step = b.step("test", "Run unit tests");
    const test_roots = [_][]const u8{ "src/main.zig", "sdk/zig/determinismo.zig", "tools/tidy.zig" };
    for (test_roots) |root| {
        const unit_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = b.graph.host,
            .optimize = .Debug,
        }) });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
}
