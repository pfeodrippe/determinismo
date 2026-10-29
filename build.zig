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
    // The events database (src/duckdb.zig): DuckDB 2.0's static libraries for musl and the
    // libstdc++ they were built against, as infra/host/tools.sh installs them.
    const duckdb = b.option([]const u8, "duckdb", "DuckDB's libraries ($HOME/opt/duckdb)") orelse
        b.pathJoin(&.{ b.graph.environ_map.get("HOME") orelse "/", "opt", "duckdb" });
    const exe = b.addExecutable(.{
        .name = "determinismo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "determinismo", .module = sdk }},
        }),
    });
    duckdb_link(b, exe.root_module, duckdb);
    b.installArtifact(exe);
    // Compiled, not linked: no DuckDB needed (its functions are declared in src/duckdb.zig), so
    // any machine checks the code in seconds (`zig build check`), a Mac included.
    const check_exe = b.addExecutable(.{
        .name = "determinismo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "determinismo", .module = sdk }},
        }),
    });
    check_exe.root_module.link_libc = true;
    const check = b.step("check", "Compile determinismo without linking it (no DuckDB needed), the guest's programs and the e2e checks");
    check.dependOn(&check_exe.step);

    // A small Redis client, shared by the examples and the plain workload.
    const resp = b.createModule(.{
        .root_source_file = b.path("examples/bank/resp.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "tcp", .module = tcp }},
    });

    // A PostgreSQL client (also for CockroachDB and YugabyteDB), and list-append transactions
    // over SQL checked by Elle, shared by the SQL examples.
    const pg = b.createModule(.{
        .root_source_file = b.path("examples/shop/pg.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "determinismo", .module = sdk }},
    });
    // A MySQL client (also for MariaDB, Galera, Percona, TiDB).
    const mysql = b.createModule(.{
        .root_source_file = b.path("examples/sql/mysql.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "determinismo", .module = sdk }},
    });
    const sql_append = b.createModule(.{
        .root_source_file = b.path("examples/sql/append.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "determinismo", .module = sdk },
            .{ .name = "pg", .module = pg },
            .{ .name = "mysql", .module = mysql },
        },
    });

    // An nREPL client, shared by the nREPL and clojure-cli.repl examples.
    const nrepl = b.createModule(.{
        .root_source_file = b.path("examples/nrepl/client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "determinismo", .module = sdk }},
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
        .{ .name = "det-podlogs", .path = "guest/runtime/podlogs.zig" },
        .{ .name = "det-sinks", .path = "guest/runtime/sinks.zig" },
        .{ .name = "bank-test", .path = "examples/bank/bank_test.zig" },
        .{ .name = "shop-test", .path = "examples/shop/shop_test.zig" },
        .{ .name = "clojure-bank-test", .path = "examples/clojure-bank/clojure_bank_test.zig" },
        .{ .name = "k3s-test", .path = "examples/k3s/k3s_test.zig" },
        .{ .name = "raft-test", .path = "examples/raft/raft_test.zig" },
        .{ .name = "etcd-test", .path = "examples/etcd/etcd_test.zig" },
        .{ .name = "nats-test", .path = "examples/nats/nats_test.zig" },
        .{ .name = "tigerbeetle-test", .path = "examples/tigerbeetle/tigerbeetle_test.zig" },
        .{ .name = "redisraft-test", .path = "examples/redisraft/redisraft_test.zig" },
        .{ .name = "postgres-test", .path = "examples/postgres/postgres_test.zig" },
        .{ .name = "patroni-test", .path = "examples/patroni/patroni_test.zig" },
        .{ .name = "cockroachdb-test", .path = "examples/cockroachdb/cockroachdb_test.zig" },
        .{ .name = "mysql-test", .path = "examples/mysql/mysql_test.zig" },
        .{ .name = "galera-test", .path = "examples/galera/galera_test.zig" },
        .{ .name = "tidb-test", .path = "examples/tidb/tidb_test.zig" },
        .{ .name = "mongodb-test", .path = "examples/mongodb/mongodb_test.zig" },
        .{ .name = "mongodb-sharded-test", .path = "examples/mongodb/sharded_test.zig" },
        .{ .name = "kafka-test", .path = "examples/kafka/kafka_test.zig" },
        .{ .name = "rabbitmq-test", .path = "examples/rabbitmq/rabbitmq_test.zig" },
        .{ .name = "zookeeper-test", .path = "examples/zookeeper/zookeeper_test.zig" },
        .{ .name = "opensearch-test", .path = "examples/opensearch/opensearch_test.zig" },
        .{ .name = "tetris-test", .path = "examples/tetris/tetris_test.zig" },
        .{ .name = "scylla-test", .path = "examples/scylla/scylla_test.zig" },
        .{ .name = "yugabyte-test", .path = "examples/yugabyte/yugabyte_test.zig" },
        .{ .name = "dgraph-test", .path = "examples/dgraph/dgraph_test.zig" },
        .{ .name = "flecs-test", .path = "examples/flecs/flecs_test.zig" },
        .{ .name = "nrepl-test", .path = "examples/nrepl/nrepl_test.zig" },
        .{ .name = "clojure-libs-test", .path = "examples/clojure-libs/libs_test.zig" },
        .{ .name = "clojure-compiler-test", .path = "examples/clojure-compiler/compiler_test.zig" },
        .{ .name = "quint-test", .path = "examples/quint/quint_test.zig" },
        .{ .name = "clojure-core-async-test", .path = "examples/clojure-core-async/async_test.zig" },
        .{ .name = "clojure-cli-repl-test", .path = "examples/clojure-cli-repl/cli_repl_test.zig" },
        .{ .name = "det-selftest", .path = "tests/selftest/selftest.zig" },
        .{ .name = "det-selftest-node", .path = "tests/selftest/node.zig" },
        .{ .name = "det-selftest-catalog", .path = "tests/selftest/catalog_test.zig" },
        .{ .name = "det-maze-sum", .path = "tests/selftest/maze_sum.zig" },
        .{ .name = "det-selftest-sum", .path = "tests/mutate/sum_test.zig" },
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
                    .{ .name = "nrepl", .module = nrepl },
                    .{ .name = "pg", .module = pg },
                    .{ .name = "sql_append", .module = sql_append },
                },
            }),
        });
        b.installArtifact(guest_exe);
        check.dependOn(&guest_exe.step);
    }

    // libvoidstar.so, Antithesis's native library for the system's processes (nodes with
    // antithesis_library have it at /usr/lib/libvoidstar.so): no libc, so any program can load
    // it. Beside the runtime.
    const voidstar = b.addLibrary(.{
        .name = "voidstar",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("guest/runtime/voidstar.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
            .strip = true, // It lands in every initramfs.
        }),
    });
    b.getInstallStep().dependOn(&b.addInstallArtifact(voidstar, .{
        .dest_dir = .{ .override = .bin },
    }).step);

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

    // Flecs (an in-memory entity component system) under a stress harness (examples/flecs): its
    // amalgamated sources, fetched only for this program, built with Flecs's sanitize checks and
    // edge coverage (strategies and the tree see which of Flecs's code a timeline reached).
    if (b.lazyDependency("flecs", .{})) |flecs| {
        const flecs_stress = b.addExecutable(.{
            .name = "flecs-stress",
            .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
        });
        // Frame pointers: determinismo's stacks and profiles unwind by them.
        const flags = [_][]const u8{
            "-std=gnu11",              "-DFLECS_SANITIZE", "-fsanitize-coverage=trace-pc-guard",
            "-fno-omit-frame-pointer",
        };
        flecs_stress.root_module.addCSourceFile(.{
            .file = b.path("examples/flecs/stress.c"),
            .flags = &(flags ++ [_][]const u8{ "-Wall", "-Wextra", "-DDETERMINISMO_COVERAGE" }),
        });
        flecs_stress.root_module.addCSourceFile(.{ .file = flecs.path("distr/flecs.c"), .flags = &flags });
        flecs_stress.root_module.addIncludePath(flecs.path("distr"));
        flecs_stress.root_module.addIncludePath(b.path("sdk/c"));
        b.installArtifact(flecs_stress);
    }

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
    check.dependOn(&e2e.step);
    const e2e_run = b.addRunArtifact(e2e);
    e2e_run.step.dependOn(b.getInstallStep());
    e2e_run.setCwd(b.path(".")); // Its defaults (zig-out/bin) and the examples' paths.
    // Checks take the host's next free CPUs before exploration runs (src/cpus.zig).
    e2e_run.setEnvironmentVariable("DETERMINISMO_CPU_PRIORITY", "1");
    // Its explorations are runs (src/runs.zig): in a store of its own, not the user's.
    // Relative to its working directory, the repository's.
    e2e_run.setEnvironmentVariable("DETERMINISMO_DATA", ".zig-cache/e2e-runs");
    const e2e_only = b.option([]const u8, "only", "e2e: the checks whose names contain this");
    if (e2e_only) |only| e2e_run.addArgs(&.{ "--only", only });
    const e2e_guest = b.option([]const u8, "guest", "e2e: the guest kernel and initramfs ($HOME/guest)");
    if (e2e_guest) |guest| e2e_run.addArgs(&.{ "--guest", guest });
    // Babashka, for the notebook's checks ($DETERMINISMO_BB did not reach the suite on srv3).
    const e2e_bb = b.option([]const u8, "bb", "e2e: babashka, for notebook evaluation");
    if (e2e_bb) |bb| e2e_run.addArgs(&.{ "--bb", bb });
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
        "src/replays.zig",
        "src/verify.zig",
        "sdk/zig/determinismo.zig",
        "sdk/zig/tcp.zig",
        "guest/runtime/init.zig",
        "guest/runtime/nodes.zig",
        "guest/runtime/netlink.zig",
        "guest/runtime/faults.zig",
        "guest/runtime/composer.zig",
        "guest/runtime/profile.zig",
        "guest/runtime/cores.zig",
        "guest/runtime/voidstar.zig",
        "guest/runtime/output.zig",
        "guest/runtime/podlogs.zig",
        "guest/runtime/follow.zig",
        "examples/nrepl/bencode.zig",
        "examples/nats/client.zig",
        "examples/sql/append.zig",
        "examples/sql/mysql.zig",
        "examples/mongodb/bson.zig",
        "examples/mongodb/client.zig",
        "examples/mongodb/mongodb_test.zig",
        "examples/mongodb/sharded_test.zig",
        "examples/kafka/kafka_test.zig",
        "examples/rabbitmq/rabbitmq_test.zig",
        "examples/zookeeper/zookeeper_test.zig",
        "examples/opensearch/opensearch_test.zig",
        "examples/tetris/tetris_test.zig",
        "examples/scylla/cql.zig",
        "examples/scylla/scylla_test.zig",
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
        if (std.mem.eql(u8, root, "src/main.zig")) duckdb_link(b, unit_tests.root_module, duckdb);
        if (std.mem.eql(u8, root, "examples/sql/append.zig")) {
            unit_tests.root_module.addImport("pg", pg);
            unit_tests.root_module.addImport("mysql", mysql);
        }
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
    const tidy_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/tidy.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    test_step.dependOn(&b.addRunArtifact(tidy_tests).step);
}

fn duckdb_link(b: *std.Build, module: *std.Build.Module, directory: []const u8) void {
    const archives = [_][]const u8{
        "libduckdb_static.a", "libcore_functions_extension.a", "libjson_extension.a", "libstdc++.a",
    };
    for (archives) |archive| module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ directory, archive }) });
    module.link_libc = true;
    // libstdc++ unwinds with LLVM's libunwind, Zig's own (the same _Unwind ABI as libgcc's).
    module.linkSystemLibrary("unwind", .{ .use_pkg_config = .no });
}
