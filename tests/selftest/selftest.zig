// SPDX-License-Identifier: MIT
//! det-selftest: determinismo testing itself through a real system (ARCHITECTURE.md §14).
//!
//! One node, det-selftest-node, from a `binary` source. Scenarios:
//!   steady     the node answers; every property passes (and fails on profile "mutant", whose
//!              echo node answers in uppercase: the tests catch the mutant)
//!   node_exit  a driver makes the node exit: the built-in property
//!              "no unexpected container exits" must fail
//!   oom        (profile "memory") a command in the echo node exceeds its memory limit: the
//!              built-in property "the kernel kills no process for lack of memory" must fail
//!   stress     drivers hammer clocks, sleeps, yields, page faults and forks at once, and report
//!              what they observe as events: any nondeterminism changes the event hash
//!   quiet      (profile "workers") a driver asks for a 2 second quiet period from inside the
//!              echo node (det-stop-faults, as Antithesis's ANTITHESIS_STOP_FAULTS): no fault
//!              but clock skips may start during it
//!   inject     (profile "injectable") faults the scenario asks for (sdk.fault): a pause, a
//!              graceful stop and a one-way partition, each taking the node away and giving it
//!              back
//!   hang       a driver that never ends: the timeline's ceiling of virtual time ends it, hung
//!   readdress  (profile "movable") restarts the scenario asks for: the node answers at its
//!              name each time, and sometimes came back at a new address
//!   disk       (profile "durable") the echo node's disk under a crash and a wipe: what it synced
//!              survives a crash, what it did not is lost, a wipe loses both (with a second
//!              durable node beside it); then disk faults asked for: lost writes, failing
//!              writes, a slow disk, and the disk afterwards
//!   durability (profile "durable") faults at the echo node's durability points: a stall holds
//!              its syncs; a crash at a sync loses the write when it comes before it, and keeps
//!              it when it comes just after
//!   records    a driver records numbers and their squares (sdk.record), and the host check
//!              `squares` (run on the host when the timeline ends) asserts every square and the
//!              count, from the records alone
//!   controller (profile "controller", ARCHITECTURE.md §14 level 1) determinismo's own HTTP API
//!              as the system under test, with a fake explorer, under pauses, partitions and
//!              restarts: every run it accepted must survive with a sensible state
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");

const Nodes = struct {
    echo: ?sdk.Node,
    csdk: ?sdk.Node,
    controller: ?sdk.Node,
    maze: ?sdk.Node,
    zigmaze: ?sdk.Node,
    summaze: ?sdk.Node,
    /// A second durable node: its mount namespace must not keep the echo node's disk (nor the
    /// echo node's keep its own) alive across a crash.
    witness: ?sdk.Node,
};
pub const System = sdk.System(Nodes);
const port = 7000;
/// No faults: these nodes check the platform, not resilience.
const quiet = sdk.schema.Faults{
    .pause = false,
    .isolate = false,
    .partition = false,
    .degrade = false,
    .throttle = false,
    .process_pause = false,
    .sync_stall = false,
};

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{
        .describe = describe,
        .scenarios = .{
            .steady = steady,
            .node_exit = node_exit,
            .oom = oom,
            .crash = crash,
            .disk = disk,
            .durability = durability,
            .inject = inject,
            .readdress = readdress,
            .hang = hang,
            .stress = stress,
            .quiet = quiet_scenario,
            .controller = @import("controller.zig").scenario,
            .maze = maze,
            .records = records_scenario,
            .ending = ending_scenario,
            .sinks = sinks_scenario,
        },
        .checks = .{ .squares = squares_check },
    });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = quiet,
    });
    // The same system with a mutant echo node: "steady" must catch it.
    const mutant = try d.profile("mutant");
    mutant.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .env = &.{"DET_MUTANT=1"},
        .ready = .{ .tcp = port },
        .faults = quiet,
    });
    const memory = try d.profile("memory");
    memory.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = quiet,
        .memory_max_mib = 32,
    });
    // Workers under a supervisor, and faults that kill processes (never the main one).
    const workers = try d.profile("workers");
    var kills = quiet;
    kills.process_kill = true;
    kills.custom = &.{"/bin/det-selftest-node custom-fault"};
    workers.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .env = &.{"DET_WORKERS=3"},
        .ready = .{ .tcp = port },
        .faults = kills,
    });
    try describe_faulted(d);
    try describe_mazes(d);
    const controller = try d.profile("controller");
    controller.node(.controller, .{
        .directory = "zig-out/bin", // determinismo and det-fake-explore.
        .command = &.{
            "/determinismo", "serve",     "--listen",   "0.0.0.0:7878",
            "--data",        "/var/runs", "--explorer", "/det-fake-explore",
        },
        .ready = .{ .tcp = 7878 },
        .faults = .{ .restart = true },
    });
    // A node in C reporting through the C SDK; no faults (its properties are about the SDK).
    default.node(.csdk, .{
        .binary = "zig-out/bin/det-selftest-c",
        .faults = quiet,
    });
}

/// The echo node with faults the scenarios ask for.
fn describe_faulted(d: *System.Describe) !void {
    // A disk of its own (crash faults allowed), for the "disk" scenario.
    const durable = try d.profile("durable");
    var crashes = quiet;
    crashes.crash = true;
    crashes.disk = true;
    durable.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .env = &.{"DET_DURABLE=1"},
        .ready = .{ .tcp = port },
        .faults = crashes,
    });
    durable.node(.witness, .{
        .binary = "zig-out/bin/det-selftest-node",
        .env = &.{"DET_DURABLE=1"},
        .ready = .{ .tcp = port },
        .faults = crashes,
    });
    // Faults the scenario asks for: the injector runs (it may pause or stop the node).
    const injectable = try d.profile("injectable");
    var asked = quiet;
    asked.pause = true;
    asked.stop = true;
    injectable.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = asked,
    });
    // Restarts that may give it a new address, for the "readdress" scenario.
    const movable = try d.profile("movable");
    var moves = quiet;
    moves.restart = true;
    moves.new_address = true;
    movable.node(.echo, .{
        .binary = "zig-out/bin/det-selftest-node",
        .ready = .{ .tcp = port },
        .faults = moves,
    });
}

/// The mazes coverage-guided strategies must solve (C, the sum, Zig).
fn describe_mazes(d: *System.Describe) !void {
    const maze_profile = try d.profile("maze");
    maze_profile.node(.maze, .{
        .binary = "zig-out/bin/det-maze",
        .command = &.{ "/bin/det-maze", "idle" },
        .faults = quiet,
    });
    // The same maze in Zig: coverage through the Zig SDK.
    const maze_sum = try d.profile("maze-sum");
    maze_sum.node(.summaze, .{
        .binary = "zig-out/bin/det-maze-sum",
        .command = &.{ "/bin/det-maze-sum", "idle" },
        .faults = quiet,
    });
    const maze_zig = try d.profile("maze-zig");
    maze_zig.node(.zigmaze, .{
        .binary = "zig-out/bin/det-maze-zig",
        .command = &.{ "/bin/det-maze-zig", "idle" },
        .faults = quiet,
    });
}

fn steady(s: *System.Scenario) void {
    s.first("entropy", entropy);
    s.parallel_driver("ping", ping);
    s.finally("ping_after", ping);
}

/// Antithesis's output sink (ANTITHESIS_OUTPUT_DIR): files written there in a node become
/// events (det-sinks). Written here from the runner, through the node's root (the echo node runs
/// no shell); its processes see the variable.
fn sinks_scenario(s: *System.Scenario) void {
    s.singleton_driver("sink_write", sink_write);
}

fn sink_write(_: *System.Context) !void {
    const sink = "/run/det/nodes/echo/root/run/antithesis";
    const assertion = "{\"antithesis_assert\":{\"hit\":true,\"must_hit\":true,\"assert_type\":\"always\"," ++
        "\"display_type\":\"Always\",\"message\":\"a sink assertion\",\"condition\":true," ++
        "\"id\":\"a sink assertion\",\"location\":{},\"details\":{}}}\n";
    try sink_append(sink ++ "/sdk.jsonl", assertion);
    try sink_append(sink ++ "/debug.log", "hello sink\n");
    try sink_append(sink ++ "/data.bin", "\x00\x01\x02");
    // The retroactive sink: out of the exploration's logs, back in a replay's.
    try sink_append("/run/det/nodes/echo/root/run/antithesis-filtered/verbose.log", "a filtered line\n");
    // The node's main process has the variable (Antithesis sets it in every container).
    const pid = nodes_pid_of("echo") orelse return error.NoEcho;
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/environ", .{pid}, 0);
    var environment: [8192]u8 = undefined;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.NoEnviron;
    defer _ = linux.close(@intCast(fd));
    const size = linux.read(@intCast(fd), &environment, environment.len);
    if (linux.errno(size) != .SUCCESS) return error.NoEnviron;
    const set = std.mem.indexOf(u8, environment[0..size], "ANTITHESIS_OUTPUT_DIR=/run/antithesis") != null;
    sdk.always(set, "nodes have ANTITHESIS_OUTPUT_DIR", .{});
    // det-sinks looks every 50 ms: the timeline goes on a little.
    const pause_long = linux.timespec{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
    _ = linux.nanosleep(&pause_long, null);
}

fn sink_append(path: [:0]const u8, data: []const u8) !void {
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
    const fd = linux.open(path, flags, 0o644);
    if (linux.errno(fd) != .SUCCESS) return error.SinkOpen;
    defer _ = linux.close(@intCast(fd));
    if (linux.errno(linux.write(@intCast(fd), data.ptr, data.len)) != .SUCCESS) return error.SinkWrite;
}

/// A node's main process (det-nodes records it), as the runner sees it.
fn nodes_pid_of(name: []const u8) ?linux.pid_t {
    var path_buffer: [128]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/run/det/nodes/{s}/pid", .{name}, 0) catch return null;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var buffer: [32]u8 = undefined;
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    return std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, buffer[0..size], " \n"), 10) catch null;
}

/// Antithesis's endings: an eventually command kills the drivers still running (here, ones
/// that sleep far past the driver phase); a finally one waits for them, and runs only when every
/// command ran to completion.
fn ending_scenario(s: *System.Scenario) void {
    s.parallel_driver("sleeper", sleeper);
    s.eventually("after_kill", ending_eventually);
    s.finally("after_all", ending_finally);
}

fn sleeper(_: *System.Context) !void {
    sdk.event("sleeper_start", .{});
    const long = linux.timespec{ .sec = 30, .nsec = 0 };
    _ = linux.nanosleep(&long, null);
    sdk.event("sleeper_done", .{});
}

fn ending_eventually(_: *System.Context) !void {
    sdk.reachable("an eventually command ran", .{});
}

fn ending_finally(_: *System.Context) !void {
    sdk.reachable("a finally command ran", .{});
}

fn quiet_scenario(s: *System.Scenario) void {
    s.singleton_driver("quiet_period", quiet_period);
}

/// Faults for a while, a quiet period requested from inside the node, then past its end.
fn quiet_period(context: *System.Context) !void {
    const node = context.nodes.echo orelse return error.NoEchoNode;
    const second = linux.timespec{ .sec = 1, .nsec = 0 };
    _ = linux.nanosleep(&second, null);
    sdk.event("quiet_request", .{ .seconds = 2 });
    _ = try node.exec(&.{ "/opt/determinismo/bin/det-stop-faults", "2" });
    const after = linux.timespec{ .sec = 3, .nsec = 0 };
    _ = linux.nanosleep(&after, null);
}

fn node_exit(s: *System.Scenario) void {
    s.singleton_driver("kill_echo", tell_die);
}

/// A process in the echo node dies of SIGSEGV: "no process crashes" must fail.
fn crash(s: *System.Scenario) void {
    s.singleton_driver("segfault", segfault);
}

fn segfault(context: *System.Context) !void {
    const node = context.nodes.echo orelse return error.NoEchoNode;
    _ = try node.exec(&.{ "/bin/det-selftest-node", "crash" });
}

fn records_scenario(s: *System.Scenario) void {
    s.singleton_driver("record", records_make);
}

const Square = struct { n: u64, square: u64 };
const records_count = 50;

/// Numbers and their squares, then a last record that says how many came before.
fn records_make(context: *System.Context) !void {
    _ = context;
    for (0..records_count) |n| sdk.record("squares", Square{ .n = n, .square = n * n });
    sdk.record("squares", Square{ .n = records_count, .square = 0 }); // The count: no square.
}

/// On the host, when the timeline ended: every record decoded, in order.
fn squares_check(check: *sdk.Check, records: []const Square) !void {
    sdk.always(std.mem.eql(u8, check.scenario, "records"), "a host check knows its scenario", .{});
    sdk.always(records.len == records_count + 1, "a host check gets every record", .{
        .records = records.len,
    });
    for (records[0..@min(records.len, records_count)], 0..) |record, index| {
        sdk.always(record.n == index and record.square == index * index, "a host check " ++
            "gets the records in order, as made", .{ .index = index, .n = record.n });
    }
}

fn disk(s: *System.Scenario) void {
    s.singleton_driver("disk_faults", disk_faults);
}

fn durability(s: *System.Scenario) void {
    s.singleton_driver("durability_faults", durability_faults);
}

/// Faults at durability points, asked for in a quiet period: only these.
fn durability_faults(context: *System.Context) !void {
    const echo = context.nodes.echo.?;
    sdk.stop_faults(600 * std.time.ns_per_s);
    // Every sync held 200 ms: a file and its directory synced take 400 ms or more.
    const stall_ms = 200;
    sdk.fault(.{
        .kind = "sync_stall",
        .node = echo.name,
        .one_in = 1,
        .stall_ms_min = stall_ms,
        .stall_ms_max = stall_ms,
        .duration_ms = 5000,
    });
    sdk.sleep_ms(100); // The injector applies it.
    const start_ns = monotonic_ns();
    const stalled_written = synced_write(&echo, "/data/stalled");
    const took_ns = monotonic_ns() - start_ns;
    const held = stalled_written and took_ns >= 2 * stall_ms * std.time.ns_per_ms;
    sdk.always(held, "a sync stall holds a node's syncs, and they complete", .{
        .took_ns = took_ns,
        .written = stalled_written,
    });
    sdk.sleep_ms(5000);
    // A crash at the write's first sync, before it: the write is gone after the restart.
    try durable_crash_at(&echo, "/data/before", false);
    const before = file_present(&echo, "/data/before");
    sdk.always(!before, "a crash just before a sync loses the write", .{ .present = before });
    // Just after it: the file synced (its directory entry with it) survives.
    try durable_crash_at(&echo, "/data/after", true);
    const after = file_present(&echo, "/data/after");
    sdk.always(after, "a crash just after a sync keeps the write", .{ .present = after });
    // Two threads at durability points at once: one crash. A second, there, once switched the
    // disk to dropping writes and failed, leaving it so: what was synced after was lost at the
    // next crash (Kafka's run 67 on srv3, a false data loss).
    sdk.fault(.{ .kind = "durable_crash", .node = echo.name, .one_in = 1, .duration_ms = 2000 });
    sdk.sleep_ms(100);
    _ = echo.exec(&.{ "/bin/det-selftest-node", "write2", "/data/two-a", "/data/two-b" }) catch 0;
    sdk.sleep_ms(2000);
    try sdk.retry(100, 100, answers, .{echo.address});
    const kept_written = synced_write(&echo, "/data/kept");
    sdk.fault(.{ .kind = "crash", .node = echo.name, .duration_ms = 500 });
    sdk.sleep_ms(600);
    try sdk.retry(100, 100, answers, .{echo.address});
    const kept = file_present(&echo, "/data/kept");
    sdk.always(kept_written and kept, "after a crash at two durability points at once, the disk " ++
        "keeps what is synced", .{ .written = kept_written, .present = kept });
    sdk.stop_faults(0);
}

/// The node crashes at the first sync of a write of `path` (before it or just after), and is
/// back at the fault's end.
fn durable_crash_at(echo: *const sdk.Node, path: []const u8, after_sync: bool) !void {
    const fault_ms = 2000;
    sdk.fault(.{
        .kind = "durable_crash",
        .node = echo.name,
        .one_in = 1,
        .after_sync = after_sync,
        .duration_ms = fault_ms,
    });
    sdk.sleep_ms(100);
    const written = synced_write(echo, path); // Killed in its sync.
    sdk.always(!written, "a write crashed at its sync never returns", .{});
    sdk.sleep_ms(fault_ms);
    try sdk.retry(100, 100, answers, .{echo.address});
}

fn disk_faults(context: *System.Context) !void {
    const echo = context.nodes.echo.?;
    const witness = context.nodes.witness.?;
    sdk.stop_faults(600 * std.time.ns_per_s);
    // Whichever started first, the other's mount namespace began with its disk in it.
    try witness.crash();
    try sdk.retry(100, 100, answers, .{witness.address});
    try crash_and_wipe(&echo);
    try disk_failures(&echo);
    sdk.stop_faults(0);
}

/// The echo node wrote one file synced and one not (DET_DURABLE). After a crash the first is
/// there and the second is not; after a wipe neither is. In a quiet period: only these.
fn crash_and_wipe(echo: *const sdk.Node) !void {
    try echo.crash();
    try sdk.retry(100, 100, answers, .{echo.address});
    const synced = file_present(echo, "/data/synced");
    const unsynced = file_present(echo, "/data/unsynced");
    sdk.event("disk_after_crash", .{ .synced = synced, .unsynced = unsynced });
    sdk.always(synced and !unsynced, "a crash keeps what was synced and loses the rest", .{
        .synced = synced,
        .unsynced = unsynced,
    });
    try echo.wipe();
    try sdk.retry(100, 100, answers, .{echo.address});
    // The node wrote both again on its fresh start: the wipe lost what the crash kept.
    sdk.always(file_present(echo, "/data/unsynced"), "a wipe starts the node fresh", .{});
}

/// Disk faults asked for. Writes a disk drops are acknowledged, synced even, and gone after a
/// crash; writes a disk refuses fail the sync (and the node, its filesystem read-only, starts
/// again at the fault's end); a slow disk slows a sync; afterwards the disk works.
fn disk_failures(echo: *const sdk.Node) !void {
    const lost_ms = 1000;
    sdk.fault(.{
        .kind = "disk",
        .node = echo.name,
        .failure = "lost_writes",
        .duration_ms = lost_ms,
    });
    sdk.sleep_ms(100); // The injector applies it.
    const acknowledged = synced_write(echo, "/data/lost");
    sdk.sleep_ms(lost_ms); // The fault is over: the disk is healthy again.
    try echo.crash();
    try sdk.retry(100, 100, answers, .{echo.address});
    const vanished = !file_present(echo, "/data/lost");
    const message = "writes a disk drops are synced, then gone after a crash";
    sdk.always(acknowledged and vanished, message, .{
        .acknowledged = acknowledged,
        .vanished = vanished,
    });

    sdk.fault(.{
        .kind = "disk",
        .node = echo.name,
        .failure = "write_errors",
        .duration_ms = 1000,
    });
    sdk.sleep_ms(100);
    sdk.always(!synced_write(echo, "/data/refused"), "a disk refusing writes fails a sync", .{});
    sdk.sleep_ms(1000);
    try sdk.retry(100, 100, answers, .{echo.address});

    const slow_ms = 300;
    sdk.fault(.{
        .kind = "disk",
        .node = echo.name,
        .failure = "slow",
        .delay_ms = slow_ms,
        .duration_ms = 5000,
    });
    sdk.sleep_ms(100);
    const start_ns = monotonic_ns();
    _ = synced_write(echo, "/data/slow");
    const took_ns = monotonic_ns() - start_ns;
    // A file and its directory synced: data, journal and commit, each waiting.
    sdk.always(took_ns >= 2 * slow_ms * std.time.ns_per_ms, "a slow disk slows a sync", .{
        .took_ns = took_ns,
    });
    sdk.sleep_ms(5000);
    sdk.always(synced_write(echo, "/data/after"), "a disk works again after its faults", .{});
}

/// The node writes the file and syncs it and its directory: whether the disk took it.
fn synced_write(node: *const sdk.Node, path: []const u8) bool {
    const status = node.exec(&.{ "/bin/det-selftest-node", "write", path }) catch return false;
    return status == 0;
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

fn inject(s: *System.Scenario) void {
    s.singleton_driver("faults_on_request", faults_on_request);
}

/// In a quiet period (no drawn faults; requested ones still apply), the driver asks for a
/// pause, a graceful stop, a partition from the runner to the node and its isolation: each
/// takes the node away for a while, then it answers again. Isolated, it still reaches itself
/// at its own address, as a host whose cables are cut does.
fn faults_on_request(context: *System.Context) !void {
    const echo = context.nodes.echo.?;
    sdk.stop_faults(600 * std.time.ns_per_s);
    sdk.fault(.{ .kind = "pause", .node = echo.name, .duration_ms = 2000 });
    sdk.sleep_ms(100);
    sdk.always(!answering(echo.address), "an injected pause stops the node", .{});
    try sdk.retry(100, 100, answers, .{echo.address});
    // The node ignores SIGTERM (no handler, init of its PID namespace): down when its grace
    // period ends in a kill.
    sdk.fault(.{ .kind = "stop", .node = echo.name, .duration_ms = 1000 });
    const down = if (sdk.retry(60, 100, gone, .{echo.address})) |_| true else |_| false;
    sdk.always(down, "an injected stop takes the node down", .{});
    try sdk.retry(100, 100, answers, .{echo.address});
    sdk.fault(.{
        .kind = "partition_groups",
        .groups = .{ .{"runner"}, .{echo.name} },
        .direction = "outbound",
        .duration_ms = 1500,
    });
    sdk.sleep_ms(100);
    sdk.always(!answering(echo.address), "an injected one-way partition cuts the node off", .{});
    try sdk.retry(100, 100, answers, .{echo.address});
    sdk.fault(.{ .kind = "isolate", .node = echo.name, .duration_ms = 1500 });
    sdk.sleep_ms(100);
    sdk.always(!answering(echo.address), "an injected isolation cuts the node off", .{});
    var own: [15]u8 = undefined;
    const own_address = std.fmt.bufPrint(&own, "{d}.{d}.{d}.{d}", .{
        echo.address[0], echo.address[1], echo.address[2], echo.address[3],
    }) catch unreachable;
    const itself = echo.exec(&.{ "/bin/det-selftest-node", "ping", own_address }) catch 255;
    sdk.always(itself == 0, "an isolated node still reaches itself at its own address", .{
        .status = itself,
    });
    try sdk.retry(100, 100, answers, .{echo.address});
    sdk.reachable("injected faults came and went", .{});
    sdk.stop_faults(0);
}

fn hang(s: *System.Scenario) void {
    s.singleton_driver("forever", forever);
}

/// A driver that never ends (an hour of sleep): the timeline's ceiling ends it as hung.
fn forever(_: *System.Context) !void {
    sdk.sleep_ms(std.time.ms_per_hour);
}

fn readdress(s: *System.Scenario) void {
    s.singleton_driver("restarts", restarts);
}

/// Restarts asked for, in a quiet period: each time the node answers at its name (where the
/// hosts file says it is); across timelines, sometimes at a new address.
fn restarts(context: *System.Context) !void {
    const echo = context.nodes.echo.?;
    sdk.stop_faults(600 * std.time.ns_per_s);
    var moved = false;
    for (0..4) |_| {
        sdk.fault(.{ .kind = "restart", .node = echo.name, .duration_ms = 200 });
        sdk.sleep_ms(300); // The fault is over: it started again, maybe elsewhere.
        const found = host_address(echo.name);
        const back = if (found) |address|
            if (sdk.retry(100, 100, answers, .{address})) |_| true else |_| false
        else
            false;
        sdk.always(back, "a restarted node answers at its name", .{});
        if (found) |address| moved = moved or !std.mem.eql(u8, &address, &echo.address);
    }
    sdk.sometimes(moved, "a restarted node comes back at a new address", .{});
    sdk.stop_faults(0);
}

/// Where /etc/hosts says `name` is.
fn host_address(name: []const u8) ?[4]u8 {
    var buffer: [4096]u8 = undefined;
    const fd = linux.open("/etc/hosts", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    const size = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return null;
    var lines = std.mem.tokenizeScalar(u8, buffer[0..size], '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const text = fields.next() orelse continue;
        const host = fields.next() orelse continue;
        if (!std.mem.eql(u8, host, name)) continue;
        var address: [4]u8 = undefined;
        var parts = std.mem.splitScalar(u8, text, '.');
        for (&address) |*byte| {
            byte.* = std.fmt.parseInt(u8, parts.next() orelse return null, 10) catch return null;
        }
        return address;
    }
    return null;
}

fn gone(address: [4]u8) !void {
    if (answering(address)) return error.StillAnswering;
}

fn answering(address: [4]u8) bool {
    answers(address) catch return false;
    return true;
}

fn file_present(node: *const sdk.Node, path: []const u8) bool {
    const status = node.exec(&.{ "/bin/det-selftest-node", "exists", path }) catch return false;
    return status == 0;
}

fn answers(address: [4]u8) !void {
    var reply: [16]u8 = undefined;
    const answer = try request(address, "ping\n", &reply);
    if (!std.mem.eql(u8, answer, "ping\n")) return error.WrongAnswer;
}

fn oom(s: *System.Scenario) void {
    s.singleton_driver("hog", hog);
}

fn hog(context: *System.Context) !void {
    const node = context.nodes.echo orelse return error.NoEchoNode;
    const status = try node.exec(&.{ "/bin/det-selftest-node", "hog" });
    sdk.always(status == 128 + 9, "the hog is killed", .{ .status = status });
}

fn stress(s: *System.Scenario) void {
    s.parallel_driver("clocks", clocks);
    s.parallel_driver("sleeps", sleeps);
    s.parallel_driver("faults", page_faults);
    s.parallel_driver("forks", forks);
    s.finally("ping_after", ping);
}

const stress_rounds = 200;

/// Reads every clock in a tight loop: the values (virtual time) must be the same on replay.
fn clocks(_: *System.Context) !void {
    var sum: u64 = 0;
    for (0..stress_rounds) |round| {
        for ([_]linux.clockid_t{ .REALTIME, .MONOTONIC, .BOOTTIME, .PROCESS_CPUTIME_ID }) |clock| {
            var now: linux.timespec = undefined;
            _ = linux.clock_gettime(clock, &now);
            sum +%= @as(u64, @intCast(now.sec)) *% 1_000_000_007 +% @as(u64, @intCast(now.nsec));
        }
        if (round % 50 == 0) sdk.event("clocks", .{ .round = round, .sum = sum });
    }
}

/// Short sleeps and yields: wake-ups land where timers fire.
fn sleeps(_: *System.Context) !void {
    for (0..stress_rounds) |round| {
        const pause = linux.timespec{ .sec = 0, .nsec = @intCast(1 + sdk.random_below(200_000)) };
        _ = linux.nanosleep(&pause, null);
        _ = linux.sched_yield();
        if (round % 50 == 0) {
            var now: linux.timespec = undefined;
            _ = linux.clock_gettime(.MONOTONIC, &now);
            sdk.event("sleeps", .{ .round = round, .ns = now.nsec });
        }
    }
}

/// Maps, touches and unmaps memory: page faults, zeroing, reclaim.
fn page_faults(_: *System.Context) !void {
    const size = 4 << 20;
    var checksum: u64 = 0;
    for (0..stress_rounds / 10) |round| {
        const protection: linux.PROT = .{ .READ = true, .WRITE = true };
        const flags: linux.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
        const address = linux.mmap(null, size, protection, flags, -1, 0);
        if (linux.errno(address) != .SUCCESS) return error.Mmap;
        const memory: [*]u8 = @ptrFromInt(address);
        var offset: usize = 0;
        while (offset < size) : (offset += 4096) memory[offset] = @truncate(offset >> 12);
        checksum +%= memory[sdk.random_below(size / 4096) * 4096];
        _ = linux.munmap(memory, size);
        sdk.event("faults", .{ .round = round, .checksum = checksum });
    }
}

/// Forks children that exit with a status the parent checks: scheduling across processes.
fn forks(_: *System.Context) !void {
    for (0..stress_rounds / 10) |round| {
        const pid = linux.fork();
        if (pid == 0) linux.exit_group(@intCast(round % 7));
        var status: i32 = 0;
        _ = linux.wait4(@intCast(pid), &status, 0, null);
        const code = (@as(u32, @bitCast(status)) >> 8) & 0xff;
        sdk.always(code == round % 7, "children exit with their status", .{ .round = round });
    }
}

/// One attempt at the maze per timeline (profile "maze", or "maze-zig"), inside the maze node:
/// by chance 1 in 10000 timelines solves it.
fn maze(s: *System.Scenario) void {
    s.singleton_driver("attempt", maze_attempt);
}

fn maze_attempt(context: *System.Context) !void {
    if (context.nodes.maze) |node| _ = try node.exec(&.{ "/bin/det-maze", "solve" });
    if (context.nodes.zigmaze) |node| _ = try node.exec(&.{ "/bin/det-maze-zig", "solve" });
    if (context.nodes.summaze) |node| _ = try node.exec(&.{ "/bin/det-maze-sum", "solve" });
}

fn ping(context: *System.Context) !void {
    var reply: [16]u8 = undefined;
    const answer = try request(context.nodes.echo.?.address, "ping\n", &reply);
    sdk.always(std.mem.eql(u8, answer, "ping\n"), "the echo node echoes", .{});
}

/// What the guest kernel's random generator gives after the snapshot: different in every
/// branch (the composer reseeds it from a platform decision), the same when a branch replays.
fn entropy(_: *System.Context) !void {
    var bytes: [8]u8 = undefined;
    const fd = linux.open("/dev/urandom", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.NoUrandom;
    defer _ = linux.close(@intCast(fd));
    if (linux.read(@intCast(fd), &bytes, bytes.len) != bytes.len) return error.ShortRead;
    sdk.event("kernel_entropy", .{ .value = std.mem.readInt(u64, &bytes, .little) });
    // An RNG passed to code that takes one: every draw a platform decision.
    var deck = [_]u16{ 1, 2, 3, 4, 5 };
    sdk.rng().shuffle(u16, &deck);
    sdk.event("shuffled", .{ .deck = &deck });
}

fn tell_die(context: *System.Context) !void {
    var reply: [16]u8 = undefined;
    _ = request(context.nodes.echo.?.address, "die\n", &reply) catch {}; // It exits instead.
    const pause = linux.timespec{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
    _ = linux.nanosleep(&pause, null); // Let the runtime see the exit.
}

fn request(address: [4]u8, message: []const u8, reply: []u8) ![]const u8 {
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket) != .SUCCESS) return error.Socket;
    const fd: linux.fd_t = @intCast(socket);
    defer _ = linux.close(fd);
    // An answer within a second (virtual time), or none: a paused node must not answer later.
    const timeout = linux.timeval{ .sec = 1, .usec = 0 };
    const option = std.mem.asBytes(&timeout);
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, option.ptr, option.len);
    // Connecting too (a dropped SYN is retried past a short partition otherwise).
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, option.ptr, option.len);
    const target = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(address),
    };
    if (linux.errno(linux.connect(fd, @ptrCast(&target), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
        return error.Connect;
    }
    _ = linux.write(fd, message.ptr, message.len);
    const size = linux.read(fd, reply.ptr, reply.len);
    if (linux.errno(size) != .SUCCESS) return error.Read;
    return reply[0..size];
}
