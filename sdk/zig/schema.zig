// SPDX-License-Identifier: MIT
//! The system description, schema version 1 (ARCHITECTURE.md §10): what a test program's
//! `--describe` prints, and the resolved form determinismo freezes into the guest disk
//! (/det/system.json) and the run record.
//!
//! A test program is anything that answers two commands:
//!   <program> --describe                 print a `Description` as JSON on stdout (on the host)
//!   <program> run <scenario> <command>   run one command of a scenario (in the guest)
//! so any language can describe a system and its tests; SDKs only make it convenient.
const std = @import("std");
const assert = std.debug.assert;

pub const version: u32 = 1;
pub const nodes_max = 15; // Plus disk 0, within the VMM's 16 disks.
pub const scenarios_max = 64;
pub const commands_max = 64;
/// Node names become host names and interface names ("d-<name>", at most 15 bytes).
pub const node_name_size_max = 12;
pub const runner_name = "runner";
pub const runner_address = [4]u8{ 10, 0, 0, 1 };

pub const Description = struct {
    schema: u32 = version,
    profiles: []const Profile,
    scenarios: []const Scenario,
    checks: []const Check = &.{},
};

/// A check the host runs on what a timeline recorded: the test program's own (System.main's
/// `.checks`), run on the host as `<program> check <name> <scenario>` with the records its
/// commands made (`sdk.record`), which the composer streams out when the timeline ends. The
/// assertions the check makes are properties of the timeline, at its end: the host runs it on
/// all its cores, the guest pays nothing, and a replay sends the same records, so it gets the
/// same verdict. (sdk.elle.check is one: Jepsen's Elle on a transaction history.)
pub const Check = struct {
    /// Its name in the program's `.checks`.
    name: []const u8,
    /// The records, in the runner (record_path(name)).
    file: []const u8,
};
pub const checks_max = 8;

/// Where `sdk.record(name, ...)` appends, in the runner.
pub fn record_path(comptime name: []const u8) [:0]const u8 {
    return std.fmt.comptimePrint("/tmp/det-check-{s}.jsonl", .{name});
}

/// One way to build the system under test.
pub const Profile = struct {
    name: []const u8,
    nodes: []const Node,
    /// A command that turns the system's logs up, run in the guest at a moment (`det-nodes exec
    /// <node> ...`): causality's explanation runs it in futures inside a jump (its
    /// `explain_exec`, serve's default for the run's analyses).
    explain: ?[]const u8 = null,
};

pub const Node = struct {
    name: []const u8,
    source: Source,
    /// Replaces the image's entrypoint (null keeps it).
    entrypoint: ?[]const []const u8 = null,
    /// The command to run, after the entrypoint; null keeps the image's.
    command: ?[]const []const u8 = null,
    /// `NAME=value` entries, added to (and overriding) the image's environment.
    env: []const []const u8 = &.{},
    workdir: ?[]const u8 = null,
    /// A numeric `uid[:gid]`; null keeps the image's user.
    user: ?[]const u8 = null,
    ready: ?Ready = null,
    /// Nodes that must be ready before this one starts.
    after: []const []const u8 = &.{},
    faults: Faults = .{},
    /// The memory its processes may use (cgroup memory.max); past it, the kernel reclaims and
    /// then kills one of them. Null: no limit beyond the VM's memory.
    memory_max_mib: ?u32 = null,
    /// /sys and the node's cgroups writable, as for a privileged container: for nodes that run
    /// containers themselves (K3s, Docker in Docker).
    privileged: bool = false,
    /// Process limits of its processes and of commands run in it (Compose's `ulimits`); null:
    /// Docker's (open files 1048576, the kernel's for the rest).
    ulimits: ?[]const Ulimit = null,
    /// Antithesis's native library at /usr/lib/libvoidstar.so (determinismo's): Antithesis's
    /// SDKs then send through it, and instrumented programs report coverage. Imported Compose
    /// projects have it, as on Antithesis. Off by default: a static program with Antithesis's
    /// Go SDK (K3s, through etcd) cannot load a library, and the SDK stops it when one is there.
    antithesis_library: bool = false,
    /// Processes (by command name) whose crashes the system is known to have: such a crash is
    /// counted ("a process crash the system is known to have: <name>", a sometimes) instead of
    /// failing "no process crashes: <name>" in every timeline, which left a run's failing
    /// timelines saying nothing (YugabyteDB 1.3.1's YSQL backends crash on their way out: run
    /// 77, every timeline). Another process's crash still fails.
    crashes_known: []const []const u8 = &.{},
    /// A writeback window, in seconds: the guest writes nothing back unasked (a power loss drops
    /// every write never synced, however old), but this node's disk is synced that often, as a
    /// host's flusher writes dirty data back within ~30 s: a power loss drops the last window's
    /// writes only. For systems that leave their own metadata to writeback (RabbitMQ's feature
    /// flags and Mnesia tables bricked nodes after power losses at any age). Null: strict.
    writeback_s: ?u32 = null,
    /// Exits the system is known to make, by what the node wrote last (a substring of its
    /// output's last 64 KB): such an exit is counted ("an exit the system is known to make:
    /// <text>", a sometimes) instead of failing "no unexpected container exits" in nearly every
    /// timeline (ZooKeeper's servers that lost power before their first snapshot reached the
    /// disk refuse to start: ZOOKEEPER-3220). Another exit still fails.
    exits_known: []const []const u8 = &.{},
};

/// Where a node's root filesystem comes from: exactly one field is set.
pub const Source = struct {
    /// An OCI image reference, pinned to a digest when resolved.
    image: ?[]const u8 = null,
    /// A directory on the host, used as the root filesystem.
    directory: ?[]const u8 = null,
    /// A static executable on the host, alone in an otherwise empty root filesystem.
    binary: ?[]const u8 = null,
    /// An image built on the host from a Dockerfile, then used like `image`.
    build: ?Build = null,

    pub fn kind_count(source: Source) u32 {
        return @as(u32, @intFromBool(source.image != null)) +
            @intFromBool(source.directory != null) + @intFromBool(source.binary != null) +
            @intFromBool(source.build != null);
    }
};

/// A build context directory and the Dockerfile in it (relative to the context).
pub const Build = struct {
    context: []const u8,
    dockerfile: []const u8 = "Dockerfile",
};

/// The node is ready once this succeeds (from the runner).
pub const Ready = struct {
    tcp: u16,
    /// How long it may take, in seconds of virtual time: a node that joins its cluster before
    /// it listens (Cassandra's CQL port, after its ring delay alone) needs more than a minute.
    timeout_s: u32 = 60,
};

/// A process limit, by Docker's name ("nofile", "memlock", "nproc", ...: ulimit_resource), set
/// before a node's command runs. `unlimited` (RLIM_INFINITY) for no limit.
pub const Ulimit = struct {
    name: []const u8,
    soft: u64,
    hard: u64,

    pub const unlimited = std.math.maxInt(u64);
};
pub const ulimits_max = 16;

/// The Linux resource number (RLIMIT_*) of a Docker ulimit name; null for another name.
pub fn ulimit_resource(name: []const u8) ?u32 {
    const names = [_][]const u8{
        "cpu",     "fsize", "data",  "stack",      "core",     "rss",  "nproc",  "nofile",
        "memlock", "as",    "locks", "sigpending", "msgqueue", "nice", "rtprio", "rttime",
    };
    for (names, 0..) |known, resource| {
        if (std.mem.eql(u8, name, known)) return @intCast(resource);
    }
    return null;
}

test ulimit_resource {
    try std.testing.expectEqual(@as(?u32, 7), ulimit_resource("nofile"));
    try std.testing.expectEqual(@as(?u32, 8), ulimit_resource("memlock"));
    try std.testing.expectEqual(@as(?u32, 15), ulimit_resource("rttime"));
    try std.testing.expectEqual(@as(?u32, null), ulimit_resource("files"));
}

/// What the fault injector may do to the node.
pub const Faults = struct {
    /// Freeze all its processes for a while.
    pause: bool = true,
    /// Cut all its network links for a while.
    isolate: bool = true,
    /// Cut single links between it and other nodes for a while.
    partition: bool = true,
    /// Kill it and start it again (its files survive, its memory does not).
    restart: bool = false,
    /// Kill it as a power loss would and start it again: its disk keeps what was synced
    /// (fsync, sync, O_SYNC) and loses the rest (Antithesis's restarts that keep "durably synced
    /// filesystem changes"). The node's writable layer is then an ext4 disk of its own. With
    /// it, crashes at durability points too: at one of its fsyncs (or sync writes), before its
    /// data reaches the disk or just after.
    crash: bool = false,
    /// Hold its fsyncs (and sync writes) for a while, one in a few, while its other threads
    /// run: the interleavings around persisting (a goroutine waiting on a store write while
    /// another acts on what the store says).
    sync_stall: bool = true,
    /// Kill it and start it fresh from its image: everything it wrote is gone (Antithesis's
    /// restarts that "lose all of their modified data").
    wipe: bool = false,
    /// Stop it gracefully (SIGTERM, then a kill after a grace period) and start it again
    /// (Antithesis's node stop, beside the kill that restart is).
    stop: bool = false,
    /// Make its disk fail for a while: every I/O failing, writes failing, writes acknowledged
    /// and never stored, reads corrupted, or slow I/O. The node's writable layer is then an
    /// ext4 disk of its own (as with crash). An exit while the disk fails is expected; at the
    /// fault's end a node that exited, or whose filesystem gave up (read-only), starts again
    /// with its disk mounted afresh, as an operator would reboot it.
    disk: bool = false,
    /// A restart (restart, crash, wipe, stop) may give it a new address (Antithesis's
    /// "Restarted nodes may change IP addresses upon rejoining the network"): every hosts file
    /// then names it there; a peer that kept its old address loses it. Imported Compose
    /// projects have it; test programs whose drivers hold `Node.address` leave it off.
    new_address: bool = false,
    /// Degrade single links, in one direction, for a while: delay and loss, duplication,
    /// corruption, reordering or congestion.
    degrade: bool = true,
    /// Whether link faults (isolate, partition, degrade, partitions into groups, clogs) may
    /// reach its link with the runner (the test program's drivers). Off for a node that stands
    /// for the test's own client library, as Jepsen's clients live in the test process: its
    /// links to the servers are faulted (a commit delayed on its way to the coordinator), the
    /// drivers' calls into it are not.
    runner_links: bool = true,
    /// Limit its CPU (a share of one CPU) for a while.
    throttle: bool = true,
    /// Skew its realtime clock for a while, forward or back, 1 ms to 10 s (Jepsen's clock bumps;
    /// one in four strobes, coming and going every 10 ms to a second): its CLOCK_REALTIME apart
    /// from the other nodes', the monotonic clock untouched.
    /// For systems ordering by wall clocks (hybrid logical clocks, leases, timestamps). Off by
    /// default: some stop a node on purpose past their maximum offset.
    clock_skew: bool = false,
    /// The largest clock skew, in milliseconds (at least 10): below a system's documented
    /// maximum offset when its safety assumes one (YugabyteDB's and CockroachDB's 500 ms), so
    /// that what it then does wrong is a bug.
    clock_skew_ms_max: u32 = 10_000,
    /// Stop one of its processes (SIGSTOP) for a while.
    process_pause: bool = true,
    /// Kill one of its processes other than its main one (SIGKILL), as a crash its supervisor
    /// must recover from (a worker, a pod's process under kubelet).
    process_kill: bool = false,
    /// When not empty, the processes process_kill may kill: those whose command name (comm,
    /// 15 characters at most) is one of these. A system's own servers, not what they spawn and
    /// handle the death of themselves (a PostgreSQL backend killed makes its postmaster restart
    /// every backend, by design: YugabyteDB's YSQL), nor the node's scaffolding (a supervising
    /// shell killed leaves its server unsupervised; a start script's helper killed under set -e
    /// ends the script, the node down for good: Dgraph's and Scylla's first hunts).
    process_kill_names: []const []const u8 = &.{},
    /// Kubernetes pods run in it (`explore --kubernetes`, kubernetes.zig): faults also act on one
    /// of its pods at a time, as Antithesis's on a cluster's pods: frozen, killed (kubelet starts
    /// its containers again), cut off, or its network degraded (in the pod's own namespace).
    pods: bool = false,
    /// Commands in the node (an absolute path, then arguments, split at spaces: no shell) that
    /// the fault injector runs at random times, as Antithesis's custom faults: calling an admin
    /// API, forcing a compaction, a failover. They can draw from the SDK's randomness.
    custom: []const []const u8 = &.{},
};

pub const Scenario = struct {
    name: []const u8,
    commands: []const Command,
    /// Where the commands run: null for the test program in the runner, or a node whose
    /// filesystem holds them (`Command.path`), as with Antithesis test templates.
    node: ?[]const u8 = null,
    /// Whether the fault injector runs during the driver phase.
    faults: bool = true,
    clock_skip: bool = false,
    /// How the fault injector paces its faults.
    pacing: Pacing = .{},
};

/// The fault injector's pace. By default a fault every 10 to 300 ms for the whole driver phase.
/// With bursts (`active_ms_max` > 0), stretches of faults and quiet stretches alternate, each
/// drawn up to its maximum (named decisions, "fault.active_ms" and "fault.quiet_ms": a strategy
/// steers them), a quiet stretch healing what was under way: a system slow to recover (an
/// election, a catalog loaded) gets windows to make progress in, and faults land on its work
/// rather than on its recovery alone, as Jepsen's nemeses' intervals (10 s) left.
pub const Pacing = struct {
    active_ms_max: u32 = 0,
    quiet_ms_max: u32 = 0,
};

pub const Command = struct {
    kind: Kind,
    name: []const u8,
    /// The executable inside `Scenario.node`, for scenarios that run in a node.
    path: ?[]const u8 = null,
};

pub const Kind = enum {
    setup,
    first,
    parallel_driver,
    serial_driver,
    singleton_driver,
    anytime,
    eventually,
    finally,
};

/// What the guest receives: one profile, resolved, and every scenario.
pub const System = struct {
    schema: u32 = version,
    profile: []const u8,
    nodes: []const Resolved,
    scenarios: []const Scenario,
    /// The system declares its own setup through an Antithesis SDK (Compose projects): the
    /// composer waits for it before the drivers, as Antithesis does.
    sdk_setup: bool = false,
    checks: []const Check = &.{},
    /// The profile's command that turns the system's logs up (Profile.explain).
    explain: ?[]const u8 = null,

    pub fn scenario(system: *const System, name: []const u8) ?*const Scenario {
        for (system.scenarios) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    pub fn node(system: *const System, name: []const u8) ?*const Resolved {
        for (system.nodes) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }
};

/// A node with everything the guest needs to run it.
pub const Resolved = struct {
    name: []const u8,
    /// IPv4 address on the guest network, "10.0.0.N".
    address: []const u8,
    /// The block device holding its root filesystem ("vdb", "vdc", ...).
    disk: []const u8,
    /// Identifies the root filesystem's content (image digest or content hash).
    digest: []const u8,
    command: []const []const u8,
    env: []const []const u8,
    workdir: []const u8 = "/",
    user: ?[]const u8 = null,
    ready: ?Ready = null,
    after: []const []const u8 = &.{},
    faults: Faults = .{},
    memory_max_mib: ?u32 = null,
    privileged: bool = false,
    ulimits: ?[]const Ulimit = null,
    antithesis_library: bool = false,
    crashes_known: []const []const u8 = &.{},
    writeback_s: ?u32 = null,
    exits_known: []const []const u8 = &.{},
};

pub fn node_address(index: u32) [4]u8 {
    assert(index < nodes_max);
    return .{ 10, 0, 0, @intCast(index + 2) };
}

/// The block device of node `index` (disk 0, vda, is the system disk).
pub fn node_disk(buffer: *[3]u8, index: u32) []const u8 {
    assert(index < nodes_max);
    buffer.* = .{ 'v', 'd', @intCast('b' + index) };
    return buffer;
}

pub fn name_valid(name: []const u8) bool {
    if (name.len == 0 or name.len > node_name_size_max) return false;
    if (std.mem.eql(u8, name, runner_name)) return false;
    for (name) |byte| {
        const valid = std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-';
        if (!valid) return false;
    }
    return std.ascii.isLower(name[0]);
}

pub fn parse(comptime T: type, arena: std.mem.Allocator, source: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, source, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

test name_valid {
    try std.testing.expect(name_valid("redis"));
    try std.testing.expect(name_valid("pg-1"));
    try std.testing.expect(!name_valid("Redis"));
    try std.testing.expect(!name_valid("runner"));
    try std.testing.expect(!name_valid("a-very-long-name"));
}

test "a system round-trips through JSON" {
    const arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    var arena = arena_state;
    defer arena.deinit();
    const source =
        \\{"schema":1,"profile":"default","nodes":[{"name":"redis","address":"10.0.0.2",
        \\"disk":"vdb","digest":"sha256:x","command":["redis-server"],"env":["A=1"],
        \\"ready":{"tcp":6379}}],"scenarios":[{"name":"bank","commands":[
        \\{"kind":"setup","name":"seed"},{"kind":"parallel_driver","name":"transfer"}]}]}
    ;
    const system = try parse(System, arena.allocator(), source);
    try std.testing.expectEqual(@as(u16, 6379), system.node("redis").?.ready.?.tcp);
    const bank = system.scenario("bank").?;
    try std.testing.expectEqual(Kind.parallel_driver, bank.commands[1].kind);
    try std.testing.expect(bank.faults);
}
