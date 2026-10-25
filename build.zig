// SPDX-License-Identifier: MIT
const std = @import("std");

pub fn build(b: *std.Build) void {
    // The VMM and the guest tools only ever run on x86-64 Linux: cross-compile by default.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // TCP with timeouts (sdk.tcp), its own module so that protocol clients use it too.
    const tcp = b.addModule("tcp", .{
        .root_source_file = b.path("sdk/zig/tcp.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The SDK for tests written in Zig; it also holds the system schema the VMM reads.
    const sdk = b.addModule("determinismo", .{
        .root_source_file = b.path("sdk/zig/determinismo.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "tcp", .module = tcp }},
    });
    const exe = b.addExecutable(.{
        .name = "determinismo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "determinismo", .module = sdk }},
        }),
    });
    b.installArtifact(exe);

    // A small Redis client, shared by the examples and the plain workload.
    const resp = b.createModule(.{
        .root_source_file = b.path("examples/bank/resp.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "tcp", .module = tcp }},
    });

    // Guest side: the in-guest runtime and example tests, static binaries that run in the VM.
    const guest_programs = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "det-init", .path = "guest/runtime/init.zig" },
        .{ .name = "det-nodes", .path = "guest/runtime/nodes_main.zig" },
        .{ .name = "det-composer", .path = "guest/runtime/composer.zig" },
        .{ .name = "det-faults", .path = "guest/runtime/faults.zig" },
        .{ .name = "det-agent", .path = "guest/runtime/agent.zig" },
        .{ .name = "det-stop-faults", .path = "guest/runtime/stop_faults.zig" },
        .{ .name = "det-profile", .path = "guest/runtime/profile.zig" },
        .{ .name = "det-core", .path = "guest/runtime/cores.zig" },
        .{ .name = "bank-test", .path = "examples/bank/bank_test.zig" },
        .{ .name = "shop-test", .path = "examples/shop/shop_test.zig" },
        .{ .name = "clojure-bank-test", .path = "examples/clojure-bank/clojure_bank_test.zig" },
        .{ .name = "k3s-test", .path = "examples/k3s/k3s_test.zig" },
        .{ .name = "raft-test", .path = "examples/raft/raft_test.zig" },
        .{ .name = "nrepl-test", .path = "examples/nrepl/nrepl_test.zig" },
        .{ .name = "clojure-libs-test", .path = "examples/clojure-libs/libs_test.zig" },
        .{ .name = "det-selftest", .path = "tests/selftest/selftest.zig" },
        .{ .name = "det-selftest-node", .path = "tests/selftest/node.zig" },
        .{ .name = "det-selftest-catalog", .path = "tests/selftest/catalog_test.zig" },
        .{ .name = "det-maze-sum", .path = "tests/selftest/maze_sum.zig" },
        .{ .name = "det-fake-explore", .path = "tests/selftest/fake_explore.zig" },
    };
    for (guest_programs) |program| {
        const guest_exe = b.addExecutable(.{
            .name = program.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(program.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "determinismo", .module = sdk },
                    .{ .name = "resp", .module = resp },
                },
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

    // A node written in C with the C SDK, for the self-tests.
    const c_node = b.addExecutable(.{
        .name = "det-selftest-c",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    c_node.root_module.addCSourceFile(.{
        .file = b.path("tests/selftest/c_node.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    c_node.root_module.addIncludePath(b.path("sdk/c"));
    b.installArtifact(c_node);

    // A maze for coverage-guided exploration, instrumented for edge coverage.
    const maze = b.addExecutable(.{
        .name = "det-maze",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    maze.root_module.addCSourceFile(.{
        .file = b.path("tests/selftest/maze.c"),
        .flags = &.{
            "-std=c11", "-Wall", "-Wextra", "-Werror", "-fsanitize-coverage=trace-pc-guard",
        },
    });
    maze.root_module.addIncludePath(b.path("sdk/c"));
    b.installArtifact(maze);
    // The same maze in Zig, through the Zig SDK's coverage hooks.
    const maze_zig = b.addExecutable(.{
        .name = "det-maze-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/selftest/maze.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "determinismo", .module = sdk }},
        }),
    });
    maze_zig.sanitize_coverage_trace_pc_guard = true;
    maze_zig.use_llvm = true; // Coverage instrumentation is an LLVM pass.
    b.installArtifact(maze_zig);

    // The guest's base initramfs, built on the host from the guest runtime above.
    const initramfs = b.addExecutable(.{
        .name = "det-initramfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/initramfs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(initramfs);

    // End-to-end checks: real VMs through the command line, on the Linux host.
    const e2e = b.addExecutable(.{
        .name = "e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/e2e.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const e2e_run = b.addRunArtifact(e2e);
    e2e_run.step.dependOn(b.getInstallStep());
    e2e_run.setCwd(b.path(".")); // Its defaults (zig-out/bin) and the examples' paths.
    const e2e_only = b.option([]const u8, "only", "e2e: the checks whose names contain this");
    if (e2e_only) |only| e2e_run.addArgs(&.{ "--only", only });
    b.step("e2e", "Boot real systems: exploration, exact replays, tapes (on the Linux host)")
        .dependOn(&e2e_run.step);

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

    // Unit tests use Linux system calls: they run on the Linux host (`zig build test` there).
    const test_step = b.step("test", "Run unit tests (on x86-64 Linux)");
    const test_roots = [_][]const u8{
        "src/main.zig",
        "sdk/zig/determinismo.zig",
        "sdk/zig/tcp.zig",
        "guest/runtime/init.zig",
        "guest/runtime/nodes.zig",
        "guest/runtime/netlink.zig",
        "guest/runtime/faults.zig",
        "guest/runtime/composer.zig",
        "guest/runtime/profile.zig",
        "guest/runtime/cores.zig",
        "examples/nrepl/bencode.zig",
        "examples/shop/pg.zig",
        "tools/e2e.zig",
        "tools/initramfs.zig",
    };
    for (test_roots) |root| {
        const unit_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "determinismo", .module = sdk },
                .{ .name = "tcp", .module = tcp },
            },
        }) });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
    const tidy_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/tidy.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    test_step.dependOn(&b.addRunArtifact(tidy_tests).step);
}
