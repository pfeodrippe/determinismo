// SPDX-License-Identifier: MIT
//! The determinismo command line.
//!
//!   run       boot one timeline from scratch
//!   explore   boot once, snapshot at setup_complete, then run many branches from the snapshot,
//!             each with its own decisions, and report properties across the multiverse
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const VM = @import("vm.zig");
const kvm = @import("kvm.zig");
const Snapshot = @import("snapshot.zig");
const Events = @import("events.zig");
const report = @import("report.zig");
const Strategy = @import("strategy.zig");
const tape = @import("tape.zig");
const fd_pass = @import("fd_pass.zig");
const holders = @import("holders.zig");
const saver_zig = @import("saver.zig");
const prepare = @import("prepare.zig");
const serve = @import("serve.zig");
const mcp = @import("mcp.zig");
const merge = @import("merge.zig");
const script = @import("script.zig");
const tla = @import("tla.zig");
const query = @import("query.zig");
const runs_cli = @import("runs_cli.zig");
const cpus = @import("cpus.zig");
const checks = @import("checks.zig");
const causality = @import("causality.zig");
const mutate = @import("mutate.zig");
const verify = @import("verify.zig");
const replays = @import("replays.zig");
const runs = @import("runs.zig");
const changed = @import("changed.zig");
const extract = @import("extract.zig");
const event_sets = @import("event_sets.zig");
const profiler = @import("profile.zig");

const usage =
    \\usage: determinismo run     <machine options> [--trace <out.txt>] [--events <out.jsonl>]
    \\       determinismo serve   [--listen <address:port>[,<address:port>...]] [--data <dir>]
    \\                            [--archive "<cmd>"]
    \\                            [--snapshots-keep-hours <h>]   (runs' snapshots on disk, from
    \\                            causality analyses: removed when none was saved for that long;
    \\                            24 by default) [--failure-snapshots]   (each failing
    \\                            property's first failing timeline saved to disk as soon as it
    \\                            is found, for analyses to start at once; off: a replay each)
    \\                            [--failure-analysis]   (each analyzed at once, in the background,
    \\                            on 4 CPUs beside the runs) <machine options>
    \\       determinismo mcp     <machine options>   (an MCP server on stdio, for agents)
    \\       determinismo verify  <explore options> --record <run.jsonl> --tape-dir <dir>
    \\                            [--sample <n>] [--jobs <n>]   (a sample of a run's timelines
    \\                            replayed from their tapes, beside whatever else runs: each must
    \\                            replay to its recorded history); or --run <run directory>
    \\                            for a run serve made: its options, record and tapes
    \\       determinismo mutate  <explore options> --mutants <mutants.jsonl> [--out <dir>]
    \\                            (each mutant a patch to a node's build: caught, never ran, or
    \\                            unnoticed)
    \\       determinismo explore <machine options> [--branches <n>] [--branch <index>] [--jobs <n>]
    \\                            [--time-budget <duration>]   (e.g. 90s, 10m, 2h: timelines until
    \\                            then, --branches at most)
    \\                            [--timeline <duration>]   (each timeline's drivers run that long
    \\                            in virtual time; part of the inputs)
    \\                            [--return-branches <n>]   (a tree's branches from each moment it
    \\                            returns to: 4; fewer branches, more moments a generation)
    \\                            [--horizon <duration>]   (a tree's returns run that long past
    \\                            their moment, then stop: short branches, extended when they
    \\                            find something; default: to the timeline's end)
    \\                            [--no-archive]   (Go-Explore's archive, on by default: half the
    \\                            returns to the newest frontier, the rest to the least visited
    \\                            behaviors of any generation; without it, the frontier only)
    \\                            [--no-prefer-sometimes]   (on by default, as Antithesis does:
    \\                            returns go first to just after a `sometimes` or `reachable`
    \\                            assertion made true, the states the program marks worth
    \\                            reaching; without it, every new behavior weighs the same)
    \\                            [--pipeline <n>]   (a tree's generations of timelines planned
    \\                            from the setup snapshot before its first returns, 1 to 4, and
    \\                            queued ahead after: default 2 up to 16 workers, else 3)
    \\                            [--generation <n>]   (a tree's timelines per generation: 16,
    \\                            or a multiple of it for machines with more CPUs)
    \\                            [--timeline-limit <duration>]   (1h: a timeline not finished by
    \\                            then, in virtual time, ends as hung)
    \\                            [--retroactive '<text>']...   (output lines with it are left out
    \\                            of the events; a replay of a timeline writes them)
    \\                            [--changed <diff file | git range>]   (a targeted run: the tree
    \\                            returns first to timelines that ran changed lines, and says
    \\                            which hunks ran and which never did)
    \\                            [--changed-repository <directory | URL>]   (where the range
    \\                            is: a commit, a.b, v1.6.0..v1.7.0; a URL is fetched into the
    \\                            cache; one revision is that commit's change)
    \\                            [--branching tree|flat]   (tree, the default: also from moments
    \\                            of earlier branches that reached new behaviors; replay one by
    \\                            its tape)
    \\                            [--strategy "<plugin> <args>"] [--tape-dir <dir>]
    \\                            [--tape <branch.jsonl>]
    \\                            [--at-vtime-ms <ms>] [--until '<condition>' [--rewind-ms <ms>]]
    \\                            (both: the condition, or that time at the latest)
    \\                            [--exec "<cmd>" | --exec-script <file>]   (a command a line, run
    \\                            in turn; or a step: "det:background <cmd>" runs beside the
    \\                            next ones, "det:wait <ms>" runs on, "det:until <ms> <condition>"
    \\                            runs on until an event matches, <ms> at most (0: no limit))
    \\                            [--continue]   (after --exec, run on to the end)
    \\                            [--fresh-seed <n>]   (with --exec: from the moment on,
    \\                            randomness from n, the guest kernel's generator reseeded:
    \\                            the branch's own future, as Antithesis's branches)
    \\                            [--from-branch <index> --from-vtime-ms <ms> [--from-exec "<cmd>"]]
    \\                            [--save-snapshots <dir> --save-at-ms <ms,ms,...>]   (with --tape
    \\                            or --branch: the replay saved to disk at those moments, each
    \\                            the pages changed since the one before)
    \\                            [--from-snapshot <dir>/<name>]   (branches from one saved)
    \\                            [--record <results.jsonl>] [--shard <k>/<n>]
    \\                            [--verify-replays <n>]   (with --record and --tape-dir: every
    \\                            n-th timeline replayed from its tape as the run goes, at most
    \\                            16, beside its workers: "timelines replay to their recorded
    \\                            history"; 16 by default, 0 for none)
    \\                            [--resume]   (with --record: continue that run, its recorded
    \\                            timelines skipped; the same inputs, seed and branching; a tree
    \\                            without a strategy, from its timelines' summaries)
    \\                            [--no-cpu-modulation]   (branches at one speed: they run at
    \\                            varying speeds by default, as Antithesis's with faults)
    \\                            [--verify-holders]   (remake every node an in-run snapshot made
    \\                            by a replay and compare them, to check holders; slower)
    \\                            [--holders-on-disk]   (every in-run snapshot written to the
    \\                            run's directory, as while memory runs low: to check them)
    \\                            [--data <dir>]   (the host's runs, where this one goes:
    \\                            $DETERMINISMO_DATA, else ~/.determinismo; serve shows them)
    \\                            [--events-dir <dir>]   (every branch's events, for query, and
    \\                            the system's pin)
    \\                            [--system <pin.json>]   (a pinned system and its node disks,
    \\                            booted as is: replays on another host of the same CPU model)
    \\       determinismo merge   <results.jsonl>...   (the records of an exploration's shards)
    \\       determinismo script  <events.jsonl>       (a branch's shape, for --script)
    \\       determinismo tla     --spec <Spec.tla> --events <events.jsonl> [--tla2tools <jar>]
    \\       determinismo runs    list | show <id> | properties <id> [--details] |
    \\                            logs <id> <timeline> <seconds> | search <id> '<condition>' |
    \\                            exec <id> <timeline> <seconds> --node <node> '<command>' |
    \\                            start (--program | --compose) <path> [...] | stop <id>
    \\                            [--url http://host:port]   (serve's runs from a terminal,
    \\                            as Antithesis's Snouty: see runs_cli.zig)
    \\       determinismo query   <events-dir> '<condition>' [temporal conditions] (see query.zig)
    \\       determinismo events  <events-dir> '<pipeline>' (event sets, see event_sets.zig)
    \\       determinismo causality <options> --branch <n> --property '<message>' [--points <k>]
    \\                            [--futures <m>] [--refine <rounds>] [--moments-max <n>]
    \\                            [--jump-min <0..1>] [--gap-min-ms <ms>] [--tape <tape>]
    \\                            [--planner <cmd> | tcp://host:port] [--run-url <url>]
    \\                            [--verdict '<condition>']   (the bug, instead of the property)
    \\                            [--snapshots <dir>] [--json]   (see causality.zig)
    \\                            [--explain-exec '<command>' [--explain-dir <dir>]]   (futures
    \\                            inside the jump with the command at their moment: logs up)
    \\       determinismo extract <options> --branch <n> (--at-vtime-ms <ms> | --until '<cond>')
    \\                            --file <node>:<path> --to <local file>
    \\       determinismo inject  <options> --branch <n> (--at-vtime-ms <ms> | --until '<cond>')
    \\                            --file <node>:<path> --from <local file> [--mode <octal>]
    \\                            [--then '<command>'] [--continue]
    \\       determinismo profile <options> --branch <n> (--at-vtime-ms <ms> | --until '<cond>')
    \\                            --node <node> [--ms <duration>] [--interval-us <us>] [--all]
    \\                            [--pid <pid>] [--svg <flame graph.svg>] [--folded <file>]
    \\       determinismo stacks  <options> --branch <n> (--at-vtime-ms <ms> | --until '<cond>')
    \\                            --node <node> [--pid <pid>]   (every thread's stack there)
    \\
    \\system options (instead of --disk; see ARCHITECTURE.md §10):
    \\  (--program <test program> | --compose <compose.yaml> | --kubernetes <manifests dir>)
    \\  [--profile <name>|<a,b,..>|all]
    \\  [--scenario <name>|all] [--cache <dir>] [--script <script.json>]
    \\  [--faults +restart,+crash,...]   (fault kinds every node also allows)
    \\  [--no-faults <node>,...]   (nodes that get no faults: a client, a monitor)
    \\
    \\machine options:
    \\  --kernel <bzImage> [--initrd <file>] [--memory-mib <n>] [--disk <image>]...
    \\  [--cmdline <text> | --append <text>] [--deterministic] [--seed <n>]
    \\  [--margin-branches <n>] [--timer-slack-us <n>]
    \\
    \\--deterministic needs the determinismo-patched KVM; explore implies it.
    \\
;

/// print-fatal-signals: the kernel logs every process killed by a core-dumping signal (segfault,
/// abort, ...), even after a handler printed a trace: det-init's "no process crashes" reads it.
const cmdline_default = "console=ttyS0 earlyprintk=serial,ttyS0 acpi=off pci=off nokaslr " ++
    "reboot=t panic=-1 i8042.nokbd i8042.noaux tsc=reliable no_timer_check " ++
    "print-fatal-signals=1";
const memory_mib_min = 64;
const memory_mib_max = VM.memory_size_max >> 20;
const arguments_max = 64;
const branches_max = 100_000;

const Command = enum { run, explore };

const Arguments = struct {
    command: Command,
    kernel_path: []const u8 = "",
    initrd_path: ?[]const u8 = null,
    memory_mib: u32 = 1024,
    cmdline: []const u8 = cmdline_default,
    /// The command line as given (--cmdline, --append), before --deterministic adds its own:
    /// what a run keeps (machine.json) for its replays, which add them again.
    cmdline_given: []const u8 = cmdline_default,
    deterministic: bool = false,
    seed: u64 = 0,
    margin_branches: u32 = 128,
    timer_slack_us: u64 = 1000,
    /// The raw PMU event that is the guest's clock (see VM.Options.branch_event).
    branch_event: u64 = 0x01c4,
    events_path: ?[]const u8 = null,
    /// The timeline's fault events only (`--faults-record`: causality's futures).
    faults_record_path: ?[]const u8 = null,
    /// The resolved system (nodes, scenarios), recorded with the run: its environment.
    system: ?std.json.Value = null,
    /// The moment is the first event matching this (`--until '<condition>'`, query.zig).
    until: ?*const query.Condition = null,
    /// Every branch's events: setup.jsonl (boot and setup, shared), fork.jsonl (from the
    /// snapshot to a fork point), branch-<index>.jsonl (each branch after them).
    events_directory: ?[]const u8 = null,
    trace_path: ?[]const u8 = null,
    branches: u32 = 16,
    branches_given: bool = false,
    /// `<node>=<patch>`: that node built from a patched copy of its build context (a mutant).
    mutant: ?[]const u8 = null,
    /// A pinned system (`--system <pin.json>`, prepare.zig): booted as is, nothing built.
    pinned: ?[]const u8 = null,
    /// Fault kinds every node also allows, and nodes that allow none (prepare.zig).
    faults_added: ?[]const u8 = null,
    faults_none: ?[]const u8 = null,
    /// flat: every branch from the setup snapshot; tree (the default when nothing else plans
    /// the branches): from moments of earlier branches too.
    branching: enum { flat, tree } = .tree,
    branching_given: bool = false,
    /// Explore until this much wall time has passed (from the start, boot included), at most
    /// `branches` timelines: as many as fit, as an Antithesis run's duration.
    time_budget_ns: ?u64 = null,
    time_budget_text: ?[]const u8 = null,
    /// How long (virtual time) each timeline's drivers run: commands keep starting until then
    /// (Antithesis's long timelines). Without it, a drawn number of starts (4 to 64).
    timeline_ms: ?u64 = null,
    /// Timelines per tree generation (`--generation`, a multiple of 16): by default the workers,
    /// rounded up (a generation is judged once its slowest timeline ends: with 16 on a 36-thread
    /// host, about 10 timelines ran at once), with more moments returned to.
    generation_size: u32 = tree.generation_base,
    generation_given: bool = false,
    /// Branches from each moment a tree returns to (`--return-branches`): fewer branches, more
    /// moments per generation.
    return_branches: u32 = tree.children,
    /// A tree's branches returned to a moment run this long past it, then stop (`--horizon`):
    /// short branches, many of them, around the moments that mattered (Antithesis returns to
    /// decision points often; a branch is extended only when it found something). Null: to the
    /// timeline's end.
    horizon_ns: ?u64 = null,
    horizon_text: ?[]const u8 = null,
    /// Generations planned ahead (`--pipeline`): that many start from the setup snapshot, and the
    /// queue keeps that many while one fills (explore_tree); enough keeps every worker busy.
    pipeline: u32 = pipeline_depth_default,
    pipeline_given: bool = false,
    /// Go-Explore's archive (on unless `--no-archive`): the tree keeps every behavior any timeline
    /// reached, where (just after it), and how often it returned there; each generation returns
    /// to the newest frontier with up to half its nodes and to the least visited cells of any
    /// generation with the rest (a timeline of an earlier one is rebuilt by replaying its path).
    /// Off, only to what the last generation found new: a promising state found earlier is
    /// forgotten once newer ones come, and a bug needing a second rare event after it is lost.
    archive: bool = true,
    archive_given: bool = false,
    /// Returns go first to just after a `sometimes` or `reachable` made true (`--no-prefer-
    /// sometimes`: every new behavior alike): Antithesis restarts tests from where one is hit.
    prefer_sometimes: bool = true,
    prefer_sometimes_given: bool = false,
    timeline_text: ?[]const u8 = null,
    /// A targeted run: a diff file or git range whose changed lines the tree explores first.
    changed: ?[]const u8 = null,
    /// Where --changed's range is: a repository's directory or URL (else the working directory).
    changed_repository: ?[]const u8 = null,
    /// A timeline's ceiling of virtual time: one that has not finished by then ends as hung.
    timeline_limit_ns: ?u64 = std.time.ns_per_hour,
    /// Retroactive logging: output lines with these texts are left out of an exploration's
    /// events (a replay of one timeline writes them).
    retroactive: [retroactive_max][]const u8 = undefined,
    retroactive_count: u32 = 0,
    /// Run only this branch (to replay one timeline of an exploration).
    branch_only: ?u32 = null,
    strategy_command: ?[]const u8 = null,
    tape_directory: ?[]const u8 = null,
    /// Replay the branch recorded in this tape.
    tape_path: ?[]const u8 = null,
    /// Explore from a moment of a branch: replay branch `from_branch` to `from_vtime_ms`,
    /// snapshot there, and branch from that snapshot.
    from_branch: ?u32 = null,
    from_vtime_ms: ?u64 = null,
    /// A command to run at the fork point before exploring its futures.
    from_exec: ?[]const u8 = null,
    /// Save the replayed branch (`--tape`, `--branch`) to disk at these moments
    /// (`--save-snapshots <dir> --save-at-ms <a,b,...>`, saver.zig).
    save_directory: ?[]const u8 = null,
    save_at_ms: []const u64 = &.{},
    /// Branch from a snapshot saved to disk (`<dir>/<name>`) instead of booting.
    from_snapshot: ?[]const u8 = null,
    /// After --exec at the moment, run on to the end of the timeline.
    moment_continue: bool = false,
    /// From the moment on, randomness from this seed instead of the timeline's (and the guest
    /// kernel's generator reseeded): the branch's own future, as Antithesis's branches diverge
    /// from their timeline at once.
    fresh_seed: ?u64 = null,
    /// Branches at varying speeds (VM.Modulation): on by default for explorations, as
    /// Antithesis turns it on with faults (the Raft POC's double vote needed it); a run keeps
    /// whether it had it (request.json), and its replays and tapes follow.
    cpu_modulation: bool = false,
    cpu_modulation_given: ?bool = null,
    /// Remake every tree node an in-run snapshot made (holders.zig) by a replay, and print how
    /// the two differ in what the guest can see ("verify ... DIFFERENT"): a check of holders.
    verify_holders: bool = false,
    /// Every holder on disk (holders.Disk), as while memory runs low: what checks use.
    holders_on_disk: bool = false,
    /// The host's runs (runs.zig): an exploration is one of them, in its own directory there.
    data_directory: ?[]const u8 = null,
    /// The run's directory, claimed already (serve's runs); else the exploration claims one.
    run_directory: ?[]const u8 = null,
    /// This host runs the branches whose index modulo `shard_count` is `shard_index`
    /// (`--shard k/n`); `determinismo merge` combines the shards' records.
    shard_index: u32 = 0,
    shard_count: u32 = 1,
    /// Write results as JSON lines here (see report.record).
    record_path: ?[]const u8 = null,
    /// The command line as given (the replays' verifier boots the system the same way).
    raw_argv: []const [:0]const u8 = &.{},
    /// While exploring with a record and tapes, every this many timelines one is replayed from
    /// its tape (replays.zig); 0: none.
    verify_every: u32 = verify_every_default,
    /// Continue the run whose record is `record_path`: its timelines already recorded are
    /// skipped (flat branching; the same inputs and seed).
    resume_run: bool = false,
    /// Parallel workers for branches (default: one per available CPU).
    jobs: ?u32 = null,
    /// Multiverse debugging: stop the (single) branch at this virtual time, run this there.
    moment_vtime_ms: ?u64 = null,
    /// With --until: the moment this long (virtual time) before the condition first holds.
    rewind_ms: ?u64 = null,
    moment_command: ?[]const u8 = null,
    /// Commands for the moment, one per line, run one after the other (instead of --exec).
    moment_script_path: ?[]const u8 = null,
    /// Read-only disk images, in guest order (/dev/vda first).
    disk_paths: [VM.disks_max][]const u8 = undefined,
    disk_count: u32 = 0,
    /// A test program: its system becomes the disks, its scenario the guest's work.
    program_path: ?[]const u8 = null,
    /// Or a Compose file: services become nodes, Antithesis test templates scenarios.
    compose_path: ?[]const u8 = null,
    /// Or a directory of Kubernetes manifests: a K3s node runs them (kubernetes.zig).
    kubernetes_path: ?[]const u8 = null,
    /// Commands and faults follow this script (determinismo script) instead of choosing.
    script_path: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    scenario: ?[]const u8 = null,
    cache_directory: []const u8 = ".determinismo-cache",
};

/// Every n-th timeline a run replays as it goes (--verify-replays).
const verify_every_default = 16;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "serve")) return command_serve(init, argv[2..]);
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "mcp")) return command_mcp(init, argv[2..]);
    if (argv.len >= 2) {
        if (try command_tool(arena, init.io, init.minimal.environ.block.slice, argv)) |status| std.process.exit(status);
    }
    if (argv.len == 3 and std.mem.eql(u8, argv[1], "script")) {
        return script.extract(arena, init.io, argv[2]);
    }
    if (argv.len == 6 and std.mem.eql(u8, argv[1], "snapshot-diff")) {
        return snapshot_diff(init, argv[2..6]);
    }
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "merge")) {
        const failing = try merge.merge(arena, init.io, argv[2..]);
        if (failing > 0) std.process.exit(3);
        return;
    }
    const arguments = parse_arguments(arena, argv) catch {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    };
    // This process and everything it forks are one run sharing the host's CPUs (cpus.zig), and
    // its memory: each of its VMs claims its guest's size with the CPU it runs on.
    cpus.run_key = linux.getpid();
    cpus.claim_bytes = @as(u64, arguments.memory_mib) << 20;
    const vm = try arena.create(VM); // Large (port statistics): never on the stack.
    const profile = arguments.profile orelse "";
    const all = std.mem.eql(u8, profile, "all");
    const several = std.mem.indexOfScalar(u8, profile, ',') != null;
    if (!all and !several) {
        if (try system_run(init, vm, arguments) > 0) std.process.exit(3);
        return;
    }
    // Several profiles (e.g. a system and its mutants): their own disks, snapshot and verdict.
    const names = if (all) try prepare.profile_names(arena, init.io, .{
        .program = arguments.program_path,
        .compose = arguments.compose_path,
        .kubernetes = arguments.kubernetes_path,
        .cache_directory = arguments.cache_directory,
    }) else try list_split(arena, profile);
    const verdicts = try arena.alloc(u32, names.len);
    for (names, verdicts) |name, *failing| {
        std.debug.print("[determinismo] profile {s}\n", .{name});
        var copy = arguments;
        copy.profile = name;
        failing.* = try system_run(init, vm, copy);
    }
    std.debug.print("[determinismo] profiles:\n", .{});
    for (names, verdicts) |name, failing| {
        const status = if (failing > 0) "FAIL" else "PASS";
        const line = "  {s} {s} ({d} scenarios with failing properties)\n";
        std.debug.print(line, .{ status, name, failing });
    }
    for (verdicts) |failing| if (failing > 0) std.process.exit(3);
}

/// The commands that read what explorations wrote (tla, query, causality): their exit status,
/// or null for other commands. An error exits with 2 (`runs search` keeps 1 for no match).
fn command_tool(
    arena: std.mem.Allocator,
    io: std.Io,
    environ: [:null]const ?[*:0]const u8,
    argv: []const [:0]const u8,
) !?u8 {
    const eql = std.mem.eql;
    const name = argv[1];
    const rest = argv[2..];
    const result = if (eql(u8, name, "causality"))
        causality.run(arena, io, argv[0], environ, rest)
    else if (eql(u8, name, "mutate"))
        mutate.run(arena, io, argv[0], rest)
    else if (eql(u8, name, "verify"))
        verify.run(arena, io, argv[0], rest)
    else if (eql(u8, name, "extract"))
        extract.run(arena, io, argv[0], rest)
    else if (eql(u8, name, "inject"))
        extract.inject_run(arena, io, argv[0], rest)
    else if (eql(u8, name, "profile"))
        profiler.run(arena, io, argv[0], rest)
    else if (eql(u8, name, "stacks"))
        profiler.stacks_run(arena, io, argv[0], rest)
    else if (eql(u8, name, "query"))
        query.run(arena, io, rest)
    else if (eql(u8, name, "events"))
        event_sets.run(arena, io, rest)
    else if (eql(u8, name, "tla"))
        tla.check(arena, io, rest)
    else if (eql(u8, name, "runs"))
        runs_cli.run(arena, io, rest)
    else
        return null;
    // The usage for a usage error only: after another (a run's events held by serve, a missing
    // file) it buried what was said in a hundred lines.
    return result catch |err| {
        if (err == error.Usage) {
            std.debug.print("{s}", .{usage});
            return 2;
        }
        std.debug.print("error: {s}\n", .{@errorName(err)});
        return 2;
    };
}

fn list_split(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.tokenizeScalar(u8, text, ',');
    while (parts.next()) |name| try names.append(arena, name);
    return names.items;
}

/// Prepares the system (if any), then runs or explores its scenarios. Returns the number of
/// scenarios with failing properties.
/// The CPU this process runs its own VMs on (the boot and setup, branches run in-process): a
/// CPU of the host's pool (cpus.zig), never shared with another VM's core. Given back, and the
/// process unpinned, before forking processes that take CPUs of their own.
const OwnCpu = struct {
    pool: cpus.Pool = undefined,
    opened: bool = false,
    held: ?cpus.Held = null,

    fn take(own: *OwnCpu) void {
        if (own.held != null) return;
        if (!own.opened) {
            own.pool.open() catch |err| {
                std.debug.print("[determinismo] the CPU pool: {s}\n", .{@errorName(err)});
                linux.exit_group(1);
            };
            own.opened = true;
        }
        own.held = own.pool.take();
    }

    fn give(own: *OwnCpu) void {
        const held = own.held orelse return;
        own.pool.give(held);
        own.held = null;
        cpus.unpin();
    }
};
var own_cpu: OwnCpu = .{};

fn system_run(init: std.process.Init, vm: *VM, arguments_given: Arguments) !u32 {
    const arena = init.arena.allocator();
    var arguments = arguments_given;
    if (exploration_is_run(&arguments)) try run_register(arena, init.io, &arguments);
    // A replay or a future (one VM, not a run's explorer): the OOM killer's before the host's
    // own processes, as a run's timelines are (one killed by it once took podman's pause
    // process down with it: user@.service's OOM policy).
    if (arguments.command == .explore and !exploration_is_run(&arguments)) oom_before_the_host();
    if (arguments.resume_run) try resume_settings_adopt(arena, init.io, &arguments);
    const has_system = arguments.program_path != null or arguments.compose_path != null or
        arguments.kubernetes_path != null or
        arguments.pinned != null;
    const prepared = if (has_system) try system_prepare(arena, init.io, &arguments) else null;
    const cwd = std.Io.Dir.cwd();
    if (arguments.moment_script_path) |path| {
        const lines = try cwd.readFileAlloc(init.io, path, arena, .unlimited);
        arguments.moment_command = try commands_join(arena, lines);
    }
    const kernel = try cwd.readFileAlloc(init.io, arguments.kernel_path, arena, .unlimited);
    const initrd = if (arguments.initrd_path) |path|
        try cwd.readFileAlloc(init.io, path, arena, .unlimited)
    else
        null;
    var options = VM.Options{
        .memory_size = @as(u64, arguments.memory_mib) << 20,
        .kernel = kernel,
        .initrd = initrd,
        .cmdline = arguments.cmdline,
        .deterministic = arguments.deterministic,
        .seed = arguments.seed,
        .margin_branches = arguments.margin_branches,
        .timer_slack_ns = arguments.timer_slack_us * std.time.ns_per_us,
        .branch_event = arguments.branch_event,
        .events_fd = if (arguments.events_path) |path| try open_for_writing(arena, path) else null,
        .faults_record_fd = if (arguments.faults_record_path) |path| try open_for_writing(arena, path) else null,
        .events_parse_buffer = try arena.alloc(u8, Events.parse_buffer_size),
        .trace_fd = if (arguments.trace_path) |path| try open_for_writing(arena, path) else null,
        .rdtsc_log_fd = if (arguments.trace_path) |path|
            try open_for_writing(arena, try std.fmt.allocPrint(arena, "{s}.rdtsc", .{path}))
        else
            null,
        // Debugging (with --trace): DETERMINISMO_ITRACE_AT=<RDTSC exit> traces every
        // instruction from there to the next RDTSC exit into <trace>.itrace.
        .itrace_fd = if (arguments.trace_path != null and std.c.getenv("DETERMINISMO_ITRACE_AT") != null)
            try open_for_writing(arena, try std.fmt.allocPrint(arena, "{s}.itrace", .{arguments.trace_path.?}))
        else
            null,
        .itrace_at = if (std.c.getenv("DETERMINISMO_ITRACE_AT")) |text|
            std.fmt.parseInt(u64, std.mem.span(text), 10) catch 0
        else
            0,
        // With --trace: RDTSC exits logged, the first 4M by default (DETERMINISMO_RDTSC_LOG_CAP:
        // more, for a divergence later in a long timeline; 16 bytes each, in the host kernel).
        .rdtsc_log_cap = if (std.c.getenv("DETERMINISMO_RDTSC_LOG_CAP")) |text|
            std.fmt.parseInt(u32, std.mem.span(text), 10) catch VM.rdtsc_log_cap_default
        else
            VM.rdtsc_log_cap_default,
        .moment_vtime_ns = if (arguments.moment_vtime_ms) |ms| ms * std.time.ns_per_ms else null,
        .moment_command = arguments.moment_command,
        .until = arguments.until,
        .disks = try open_disks(arena, arguments.disk_paths[0..arguments.disk_count]),
        .builtin_properties = has_system,
        .checks = if (prepared) |system| system.system.checks else &.{},
        .check_program = arguments.program_path,
        .check_buffer = if (prepared != null and prepared.?.system.checks.len > 0)
            try std.heap.page_allocator.alloc(u8, checks.input_size_max) // Touched as used.
        else
            &.{},
        .cpu_modulation = arguments.cpu_modulation,
        .retroactive = try retroactive_texts(arena, &arguments),
        .vtime_limit_ns = arguments.timeline_limit_ns,
    };
    const context = Context{
        .arena = arena,
        .io = init.io,
        .environ = init.minimal.environ.block.slice,
    };
    const base_cmdline = arguments.cmdline;
    var failing_scenarios: u32 = 0;
    var catalog = report.Catalog{ .arena = arena };
    const scenarios = try scenarios_selected(arena, &arguments, prepared);
    for (scenarios, 0..) |scenario, index| {
        // Several scenarios explored: each its own run (its record, events and tapes, branch
        // numbers of its own); in one run, each scenario's timelines took the same files, and the
        // last scenario's were all that stayed (Quint, srv3 run 25).
        if (scenarios.len > 1 and exploration_is_run(&arguments)) {
            try run_scenario(arena, init.io, &arguments, scenario.?, index == 0);
        }
        options.cmdline = try cmdline_build(arena, base_cmdline, &arguments, scenario);
        options.check_scenario = scenario orelse "";
        if (scenario) |name| std.debug.print("[determinismo] scenario {s}\n", .{name});
        switch (arguments.command) {
            .run => try command_run(vm, &options),
            .explore => {
                const multiverse = try command_explore(context, vm, &options, &arguments);
                failing_scenarios += @intFromBool(multiverse.failing_properties() > 0);
                try multiverse.catalog_reached(&catalog);
            },
        }
    }
    // Catalogs span scenarios (a test program's, a service serving several): an assertion
    // must be reached in some scenario, judged once all ran.
    const all_scenarios = if (prepared) |known| known.system.scenarios.len else scenarios.len;
    const every_scenario = scenarios.len == all_scenarios;
    if (catalog.judge(every_scenario) > 0) failing_scenarios += 1;
    return failing_scenarios;
}

/// Whether the command is an exploration, which is one of the host's runs (runs.zig): not a
/// replay of one timeline (a tape, a branch), nor futures forked from a saved snapshot.
fn exploration_is_run(arguments: *const Arguments) bool {
    return arguments.command == .explore and arguments.tape_path == null and
        arguments.branch_only == null and arguments.from_snapshot == null;
}

/// The exploration as one of the host's runs (runs.zig): its directory claimed, unless serve
/// gave it one (`--run-directory`), its output kept there too, its request and machine written
/// (what serve replays and continues it with); its pid held; its record, events and tapes there,
/// or, asked elsewhere, named from there.
fn run_register(arena: std.mem.Allocator, io: std.Io, arguments: *Arguments) !void {
    const directory = arguments.run_directory orelse claimed: {
        const data = try runs.data_directory(arena, arguments.data_directory);
        // A resume continues the run whose record it names, once that run's explorer is gone:
        // its directory again, not another run refused its record (e2e `resume`, 2026-10-29).
        if (arguments.resume_run) if (arguments.record_path) |path| {
            if (try runs.linked_by(arena, data, "record.jsonl", try runs.absolute(arena, path))) |id| {
                const own = try runs.directory_of(arena, data, id);
                if (runs.running_pid(arena, own) == null) {
                    try runs.output_tee(arena, try std.fs.path.join(arena, &.{ own, "output.log" }));
                    std.debug.print("[determinismo] run {d} resumed: {s}\n", .{ id, own });
                    break :claimed own;
                }
            }
        };
        // Never over another run's events, record or tapes: they would be its no more.
        for ([_]struct { []const u8, ?[]const u8, []const u8 }{
            .{ "events", arguments.events_directory, "--events-dir" },
            .{ "record.jsonl", arguments.record_path, "--record" },
            .{ "tapes", arguments.tape_directory, "--tape-dir" },
        }) |asked| {
            const path = asked[1] orelse continue;
            const target = try runs.absolute(arena, path);
            if (try runs.linked_by(arena, data, asked[0], target)) |id| {
                // Deleted since, it is that run's no more: its link goes (or it would show this
                // run's), and this run takes the path. Still there, it is refused.
                const target_z = try arena.dupeSentinel(u8, target, 0);
                const kept = linux.errno(linux.access(target_z, linux.F_OK)) == .SUCCESS;
                if (kept) {
                    std.debug.print("error: {s} {s} holds run {d}'s; give another, or delete it " ++
                        "(its run then keeps none)\n", .{ asked[2], path, id });
                    return error.DirectoryOfAnotherRun;
                }
                try runs.link_drop(arena, data, id, asked[0]);
                std.debug.print("[determinismo] {s} {s} was run {d}'s, deleted since: that run " ++
                    "keeps none\n", .{ asked[2], path, id });
            }
        }
        const run = try runs.claim(arena, io, data);
        try runs.output_tee(arena, try std.fs.path.join(arena, &.{ run.directory, "output.log" }));
        std.debug.print("[determinismo] run {d}: {s}\n", .{ run.id, run.directory });
        try run_request_write(arena, io, data, run.directory, arguments);
        break :claimed run.directory;
    };
    try runs.running_mark(arena, directory);
    arguments.run_directory = directory;
    const Placed = struct { name: []const u8, path: *?[]const u8 };
    for ([_]Placed{
        .{ .name = "events", .path = &arguments.events_directory },
        .{ .name = "record.jsonl", .path = &arguments.record_path },
        .{ .name = "tapes", .path = &arguments.tape_directory },
    }) |placed| {
        const own = try std.fs.path.join(arena, &.{ directory, placed.name });
        const elsewhere = placed.path.* orelse {
            placed.path.* = own;
            continue;
        };
        const target = try runs.absolute(arena, elsewhere);
        if (std.mem.eql(u8, target, own)) continue;
        const target_z = try arena.dupeSentinel(u8, target, 0);
        _ = linux.symlinkat(target_z, linux.AT.FDCWD, try arena.dupeSentinel(u8, own, 0));
    }
}

/// One scenario of an exploration of several, as a run of its own: the first keeps the run
/// already claimed (its request now naming the scenario), each next one claims another, with
/// its own output, request, record, events and tapes, the one before ending.
fn run_scenario(
    arena: std.mem.Allocator,
    io: std.Io,
    arguments: *Arguments,
    scenario: []const u8,
    first: bool,
) !void {
    const data = try runs.data_directory(arena, arguments.data_directory);
    arguments.scenario = scenario;
    if (first) {
        try run_request_write(arena, io, data, arguments.run_directory.?, arguments);
        return;
    }
    const run = try runs.claim(arena, io, data);
    try runs.output_tee(arena, try std.fs.path.join(arena, &.{ run.directory, "output.log" }));
    std.debug.print("[determinismo] run {d}: {s} (scenario {s})\n", .{ run.id, run.directory, scenario });
    try run_request_write(arena, io, data, run.directory, arguments);
    try runs.running_mark(arena, run.directory);
    // The record is opened once per run (command_explore): this one's anew.
    if (report.record_fd) |fd| {
        close(fd);
        report.record_fd = null;
    }
    arguments.run_directory = run.directory;
    arguments.events_directory = try std.fs.path.join(arena, &.{ run.directory, "events" });
    arguments.record_path = try std.fs.path.join(arena, &.{ run.directory, "record.jsonl" });
    arguments.tape_directory = try std.fs.path.join(arena, &.{ run.directory, "tapes" });
}

/// A run started here: what was asked (serve's request: the program kept by its content, as
/// serve keeps it) and the machine it boots (its kernel and initramfs kept the same way).
fn run_request_write(
    arena: std.mem.Allocator,
    io: std.Io,
    data: []const u8,
    directory: []const u8,
    arguments: *const Arguments,
) !void {
    const asked: serve.RunRequest = .{
        .program = if (arguments.program_path) |path| try runs.artifact_keep(arena, io, data, path) else null,
        .program_asked = if (arguments.program_path) |path| try runs.absolute(arena, path) else null,
        .compose = if (arguments.compose_path) |path| try runs.absolute(arena, path) else null,
        .kubernetes = if (arguments.kubernetes_path) |path| try runs.absolute(arena, path) else null,
        .scenario = arguments.scenario,
        .profile = arguments.profile,
        .seed = arguments.seed,
        .branches = if (arguments.branches_given) arguments.branches else null,
        .time_budget = arguments.time_budget_text,
        .branching = @tagName(arguments.branching),
        .faults = arguments.faults_added,
        .no_faults = arguments.faults_none,
        .timeline = arguments.timeline_text,
        .generation = arguments.generation_size,
        .horizon = arguments.horizon_text,
        .pipeline = arguments.pipeline,
        .jobs = arguments.jobs,
        .strategy = arguments.strategy_command,
        .changed = arguments.changed,
        .changed_repository = arguments.changed_repository,
        .retroactive = arguments.retroactive[0..arguments.retroactive_count],
        .from_branch = arguments.from_branch,
        .from_vtime_ms = arguments.from_vtime_ms,
        .cpu_modulation = arguments.cpu_modulation,
        .memory_mib = arguments.memory_mib,
        .verify_replays = if (arguments.verify_every != verify_every_default) arguments.verify_every else null,
        .priority = std.c.getenv("DETERMINISMO_CPU_PRIORITY") != null,
    };
    var machine: std.ArrayList([]const u8) = .empty;
    try machine.appendSlice(arena, &.{ "--kernel", try runs.artifact_keep(arena, io, data, arguments.kernel_path) });
    if (arguments.initrd_path) |path| try machine.appendSlice(arena, &.{ "--initrd", try runs.artifact_keep(arena, io, data, path) });
    try machine.appendSlice(arena, &.{
        "--cmdline",    arguments.cmdline_given,
        "--cache",      try runs.absolute(arena, arguments.cache_directory),
        "--memory-mib", try std.fmt.allocPrint(arena, "{d}", .{arguments.memory_mib}),
    });
    for (arguments.disk_paths[0..arguments.disk_count]) |path| {
        try machine.appendSlice(arena, &.{ "--disk", try runs.absolute(arena, path) });
    }
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ directory, "request.json" }),
        .data = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(asked, .{})}),
    });
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ directory, "machine.json" }),
        .data = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(machine.items, .{})}),
    });
}

/// `determinismo serve [--listen <address:port>] [--data <dir>] <machine options>`: the HTTP
/// API (serve.zig). Machine options are passed to every run it starts.
fn command_serve(init: std.process.Init, argv: []const [:0]const u8) !void {
    const arena = init.arena.allocator();
    var listen: []const u8 = "127.0.0.1:7878";
    var data: ?[]const u8 = null;
    var explorer: ?[]const u8 = null;
    var archive: ?[]const u8 = null;
    var snapshots_keep_hours: u64 = 24;
    var failure_snapshots = false;
    var failure_analysis = false;
    var bb: []const u8 = "bb";
    var machine: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const flag = argv[index];
        const value = if (index + 1 < argv.len) argv[index + 1] else "";
        if (std.mem.eql(u8, flag, "--listen")) {
            listen = value;
            index += 1;
        } else if (std.mem.eql(u8, flag, "--data")) {
            data = value;
            index += 1;
        } else if (std.mem.eql(u8, flag, "--archive")) {
            archive = value;
            index += 1;
        } else if (std.mem.eql(u8, flag, "--snapshots-keep-hours")) {
            snapshots_keep_hours = try std.fmt.parseInt(u64, value, 10);
            index += 1;
        } else if (std.mem.eql(u8, flag, "--failure-snapshots")) {
            failure_snapshots = true;
        } else if (std.mem.eql(u8, flag, "--failure-analysis")) {
            failure_analysis = true;
        } else if (std.mem.eql(u8, flag, "--explorer")) {
            explorer = value; // Self-tests: a stand-in for `determinismo explore`.
            index += 1;
        } else if (std.mem.eql(u8, flag, "--bb")) {
            bb = value;
            index += 1;
        } else {
            try machine.append(arena, flag);
        }
    }
    var self_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const self_size = linux.readlink("/proc/self/exe", &self_buffer, self_buffer.len);
    if (linux.errno(self_size) != .SUCCESS) return error.SelfPath;
    try serve.serve(arena, init.io, .{
        .listen = listen,
        .data_directory = try runs.data_directory(arena, data),
        .machine = machine.items,
        .self = explorer orelse self_buffer[0..self_size],
        .archive = archive,
        .bb = bb,
        .snapshots_keep_ns = snapshots_keep_hours * std.time.ns_per_hour,
        .failure_snapshots = failure_snapshots,
        .failure_analysis = failure_analysis,
    });
}

/// `determinismo mcp <machine options>`: an MCP server on stdio (mcp.zig).
fn command_mcp(init: std.process.Init, argv: []const [:0]const u8) !void {
    const arena = init.arena.allocator();
    const machine = try arena.alloc([]const u8, argv.len);
    for (argv, machine) |argument, *target| target.* = argument;
    var self_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const self_size = linux.readlink("/proc/self/exe", &self_buffer, self_buffer.len);
    if (linux.errno(self_size) != .SUCCESS) return error.SelfPath;
    try mcp.serve(arena, init.io, .{
        .machine = machine,
        .self = self_buffer[0..self_size],
        .scratch_directory = "/tmp/determinismo-mcp",
    });
}

/// Builds the disks of the program's system and records what was resolved.
fn system_prepare(
    arena: std.mem.Allocator,
    io: std.Io,
    arguments: *Arguments,
) !prepare.Prepared {
    if (arguments.disk_count > 0) return error.DisksAndProgram;
    const sources = @as(u32, @intFromBool(arguments.program_path != null)) +
        @intFromBool(arguments.compose_path != null) + @intFromBool(arguments.kubernetes_path != null);
    if (sources > 1) return error.Usage;
    const prepared = try prepare.prepare(arena, io, .{
        .program = arguments.program_path,
        .compose = arguments.compose_path,
        .kubernetes = arguments.kubernetes_path,
        .script = arguments.script_path,
        .profile = arguments.profile,
        .cache_directory = arguments.cache_directory,
        .mutant = arguments.mutant,
        .faults_added = arguments.faults_added,
        .faults_none = arguments.faults_none,
        .pinned = arguments.pinned,
    });
    if (prepared.disk_paths.len > VM.disks_max) return error.TooManyDisks;
    // With the run's events: what replays it (serve's replays, a kit for another host).
    if (arguments.events_directory) |directory| {
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, directory);
        const pin = try std.fs.path.join(arena, &.{ directory, "system.pin.json" });
        try cwd.copyFile(prepared.pin_path, cwd, pin, io, .{});
    }
    const system_json = prepared.system_json;
    arguments.system = try std.json.parseFromSliceLeaky(std.json.Value, arena, system_json, .{});
    for (prepared.disk_paths, 0..) |path, index| arguments.disk_paths[index] = path;
    arguments.disk_count = @intCast(prepared.disk_paths.len);
    std.debug.print("[determinismo] system {x:0>16}: profile {s}, {d} nodes, disk {s}, pin {s}\n", .{
        prepared.hash,          prepared.system.profile, prepared.system.nodes.len,
        prepared.disk_paths[0], prepared.pin_path,
    });
    return prepared;
}

/// How many nodes the system has (its JSON's `nodes`); 0 when unknown.
fn system_nodes(system: ?std.json.Value) u32 {
    const object = switch (system orelse return 0) {
        .object => |object| object,
        else => return 0,
    };
    const nodes = object.get("nodes") orelse return 0;
    return switch (nodes) {
        .array => |array| @intCast(array.items.len),
        else => 0,
    };
}

/// The scenarios to run, one at a time (null: the guest decides, as without --program).
fn scenarios_selected(
    arena: std.mem.Allocator,
    arguments: *const Arguments,
    prepared: ?prepare.Prepared,
) ![]const ?[]const u8 {
    const system = (prepared orelse return &.{null}).system;
    const wanted = arguments.scenario orelse if (system.scenarios.len == 1)
        system.scenarios[0].name
    else {
        std.debug.print("[determinismo] pick a scenario with --scenario (or all)\n", .{});
        return error.Usage;
    };
    if (std.mem.eql(u8, wanted, "all") and system.scenario("all") != null) {
        std.debug.print("[determinismo] a scenario is named all: rename it (--scenario all " ++
            "explores every scenario, so it would never run alone)\n", .{});
        return error.Usage;
    }
    if (std.mem.eql(u8, wanted, "all")) {
        const all = try arena.alloc(?[]const u8, system.scenarios.len);
        for (system.scenarios, all) |scenario, *name| name.* = scenario.name;
        return all;
    }
    if (system.scenario(wanted) == null) {
        std.debug.print("[determinismo] no scenario named {s}\n", .{wanted});
        return error.Usage;
    }
    const one = try arena.alloc(?[]const u8, 1);
    one[0] = wanted;
    return one;
}

fn cmdline_build(
    arena: std.mem.Allocator,
    base: []const u8,
    arguments: *const Arguments,
    scenario: ?[]const u8,
) ![]const u8 {
    var parts: [5][]const u8 = undefined;
    var count: u32 = 0;
    parts[count] = base;
    count += 1;
    if (arguments.disk_count > 0) {
        parts[count] = try VM.disks_cmdline(arena, arguments.disk_count);
        count += 1;
    }
    if (scenario) |name| {
        parts[count] = try std.fmt.allocPrint(arena, "det.scenario={s}", .{name});
        count += 1;
    }
    if (arguments.timeline_ms) |ms| { // det-composer's.
        parts[count] = try std.fmt.allocPrint(arena, "det.timeline_ms={d}", .{ms});
        count += 1;
    }
    if (arguments.timeline_limit_ns) |ns| { // det-composer's: no driver starts past its half.
        parts[count] = try std.fmt.allocPrint(arena, "det.timeline_limit_ms={d}", .{ns / std.time.ns_per_ms});
        count += 1;
    }
    return std.mem.join(arena, " ", parts[0..count]);
}

fn command_run(vm: *VM, options: *const VM.Options) !void {
    assert(!options.stop_at_setup_complete);
    own_cpu.take();
    try vm.init(options);
    defer vm.deinit();
    const time_start_ns = monotonic_ns();
    const outcome = try vm.run_until_exit();
    try report.run(vm, .{ .outcome = outcome, .wall_ns = monotonic_ns() - time_start_ns });
    switch (outcome) {
        .failed => std.process.exit(1),
        .debug_exit => |status| std.process.exit(status),
        .shutdown, .hlt, .moment_reached, .command_done, .hung => {},
        .setup_complete => unreachable,
    }
}

const Context = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    /// determinismo's environment, which strategy plugins inherit.
    environ: [:null]const ?[*:0]const u8,
};

/// What drives the branches of one exploration besides the seed.
const Exploration = struct {
    /// Set when branching from a moment of another branch.
    fork: ?tape.Fork = null,
    /// Identifies what the machine boots; recorded in tapes.
    inputs: u64 = 0,
    /// This build of determinismo (a hash of its executable): recorded in tapes and the run's
    /// record, so that a replay by another build says so.
    host: u64 = 0,
    exploration_seed: u64,
    strategy: ?*Strategy = null,
    tape_directory: ?[]const u8 = null,
    /// Set when replaying one recorded branch.
    replay: ?struct { header: tape.Header, overrides: *tape.Overrides } = null,
    /// A resumed run's (--resume): its timelines already recorded, skipped.
    done: ?*const Resumed = null,
};

/// `determinismo snapshot-diff <dir> <name> <dir> <name>`: how two saved moments' guest memory
/// differs (two runs of one timeline, saved at the same moment, should not). Each differing
/// 8-byte word is classed by its XOR: the bits a processor sets on its own in page-table
/// entries (Accessed 0x20, Dirty 0x40), or other data; the first pages are listed.
fn snapshot_diff(init: std.process.Init, names: []const []const u8) !void {
    const arena = init.arena.allocator();
    var snapshots: [2]Snapshot = undefined;
    const check_buffer = try std.heap.page_allocator.alloc(u8, checks.input_size_max); // Touched as used.
    for (&snapshots, 0..) |*snapshot, side| {
        try snapshot.disk_load(arena, init.io, names[2 * side], names[2 * side + 1], check_buffer);
    }
    if (snapshots[0].memory_size != snapshots[1].memory_size) return error.SizesDiffer;
    const size = snapshots[0].memory_size;
    var memories: [2][]const u8 = undefined;
    for (&memories, snapshots) |*memory, snapshot| {
        const address = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .SHARED }, snapshot.memory_fd, 0);
        if (linux.errno(address) != .SUCCESS) return error.OutOfMemory;
        memory.* = @as([*]const u8, @ptrFromInt(address))[0..size];
    }
    const page = std.heap.page_size_min;
    var pages_differing: u64 = 0;
    var accessed_only: u64 = 0; // Words differing only in bit 5.
    var dirty_only: u64 = 0; // Only in bit 6.
    var both: u64 = 0;
    var other: u64 = 0;
    var listed: u32 = 0;
    var offset: usize = 0;
    while (offset < size) : (offset += page) {
        const a = memories[0][offset..][0..page];
        const b = memories[1][offset..][0..page];
        if (std.mem.eql(u8, a, b)) continue;
        pages_differing += 1;
        var words_ad: u32 = 0;
        var words_other: u32 = 0;
        var first_other: ?usize = null;
        var word: usize = 0;
        while (word < page) : (word += 8) {
            const x = std.mem.readInt(u64, a[word..][0..8], .little) ^ std.mem.readInt(u64, b[word..][0..8], .little);
            if (x == 0) continue;
            switch (x) {
                0x20 => accessed_only += 1,
                0x40 => dirty_only += 1,
                0x60 => both += 1,
                else => {
                    other += 1;
                    words_other += 1;
                    first_other = first_other orelse word;
                    continue;
                },
            }
            words_ad += 1;
        }
        if (listed < 40) {
            listed += 1;
            std.debug.print("page 0x{x}: {d} words differ in Accessed/Dirty bits, {d} otherwise", .{ offset, words_ad, words_other });
            if (first_other) |at| {
                std.debug.print(" (first at +0x{x}: {x:0>16} vs {x:0>16})", .{
                    at, std.mem.readInt(u64, a[at..][0..8], .little), std.mem.readInt(u64, b[at..][0..8], .little),
                });
            }
            std.debug.print("\n", .{});
        }
    }
    std.debug.print("{d} pages differ; words: {d} only Accessed, {d} only Dirty, {d} both, {d} otherwise\n", .{
        pages_differing, accessed_only, dirty_only, both, other,
    });
}

/// What a resumed run (--resume) takes from its record: the timelines it has, and for a tree
/// each one's summary (`<record>.summaries`), how many recorded timelines each return (its
/// generation, parent and moment) started, and the timelines of each generation judged, in order.
const Resumed = struct {
    done: std.AutoHashMapUnmanaged(u32, void) = .empty,
    summaries: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    /// The summaries file up to its last whole record (appended to from there).
    summaries_size: u64 = 0,
    children: std.AutoHashMapUnmanaged(ReturnKey, u32) = .empty,
    generations: std.ArrayList([]const u32) = .empty,
};
const ReturnKey = struct { generation: u32, branch: u32, vtime_ns: u64 };

/// What a run's record already has, for --resume: its run must be this one (the same inputs,
/// seed, branching and, for a tree, how it plans), or there is nothing to continue.
/// A resumed tree keeps the settings its record says it ran with (its archive, its pipeline),
/// unless given again: a run started under other defaults still continues.
fn resume_settings_adopt(arena: std.mem.Allocator, io: std.Io, arguments: *Arguments) !void {
    const path = arguments.record_path orelse return;
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return;
    const first = source[0 .. std.mem.indexOfScalar(u8, source, '\n') orelse source.len];
    const Line = struct { run: ?struct { pipeline: ?u32 = null, archive: ?bool = null, prefer_sometimes: ?bool = null } = null };
    const line = std.json.parseFromSliceLeaky(Line, arena, first, .{ .ignore_unknown_fields = true }) catch return;
    const run = line.run orelse return;
    if (!arguments.archive_given) if (run.archive) |archive| {
        arguments.archive = archive;
    };
    // Recorded before it existed: it ran without.
    if (!arguments.prefer_sometimes_given) arguments.prefer_sometimes = run.prefer_sometimes orelse false;
    if (!arguments.pipeline_given) if (run.pipeline) |pipeline| {
        arguments.pipeline = pipeline;
    };
}

fn resume_read(context: Context, arguments: *const Arguments, inputs: u64) !*const Resumed {
    const path = arguments.record_path orelse {
        std.debug.print("[determinismo] --resume continues the run of a record: give --record\n", .{});
        return error.Usage;
    };
    const tree_run = arguments.branching == .tree;
    if (tree_run and arguments.strategy_command != null) {
        std.debug.print("[determinismo] --resume continues trees without a strategy (a strategy's " ++
            "state was its own process's)\n", .{});
        return error.Usage;
    }
    const Line = struct {
        run: ?struct {
            inputs: ?[]const u8 = null,
            seed: ?[]const u8 = null,
            branching: ?[]const u8 = null,
            generation: ?u32 = null,
            pipeline: ?u32 = null,
            archive: ?bool = null,
            horizon_ns: ?u64 = null,
            /// Before --return-branches, every record's: 4.
            return_branches: u32 = tree.children,
            queue: bool = false,
        } = null,
        branch: ?struct {
            index: u32,
            generation: u32 = 0,
            path: []const struct { branch: u32, vtime_ns: u64 } = &.{},
        } = null,
        generation: ?struct { number: u32, branches: []const u32 } = null,
    };
    const source = try std.Io.Dir.cwd().readFileAlloc(context.io, path, context.arena, .unlimited);
    const resumed = try context.arena.create(Resumed);
    resumed.* = .{};
    var run_seen = false;
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    while (lines.next()) |text| {
        // A line cut short by the interruption is not a timeline.
        const line = std.json.parseFromSliceLeaky(Line, context.arena, text, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        if (line.run) |run| {
            run_seen = true;
            const same = std.mem.eql(u8, run.inputs orelse "", &hex16(inputs)) and
                std.mem.eql(u8, run.seed orelse "", &hex16(arguments.seed)) and
                std.mem.eql(u8, run.branching orelse "", @tagName(arguments.branching)) and
                (!tree_run or (run.generation == arguments.generation_size and
                    run.pipeline == arguments.pipeline and run.archive == arguments.archive and
                    run.horizon_ns == arguments.horizon_ns and
                    run.return_branches == arguments.return_branches and run.queue));
            if (!same) {
                std.debug.print("[determinismo] {s} is the record of another run (inputs {s}, " ++
                    "seed {s}, {s} branching; these: {s}, {s}, {s}; a tree's generation, " ++
                    "pipeline, archive, horizon, return branches and queue too): start a new run\n", .{
                    path,                          run.inputs orelse "?", run.seed orelse "?",
                    run.branching orelse "?",      &hex16(inputs),        &hex16(arguments.seed),
                    @tagName(arguments.branching),
                });
                return error.Usage;
            }
        }
        if (line.generation) |judged| {
            if (judged.number == resumed.generations.items.len) {
                try resumed.generations.append(context.arena, judged.branches);
            }
        }
        if (line.branch) |branch| {
            try resumed.done.put(context.arena, branch.index, {});
            if (branch.path.len > 0) {
                const last = branch.path[branch.path.len - 1];
                const key: ReturnKey = .{ .generation = branch.generation, .branch = last.branch, .vtime_ns = last.vtime_ns };
                const entry = try resumed.children.getOrPut(context.arena, key);
                entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
            }
        }
    }
    if (!run_seen) {
        std.debug.print("[determinismo] {s} has no run to continue\n", .{path});
        return error.Usage;
    }
    if (tree_run) {
        const summaries_path = try std.fmt.allocPrint(context.arena, "{s}.summaries", .{path});
        const bytes = std.Io.Dir.cwd().readFileAlloc(context.io, summaries_path, context.arena, .unlimited) catch |err| {
            std.debug.print("[determinismo] {s}: {s} (a tree continues from its timelines' " ++
                "summaries, recorded since this version)\n", .{ summaries_path, @errorName(err) });
            return error.Usage;
        };
        resumed.summaries_size = try summaries_index(context.arena, bytes, &resumed.summaries);
        // A timeline without its summary (the interruption cut it) runs again.
        var indices = resumed.done.keyIterator();
        var missing: std.ArrayList(u32) = .empty;
        while (indices.next()) |index| {
            if (!resumed.summaries.contains(index.*)) try missing.append(context.arena, index.*);
        }
        for (missing.items) |index| _ = resumed.done.remove(index);
    }
    std.debug.print("[determinismo] resuming {s}: {d} timelines recorded, skipped\n", .{ path, resumed.done.count() });
    const left = for (0..arguments.branches) |index| {
        if (!resumed.done.contains(@intCast(index))) break true;
    } else false;
    if (!left) {
        std.debug.print("[determinismo] the run is complete: all {d} timelines recorded\n", .{arguments.branches});
        std.process.exit(0);
    }
    return resumed;
}

/// Where a tree's timelines write their summaries as they end (`<record>.summaries`, for
/// --resume): opened by the explorer before its workers fork, written by them.
var tree_summaries_fd: ?linux.fd_t = null;

/// A tree timeline's summary on disk (`<record>.summaries`, for --resume): this, then the
/// behaviors it reached (only those); its holders were processes of the run.
const SummaryHeader = extern struct {
    index: u32,
    behavior_count: u32,
    start_ns: u64,
    end_ns: u64,
    trace_hash: u64,
    last_pull_ns: u64,
    cut: u8,
    /// The behaviors' layout (summary_format): another build's are refused.
    format: u8 = summary_format,
    reserved: [6]u8 = @splat(0),
};

/// Bumped whenever Events.Behavior changes. 1: `sought`.
const summary_format = 1;

fn summary_write(fd: linux.fd_t, summary: *const Summary) void {
    const header: SummaryHeader = .{
        .index = summary.index,
        .behavior_count = summary.behavior_count,
        .start_ns = summary.start_ns,
        .end_ns = summary.end_ns,
        .trace_hash = summary.trace_hash,
        .last_pull_ns = summary.last_pull_ns,
        .cut = @intFromBool(summary.cut),
    };
    const behaviors = std.mem.sliceAsBytes(summary.behaviors[0..summary.behavior_count]);
    const vectors = [_]std.posix.iovec_const{
        .{ .base = std.mem.asBytes(&header), .len = @sizeOf(SummaryHeader) },
        .{ .base = behaviors.ptr, .len = behaviors.len },
    };
    _ = linux.writev(fd, &vectors, vectors.len); // One write: a record whole, or cut at its end.
}

/// Each whole summary record's bytes, by its timeline (a last one the interruption cut is left);
/// returns where the whole records end.
fn summaries_index(arena: std.mem.Allocator, bytes: []const u8, out: *std.AutoHashMapUnmanaged(u32, []const u8)) !usize {
    var at: usize = 0;
    while (bytes.len - at >= @sizeOf(SummaryHeader)) {
        const header = std.mem.bytesToValue(SummaryHeader, bytes[at..][0..@sizeOf(SummaryHeader)]);
        if (header.format != summary_format) return error.SummariesOfAnotherBuild;
        if (header.behavior_count > Events.behavior_count_max) return error.BadSummaries;
        const size = @sizeOf(SummaryHeader) + header.behavior_count * @sizeOf(Events.Behavior);
        if (bytes.len - at < size) break;
        try out.put(arena, header.index, bytes[at..][0..size]);
        at += size;
    }
    return at;
}

fn summary_load(summary: *Summary, bytes: []const u8) void {
    const header = std.mem.bytesToValue(SummaryHeader, bytes[0..@sizeOf(SummaryHeader)]);
    summary.index = header.index;
    summary.start_ns = header.start_ns;
    summary.end_ns = header.end_ns;
    summary.trace_hash = header.trace_hash;
    summary.last_pull_ns = header.last_pull_ns;
    summary.cut = header.cut != 0;
    summary.holder_count = 0; // Gone with the run: its moments are made again by replay.
    summary.failing_count = 0; // Its holders went with the run: no ladder to save.
    summary.behavior_count = header.behavior_count;
    @memcpy(std.mem.sliceAsBytes(summary.behaviors[0..header.behavior_count]), bytes[@sizeOf(SummaryHeader)..]);
}

test "a resumed run keeps the archive and pipeline its record says, unless given again" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const record = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/record.jsonl", .{&tmp.sub_path});
    // Recorded under the old defaults: no archive, three generations in flight.
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = record,
        .data = "{\"run\":{\"seed\":\"0000000000000002\",\"pipeline\":3,\"archive\":false}}\n",
    });
    var kept: Arguments = .{ .command = .explore, .record_path = record, .pipeline = 2 };
    try resume_settings_adopt(arena, io, &kept);
    try std.testing.expect(!kept.archive);
    try std.testing.expectEqual(3, kept.pipeline);
    var given: Arguments = .{
        .command = .explore,
        .record_path = record,
        .archive_given = true,
        .pipeline = 2,
        .pipeline_given = true,
    };
    try resume_settings_adopt(arena, io, &given);
    try std.testing.expect(given.archive);
    try std.testing.expectEqual(2, given.pipeline);
}

test "summaries round trip, a cut last one left" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const summary = try arena.allocator().create(Summary);
    summary.index = 7;
    summary.start_ns = 1;
    summary.end_ns = 9;
    summary.trace_hash = 0xabc;
    summary.last_pull_ns = 5;
    summary.cut = true;
    summary.behavior_count = 2;
    summary.behaviors[0] = .{ .hash = 11, .vtime_ns = 3 };
    summary.behaviors[1] = .{ .hash = 12, .vtime_ns = 4 };
    var pipe: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&pipe, .{})));
    summary_write(pipe[1], summary);
    summary_write(pipe[1], summary);
    _ = linux.close(pipe[1]);
    var buffer: [4096]u8 = undefined;
    const size = linux.read(pipe[0], &buffer, buffer.len);
    _ = linux.close(pipe[0]);
    const record_size = @sizeOf(SummaryHeader) + 2 * @sizeOf(Events.Behavior);
    try std.testing.expectEqual(2 * record_size, size);
    var index: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    const whole = try summaries_index(arena.allocator(), buffer[0 .. size - 1], &index); // The second cut.
    try std.testing.expectEqual(1, index.count());
    try std.testing.expectEqual(record_size, whole);
    const loaded = try arena.allocator().create(Summary);
    summary_load(loaded, index.get(7).?);
    try std.testing.expectEqual(2, loaded.behavior_count);
    try std.testing.expectEqual(12, loaded.behaviors[1].hash);
    try std.testing.expect(loaded.cut);
    try std.testing.expectEqual(0, loaded.holder_count);
}

/// Boots once to setup_complete, snapshots, then runs every branch from the snapshot.
/// Returns the multiverse: its verdict, and what the test program's catalog saw.
fn command_explore(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    arguments: *const Arguments,
) !*const report.Multiverse {
    assert(options.deterministic);
    var exploration = Exploration{
        .exploration_seed = arguments.seed,
        .tape_directory = arguments.tape_directory,
    };
    if (arguments.tape_directory) |directory| {
        try std.Io.Dir.cwd().createDirPath(context.io, directory);
    }
    exploration.inputs = inputs_hash(options, arguments);
    exploration.host = host_build();
    const signature = host_cpu_signature()[3];
    std.debug.print("[determinismo] inputs {x:0>16} (determinism ABI {d}, CPU signature " ++
        "{x:0>8})\n", .{ exploration.inputs, VM.determinism_abi, signature });
    if (arguments.resume_run) {
        exploration.done = try resume_read(context, arguments, exploration.inputs);
    }
    if (arguments.record_path) |path| {
        if (report.record_fd == null) {
            report.record_fd = try open_for_appending(context.arena, path, if (arguments.resume_run) .resumed else .fresh);
        }
    }
    if (arguments.record_path != null and !arguments.resume_run) {
        report.record(.{
            .run = .{
                .scenario = scenario_of(options.cmdline),
                .profile = arguments.profile,
                .program = arguments.program_path,
                .compose = arguments.compose_path,
                .kubernetes = arguments.kubernetes_path,
                .system = arguments.system,
                .inputs = &hex16(exploration.inputs),
                .seed = &hex16(arguments.seed),
                .branches = arguments.branches,
                .from_branch = arguments.from_branch,
                .from_vtime_ms = arguments.from_vtime_ms,
                .shard = &.{ arguments.shard_index, arguments.shard_count },
                .time_budget_s = if (arguments.time_budget_ns) |ns| ns / std.time.ns_per_s else null,
                .timeline_ms = arguments.timeline_ms,
                .generation = arguments.generation_size,
                .pipeline = arguments.pipeline,
                .archive = arguments.archive,
                .prefer_sometimes = arguments.prefer_sometimes,
                .horizon_ns = arguments.horizon_ns,
                .return_branches = arguments.return_branches,
                .jobs = jobs_count(arguments),
                .strategy = arguments.strategy_command,
                .branching = @tagName(arguments.branching),
                .host = &hex16(exploration.host),
                // A tree's generations are the timelines that finished together, recorded as
                // judged (explore_tree): a record without them is not one to resume.
                .queue = true,
            },
        });
    }
    if (arguments.tape_path) |path| {
        const overrides = try context.arena.create(tape.Overrides);
        const cwd = std.Io.Dir.cwd();
        const source = try cwd.readFileAlloc(context.io, path, context.arena, .unlimited);
        const scratch = try context.arena.alloc(u8, 64 * 1024);
        const header = try tape.parse(source, scratch, overrides);
        if (header.inputs != exploration.inputs) {
            std.debug.print("[determinismo] the tape was recorded with inputs {x:0>16}; " ++
                "these are {x:0>16} (kernel, initramfs, command line, disks or CPU modulation " ++
                "differ: runs before 2026-10-28 had none, --no-cpu-modulation)\n", .{
                header.inputs, exploration.inputs,
            });
            return error.TapeInputsDiffer;
        }
        // Recorded by another build: allowed (most changes leave timelines as they were), but a
        // replay that parts from the tape may then be the build's doing (run 56, recorded the day
        // before: the same 26 of 64 parted, at the same events, with or without hyperthreads).
        if (header.host) |host| if (host != exploration.host) {
            std.debug.print("[determinismo] the tape was recorded by another build of determinismo " ++
                "({x:0>16}; this is {x:0>16}): a replay that parts from it may be the build's " ++
                "doing\n", .{ host, exploration.host });
        };
        exploration.exploration_seed = header.exploration_seed;
        exploration.replay = .{ .header = header, .overrides = overrides };
        exploration.fork = header.fork;
    }
    if (arguments.from_branch) |branch| {
        if (exploration.replay != null) return error.Usage; // The tape says where it forked.
        exploration.fork = .{
            .branch = branch,
            .vtime_ns = arguments.from_vtime_ms.? * 1_000_000,
            .exec = arguments.from_exec,
        };
    }
    if (arguments.strategy_command != null and exploration.replay != null) {
        return error.ReplayWithStrategy; // Tapes replace plugins.
    }
    const time_start_ns = monotonic_ns();
    options.seed = exploration.exploration_seed;
    const snapshot = try context.arena.create(Snapshot);
    if (arguments.events_directory) |directory| {
        try std.Io.Dir.cwd().createDirPath(context.io, directory);
        options.events_fd = try events_file(context.arena, directory, "setup.jsonl");
        const timelines = try std.fs.path.join(context.arena, &.{ directory, "timelines.jsonl" });
        report.timelines_fd = try open_for_appending(context.arena, timelines, if (arguments.resume_run) .resumed else .fresh);
    }
    if (arguments.from_snapshot) |path| {
        const directory = std.fs.path.dirname(path) orelse ".";
        const name = std.fs.path.basename(path);
        try snapshot.disk_load(context.arena, context.io, directory, name, options.check_buffer);
        if (snapshot.memory_size != options.memory_size) return error.SnapshotMemoryDiffers;
        exploration.exploration_seed = futures_seed(arguments.seed, snapshot);
        options.seed = exploration.exploration_seed;
    } else try explore_snapshot(vm, options, snapshot);
    report.snapshot_taken(snapshot, monotonic_ns() - time_start_ns);
    report.record(.{ .snapshot = .{
        .vtime_ns = snapshot.tsc / report.tsc_per_ns,
        .wall_ns = monotonic_ns() - time_start_ns,
    } });
    if (arguments.events_directory) |directory| {
        close(options.events_fd.?);
        options.events_fd = if (exploration.fork != null)
            try events_file(context.arena, directory, "fork.jsonl")
        else
            null;
    }
    var start = if (exploration.fork) |fork| try explore_fork(context, vm, options, .{
        .from = snapshot,
        .exploration = &exploration,
        .fork = fork,
    }) else snapshot;
    // A tree explorer's branch replays along its path: each ancestor to the moment the next
    // branched from it, snapshotted there as the exploration did.
    if (exploration.replay) |replay| {
        // Ancestors' tapes are beside this one: what a strategy decided in them, replayed.
        const directory = std.fs.path.dirname(arguments.tape_path.?) orelse ".";
        const ancestor = if (replay.header.chain.len > 0)
            try context.arena.create(tape.Overrides)
        else
            undefined;
        for (replay.header.chain, 0..) |segment, depth| {
            const overrides = try tape_overrides(context, directory, segment.branch, ancestor);
            const arena = context.arena;
            const at = segment.vtime_ns;
            start = try node_make(arena, vm, options, start, segment.seed, at, overrides, depth > 0);
        }
        // Futures from a moment of the taped branch (`--tape ... --from-vtime-ms`, causality
        // analysis): the branch itself replayed to the moment, then new branches from there,
        // with their own seeds.
        if (arguments.from_vtime_ms) |ms| {
            const own = try context.arena.create(tape.Overrides);
            const overrides = try tape_overrides(context, directory, replay.header.branch, own);
            const at = ms * std.time.ns_per_ms;
            const branch_point = replay.header.chain.len > 0;
            start = try node_make(context.arena, vm, options, start, replay.header.branch_seed, at, overrides, branch_point);
            exploration.replay = null;
            exploration.exploration_seed = futures_seed(exploration.exploration_seed, start);
        }
    }
    if (arguments.events_directory != null) {
        if (options.events_fd) |fd| close(fd);
        options.events_fd = null; // Each branch writes its own file.
    }
    const multiverse = try context.arena.create(report.Multiverse);
    multiverse.* = .{ .nodes = system_nodes(arguments.system) };
    const branches = Branches{
        .snapshot = start,
        .setup = snapshot,
        .multiverse = multiverse,
        .exploration = &exploration,
        .arguments = arguments,
        .deadline_ns = if (arguments.time_budget_ns) |ns| time_start_ns + ns else null,
    };
    const jobs = jobs_count(arguments);
    // Timelines replayed from their tapes as the run goes, beside its workers (replays.zig).
    const verifier: ?replays.Verifier = if (arguments.record_path != null and
        arguments.tape_directory != null and arguments.verify_every > 0 and
        arguments.branch_only == null and arguments.tape_path == null and arguments.raw_argv.len >= 2)
        try replays.Verifier.start(context.arena, context.io, arguments.raw_argv, arguments.record_path.?, arguments.tape_directory.?, arguments.verify_every, jobs)
    else
        null;
    if (arguments.branching == .tree) {
        // A strategy decides within its branches and chooses where the tree returns: an
        // instance here (and one per worker).
        try strategy_start(context, arguments, &exploration);
        defer if (exploration.strategy) |strategy| strategy.stop();
        if (arguments.time_budget_text) |budget| {
            std.debug.print("[determinismo] a tree for {s} (at most {d} timelines) on {d} workers\n", .{
                budget, arguments.branches, jobs,
            });
        } else {
            std.debug.print("[determinismo] a tree of {d} timelines on {d} workers\n", .{ arguments.branches, jobs });
        }
        try explore_tree(context, vm, options, branches, jobs);
    } else if (jobs == 1) {
        try strategy_start(context, arguments, &exploration);
        defer if (exploration.strategy) |strategy| strategy.stop();
        try explore_branches(context, vm, options, branches);
    } else {
        if (arguments.time_budget_text) |budget| {
            std.debug.print("[determinismo] branches for {s} (at most {d}) on {d} workers\n", .{
                budget, arguments.branches, jobs,
            });
        } else {
            std.debug.print("[determinismo] {d} branches on {d} workers\n", .{
                arguments.branches, jobs,
            });
        }
        try explore_parallel(context, vm, options, branches, jobs);
    }
    if (verifier) |*running| {
        const found = try running.finish(context.arena, context.io);
        try multiverse.replays_judge(found.replayed, found.same, found.first_different);
        for (found.different) |line| std.debug.print("[determinismo] did not replay: {s}\n", .{line});
    }
    multiverse.summarize(monotonic_ns() - time_start_ns);
    return multiverse;
}

const Fork = struct { from: *const Snapshot, exploration: *const Exploration, fork: tape.Fork };

/// Replays branch `fork.branch` of the setup snapshot to the moment and snapshots it there.
fn explore_fork(context: Context, vm: *VM, options: *VM.Options, fork: Fork) !*const Snapshot {
    const time_start_ns = monotonic_ns();
    try moment_after_snapshot(fork.from, fork.fork.vtime_ns);
    options.seed = branch_seed(fork.exploration.exploration_seed, fork.fork.branch);
    options.moment_vtime_ns = fork.fork.vtime_ns;
    options.moment_command = fork.fork.exec;
    const until = options.until;
    options.until = null; // The fork point is the moment; --until belongs to its branches.
    defer options.until = until;
    options.moment_continue = false;
    defer options.moment_vtime_ns = null;
    defer options.moment_command = null;
    own_cpu.take();
    try vm.init_from_snapshot(options, fork.from);
    const outcome = try vm.run_until_exit();
    const expected: VM.Outcome = if (fork.fork.exec != null) .command_done else .moment_reached;
    if (std.meta.activeTag(outcome) != std.meta.activeTag(expected)) {
        std.debug.print("[determinismo] branch {d} ended ({s}) before {d}ns\n", .{
            fork.fork.branch, @tagName(outcome), fork.fork.vtime_ns,
        });
        vm.deinit();
        return error.ForkPointNotReached;
    }
    const snapshot = try context.arena.create(Snapshot);
    try snapshot.take_copy(vm);
    vm.deinit();
    const wall_s = @as(f64, @floatFromInt(monotonic_ns() - time_start_ns)) / std.time.ns_per_s;
    std.debug.print("[determinismo] forked branch {d} at vtime={d}ns branches={d} " ++
        "({d:.3}s wall); its branches follow\n", .{
        fork.fork.branch,
        fork.fork.vtime_ns,
        snapshot.branches,
        wall_s,
    });
    return snapshot;
}

/// The seed of futures from a moment of a timeline (causality's), replayed to it or saved there
/// (`--from-snapshot`): the same either way, and neither the timeline's own nor another moment's.
fn futures_seed(exploration_seed: u64, at: *const Snapshot) u64 {
    return exploration_seed ^ 0x9e3779b97f4a7c15 ^ at.tsc;
}

/// Branches start at their snapshot: a moment before it would be in the past.
fn moment_after_snapshot(snapshot: *const Snapshot, vtime_ns: u64) !void {
    const snapshot_ns = snapshot.tsc / (cpuid_tsc_hz / std.time.ns_per_s);
    if (vtime_ns > snapshot_ns) return;
    std.debug.print("[determinismo] the moment {d}ns is not after the snapshot ({d}ns): " ++
        "branches start there\n", .{ vtime_ns, snapshot_ns });
    return error.MomentBeforeSnapshot;
}

const cpuid_tsc_hz = @import("cpuid.zig").tsc_hz;

fn strategy_start(context: Context, arguments: *const Arguments, exploration: *Exploration) !void {
    const command = arguments.strategy_command orelse return;
    const strategy = try context.arena.create(Strategy);
    try strategy.start(context.arena, command, context.environ);
    try strategy.hello(exploration.exploration_seed);
    exploration.strategy = strategy;
}

/// Workers for the branches: one per CPU this process may run on, unless one branch is asked
/// for or events are logged (one log, one timeline at a time).
fn jobs_count(arguments: *const Arguments) u32 {
    const single = arguments.branch_only != null or arguments.tape_path != null;
    if (single or arguments.events_path != null) return 1;
    const jobs = arguments.jobs orelse cpus_available();
    const shard_branches = @divCeil(arguments.branches, arguments.shard_count);
    return @max(1, @min(jobs, shard_branches, jobs_max));
}

/// Tree branching unless something else plans the branches (a strategy, a tape, a fork, one
/// branch, shards, a moment): then flat; asked for a tree, an error.
fn branching_resolve(arguments: *Arguments, at_moment: bool) !void {
    if (arguments.changed != null and arguments.branching != .tree) return changed_needs_tree();
    if (arguments.changed_repository != null and arguments.changed == null) {
        std.debug.print("[determinismo] --changed-repository says where --changed's range is: " ++
            "give the range too (a commit, a..b, v1.6.0..v1.7.0)\n", .{});
        return error.Usage;
    }
    if (arguments.branching != .tree) return;
    // A strategy in a tree (asked for): its parents are replayed with their tapes.
    if (arguments.branching_given and arguments.strategy_command != null) {
        if (arguments.tape_directory == null) {
            std.debug.print("[determinismo] a strategy in a tree needs --tape-dir: nodes " ++
                "replay their parents' decisions from their tapes\n", .{});
            return error.Usage;
        }
    }
    const strategy_planned = arguments.strategy_command != null and !arguments.branching_given;
    const planned = strategy_planned or arguments.branch_only != null or
        arguments.tape_path != null or arguments.from_branch != null or
        arguments.from_snapshot != null or arguments.shard_count > 1 or at_moment;
    if (planned and arguments.branching_given) return error.Usage;
    // A tree's first generation starts from the snapshot, as flat branches do; later ones start
    // inside others and replay from their tapes only.
    if (arguments.branch_only) |only| {
        if (!arguments.branching_given and only >= arguments.generation_size) {
            std.debug.print("[determinismo] branch {d} of a tree exploration (the default) " ++
                "starts from a moment of another: replay it from its tape (--tape " ++
                "<tape dir>/branch-{d}.jsonl), or explore with --branching flat\n", .{
                only, only,
            });
            return error.Usage;
        }
    }
    if (planned and arguments.changed != null) return changed_needs_tree();
    if (planned) arguments.branching = .flat;
}

const retroactive_max = 16;

/// The texts retroactive logging hides: none when looking at one timeline (a replay, a moment, a
/// tape), which writes everything.
fn retroactive_texts(arena: std.mem.Allocator, arguments: *const Arguments) ![]const []const u8 {
    const one = arguments.branch_only != null or arguments.tape_path != null or
        arguments.moment_vtime_ms != null or arguments.until != null;
    if (one) return &.{};
    // And Antithesis's retroactive sink (ANTITHESIS_FILTERED_OUTPUT_DIR: det-sinks names its
    // lines' stream "filtered <file>"), whatever was asked.
    const texts = try arena.alloc([]const u8, arguments.retroactive_count + 1);
    @memcpy(texts[0..arguments.retroactive_count], arguments.retroactive[0..arguments.retroactive_count]);
    texts[arguments.retroactive_count] = filtered_stream_text;
    return texts;
}

const filtered_stream_text = "\"stream\":\"filtered ";

fn changed_needs_tree() error{Usage} {
    std.debug.print("[determinismo] --changed aims the tree explorer: not with flat branching, " ++
        "a strategy's plan, shards or a replay\n", .{});
    return error.Usage;
}

/// A duration: a number of seconds, or with a unit (`500ms`, `90s`, `10m`, `2h`).
fn duration_parse(text: []const u8) !u64 {
    const units = [_]struct { suffix: []const u8, ns: u64 }{
        .{ .suffix = "ms", .ns = std.time.ns_per_ms },
        .{ .suffix = "s", .ns = std.time.ns_per_s },
        .{ .suffix = "m", .ns = std.time.ns_per_min },
        .{ .suffix = "h", .ns = std.time.ns_per_hour },
    };
    for (units) |unit| {
        if (!std.mem.endsWith(u8, text, unit.suffix)) continue;
        const number = text[0 .. text.len - unit.suffix.len];
        // "10ms" also ends in "s": the longer suffix is tried first.
        if (number.len > 0 and std.ascii.isDigit(number[number.len - 1])) {
            return try std.math.mul(u64, try std.fmt.parseInt(u64, number, 10), unit.ns);
        }
    }
    return try std.math.mul(u64, try std.fmt.parseInt(u64, text, 10), std.time.ns_per_s);
}

test duration_parse {
    try std.testing.expectEqual(@as(u64, 500 * std.time.ns_per_ms), try duration_parse("500ms"));
    try std.testing.expectEqual(@as(u64, 90 * std.time.ns_per_s), try duration_parse("90s"));
    try std.testing.expectEqual(@as(u64, 90 * std.time.ns_per_s), try duration_parse("90"));
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_min), try duration_parse("10m"));
    try std.testing.expectEqual(@as(u64, 2 * std.time.ns_per_hour), try duration_parse("2h"));
    try std.testing.expectError(error.InvalidCharacter, duration_parse("ten"));
}

/// The CPUs VMs may run on here: one thread per core (cpus.zig).
fn cpus_available() u32 {
    return cpus.usable_count();
}

/// Forks `jobs` workers after the snapshot: each makes its own VMs from it (copy-on-write) and
/// runs the next branch not yet taken until none is left, then sends its results through a
/// pipe. A branch's timeline does not depend on which worker runs it.
fn explore_parallel(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    branches: Branches,
    jobs: u32,
) !void {
    assert(jobs > 1 and jobs <= jobs_max);
    own_cpu.give(); // The workers take their own.
    // The workers' shared counter of positions (branch_place).
    const protection: linux.PROT = .{ .READ = true, .WRITE = true };
    const shared_flags: linux.MAP = .{ .TYPE = .SHARED, .ANONYMOUS = true };
    const shared = linux.mmap(null, std.heap.page_size_min, protection, shared_flags, -1, 0);
    if (linux.errno(shared) != .SUCCESS) return error.Mmap;
    defer _ = linux.munmap(@ptrFromInt(shared), std.heap.page_size_min);
    const counter: *std.atomic.Value(u32) = @ptrFromInt(shared);
    counter.* = .init(0);
    var shared_branches = branches;
    shared_branches.next = counter;
    var readers: [jobs_max]linux.fd_t = undefined;
    var pids: [jobs_max]linux.pid_t = undefined;
    const explorer = linux.getpid();
    for (0..jobs) |worker| {
        var pipe: [2]linux.fd_t = undefined;
        if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
        const pid = linux.fork();
        if (linux.errno(pid) != .SUCCESS) return error.Fork;
        if (pid == 0) {
            child_dies_with(explorer);
            _ = linux.close(pipe[0]);
            worker_run(context, vm, options, shared_branches, .{
                .worker = @intCast(worker),
                .jobs = jobs,
                .results_fd = pipe[1],
            });
        }
        _ = linux.close(pipe[1]);
        readers[worker] = pipe[0];
        pids[worker] = @intCast(pid);
    }
    const results = try context.arena.create(report.Multiverse);
    for (readers[0..jobs], pids[0..jobs]) |reader, pid| {
        var received = read_exact(reader, std.mem.asBytes(results));
        // Then a tree generation's summaries: their count, and each.
        if (branches.summaries) |summaries| {
            var count: u32 = 0;
            received = received and read_exact(reader, std.mem.asBytes(&count));
            received = received and summaries.count + count <= summaries.items.len;
            if (received) {
                const into = summaries.items[summaries.count..][0..count];
                received = read_exact(reader, std.mem.sliceAsBytes(into));
                summaries.count += count;
            }
        }
        _ = linux.close(reader);
        var status: i32 = 0;
        _ = linux.waitpid(pid, &status, 0);
        if (!received or status != 0) return error.WorkerFailed;
        try branches.multiverse.absorb(results);
    }
}

const Worker = struct { worker: u32, jobs: u32, results_fd: linux.fd_t };

fn worker_run(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    branches: Branches,
    worker: Worker,
) noreturn {
    // The host's CPUs, shared with every other run's workers: one per timeline (cpus.zig).
    var pool: cpus.Pool = undefined;
    pool.open() catch |err| {
        std.debug.print("[determinismo] worker {d}: the CPU pool: {s}\n", .{
            worker.worker, @errorName(err),
        });
        linux.exit_group(1);
    };
    var exploration = branches.exploration.*;
    // The explorer's plugin stays the explorer's: this process starts its own (worker_explore),
    // and the explorer's pipes kept here (and in this process's holders) would keep that plugin
    // from seeing the end of its input when the explorer stops it.
    if (exploration.strategy) |explorer_strategy| explorer_strategy.forget();
    var mine = branches;
    mine.exploration = &exploration;
    mine.worker = worker.worker;
    mine.jobs = worker.jobs;
    mine.pool = &pool;
    mine.multiverse.* = .{};
    var summaries: Summaries = undefined;
    if (branches.summaries) |all| {
        summaries = .{ .items = all.items };
        mine.summaries = &summaries;
    }
    const ok = worker_explore(context, vm, options, mine, &exploration);
    if (ok) write_all(worker.results_fd, std.mem.asBytes(mine.multiverse));
    if (ok and branches.summaries != null) {
        write_all(worker.results_fd, std.mem.asBytes(&summaries.count));
        write_all(worker.results_fd, std.mem.sliceAsBytes(summaries.items[0..summaries.count]));
    }
    linux.exit_group(if (ok) 0 else 1);
}

fn worker_explore(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    branches: Branches,
    exploration: *Exploration,
) bool {
    strategy_start(context, branches.arguments, exploration) catch return false;
    defer if (exploration.strategy) |strategy| strategy.stop();
    explore_branches(context, vm, options, branches) catch |err| {
        std.debug.print("[determinismo] worker {d}: {s}\n", .{ branches.worker, @errorName(err) });
        return false;
    };
    return true;
}

fn read_exact(fd: linux.fd_t, target: []u8) bool {
    var done: u64 = 0;
    while (done < target.len) {
        const result = linux.read(fd, target[done..].ptr, target.len - done);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS or result == 0) return false;
        done += result;
    }
    return true;
}

fn write_all(fd: linux.fd_t, bytes: []const u8) void {
    var done: u64 = 0;
    while (done < bytes.len) {
        const result = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS) return;
        done += result;
    }
}

fn explore_snapshot(vm: *VM, options: *VM.Options, snapshot: *Snapshot) !void {
    options.stop_at_setup_complete = true;
    defer options.stop_at_setup_complete = false;
    // Moments belong to branches: none during the run to the snapshot.
    const moment_vtime_ns = options.moment_vtime_ns;
    const moment_command = options.moment_command;
    const until = options.until;
    options.moment_vtime_ns = null;
    options.moment_command = null;
    options.until = null;
    defer options.moment_vtime_ns = moment_vtime_ns;
    defer options.moment_command = moment_command;
    defer options.until = until;
    own_cpu.take();
    try vm.init(options);
    const outcome = try vm.run_until_exit();
    if (outcome != .setup_complete) {
        std.debug.print("[determinismo] the guest never signalled setup_complete ({s})\n", .{
            @tagName(outcome),
        });
        std.process.exit(1);
    }
    try snapshot.take(vm);
    vm.deinit();
    assert(snapshot.branches > 0);
}

const Branches = struct {
    snapshot: *const Snapshot,
    /// The setup snapshot (`snapshot` is a later one when branching from a moment): the base of
    /// snapshots saved to disk (saver.zig).
    setup: ?*const Snapshot = null,
    multiverse: *report.Multiverse,
    exploration: *const Exploration,
    arguments: *const Arguments,
    /// No branch starts after this (monotonic_ns): the time budget.
    deadline_ns: ?u64 = null,
    /// A worker's: each timeline runs on a CPU taken from it (and given back after).
    pool: ?*cpus.Pool = null,
    /// The tree explorer's generation: which branches run, and where each starts. Null: the
    /// branches `0..arguments.branches`, all from `snapshot`.
    plan: ?[]const Planned = null,
    /// Where the branches of a plan tell how they went (behaviors, for the next generation).
    summaries: ?*Summaries = null,
    /// This process runs the branches whose index modulo `jobs` is `worker`; or, with `next`,
    /// whichever comes next.
    worker: u32 = 0,
    jobs: u32 = 1,
    /// The tree's in-run snapshots (holders.zig): the explorer that names them, and the
    /// behaviors the tree knew before this generation. Null: none (no tree, or a strategy, or
    /// CPU modulation).
    holders: ?linux.pid_t = null,
    seen: ?*const std.AutoHashMapUnmanaged(u64, void) = null,
    /// Where its holders write themselves when it fails (Ladders).
    ladder: ?*const holders.Ladder = null,
    /// Where its holders go while memory runs low.
    holders_disk: ?*const holders.Disk = null,
    /// Where the run's timelines end, on average so far (virtual time): its holders' spacing
    /// when neither a horizon nor `--timeline` says how long it runs.
    end_ns_expected: ?u64 = null,
    /// Shared by parallel workers (memory mapped before they fork): the next position to run.
    /// A timeline is the same whichever worker runs it, so a worker that finished takes the
    /// next instead of idling while others run long ones.
    next: ?*std.atomic.Value(u32) = null,
};

const jobs_max = 256;

fn explore_branches(context: Context, vm: *VM, options: *VM.Options, branches: Branches) !void {
    const exploration = branches.exploration;
    const replay_branch = if (exploration.replay) |replay| replay.header.branch else null;
    const first = replay_branch orelse branches.arguments.branch_only orelse 0;
    const single = replay_branch != null or branches.arguments.branch_only != null;
    const count = if (single) 1 else branches.arguments.branches;
    if (branches.arguments.moment_vtime_ms) |ms| {
        try moment_after_snapshot(branches.snapshot, ms * std.time.ns_per_ms);
    }
    const total = if (branches.plan) |plan| plan.len else count;
    // A holder's capture (one at a time: each holder keeps its own copy, forked).
    const capture = if (branches.holders != null) try context.arena.create(Snapshot) else undefined;
    var maker = HolderMaker{ .arena = context.arena, .options = options };
    var position_next: usize = 0;
    while (true) {
        const position: usize = if (branches.next) |counter|
            counter.fetchAdd(1, .monotonic)
        else
            position_next;
        position_next += 1;
        if (position >= total) break;
        const place = branch_place(branches, first + position, single, position) orelse continue;
        const index = place.index;
        if (exploration.done) |resumed| {
            if (resumed.done.contains(index)) continue;
        }
        if (branches.deadline_ns) |deadline| {
            if (monotonic_ns() >= deadline) break;
        }
        const held = if (branches.pool) |pool| pool.take() else null;
        defer if (held) |cpu| branches.pool.?.give(cpu);
        options.seed = place.seed;
        const moment_ms = branches.arguments.moment_vtime_ms;
        options.moment_vtime_ns = if (moment_ms) |ms| ms * std.time.ns_per_ms else place.horizon_ns;
        options.moment_command = branches.arguments.moment_command;
        options.moment_continue = branches.arguments.moment_continue;
        options.fresh_seed = branches.arguments.fresh_seed;
        options.until = branches.arguments.until;
        // Saving to disk: the replay goes just past the last moment saved.
        const save_at_ms = branches.arguments.save_at_ms;
        if (save_at_ms.len > 0) {
            const last_ns = (std.mem.max(u64, save_at_ms) + 1) * std.time.ns_per_ms;
            options.moment_vtime_ns = @min(options.moment_vtime_ns orelse last_ns, last_ns);
        }
        if (branches.arguments.rewind_ms) |ms| {
            try rewind(vm, options, branches.snapshot, exploration, ms * std.time.ns_per_ms);
        }
        if (branches.pool == null) own_cpu.take(); // In this process: its own CPU.
        // From a node (a moment of another timeline): a branch point. Not for causality's
        // futures from a moment (--from-vtime-ms): how likely a failure is from there, not
        // after a fault drawn there.
        options.branch_signal = place.path.len > 0 and branches.arguments.from_vtime_ms == null;
        defer options.branch_signal = false;
        try vm.init_from_snapshot(options, place.snapshot);
        defer vm.deinit();
        if (branches.arguments.events_directory) |directory| {
            const name = try std.fmt.allocPrint(context.arena, "branch-{d}.jsonl", .{index});
            vm.events.log_fd = try events_file(context.arena, directory, name);
            // A tree's timeline begins inside its ancestors: queries assemble it (query.zig).
            if (place.path.len > 0) {
                const header = try std.fmt.allocPrint(context.arena, "{f}\n", .{
                    std.json.fmt(.{ .path = place.path }, .{}),
                });
                _ = linux.write(vm.events.log_fd.?, header.ptr, header.len);
            }
        }
        defer if (branches.arguments.events_directory != null) close(vm.events.log_fd.?);
        var owner: holders.Owner = undefined;
        if (branches.holders) |explorer| {
            owner = .{
                .explorer = explorer,
                .worker = linux.getpid(),
                .seen = branches.seen.?,
                .branch = index,
                .seed = place.seed,
                .start_ns = place.snapshot.tsc / (cpuid_tsc_hz / std.time.ns_per_s),
                // Spread over the branch: a short one keeps holders up to its horizon, where the
                // tree extends it.
                .spacing_ns = holders.Owner.spacing(if (place.horizon_ns) |horizon|
                    horizon -| place.snapshot.tsc / (cpuid_tsc_hz / std.time.ns_per_s)
                else if (branches.arguments.timeline_ms) |ms|
                    ms * std.time.ns_per_ms
                else if (branches.end_ns_expected) |end|
                    end -| place.snapshot.tsc / (cpuid_tsc_hz / std.time.ns_per_s)
                else
                    null),
                .snapshot = capture,
                .make = .{ .context = &maker, .function = HolderMaker.make },
                .ladder = branches.ladder,
                .disk = branches.holders_disk,
                .disk_always = branches.arguments.holders_on_disk,
                .disk_origin = place.disk_origin,
            };
            try owner.attach(vm);
        }
        var saver: saver_zig.Saver = undefined;
        if (branches.arguments.save_directory) |directory| {
            assert(branches.holders == null); // One hold owner: a replayed branch has none.
            const setup = branches.setup.?;
            var hasher = std.hash.Wyhash.init(0);
            for ([_]u64{ exploration.inputs, exploration.exploration_seed, setup.tsc, setup.branches }) |value| {
                hasher.update(std.mem.asBytes(&value));
            }
            const setup_name = try std.fmt.allocPrint(context.arena, "setup-{x:0>16}", .{hasher.final()});
            try std.Io.Dir.cwd().createDirPath(context.io, directory);
            saver = try saver_zig.Saver.init(context.arena, directory, index, save_at_ms, setup, setup_name);
            try saver.attach(vm, place.snapshot.tsc / (cpuid_tsc_hz / std.time.ns_per_s));
        }
        vm.strategy = exploration.strategy;
        if (exploration.replay) |replay| vm.overrides = replay.overrides;
        try branch_announce(context, vm, exploration, place);
        defer if (vm.tape_fd) |fd| close(fd);
        const time_start_ns = monotonic_ns();
        const idle_start_tsc = vm.stats.idle_tsc;
        const outcome = try vm.run_until_exit();
        // Its last holder on disk complete before the explorer may load it.
        if (branches.holders != null) owner.disk_wait();
        if (branches.arguments.save_directory != null) try saver.finish();
        // A tree timeline's summary on disk before its line in the record: killed between the
        // two, the resumed run runs it again (once), never takes it as recorded without one.
        if (branches.summaries) |summaries| {
            summaries.note(vm, place, outcome, if (branches.holders != null) owner.holders() else &.{});
            if (tree_summaries_fd) |fd| summary_write(fd, &summaries.items[summaries.count - 1]);
        }
        try branches.multiverse.add(vm, .{
            .index = index,
            .seed = options.seed,
            .outcome = outcome,
            .wall_ns = monotonic_ns() - time_start_ns,
            .start_tsc = place.snapshot.tsc,
            .start_idle_tsc = idle_start_tsc,
            .path = place.path,
            .generation = place.generation,
            .why = place.why,
            .memory_wait_ns = if (held) |cpu| cpu.memory_wait_ns else 0,
            .cpu_wait_ns = if (held) |cpu| cpu.cpu_wait_ns else 0,
        });
        if (exploration.strategy) |strategy| {
            const end = BranchResult{ .index = index, .outcome = outcome };
            if (try strategy_branch_end(strategy, vm, end)) break;
        }
    }
}

/// Tells the strategy a branch starts (and where), and opens its tape.
fn branch_announce(
    context: Context,
    vm: *VM,
    exploration: *const Exploration,
    place: Planned,
) !void {
    if (exploration.strategy) |strategy| {
        const from: ?Strategy.From = if (place.path.len == 0) null else .{
            .branch = place.path[place.path.len - 1].branch,
            .vtime_ns = place.path[place.path.len - 1].vtime_ns,
        };
        try strategy.branch(place.index, place.seed, from);
    }
    if (exploration.tape_directory) |directory| {
        vm.tape_fd = try open_tape(context.arena, directory, place.index);
        tape.write_header(vm.tape_fd.?, .{
            .inputs = exploration.inputs,
            .exploration_seed = exploration.exploration_seed,
            .branch = place.index,
            .branch_seed = place.seed,
            .fork = exploration.fork,
            .chain = place.path,
            .host = exploration.host,
        });
    }
}

/// Where the branch at `position` starts, if this worker (and shard) runs it: the snapshot, or
/// (a tree explorer's branch) a moment of another.
fn branch_place(branches: Branches, index_flat: usize, single: bool, position: usize) ?Planned {
    const mine = branches.next != null or position % branches.jobs == branches.worker;
    if (branches.plan) |plan| {
        if (!mine) return null;
        return plan[position];
    }
    const index: u32 = @intCast(index_flat);
    const shards = if (single) 1 else branches.arguments.shard_count;
    const shard = if (single) 0 else branches.arguments.shard_index;
    if (index % shards != shard) return null;
    if (branches.next == null and index / shards % branches.jobs != branches.worker) return null;
    const exploration = branches.exploration;
    const replay = exploration.replay;
    return .{
        .index = index,
        .seed = if (replay) |tape_replay|
            tape_replay.header.branch_seed
        else
            branch_seed(seed_base(exploration), index),
        .snapshot = branches.snapshot,
        .path = if (replay) |tape_replay| tape_replay.header.chain else &.{},
    };
}

/// Where a branch starts and with what: the tree explorer plans these, a generation at a time.
const Planned = struct {
    index: u32,
    seed: u64,
    snapshot: *const Snapshot,
    /// From the setup snapshot to `snapshot`: the ancestors and the moments they branched.
    path: []const tape.Segment = &.{},
    generation: u32 = 0,
    /// Why it starts there, for people (the tree explorer's reason).
    why: []const u8 = "",
    /// Where it stops (virtual time), a returned branch's horizon: null for the timeline's end.
    horizon_ns: ?u64 = null,
    /// The disk holder its node was made from: its own first disk holder saves against it.
    disk_origin: ?holders.Origin = null,
};

/// How a branch went, for planning the next generation: the behaviors it reached first, when.
const Summary = struct {
    index: u32,
    start_ns: u64,
    end_ns: u64,
    behavior_count: u32,
    behaviors: [Events.behavior_count_max]Events.Behavior,
    /// The in-run snapshots it kept (holders.zig), for the explorer to return to.
    holder_count: u32,
    holders: [holders.per_timeline_max]holders.Held,
    /// Its whole trace's hash (from the setup snapshot): equal, the same timeline.
    trace_hash: u64,
    /// At or before its last randomness pull (VM.last_pull_ns), and before its checks' inputs
    /// streamed out (Events.checks_start_ns): branches return before it. From later, a branch
    /// replays the timeline's shutdown alone, and its host checks get part of their input (run
    /// 43, srv3: the archive returned after a built-in property of the end, and Elle refused
    /// 28 such histories).
    last_pull_ns: u64,
    /// Stopped at its horizon: it can be extended (returned to at its end), its future unknown.
    cut: bool,
    /// The properties it fails (their messages' hashes), up to `failing_max`: the explorer saves
    /// the first failing timeline of each to disk from its holders (Ladders).
    failing: [failing_max]u64 = undefined,
    failing_count: u8 = 0,

    const failing_max = 16;
};

const Summaries = struct {
    items: []Summary,
    count: u32 = 0,

    fn note(
        summaries: *Summaries,
        vm: *VM,
        place: Planned,
        outcome: VM.Outcome,
        kept: []const holders.Held,
    ) void {
        assert(summaries.count < summaries.items.len);
        const summary = &summaries.items[summaries.count];
        summaries.count += 1;
        summary.index = place.index;
        summary.start_ns = place.snapshot.tsc / (cpuid_tsc_hz / std.time.ns_per_s);
        summary.end_ns = if (vm.moment()) |moment| moment.vtime_ns else |_| summary.start_ns;
        summary.behavior_count = vm.events.behavior_count;
        summary.trace_hash = vm.events.hash.final();
        summary.last_pull_ns = @min(vm.last_pull_ns, vm.events.checks_start_ns orelse std.math.maxInt(u64));
        summary.cut = place.horizon_ns != null and outcome == .moment_reached;
        summary.holder_count = @intCast(kept.len);
        @memcpy(summary.holders[0..kept.len], kept);
        summary.failing_count = 0;
        for (vm.events.properties[0..vm.events.property_count]) |*property| {
            if (property.passing() or summary.failing_count == Summary.failing_max) continue;
            summary.failing[summary.failing_count] = std.hash.Wyhash.hash(0, property.name());
            summary.failing_count += 1;
        }
        @memcpy(
            summary.behaviors[0..summary.behavior_count],
            vm.events.behaviors[0..vm.events.behavior_count],
        );
    }
};

/// Antithesis's exploration, as a tree: every branch is a potential branch point. The first
/// generation starts from the setup snapshot; after each, the branches that reached behaviors
/// no branch before them had are returned to (Go-Explore): a snapshot at the moment just after
/// the new behavior (replaying the branch to it), and new branches from there, with their own
/// seeds. Some branches of every generation start from the setup snapshot again. A generation
/// is planned only from the ones before it, so the tree is the same whatever the workers.
const tree = struct {
    /// Timelines per generation by default, and the unit of `--generation`.
    const generation_base = 16;
    const generation_max = 256;
    /// Branches from each moment returned to, by default (`--return-branches`).
    const children = 4;

    /// From the setup snapshot, in every generation after the first: a quarter.
    fn roots(size: u32) u32 {
        return size / 4;
    }

    /// Moments returned to per generation, `branches` from each.
    fn nodes(size: u32, branches: u32) u32 {
        assert(branches > 0);
        return (size - roots(size)) / branches;
    }

    /// Whether each moment's branches fill a generation's returns exactly.
    fn fits(size: u32, branches: u32) bool {
        return branches > 0 and (size - roots(size)) % branches == 0;
    }

    comptime {
        assert(roots(generation_base) + nodes(generation_base, children) * children == generation_base);
    }
};

fn explore_tree(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    branches: Branches,
    jobs: u32,
) !void {
    const arena = context.arena;
    own_cpu.give(); // Its timelines and node makers take their own.
    const exploration = branches.exploration;
    const size = branches.arguments.generation_size;
    if (!tree.fits(size, branches.arguments.return_branches)) {
        std.debug.print("error: --return-branches {d} does not divide a generation of {d}'s " ++
            "{d} returned timelines\n", .{ branches.arguments.return_branches, size, size - tree.roots(size) });
        return error.Usage;
    }
    // In-run snapshots (holders.zig): not with a strategy that decides within timelines (its
    // decisions replay from its tape, as holders do not); one that only chooses where the tree
    // returns ("decides":false) keeps them.
    var registry: holders.Registry = undefined;
    const deciding = if (exploration.strategy) |plugin| plugin.decides else false;
    const holding = !deciding;
    if (holding) try registry.init();
    // While memory runs low, holders go to the run's directory (holders.Disk), on its disk.
    const disk: ?*const holders.Disk = if (holding) if (branches.arguments.run_directory) |run| disk: {
        const directory = try std.fs.path.join(arena, &.{ run, "holders" });
        try std.Io.Dir.cwd().createDirPath(context.io, directory);
        const made = try arena.create(holders.Disk);
        made.* = .{ .directory = directory };
        made.delete(null); // An interrupted run's.
        break :disk made;
    } else null else null;
    defer if (holding) registry.release(disk);
    // The failing timelines' holders go to the run's snapshots (a run's: a directory to keep
    // them). The table of page hashes is shared before the workers fork: their holders write it.
    const ladders: ?*Ladders = if (holding) if (branches.arguments.run_directory) |run| ladders: {
        const setup = branches.setup orelse branches.snapshot;
        const page_hashes = try Snapshot.PageHashes.init(setup.memory_size);
        var hasher = std.hash.Wyhash.init(0);
        for ([_]u64{ exploration.inputs, exploration.exploration_seed, setup.tsc, setup.branches }) |value| {
            hasher.update(std.mem.asBytes(&value));
        }
        const directory = try Snapshot.layout_directory(arena, try std.fs.path.join(arena, &.{ run, "snapshots" }));
        try std.Io.Dir.cwd().createDirPath(context.io, directory);
        const made = try arena.create(Ladders);
        made.* = .{
            .ladder = .{ .directory = directory, .hashes = page_hashes.hashes },
            .setup = setup,
            .setup_name = try std.fmt.allocPrint(arena, "setup-{x:0>16}", .{hasher.final()}),
            .explorer = linux.getpid(),
            .io = context.io,
        };
        break :ladders made;
    } else null else null;
    const change: ?changed.Change = if (branches.arguments.changed) |source|
        try changed.read(
            arena,
            context.io,
            source,
            branches.arguments.changed_repository,
            branches.arguments.cache_directory,
        )
    else
        null;
    var state: TreeState = .{
        .base = seed_base(exploration),
        .total = branches.arguments.branches,
        .size = size,
        .children = branches.arguments.return_branches,
        .pipeline = branches.arguments.pipeline,
        .archive = branches.arguments.archive,
        .prefer_sometimes = branches.arguments.prefer_sometimes,
        .setup = branches.snapshot,
        .jobs = jobs,
        .holding = holding,
        .registry = &registry,
        .change = change,
        .hunks_reached = try arena.alloc(bool, if (change) |known| known.hunks.len else 0),
        .candidates = try arena.alloc(Candidate, size),
        .ladders = ladders,
        .disk = disk,
        .io = context.io,
        .tape_buffer = if (exploration.strategy != null)
            try arena.create(tape.Overrides)
        else
            undefined,
        .resumed = exploration.done,
    };
    if (branches.arguments.record_path) |record| {
        const path = try std.fmt.allocPrint(arena, "{s}.summaries", .{record});
        const fd = try open_for_appending(arena, path, if (state.resumed != null) .kept else .fresh);
        // A record the interruption cut: gone, the timeline runs again.
        if (state.resumed) |resumed| _ = linux.ftruncate(fd, @intCast(resumed.summaries_size));
        tree_summaries_fd = fd;
    }
    defer if (tree_summaries_fd) |fd| {
        close(fd);
        tree_summaries_fd = null;
    };
    // A queue of planned timelines, taken in order as CPUs free up; a generation is the next
    // `size` timelines to finish, whatever their indices, judged as soon as it is complete and
    // its returns planned at the queue's end. No CPU waits for a slow timeline: it is judged
    // with a later generation (a fixed set of indices once held back every timeline planned
    // after it, and minutes-long timelines left cores idle). The queue starts with `pipeline`
    // generations from the setup snapshot: while one fills, the others keep every CPU busy.
    // Which timelines formed each generation is recorded, and a resumed run judges the same
    // generations again: the tree follows the timelines' finishing order, its record says which.
    for (0..state.pipeline * size) |_| {
        if (state.next_index >= state.total) break;
        try queue_push(arena, &state, .{
            .index = state.next_index,
            .seed = branch_seed(state.base, state.next_index),
            .snapshot = branches.snapshot,
        });
        state.next_index += 1;
    }
    nodes_claim_refresh(&state); // The setup snapshot's, from the start.
    var batch: Batch = .{ .items = try arena.alloc(Summary, size), .scratch = try arena.alloc(Summary, 1) };
    batch.summaries = .{ .items = batch.items };
    if (state.resumed) |resumed| try tree_rejudge(context, vm, options, branches, &state, &batch, resumed);
    var running: [jobs_max]Running = undefined;
    var running_count: u32 = 0;
    // How busy the workers were: timelines running, over the loop's wall time (status.json and
    // the end's line). A hunt's 16 workers ran 8.8 timelines at once by their wall times (Kafka,
    // srv3 2026-10-28): which share was idle, and for memory, is what this says.
    var busy: Busy = .{ .jobs = jobs, .start_ns = monotonic_ns(), .last_ns = monotonic_ns() };
    defer busy.print(branches.multiverse);
    while (true) {
        busy.advance(running_count);
        const late = if (branches.deadline_ns) |deadline| monotonic_ns() >= deadline else false;
        // A complete generation: judged at once, its returns at the queue's end.
        if (!late and batch.summaries.count == size) {
            try tree_judge(context, vm, options, branches, &state, &batch, true);
            continue;
        }
        // Timelines start as CPUs free up, in the queue's order; none past the budget.
        if (!late and running_count < jobs) if (queue_next(&state)) |place| {
            // A resumed run's recorded timeline: its summary, not the timeline again.
            if (state.resumed) |resumed| if (resumed.summaries.get(place.index)) |bytes| {
                summary_load(&batch.items[batch.summaries.count], bytes);
                batch.summaries.count += 1;
                try batch.plan.append(arena, place);
                continue;
            };
            var mine = branches;
            mine.plan = (&place)[0..1];
            if (holding) {
                mine.holders = registry.explorer;
                mine.holders_disk = disk;
                mine.seen = &state.seen;
                if (ladders) |known| mine.ladder = &known.ladder;
                if (state.ends_count > 0) mine.end_ns_expected = state.ends_ns_sum / state.ends_count;
            }
            running[running_count] = try timeline_start(context, vm, options, mine, &batch);
            running_count += 1;
            continue;
        };
        if (running_count > 0) {
            // Every half minute without a timeline finishing, what the run is doing: a long
            // timeline (minutes) otherwise leaves its output silent.
            status_write(branches.arguments.run_directory, running[0..running_count], branches.multiverse, state.generation, &busy);
            const finished = try timeline_wait(running[0..running_count], branches.multiverse, &batch.summaries, progress_interval_ms) orelse {
                progress_print(running[0..running_count], branches.multiverse, state.generation);
                continue;
            };
            const place = running[finished.at].place;
            running[finished.at] = running[running_count - 1];
            running_count -= 1;
            if (finished.killed) {
                // Not served: its start snapshot's count already has it.
                state.kills += 1;
                if (state.kills > kills_max) return error.WorkerFailed;
                std.debug.print("[determinismo] timeline {d} was killed (SIGKILL: the host's OOM " ++
                    "killer?) before it finished: it runs again ({d} so far)\n", .{ place.index, state.kills });
                try state.queue.append(arena, place);
                continue;
            }
            try batch.plan.append(arena, place);
            continue;
        }
        // Nothing runs and nothing is queued: a last, partial generation judged (its returns
        // keep the run going), or the run is over (out of time, or of timelines).
        if (!late and batch.summaries.count > 0 and state.next_index < state.total) {
            try tree_judge(context, vm, options, branches, &state, &batch, true);
            if (state.queue_head < state.queue.items.len) continue;
        }
        break;
    }
    for (state.queue.items[state.queue_head..]) |entry| node_free(entry.snapshot, branches.snapshot);
    for (batch.plan.items) |entry| node_free(entry.snapshot, branches.snapshot);
    if (state.change) |*target| {
        target.summarize(state.next_index);
        report.record(.{ .changed = .{
            .hunks = target.hunks,
            .timelines = target.timelines,
            .first = target.first,
            .closest = target.closest,
        } });
    }
}

/// Plans a timeline at the queue's end: its start snapshot has one more timeline to serve.
fn queue_push(arena: std.mem.Allocator, state: *TreeState, place: Planned) !void {
    try state.queue.append(arena, place);
    const entry = try state.users.getOrPut(arena, place.snapshot);
    entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
}

/// The next planned timeline, if any.
fn queue_next(state: *TreeState) ?Planned {
    if (state.queue_head == state.queue.items.len) return null;
    const place = state.queue.items[state.queue_head];
    state.queue_head += 1;
    return place;
}

/// A judged timeline's start snapshot serves one timeline fewer: freed with its last (siblings
/// from one moment can finish in different generations).
fn node_served(state: *TreeState, snapshot: *const Snapshot) void {
    const entry = state.users.getEntry(snapshot) orelse return;
    entry.value_ptr.* -= 1;
    if (entry.value_ptr.* > 0) return;
    _ = state.users.remove(snapshot);
    node_free(snapshot, state.setup);
}

/// A resumed run's recorded generations judged again, in their order, each from its timelines'
/// summaries (none runs again): the queue is then the interrupted run's. A generation whose
/// summaries the interruption cut ends it: from there the run goes on as a new one would.
fn tree_rejudge(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    branches: Branches,
    state: *TreeState,
    batch: *Batch,
    resumed: *const Resumed,
) !void {
    const arena = context.arena;
    for (resumed.generations.items) |members| {
        if (members.len > batch.items.len) return;
        for (members) |index| if (!resumed.summaries.contains(index)) return;
        var found: usize = 0;
        for (state.queue.items[state.queue_head..]) |entry| {
            if (std.mem.indexOfScalar(u32, members, entry.index) != null) found += 1;
        }
        if (found != members.len) return; // Not the plan this record was made with.
        // Its timelines out of the queue (the rest keeps its order), their summaries in.
        var kept: usize = state.queue_head;
        for (state.queue.items[state.queue_head..]) |entry| {
            const member = std.mem.indexOfScalar(u32, members, entry.index) != null;
            if (member) {
                summary_load(&batch.items[batch.summaries.count], resumed.summaries.get(entry.index).?);
                batch.summaries.count += 1;
                try batch.plan.append(arena, entry);
            } else {
                state.queue.items[kept] = entry;
                kept += 1;
            }
        }
        state.queue.shrinkRetainingCapacity(kept);
        try tree_judge(context, vm, options, branches, state, batch, false);
    }
}

/// Whether the exploration's strategy decides within timelines (its answers are in tapes).
fn deciding_strategy(exploration: *const Exploration) bool {
    return if (exploration.strategy) |plugin| plugin.decides else false;
}

/// A timeline running in a process of its own (explore_tree): where its results come back, and
/// where it started.
const Running = struct { pid: linux.pid_t, results: linux.fd_t, place: Planned, index: u32, start_ns: u64 };

/// In a child just forked from the explorer: it dies with it. A worker left running after the
/// explorer was interrupted keeps its VM, its CPU and its memory (an interrupted hunt on srv2
/// left all twelve). The signal follows the forking thread: these forks are the main thread's.
/// The kernel's OOM killer takes a timeline's process (or a replay's, or a future's) before the
/// host's own (sshd, tailscaled, dbus, podman's pause process: a host OOM once took that last
/// one, and no run could start a container after, srv3 2026-10-28) and before the explorer;
/// holders go first of all (holders.zig). A timeline it kills runs again (timeline_wait).
fn oom_before_the_host() void {
    const fd = linux.open("/proc/self/oom_score_adj", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    _ = linux.write(@intCast(fd), "800", 3);
    _ = linux.close(@intCast(fd));
}

fn child_dies_with(explorer: linux.pid_t) void {
    _ = linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), @backingInt(linux.SIG.KILL), 0, 0, 0);
    if (linux.getppid() != explorer) linux.exit_group(1); // It died before the prctl.
    runs.running_forget(); // The run is the explorer's: it ends with it.
}

/// Starts the one timeline of `branches.plan` in a child process: a worker of one timeline, on a
/// CPU of the host's (cpus.zig); its results come back through a pipe.
fn timeline_start(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    branches: Branches,
    batch: *Batch,
) !Running {
    assert(branches.plan.?.len == 1);
    var pipe: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
    const explorer = linux.getpid();
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.Fork;
    if (pid == 0) {
        child_dies_with(explorer);
        oom_before_the_host();
        _ = linux.close(pipe[0]);
        var one = Summaries{ .items = batch.scratch }; // Its own copy: sent back whole.
        var mine = branches;
        mine.summaries = &one;
        mine.next = null;
        worker_run(context, vm, options, mine, .{ .worker = 0, .jobs = 1, .results_fd = pipe[1] });
    }
    _ = linux.close(pipe[1]);
    return .{
        .pid = @intCast(pid),
        .results = pipe[0],
        .place = branches.plan.?[0],
        .index = branches.plan.?[0].index,
        .start_ns = monotonic_ns(),
    };
}

/// How often a tree run says what it is doing while no timeline finishes.
const progress_interval_ms = 30 * std.time.ms_per_s;

/// The run's state for whoever shows it (serve): `status.json` in its directory, written whole
/// (renamed into place) as timelines start and finish: those running (each since when, in
/// seconds since the epoch), those done and failing, the generation judged next.
/// Timelines running, integrated over a tree loop's wall time.
const Busy = struct {
    jobs: u32,
    start_ns: u64,
    last_ns: u64,
    running_ns: u128 = 0,

    /// `count` timelines ran since the last call.
    fn advance(busy: *Busy, count: u32) void {
        const now_ns = monotonic_ns();
        busy.running_ns += @as(u128, count) * (now_ns - busy.last_ns);
        busy.last_ns = now_ns;
    }

    /// Timelines at once, on average so far.
    fn at_once(busy: *const Busy) f64 {
        const span_ns = busy.last_ns - busy.start_ns;
        if (span_ns == 0) return 0;
        return @as(f64, @floatFromInt(busy.running_ns)) / @as(f64, @floatFromInt(span_ns));
    }

    fn print(busy: *Busy, multiverse: *report.Multiverse) void {
        busy.advance(0);
        multiverse.workers = busy.jobs;
        multiverse.at_once = busy.at_once();
        std.debug.print("[determinismo] workers: {d:.1} timelines at once of {d} on average " ++
            "({d:.0}%); their VMs waited {d:.0}s for memory, {d:.0}s for a CPU\n", .{
            busy.at_once(),
            busy.jobs,
            100 * busy.at_once() / @as(f64, @floatFromInt(@max(busy.jobs, 1))),
            @as(f64, @floatFromInt(multiverse.memory_wait_ns)) / std.time.ns_per_s,
            @as(f64, @floatFromInt(multiverse.cpu_wait_ns)) / std.time.ns_per_s,
        });
    }
};

fn status_write(directory: ?[]const u8, running: []const Running, multiverse: *const report.Multiverse, generation: u32, busy: *const Busy) void {
    const known = directory orelse return;
    var buffer: [8192]u8 = undefined;
    var text: std.Io.Writer = .fixed(&buffer);
    var wall: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &wall);
    const now_ns = monotonic_ns();
    text.print("{{\"running\":[", .{}) catch return;
    for (running, 0..) |timeline, at| {
        const since_s = wall.sec - @as(i64, @intCast((now_ns - timeline.start_ns) / std.time.ns_per_s));
        text.print("{s}{{\"index\":{d},\"since_s\":{d}}}", .{ if (at == 0) "" else ",", timeline.index, since_s }) catch return;
    }
    const efficiency = multiverse.efficiency();
    text.print("],\"done\":{d},\"failing\":{d},\"generation\":{d},\"at_s\":{d}," ++
        "\"workers\":{d},\"at_once\":{d:.2},\"memory_wait_s\":{d:.1},\"cpu_wait_s\":{d:.1},\"idle_share\":{d:.3}," ++
        "\"clock_reads_per_s\":{d:.0},\"per_node\":{d:.2}}}\n", .{
        multiverse.branches,          multiverse.failing_branches, generation,                                                             wall.sec,
        busy.jobs,                    busy.at_once(),              @as(f64, @floatFromInt(multiverse.memory_wait_ns)) / std.time.ns_per_s,
        @as(f64, @floatFromInt(multiverse.cpu_wait_ns)) / std.time.ns_per_s, efficiency.idle_share,
        efficiency.clock_reads_per_s, efficiency.per_node,
    }) catch return;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const staging = std.fmt.bufPrintSentinel(&path_buffer, "{s}/status.json.next", .{known}, 0) catch return;
    var final_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const final = std.fmt.bufPrintSentinel(&final_buffer, "{s}/status.json", .{known}, 0) catch return;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const fd = linux.open(staging, flags, 0o644);
    if (linux.errno(fd) != .SUCCESS) return;
    _ = linux.write(@intCast(fd), text.buffered().ptr, text.buffered().len);
    _ = linux.close(@intCast(fd));
    _ = linux.renameat(linux.AT.FDCWD, staging, linux.AT.FDCWD, final);
}

/// One line: the timelines running (each with its wall time so far), those done and failing.
fn progress_print(running: []const Running, multiverse: *const report.Multiverse, generation: u32) void {
    var line_buffer: [1024]u8 = undefined;
    var line: std.Io.Writer = .fixed(&line_buffer);
    const now = monotonic_ns();
    line.print("[determinismo] {d} timelines running (", .{running.len}) catch {};
    for (running, 0..) |timeline, at| {
        if (at == 12) {
            line.print(" ...", .{}) catch {};
            break;
        }
        line.print("{s}#{d} {d}s", .{ if (at == 0) "" else ", ", timeline.index, (now - timeline.start_ns) / std.time.ns_per_s }) catch {};
    }
    line.print("), {d} done, {d} failing, generation {d}\n", .{
        multiverse.branches, multiverse.failing_branches, generation,
    }) catch {};
    std.debug.print("{s}", .{line.buffered()});
}

const Finished = struct { at: usize, killed: bool = false };

/// Waits for one of the running timelines to finish: its results in the run's multiverse, its
/// summary in the generation filling (`summaries`). Returns which, or null when none finished
/// within `timeout_ms`. One killed (SIGKILL: the host's OOM killer) before it sent its results
/// is `killed`: it runs again (the same timeline, from the same place).
fn timeline_wait(running: []const Running, multiverse: *report.Multiverse, summaries: *Summaries, timeout_ms: i32) !?Finished {
    assert(running.len > 0);
    var polled: [jobs_max]linux.pollfd = undefined;
    for (running, polled[0..running.len]) |timeline, *entry| {
        entry.* = .{ .fd = timeline.results, .events = linux.POLL.IN | linux.POLL.HUP, .revents = 0 };
    }
    while (true) {
        const ready = linux.poll(&polled, @intCast(running.len), timeout_ms);
        if (linux.errno(ready) == .INTR) continue;
        if (linux.errno(ready) != .SUCCESS) return error.Poll;
        if (ready == 0) return null; // None finished in time.
        break;
    }
    const at = for (polled[0..running.len], 0..) |entry, index| {
        if (entry.revents != 0) break index;
    } else unreachable;
    const timeline = running[at];
    const results = try std.heap.page_allocator.create(report.Multiverse);
    defer std.heap.page_allocator.destroy(results);
    var count: u32 = 0;
    var received = read_exact(timeline.results, std.mem.asBytes(results));
    received = received and read_exact(timeline.results, std.mem.asBytes(&count));
    received = received and count <= 1;
    if (received and count == 1) {
        // Read whole even with no slot left (past the time budget no generation is judged, and
        // they fill): unread, the worker blocks writing it, other processes holding the pipe's
        // read end, while this waits for the worker to exit (runs 177 and 200 hung so for hours).
        const room = summaries.count < summaries.items.len;
        const scratch = if (room) null else try std.heap.page_allocator.create(Summary);
        defer if (scratch) |summary| std.heap.page_allocator.destroy(summary);
        const slot = if (scratch) |summary| summary else &summaries.items[summaries.count];
        // Counted once read whole: a worker killed while it wrote leaves part of one (its
        // holders' pids among the slot's old bytes).
        received = read_exact(timeline.results, std.mem.asBytes(slot));
        if (received and room) summaries.count += 1;
        // Dropped: its holders, which no generation will take, go now.
        if (received and !room) for (slot.holders[0..@min(slot.holder_count, slot.holders.len)]) |held| {
            if (!held.disk) holders.kill(held.pid);
        };
    }
    _ = linux.close(timeline.results);
    var status: i32 = 0;
    _ = linux.waitpid(timeline.pid, &status, 0);
    const signaled: u32 = @bitCast(status);
    const killed = linux.W.IFSIGNALED(signaled) and linux.W.TERMSIG(signaled) == .KILL;
    if (!received and killed) return .{ .at = at, .killed = true };
    if (!received or status != 0) return error.WorkerFailed;
    try multiverse.absorb(results);
    return .{ .at = at };
}

/// The first failing timeline of each property, saved to disk from its holders as it is judged
/// (holders.Ladder): `b<timeline>-<ms>` at each of its in-run snapshots' moments, each diffed
/// against the one before, from the setup snapshot (saved first when it is not). Causality and
/// multiverse debugging then start from them, without the replay that otherwise saves them (a
/// YugabyteDB timeline's took longer than its exploration, srv3 2026-10-27). In a thread of
/// the explorer's (the tree goes on meanwhile), one ladder at a time: one table of page hashes.
const Ladders = struct {
    ladder: holders.Ladder,
    setup: *const Snapshot,
    setup_name: []const u8,
    /// The setup's page hashes, copied into the shared table before each ladder; null until the
    /// first.
    setup_hashes: ?[]u64 = null,
    explorer: linux.pid_t,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// Properties (their messages' hashes) a ladder was saved for: the first failure of each.
    saved: std.AutoHashMapUnmanaged(u64, void) = .empty,

    const Job = struct { ladders: *Ladders, branch: u32, helds: []holders.Held, room: []holders.Held };

    /// A timeline judged: when it fails a property no ladder has yet, its holders nobody took
    /// are set aside and written in a thread; else they go with their generation.
    fn consider(ladders: *Ladders, arena: std.mem.Allocator, registry: *holders.Registry, summary: *const Summary) !void {
        var new = false;
        for (summary.failing[0..summary.failing_count]) |hash| {
            if (!(try ladders.saved.getOrPut(arena, hash)).found_existing) new = true;
        }
        if (!new) return;
        const room = try std.heap.page_allocator.alloc(holders.Held, holders.per_timeline_max + 1);
        const helds = registry.set_aside(summary.index, room);
        if (helds.len == 0) {
            std.heap.page_allocator.free(room);
            return;
        }
        const job = try std.heap.page_allocator.create(Job);
        job.* = .{ .ladders = ladders, .branch = summary.index, .helds = helds, .room = room };
        const thread = try std.Thread.spawn(.{}, run, .{job});
        thread.detach();
    }

    fn run(job: *Job) void {
        defer {
            std.heap.page_allocator.free(job.room);
            std.heap.page_allocator.destroy(job);
        }
        const ladders = job.ladders;
        ladders.mutex.lockUncancelable(ladders.io);
        defer ladders.mutex.unlock(ladders.io);
        const setup_hashes = ladders.setup_hashes orelse ladders.setup_prepare() catch |err| {
            std.debug.print("[determinismo] ladder of timeline {d}: the setup snapshot: {s}\n", .{ job.branch, @errorName(err) });
            for (job.helds) |held| holders.end(held);
            return;
        };
        @memcpy(ladders.ladder.hashes, setup_hashes);
        var base_buffer: [Snapshot.disk_name_max]u8 = undefined;
        var base: []const u8 = ladders.setup_name;
        var saved: u32 = 0;
        var names: [holders.per_timeline_max + 1][Snapshot.disk_name_max]u8 = undefined;
        var name_lengths: [holders.per_timeline_max + 1]usize = undefined;
        // After a failed write the table is no longer the base's: the rest go unsaved.
        var broken = false;
        for (job.helds) |held| {
            if (broken) {
                holders.end(held);
                continue;
            }
            switch (holders.ask_disk(ladders.explorer, held, base)) {
                .written => {},
                // Left for memory, as holders do (a YugabyteDB ladder kept 2 of 9 that way):
                // the next one is diffed against the same base.
                .gone => continue,
                .failed => {
                    broken = true;
                    continue;
                },
            }
            const name = holders.ladder_name(&names[saved], job.branch, held.vtime_ns);
            name_lengths[saved] = name.len;
            @memcpy(base_buffer[0..name.len], name);
            base = base_buffer[0..name.len];
            saved += 1;
        }
        // A marker serve reads: this failure is on disk (its own replay that saves one is not
        // needed).
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(std.heap.page_allocator);
        text.print(std.heap.page_allocator, "saved by the explorer from timeline {d}'s in-run snapshots:", .{job.branch}) catch return;
        for (names[0..saved], name_lengths[0..saved]) |*name, length| {
            text.print(std.heap.page_allocator, " {s}", .{name[0..length]}) catch return;
        }
        text.append(std.heap.page_allocator, '\n') catch return;
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        // Serve's marker, in the run's snapshots directory (above the layout's).
        const snapshots = std.fs.path.dirname(ladders.ladder.directory) orelse return;
        const marker = std.fmt.bufPrint(&path_buffer, "{s}/failure-{d}.log", .{ snapshots, job.branch }) catch return;
        std.Io.Dir.cwd().writeFile(ladders.io, .{ .sub_path = marker, .data = text.items }) catch {};
        std.debug.print("[determinismo] ladder of timeline {d}: {d} of {d} in-run snapshots on disk\n", .{
            job.branch, saved, job.helds.len,
        });
    }

    /// The setup snapshot on disk (saved unless it is there) and its page hashes.
    fn setup_prepare(ladders: *Ladders) ![]u64 {
        const setup = ladders.setup;
        const size = setup.memory_size;
        const address = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, setup.memory_fd, 0);
        if (linux.errno(address) != .SUCCESS) return error.Map;
        defer _ = linux.munmap(@ptrFromInt(address), size);
        const memory = @as([*]align(std.heap.page_size_min) const u8, @ptrFromInt(address))[0..size];
        const directory = ladders.ladder.directory;
        @memset(ladders.ladder.hashes, 0); // A fresh table: every page is new.
        if (Snapshot.disk_exists(directory, ladders.setup_name)) {
            try Snapshot.pages_hash(memory, setup.memory_fd, ladders.ladder.hashes);
        } else {
            try Snapshot.disk_save(setup, memory, setup.memory_fd, ladders.ladder.hashes, directory, ladders.setup_name, null, false);
        }
        const hashes = try std.heap.page_allocator.dupe(u64, ladders.ladder.hashes);
        ladders.setup_hashes = hashes;
        return hashes;
    }
};

/// The tree explorer's state across generations (explore_tree, tree_judge).
const TreeState = struct {
    base: u64,
    total: u32,
    size: u32,
    /// Branches from each moment returned to (`--return-branches`).
    children: u32,
    /// Generations in flight (`--pipeline`).
    pipeline: u32,
    jobs: u32,
    holding: bool,
    registry: *holders.Registry,
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The traces explored: a timeline that repeats one is never returned to (its first was).
    traces: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// How many timelines reached each behavior (what a strategy's `returns` is told).
    visits: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    change: ?changed.Change,
    hunks_reached: []bool,
    candidates: []Candidate,
    /// Parents' tapes are read into this (a strategy's overrides), one at a time.
    tape_buffer: *tape.Overrides,
    next_index: u32 = 0,
    /// The failing timelines' holders written to disk (with a run directory).
    ladders: ?*Ladders = null,
    /// Where holders go while memory runs low (with a run directory).
    disk: ?*const holders.Disk = null,
    /// Disk holders others' are saved against: kept while those timelines are.
    lineage: holders.Lineage = .{},
    io: std.Io,
    /// Where the timelines that ran to their end ended (virtual time): their sum and count, for
    /// a timeline's expected end (holders' spacing).
    ends_ns_sum: u64 = 0,
    ends_count: u64 = 0,
    /// Planned timelines, taken in order from `queue_head` (explore_tree).
    queue: std.ArrayList(Planned) = .empty,
    queue_head: u32 = 0,
    /// Each start snapshot's timelines not judged yet: freed after its last (node_served).
    users: std.AutoHashMapUnmanaged(*const Snapshot, u32) = .empty,
    /// The generation filling: judged next.
    generation: u32 = 0,
    /// Go-Explore's archive (`--archive`): each behavior's cell, and every branch planned (its
    /// seed and path: one of an earlier generation is rebuilt from the setup snapshot).
    archive: bool,
    /// Returns go first to sought behaviors (`--no-prefer-sometimes`: all alike).
    prefer_sometimes: bool,
    cells: std.AutoHashMapUnmanaged(u64, Cell) = .empty,
    planned: std.AutoHashMapUnmanaged(u32, Planned) = .empty,
    setup: *const Snapshot,
    /// A resumed run's: recorded timelines are not run again; their summaries are judged.
    resumed: ?*const Resumed = null,
    /// Timelines killed before they finished (and queued again).
    kills: u32 = 0,
    /// Returns whose node was not made: the run's nodes held half the host's memory.
    nodes_skipped: u32 = 0,
    /// The memory of the snapshots it holds (nodes_claim_refresh).
    nodes_bytes: u64 = 0,
};

/// The memory of the snapshots the tree holds (the setup's, and each node with timelines still
/// to serve), claimed for the host's admission (cpus.nodes_claim): VMs wait while it fills it.
fn nodes_claim_refresh(state: *TreeState) void {
    var bytes: u64 = snapshot_bytes(state.setup);
    var iterator = state.users.keyIterator();
    while (iterator.next()) |snapshot| {
        if (snapshot.* != state.setup) bytes += snapshot_bytes(snapshot.*);
    }
    state.nodes_bytes = bytes;
    cpus.nodes_claim(bytes);
}

/// The memory a snapshot's memfd holds (its pages written, not its size).
fn snapshot_bytes(snapshot: *const Snapshot) u64 {
    if (snapshot.memory_fd < 0) return 0;
    var stat: linux.Statx = undefined;
    const result = linux.statx(snapshot.memory_fd, "", linux.AT.EMPTY_PATH, .{ .BLOCKS = true }, &stat);
    if (linux.errno(result) != .SUCCESS) return 0;
    return stat.blocks * 512;
}

/// Killed timelines a run takes before it ends (a host that keeps killing them).
const kills_max = 64;

/// A cell of the archive: where a behavior was first reached (the moment just after it), and how
/// often the tree returned there.
/// An archive cell: a behavior, where timelines reached it (the first; for a sought one, up to
/// `cell_places_max` timelines' moments, returns going to each in turn: the same rare state
/// reached from different pasts), and how often the tree returned there.
const Cell = struct {
    places: [cell_places_max]Place,
    place_count: u8 = 1,
    label: []const u8,
    visits: u32 = 0,
    sought: bool = false,

    const Place = struct { branch: u32, vtime_ns: u64 };

    fn place(cell: *const Cell) Place {
        assert(cell.place_count >= 1 and cell.place_count <= cell_places_max);
        return cell.places[cell.visits % cell.place_count];
    }
};

const cell_places_max = 4;

/// How much more a sought behavior (a `sometimes` or `reachable` made true) weighs than another
/// new one, in a timeline's novelty and as an archive cell (`--prefer-sometimes`): a few output
/// lines new to the tree still outweigh one, as several rare things do.
const sought_weight = 4;

/// Generations planned ahead by default (`--pipeline`): the queue starts with that many from the
/// setup snapshot, and each generation judged plans as many timelines as it had, so the queue,
/// the generation filling and the timelines running always add up to that many generations.
/// Every worker is busy while they hold at least a generation more than the workers: two for up
/// to a generation's worth of workers (16), three for more. More only delays the first returns:
/// the tree deepens from timeline `pipeline * generation` on (a system whose timelines take five
/// minutes on six workers once waited three quarters of an hour for its first branch).
const pipeline_depth_default = 3;
const pipeline_depth_few_workers = 2;
const pipeline_depth_max = 4;

/// The generation filling: the timelines finished since the last was judged, where each started
/// and its summary (in `items`, reused by every generation). `scratch`: a worker's own summary.
const Batch = struct {
    plan: std.ArrayList(Planned) = .empty,
    items: []Summary,
    summaries: Summaries = .{ .items = &.{} },
    scratch: []Summary,
};

/// A generation complete (the timelines that finished since the last): what each reached that
/// none before it had, the moments returned to (nodes made), and their branches planned at the
/// queue's end; the generation recorded unless `recording` is false (a resumed run's, judged
/// again).
fn tree_judge(
    context: Context,
    vm: *VM,
    options: *VM.Options,
    branches: Branches,
    state: *TreeState,
    batch: *Batch,
    recording: bool,
) !void {
    const plan = &batch.plan;
    const summaries = &batch.summaries;
    const generation = state.generation;
    const arena = context.arena;
    const exploration = branches.exploration;
    // In index order (workers finish in any): what each reached that none before it had.
    // Summaries are large: their order is sorted, not them.
    const done = try arena.alloc(*const Summary, summaries.count);
    for (done, summaries.items[0..summaries.count]) |*entry, *summary| entry.* = summary;
    std.sort.insertion(*const Summary, done, {}, summary_before);
    const members = try arena.alloc(u32, done.len);
    for (members, done) |*member, summary| member.* = summary.index;
    if (recording) report.record(.{ .generation = .{ .number = generation, .branches = members } });
    if (state.holding) for (done) |summary| {
        state.registry.add(summary.index, summary.holders[0..summary.holder_count]);
    };
    // What each behavior new this generation was reached by: how many of its timelines.
    // Every timeline is judged against what earlier generations knew, and what it found
    // weighs more the fewer of its generation found it too (measured on the self-test maze:
    // deeper than claiming behaviors in index order, where the first timeline took all the
    // common ones and the latest of them sat past the decisions that mattered).
    var reached: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    for (done) |summary| for (summary.behaviors[0..summary.behavior_count]) |behavior| {
        if (state.seen.contains(behavior.hash)) continue;
        const entry = try reached.getOrPut(arena, behavior.hash);
        entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
    };
    for (done) |summary| try archive_add(arena, state, plan.items, summary);
    var candidate_count: u32 = 0;
    const generation_seed = state.base ^ (@as(u64, generation) *% 0x9e3779b97f4a7c15);
    var random: std.Random.DefaultPrng = .init(generation_seed);
    for (done) |summary| {
        // A targeted run: which hunks each timeline ran (once each; its parents' prefix too),
        // whatever its trace (a timeline the same as an earlier one still ran them).
        if (state.change) |*target| {
            @memset(state.hunks_reached, false);
            for (summary.behaviors[0..summary.behavior_count]) |behavior| {
                const hunk = target.hunk_of(arena, behavior.name()) orelse {
                    // How near the hunks no timeline ran its lines come (the report's).
                    if (target.approach(arena, behavior.name())) |near| {
                        target.closest[near.hunk] = @min(target.closest[near.hunk], near.distance);
                    }
                    continue;
                };
                if (!state.hunks_reached[hunk]) {
                    target.timelines[hunk] += 1;
                    target.first[hunk] = @min(target.first[hunk], summary.index);
                }
                state.hunks_reached[hunk] = true;
            }
        }
        if ((try state.traces.getOrPut(arena, summary.trace_hash)).found_existing) continue;
        var novel: u32 = 0;
        var moment: ?u64 = null;
        var label: []const u8 = "";
        var changed_moment: ?u64 = null;
        var changed_label: []const u8 = "";
        // The frontier (Go-Explore): its rarest new behavior (the fewest of its generation
        // reached it; latest among equals) that leaves room to go on (in its first four
        // fifths); the branches return just after it.
        var score: f64 = 0;
        var moment_reached: u32 = std.math.maxInt(u32);
        var moment_sought = false;
        const room_end = if (summary.cut)
            summary.end_ns -| std.time.ns_per_ms
        else
            summary.start_ns + (summary.end_ns -| summary.start_ns) / 5 * 4;
        for (summary.behaviors[0..summary.behavior_count]) |behavior| {
            // A targeted run: when it first ran changed code itself (not in its parents'
            // prefix). Any moment with a little room after it: what follows changed code is
            // what a targeted run explores, however late it ran.
            if (state.change) |*target| if (target.hunk_of(arena, behavior.name())) |_| {
                const own = behavior.vtime_ns > summary.start_ns;
                const room = behavior.vtime_ns + changed_room_ns < summary.end_ns and
                    behavior.vtime_ns < summary.last_pull_ns;
                if (own and room and changed_moment == null) {
                    changed_moment = behavior.vtime_ns;
                    changed_label = behavior.name();
                }
            };
            const timelines = reached.get(behavior.hash) orelse continue; // Known before.
            novel += 1;
            const sought = state.prefer_sometimes and behavior.sought;
            const weight: f64 = if (sought) sought_weight else 1;
            score += weight / @as(f64, @floatFromInt(timelines));
            // A moment past its last randomness pull returns to the same timeline (a cut
            // branch's future was never drawn: open to its end). A sought behavior's moment
            // first (the rarest of them), then the rarest of the rest.
            const open = summary.cut or behavior.vtime_ns < summary.last_pull_ns;
            const better = if (sought != moment_sought) sought else timelines <= moment_reached;
            if (behavior.vtime_ns <= room_end and open and better) {
                moment = behavior.vtime_ns;
                moment_reached = timelines;
                moment_sought = sought;
                label = behavior.name();
            }
        }
        state.candidates[candidate_count] = .{
            .summary = summary,
            .novel = novel,
            .score = score,
            .moment = moment,
            .label = label,
            .sought = moment_sought,
            .changed_moment = changed_moment,
            .changed_label = changed_label,
        };
        candidate_count += 1;
    }
    var new_ones = reached.keyIterator();
    while (new_ones.next()) |hash| try state.seen.put(arena, hash.*, {});
    const chosen = state.candidates[0..candidate_count];
    std.sort.insertion(Candidate, chosen, {}, candidate_before);
    const counts = Counts{ .reached = &reached, .visits = &state.visits };
    const plugin = exploration.strategy;
    var returns = try tree_returns(arena, plugin, generation, chosen, counts, &random, state.size, state.children, &state.planned);
    if (state.archive and plugin == null) returns = try archive_returns(arena, state, returns, &random);
    for (done) |summary| for (summary.behaviors[0..summary.behavior_count]) |behavior| {
        const entry = try state.visits.getOrPut(arena, behavior.hash);
        entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
    };
    // The nodes are made at once, each replay in a child process (`state.jobs` at a time); then
    // their branches are numbered in the returns' order, as if made one after the other.
    const makings = try arena.alloc(NodeMaking, returns.len);
    const total = cpus.memory_total();
    const nodes_cap = if (total == 0) std.math.maxInt(u64) / 2 else (total -| cpus.memory_reserve()) / 2;
    var nodes_pending: u64 = 0; // The nodes being made, each its VM's size at most.
    var making_count: u32 = 0;
    var finished: u32 = 0;
    var held: u32 = 0;
    var held_disk: u32 = 0; // Of them, from holders on disk.
    for (returns) |back| {
        var earlier = false;
        const parent = for (plan.items) |entry| {
            if (entry.index == back.branch) break entry;
        } else state.planned.get(back.branch) orelse continue;
        if (state.planned.get(back.branch) != null) earlier = for (plan.items) |entry| {
            if (entry.index == back.branch) break false;
        } else true;
        // A resumed run's return whose timelines are all recorded: none runs again, no node
        // (its timelines are planned from the setup snapshot, never started).
        if (state.resumed) |resumed| {
            const key: ReturnKey = .{
                .generation = generation + 1,
                .branch = back.branch,
                .vtime_ns = back.vtime_ns,
            };
            if ((resumed.children.get(key) orelse 0) >= state.children) {
                makings[making_count] = .{ .back = back, .parent = parent, .ready = true, .snapshot = state.setup };
                making_count += 1;
                continue;
            }
        }
        if (making_count - finished == state.jobs) {
            node_make_finish(arena, &makings[finished]);
            finished += 1;
        }
        // A holder of the parent at the moment, or a little before it: no replay from the
        // parent's start. One on disk is loaded by a node maker, as a replay's node is made.
        var from_disk: ?holders.Held = null;
        if (state.holding and !earlier) if (state.registry.take(back.branch, back.vtime_ns)) |taken| {
            if (taken.disk) |on_disk| from_disk = on_disk else {
                makings[making_count] = .{
                    .back = back,
                    .parent = parent,
                    .held = true,
                    .pid = taken.pid,
                    .socket = taken.socket,
                };
                making_count += 1;
                held += 1;
                continue;
            }
        };
        // A node made by a replay holds a copy of its VM's memory, gigabytes, claimed once made
        // (nodes_claim_refresh): VMs wait while nodes fill memory. Up to half the host's, so
        // that VMs always have room to serve them; past it, the return is not made (as when
        // making fails). A holder's node is the holder's memory already.
        if (state.nodes_bytes + nodes_pending + cpus.claim_bytes > nodes_cap) {
            state.nodes_skipped += 1;
            continue;
        }
        nodes_pending += cpus.claim_bytes;
        // A strategy's decisions in the parent are in its tape: replayed to the moment.
        const overrides = if (deciding_strategy(exploration)) try tape_overrides(
            context,
            branches.arguments.tape_directory.?,
            parent.index,
            state.tape_buffer,
        ) else null;
        makings[making_count] = .{
            .back = back,
            .parent = parent,
            // Its start snapshot is gone (an earlier generation's), or was never made (a resumed
            // run's recorded timeline): replayed along its path.
            .chain_from = if ((earlier or parent.snapshot == state.setup) and parent.path.len > 0) state.setup else null,
            .disk = if (from_disk) |on_disk| .{
                .held = on_disk,
                .branch = back.branch,
                .disk = state.disk.?,
                .io = state.io,
            } else null,
        };
        if (from_disk != null) {
            held += 1;
            held_disk += 1;
        }
        try node_make_start(arena, vm, options, &makings[making_count], overrides);
        making_count += 1;
    }
    while (finished < making_count) : (finished += 1) {
        node_make_finish(arena, &makings[finished]);
    }
    for (done) |summary| if (!summary.cut and summary.end_ns > 0) {
        state.ends_ns_sum += summary.end_ns;
        state.ends_count += 1;
    };
    // A property's first failing timeline: its holders nobody took, to disk (Ladders).
    if (state.ladders) |ladders| for (done) |summary| {
        if (summary.failing_count > 0) try ladders.consider(arena, state.registry, summary);
    };
    // Their memory: this generation's (the ones in flight keep theirs). Their files once their
    // children are planned (Lineage: a child's holders save against the one its node came from).
    if (state.holding) state.registry.release_listed(members, null);
    if (branches.arguments.verify_holders) for (makings[0..making_count]) |*making| {
        const held_node = making.snapshot orelse continue;
        if (!making.held and making.disk == null) continue;
        var replayed: NodeMaking = .{ .back = making.back, .parent = making.parent };
        try node_make_start(arena, vm, options, &replayed, null);
        node_make_finish(arena, &replayed);
        const replay_node = replayed.snapshot orelse continue;
        snapshots_compare(making.back, held_node, replay_node);
        node_free(replay_node, branches.snapshot);
    };
    const planned_before = state.queue.items.len;
    var made: u32 = 0;
    for (makings[0..making_count]) |*making| {
        const snapshot = making.snapshot orelse continue;
        if (state.next_index >= state.total) {
            node_free(snapshot, branches.snapshot); // Not needed after all.
            continue;
        }
        const parent = making.parent;
        const back = making.back;
        const at = back.vtime_ns;
        made += 1;
        const path = try arena.alloc(tape.Segment, parent.path.len + 1);
        @memcpy(path[0..parent.path.len], parent.path);
        path[parent.path.len] = .{
            .branch = parent.index,
            .seed = parent.seed,
            .vtime_ns = at,
        };
        for (0..state.children) |_| {
            if (state.next_index >= state.total) break;
            try queue_push(arena, state, .{
                .index = state.next_index,
                .seed = branch_seed(state.base, state.next_index),
                .snapshot = snapshot,
                .path = path,
                .generation = generation + 1,
                .why = back.why,
                .horizon_ns = if (back.horizon_ns orelse branches.arguments.horizon_ns) |horizon| at + horizon else null,
                .disk_origin = if (making.disk) |on_disk| .{ .branch = on_disk.branch, .vtime_ns = on_disk.held.vtime_ns } else null,
            });
            if (making.disk) |on_disk| try state.lineage.depend(arena, state.next_index, on_disk.branch);
            state.next_index += 1;
        }
    }
    if (state.holding) if (state.disk) |disk| for (members) |branch| try state.lineage.release(arena, disk, branch);
    // These timelines served their start snapshots (a snapshot goes with its last timeline;
    // the setup snapshot is everyone's: never freed).
    for (plan.items) |entry| node_served(state, entry.snapshot);
    nodes_claim_refresh(state);
    if (state.nodes_skipped > 0) {
        std.debug.print("[determinismo] {d} returns not made so far: the run's nodes held half " ++
            "the host's memory\n", .{state.nodes_skipped});
    }
    // As many planned as judged: the rest start over from the setup snapshot.
    while (state.next_index < state.total and state.queue.items.len - planned_before < done.len) : (state.next_index += 1) {
        try queue_push(arena, state, .{
            .index = state.next_index,
            .seed = branch_seed(state.base, state.next_index),
            .snapshot = branches.snapshot,
            .generation = generation + 1,
            .why = "From the setup snapshot: some timelines of every generation start " ++
                "over, so the tree does not only deepen.",
        });
    }
    std.debug.print("[determinismo] tree: generation {d}: {d} branches, {d} new behaviors " ++
        "({d} known); {d} moments returned to ({d} from in-run snapshots), {d} from disk\n", .{
        generation, done.len, reached.count(), state.seen.count(), made, held, held_disk,
    });
    summaries.count = 0;
    plan.clearRetainingCapacity();
    state.generation += 1;
}

/// After changed code, the least virtual time a timeline must go on for the tree to return
/// there (tree_returns keeps moments a millisecond inside a timeline).
const changed_room_ns = 2 * std.time.ns_per_ms;

const Candidate = struct {
    summary: *const Summary,
    novel: u32,
    /// Its new behaviors, each weighing 1 / the timelines of its generation that reached it.
    score: f64 = 0,
    moment: ?u64,
    label: []const u8,
    /// Its moment follows a `sometimes` or `reachable` made true (they come first).
    sought: bool = false,
    /// A targeted run: when it first ran changed code (with room to go on), and which line.
    changed_moment: ?u64 = null,
    changed_label: []const u8 = "",
};

const TreeReturn = struct {
    branch: u32,
    vtime_ns: u64,
    why: []const u8,
    /// A strategy's horizon for this return (null: `--horizon`, or to the end).
    horizon_ns: ?u64 = null,
};

/// A judged timeline, kept for returns from later generations (a strategy's archive, or ours);
/// with `--archive`, every behavior it reached that the archive lacks becomes a cell just after
/// it (a moment that leads elsewhere: before its last randomness pull, or anywhere in a cut
/// branch).
fn archive_add(arena: std.mem.Allocator, state: *TreeState, plan: []const Planned, summary: *const Summary) !void {
    const planned = for (plan) |entry| {
        if (entry.index == summary.index) break entry;
    } else return;
    try state.planned.put(arena, summary.index, planned);
    if (!state.archive) return;
    for (summary.behaviors[0..summary.behavior_count]) |behavior| {
        if (behavior.vtime_ns <= summary.start_ns) continue; // Its ancestors' (reached before).
        const at = behavior.vtime_ns + std.time.ns_per_us;
        const open = summary.cut or at < summary.last_pull_ns;
        if (!open or at + std.time.ns_per_ms >= summary.end_ns) continue;
        const entry = try state.cells.getOrPut(arena, behavior.hash);
        if (entry.found_existing) {
            // A sought behavior reached by another timeline: one more place to return to.
            const cell = entry.value_ptr;
            if (!state.prefer_sometimes or !cell.sought or cell.place_count == cell_places_max) continue;
            const known = for (cell.places[0..cell.place_count]) |known| {
                if (known.branch == summary.index) break true;
            } else false;
            if (known) continue;
            cell.places[cell.place_count] = .{ .branch = summary.index, .vtime_ns = at };
            cell.place_count += 1;
            continue;
        }
        entry.value_ptr.* = .{
            .places = undefined,
            .label = try arena.dupe(u8, behavior.name()),
            .sought = behavior.sought,
        };
        entry.value_ptr.places[0] = .{ .branch = summary.index, .vtime_ns = at };
    }
}

/// Go-Explore's selection: half the generation's moments (all of them when it found nothing
/// new) go to the archive's most promising cells: rare (few timelines reached the behavior) and
/// seldom returned to, scored (1 + timelines) * (1 + returns), ties at random; each return
/// counts.
fn archive_returns(
    arena: std.mem.Allocator,
    state: *TreeState,
    frontier: []const TreeReturn,
    random: *std.Random.DefaultPrng,
) ![]const TreeReturn {
    const nodes = tree.nodes(state.size, state.children);
    const novel = frontier.len > 0 and !std.mem.startsWith(u8, frontier[0].why, "A random moment");
    const keep: usize = if (novel) @min(frontier.len, (nodes + 1) / 2) else 0;
    var list: std.ArrayList(TreeReturn) = .empty;
    try list.appendSlice(arena, frontier[0..keep]);
    if (state.cells.count() == 0) return list.items;
    const Ranked = struct { hash: u64, score: u64, tie: u64 };
    const ranked = try arena.alloc(Ranked, state.cells.count());
    var iterator = state.cells.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        const timelines: u64 = state.visits.get(entry.key_ptr.*) orelse 0;
        // A sought cell ranks as one a few times rarer (lower scores go first).
        const weight: u64 = if (state.prefer_sometimes and !entry.value_ptr.sought) sought_weight else 1;
        ranked[index] = .{
            .hash = entry.key_ptr.*,
            .score = (1 + timelines) * (1 + @as(u64, entry.value_ptr.visits)) * weight,
            .tie = random.random().int(u64),
        };
    }
    std.sort.pdq(Ranked, ranked, {}, struct {
        fn before(_: void, a: Ranked, b: Ranked) bool {
            return if (a.score != b.score) a.score < b.score else a.tie < b.tie;
        }
    }.before);
    for (ranked) |cell_ranked| {
        if (list.items.len == nodes) break;
        const cell = state.cells.getPtr(cell_ranked.hash).?;
        const place = cell.place();
        cell.visits += 1;
        try list.append(arena, .{
            .branch = place.branch,
            .vtime_ns = place.vtime_ns,
            .why = try std.fmt.allocPrint(arena, "Go-Explore's archive: back to just after {s}, " ++
                "as #{d} reached it ({d} timelines reached it, from {d} places kept); returned " ++
                "there {d} times.", .{
                cell.label,  place.branch, state.visits.get(cell_ranked.hash) orelse 0, cell.place_count,
                cell.visits,
            }),
        });
    }
    return list.items;
}

/// Where the next generation returns: the strategy's choice when it makes one; else the
/// branches with the most new behaviors, just after the last of them that leaves room (Go-
/// Explore's frontier), or a random moment of a branch when nothing was new.
/// A generation's behavior counts: how many of its timelines reached each behavior new to it,
/// and how many timelines of earlier generations reached each.
const Counts = struct {
    reached: *const std.AutoHashMapUnmanaged(u64, u32),
    visits: *const std.AutoHashMapUnmanaged(u64, u32),
};

fn tree_returns(
    arena: std.mem.Allocator,
    strategy: ?*Strategy,
    generation: u32,
    chosen: []const Candidate,
    counts: Counts,
    random: *std.Random.DefaultPrng,
    size: u32,
    children: u32,
    /// Every branch planned before: a strategy may return to any of them (its own archive).
    planned: *const std.AutoHashMapUnmanaged(u32, Planned),
) ![]const TreeReturn {
    var list: std.ArrayList(TreeReturn) = .empty;
    const nodes = tree.nodes(size, children);
    if (strategy) |plugin| {
        const offered = try arena.alloc(Strategy.Candidate, chosen.len);
        for (chosen, offered) |candidate, *offer| offer.* = .{
            .branch = candidate.summary.index,
            .start_ns = candidate.summary.start_ns,
            .end_ns = candidate.summary.end_ns,
            .novel = candidate.novel,
            .moment_ns = candidate.moment,
            .label = candidate.label,
            .behaviors = if (plugin.wants_behaviors)
                try behaviors_offered(arena, candidate.summary, counts)
            else
                &.{},
        };
        const answer = try plugin.returns(arena, generation, offered, nodes);
        for (answer) |back| {
            // A timeline of this generation: within its span. Of an earlier one: the strategy's
            // archive; a moment outside its span makes no node (the replay says why).
            const candidate = for (chosen) |candidate| {
                if (candidate.summary.index == back.branch) break candidate;
            } else null;
            if (candidate) |known| {
                const summary = known.summary;
                if (back.vtime_ns <= summary.start_ns or back.vtime_ns >= summary.end_ns) continue;
            } else if (!planned.contains(back.branch)) continue;
            const reason = if (back.reason.len > 0) back.reason else "(it gave no reason)";
            try list.append(arena, .{
                .branch = back.branch,
                .vtime_ns = back.vtime_ns,
                .horizon_ns = back.horizon_ns,
                .why = try std.fmt.allocPrint(arena, "The strategy returned to #{d} here: {s}", .{
                    back.branch, reason,
                }),
            });
        }
        // Fewer moments than asked: the explorer's own choices fill the rest, so a strategy that
        // knows only a few good moments costs the generation no depth (Tetris's deepest.py
        // returned to one or two, and fresh games took the rest: run 161).
    }
    next: for (chosen) |candidate| {
        if (list.items.len == nodes) break;
        const summary = candidate.summary;
        for (list.items) |taken| if (taken.branch == summary.index) continue :next;
        // Only moments before its last randomness pull lead elsewhere.
        const end_ns = @min(summary.end_ns, summary.last_pull_ns);
        const span = end_ns -| summary.start_ns;
        if (span < 2 * std.time.ns_per_ms) continue;
        const extend = summary.cut and candidate.novel > 0 and candidate.changed_moment == null;
        const after = if (candidate.changed_moment) |moment|
            moment + std.time.ns_per_us
        else if (extend)
            summary.end_ns -| std.time.ns_per_ms
        else if (candidate.moment) |moment|
            moment + std.time.ns_per_us
        else
            summary.start_ns + random.random().uintLessThan(u64, span);
        const at = std.math.clamp(
            after,
            summary.start_ns + std.time.ns_per_ms,
            end_ns - std.time.ns_per_ms,
        );
        const why = if (extend)
            try std.fmt.allocPrint(arena, "Extended #{d} from where it stopped: it reached " ++
                "{d} behaviors no timeline before it had (the rarest, {s}).", .{
                summary.index, candidate.novel, candidate.label,
            })
        else if (candidate.changed_moment != null)
            try std.fmt.allocPrint(arena, "Returned to #{d} just after it first ran changed " ++
                "code ({s}): a targeted run explores what follows it.", .{
                summary.index, candidate.changed_label,
            })
        else if (candidate.moment != null and candidate.sought)
            try std.fmt.allocPrint(arena, "Returned to #{d} just after it first reached " ++
                "{s}, a state the program marks worth reaching (a sometimes or reachable made " ++
                "true comes first), of the {d} behaviors no timeline before it had: its " ++
                "frontier.", .{
                summary.index, candidate.label, candidate.novel,
            })
        else if (candidate.moment != null)
            try std.fmt.allocPrint(arena, "Returned to #{d} just after it first reached " ++
                "{s}, the rarest of the {d} behaviors no timeline before it had: its " ++
                "frontier.", .{
                summary.index, candidate.label, candidate.novel,
            })
        else
            try std.fmt.allocPrint(arena, "A random moment of #{d}: no timeline of this " ++
                "generation reached anything new, so a moment is chosen at random.", .{
                summary.index,
            });
        try list.append(arena, .{ .branch = summary.index, .vtime_ns = at, .why = why });
    }
    return list.items;
}

/// A timeline's own behaviors (after it began), with their counts, for a strategy's `returns`.
fn behaviors_offered(
    arena: std.mem.Allocator,
    summary: *const Summary,
    counts: Counts,
) ![]const Strategy.Behavior {
    var offered: std.ArrayList(Strategy.Behavior) = .empty;
    for (summary.behaviors[0..summary.behavior_count]) |*behavior| {
        if (behavior.vtime_ns <= summary.start_ns) continue; // Its parents'.
        try offered.append(arena, .{
            .label = behavior.name(),
            .vtime_ns = behavior.vtime_ns,
            .new_in_generation = counts.reached.get(behavior.hash) orelse 0,
            .timelines_before = counts.visits.get(behavior.hash) orelse 0,
        });
    }
    return offered.items;
}

fn candidate_before(_: void, a: Candidate, b: Candidate) bool {
    // Timelines that ran changed code first (targeted runs), then the most novel.
    if ((a.changed_moment != null) != (b.changed_moment != null)) return a.changed_moment != null;
    if (a.score != b.score) return a.score > b.score;
    return a.summary.index < b.summary.index;
}

fn summary_before(_: void, a: *const Summary, b: *const Summary) bool {
    return a.index < b.index;
}

/// The overrides of branch `index`'s tape in `directory` (null when it has no tape).
fn tape_overrides(
    context: Context,
    directory: []const u8,
    index: u32,
    overrides: *tape.Overrides,
) !?*tape.Overrides {
    const name = try std.fmt.allocPrint(context.arena, "branch-{d}.jsonl", .{index});
    const path = try std.fs.path.join(context.arena, &.{ directory, name });
    const source = std.Io.Dir.cwd().readFileAlloc(context.io, path, context.arena, .unlimited) catch
        return null;
    var scratch: [64 * 1024]u8 = undefined;
    _ = try tape.parse(source, &scratch, overrides);
    return overrides;
}

/// A snapshot at `vtime_ns` of the branch that starts at `from` with `seed`: replays it there.
fn node_make(
    arena: std.mem.Allocator,
    vm: *VM,
    options: *const VM.Options,
    from: *const Snapshot,
    seed: u64,
    vtime_ns: u64,
    /// The branch's tape when a strategy overrode its decisions: they are replayed too.
    overrides: ?*tape.Overrides,
    /// `from` is a node (a moment of another timeline): the run is a branch's, from its branch
    /// point (VM.Options.branch_signal), as the timeline it replays was.
    branch_point: bool,
) !*const Snapshot {
    try moment_after_snapshot(from, vtime_ns);
    var probe = options.*;
    probe.seed = seed;
    probe.branch_signal = branch_point;
    probe.moment_vtime_ns = vtime_ns;
    probe.moment_command = null;
    probe.moment_continue = false;
    probe.until = null;
    probe.events_fd = null;
    try vm.init_from_snapshot(&probe, from);
    vm.overrides = overrides;
    const outcome = try vm.run_until_exit();
    if (outcome != .moment_reached) {
        vm.deinit();
        return error.MomentNotReached;
    }
    const snapshot = try arena.create(Snapshot);
    try snapshot.take_copy(vm);
    vm.deinit();
    return snapshot;
}

/// What a holder replays with, to a moment later than its own (node_make, in the holder).
const HolderMaker = struct {
    arena: std.mem.Allocator,
    options: *const VM.Options,

    fn make(
        context: *anyopaque,
        vm: *VM,
        from: *const Snapshot,
        seed: u64,
        vtime_ns: u64,
        point: VM.Hold.Point,
    ) anyerror!*const Snapshot {
        const maker: *HolderMaker = @ptrCast(@alignCast(context));
        var options = maker.options.*;
        assert(options.from_hold == null);
        options.from_hold = point; // The timeline goes on as it did there.
        return node_make(maker.arena, vm, &options, from, seed, vtime_ns, null, false);
    }
};

/// A tree node in the making: a child process replays its parent to the moment, freezes it and
/// hands the snapshot over (its memory's memfd through the socket, fd_pass); or a holder of the
/// parent at or before the moment does (holders.zig), with the same protocol.
const NodeMaking = struct {
    back: TreeReturn,
    parent: Planned,
    /// Set for a parent of an earlier generation: replayed from this (the setup snapshot) along
    /// its path, ancestor by ancestor, then to the moment.
    chain_from: ?*const Snapshot = null,
    /// Made by a holder (else by a replay).
    held: bool = false,
    /// Loaded from a holder on disk (holders.Disk), then replayed on to the moment as a holder
    /// does; a replay from the parent's start when it cannot be loaded.
    disk: ?DiskHeld = null,
    pid: linux.pid_t = 0,
    socket: linux.fd_t = -1,
    /// Null when the moment could not be reached (the child said why).
    snapshot: ?*const Snapshot = null,
    /// Nothing to make (a resumed run's return whose timelines are recorded).
    ready: bool = false,
};

fn node_make_start(
    arena: std.mem.Allocator,
    vm: *VM,
    options: *const VM.Options,
    making: *NodeMaking,
    overrides: ?*tape.Overrides,
) !void {
    var pair: [2]i32 = undefined;
    const flags = linux.SOCK.STREAM | linux.SOCK.CLOEXEC;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, flags, 0, &pair)) != .SUCCESS) {
        return error.Socketpair;
    }
    const explorer = linux.getpid();
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.Fork;
    if (pid == 0) {
        child_dies_with(explorer);
        close(pair[0]);
        // A replay to the node's moment: on a CPU of the host's (cpus.zig), until it is made.
        var pool: cpus.Pool = undefined;
        pool.open() catch linux.exit_group(1);
        const cpu = pool.take();
        const parent = making.parent;
        const at = making.back.vtime_ns;
        var from = parent.snapshot;
        const seed = parent.seed;
        if (making.disk) |on_disk| if (disk_node(arena, vm, options, on_disk, seed, at)) |snapshot| {
            pool.give(cpu);
            fd_pass.send(pair[1], snapshot.memory_fd) catch linux.exit_group(1);
            write_all(pair[1], std.mem.asBytes(snapshot));
            linux.exit_group(0);
        } else |err| std.debug.print("[determinismo] tree: holder {d}ns of branch {d} not loaded " ++
            "from disk ({s}): a replay\n", .{ on_disk.held.vtime_ns, parent.index, @errorName(err) });
        if (making.chain_from) |setup| {
            from = setup;
            for (parent.path, 0..) |segment, depth| {
                from = node_make(arena, vm, options, from, segment.seed, segment.vtime_ns, null, depth > 0) catch |err| {
                    std.debug.print("[determinismo] tree: no snapshot at {d}ns of branch {d}'s path: {s}\n", .{
                        segment.vtime_ns, segment.branch, @errorName(err),
                    });
                    linux.exit_group(1);
                };
            }
        }
        const snapshot = node_make(arena, vm, options, from, seed, at, overrides, parent.path.len > 0) catch |err| {
            std.debug.print("[determinismo] tree: no snapshot at {d}ns of branch {d}: {s}\n", .{
                at, parent.index, @errorName(err),
            });
            linux.exit_group(1);
        };
        // Its CPU back before the answer: the explorer may read another's first, one waiting for
        // a CPU (a pool of two, both held by makers writing to an explorer reading a third that
        // waited for one: an e2e deadlocked, srv3 2026-10-28).
        pool.give(cpu);
        fd_pass.send(pair[1], snapshot.memory_fd) catch linux.exit_group(1);
        // Everything else is plain data, or set up before the fork (the same in the explorer).
        write_all(pair[1], std.mem.asBytes(snapshot));
        linux.exit_group(0);
    }
    close(pair[1]);
    making.pid = @intCast(pid);
    making.socket = pair[0];
}

/// A holder on disk, for a node maker to load.
const DiskHeld = struct { held: holders.Held, branch: u32, disk: *const holders.Disk, io: std.Io };

/// The node at `vtime_ns` from a holder on disk: its snapshot itself at its own moment, else a
/// replay on from it as the holder would have made (HolderMaker).
fn disk_node(
    arena: std.mem.Allocator,
    vm: *VM,
    options: *const VM.Options,
    on_disk: DiskHeld,
    seed: u64,
    vtime_ns: u64,
) !*const Snapshot {
    const held = on_disk.held;
    var name_buffer: [Snapshot.disk_name_max]u8 = undefined;
    const name = holders.Disk.name(&name_buffer, on_disk.branch, held.vtime_ns);
    const loaded = try arena.create(Snapshot);
    try loaded.disk_load(arena, on_disk.io, on_disk.disk.directory, name, &.{});
    if (vtime_ns == held.vtime_ns) return loaded;
    var from_hold = options.*;
    assert(from_hold.from_hold == null);
    from_hold.from_hold = .{ .idle = held.idle }; // The timeline goes on as it did there.
    return node_make(arena, vm, &from_hold, loaded, seed, vtime_ns, null, false);
}

fn node_make_finish(arena: std.mem.Allocator, making: *NodeMaking) void {
    if (making.ready) return;
    assert(making.pid > 0);
    defer {
        close(making.socket);
        var status: i32 = 0;
        _ = linux.wait4(making.pid, &status, 0, null);
    }
    const fd = fd_pass.receive(making.socket) catch return; // It failed, and said why.
    const snapshot = arena.create(Snapshot) catch {
        close(fd);
        return;
    };
    if (!read_exact(making.socket, std.mem.asBytes(snapshot))) {
        close(fd);
        return;
    }
    snapshot.memory_fd = fd;
    making.snapshot = snapshot;
}

/// DETERMINISMO_VERIFY_HOLDERS=1: every node a holder made is made again by a replay and the
/// two compared (they must be the same: holders.zig).
/// Prints how a holder's node and a replay's node of the same moment differ (memory included),
/// but for what the guest cannot see (field_same).
fn snapshots_compare(back: TreeReturn, held: *const Snapshot, replayed: *const Snapshot) void {
    var differ: u32 = 0;
    inline for (@typeInfo(Snapshot).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "memory_fd")) continue;
        if (!field_same(name, held, replayed)) {
            differ += 1;
            const a = std.mem.asBytes(&@field(held, name));
            const b = std.mem.asBytes(&@field(replayed, name));
            const at = std.mem.indexOfDiff(u8, a, b) orelse 0;
            std.debug.print("[determinismo] verify #{d} at {d}ns: {s} differs (byte {d} of {d}: " ++
                "{x} against {x})\n", .{
                back.branch,
                back.vtime_ns,
                name,
                at,
                a.len,
                a[at..@min(a.len, at + 8)],
                b[at..@min(b.len, at + 8)],
            });
        }
    }
    const memory_same = memory_equal(held, replayed);
    if (!memory_same) differ += 1;
    std.debug.print("[determinismo] verify #{d} at {d}ns: {s}{s}\n", .{
        back.branch,
        back.vtime_ns,
        if (differ == 0) "the same" else "DIFFERENT",
        if (memory_same) "" else " (memory too)",
    });
}

/// MSRs KVM derives from host time, which the guest's clock (the branch count) is not: the TSC
/// (its reads are the branch clock) and Hyper-V's runtime and reference counters (not offered).
const host_time_msrs = [_]u32{ 0x10, 0x40000010, 0x40000020 };

/// A snapshot field the same in both, but for what the guest cannot see: host-time MSRs, the
/// last exception's or interrupt's leftovers while none is pending or injected (struct
/// kvm_vcpu_events), and the attributes of unusable segments.
/// Two machines' event states, by what they hold: never their padding, nor the arrays past
/// what is used (a holder's copy and a replay's differ there and nowhere the guest or the tree
/// can see: run on srv3, 2026-10-27, `check_inputs`' padding).
fn events_same(a: *const Events, b: *const Events) bool {
    if (a.count != b.count or !std.meta.eql(a.hash, b.hash)) return false;
    if (a.property_count != b.property_count) return false;
    for (a.properties[0..a.property_count], b.properties[0..b.property_count]) |*x, *y| {
        if (x.kind != y.kind or x.hits != y.hits or x.trues != y.trues) return false;
        if (!std.mem.eql(u8, x.name(), y.name()) or !std.mem.eql(u8, x.where(), y.where())) return false;
        if (!std.meta.eql(x.first_failure, y.first_failure)) return false;
    }
    if (!std.meta.eql(a.setup_complete, b.setup_complete) or a.guest_done != b.guest_done) return false;
    const a_last = a.last_event_name[0..a.last_event_name_size];
    if (!std.mem.eql(u8, a_last, b.last_event_name[0..b.last_event_name_size])) return false;
    if (a.output_bytes != b.output_bytes or !std.meta.eql(a.first_vtime_ns, b.first_vtime_ns)) return false;
    if (a.last_vtime_ns != b.last_vtime_ns or a.behavior_count != b.behavior_count) return false;
    for (a.behaviors[0..a.behavior_count], b.behaviors[0..b.behavior_count]) |*x, *y| {
        if (x.hash != y.hash or x.vtime_ns != y.vtime_ns or !std.mem.eql(u8, x.name(), y.name())) return false;
    }
    if (!std.mem.eql(u64, &a.behavior_slots, &b.behavior_slots)) return false;
    if (a.check_used != b.check_used) return false;
    for (a.check_inputs, b.check_inputs) |x, y| {
        if (!std.meta.eql(x, y)) return false;
    }
    return true;
}

fn field_same(comptime name: []const u8, held: *const Snapshot, replayed: *const Snapshot) bool {
    if (comptime std.mem.eql(u8, name, "msrs")) {
        if (held.msrs.count != replayed.msrs.count) return false;
        const count = held.msrs.count;
        for (held.msrs.entries[0..count], replayed.msrs.entries[0..count]) |x, y| {
            if (x.index != y.index) return false;
            if (std.mem.indexOfScalar(u32, &host_time_msrs, x.index) != null) continue;
            if (x.data != y.data) return false;
        }
        return true;
    }
    if (comptime std.mem.eql(u8, name, "vcpu_events")) {
        var a = held.vcpu_events.bytes;
        var b = replayed.vcpu_events.bytes;
        for ([_]*[64]u8{ &a, &b }) |events| {
            if (events[0] == 0 and events[3] == 0) { // Exception neither injected nor pending.
                events[1] = 0;
                events[2] = 0;
                @memset(events[4..8], 0);
            }
            if (events[8] == 0) { // Interrupt not injected.
                events[9] = 0;
                events[10] = 0;
            }
        }
        return std.mem.eql(u8, &a, &b);
    }
    if (comptime std.mem.eql(u8, name, "sregs")) {
        var a = held.sregs;
        var b = replayed.sregs;
        inline for (.{ "ds", "es", "fs", "gs", "ss", "ldt" }) |segment| {
            const x = &@field(a, segment);
            const y = &@field(b, segment);
            if (x.unusable != 0 and y.unusable != 0) { // Only the base counts (FS and GS).
                x.* = segment_unusable(x.base);
                y.* = segment_unusable(y.base);
            }
        }
        return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
    }
    // By value: an optional's padding is whatever its writer left there.
    if (comptime std.mem.eql(u8, name, "modulation")) {
        return std.meta.eql(held.modulation, replayed.modulation);
    }
    if (comptime std.mem.eql(u8, name, "events")) return events_same(&held.events, &replayed.events);
    const a = std.mem.asBytes(&@field(held, name));
    const b = std.mem.asBytes(&@field(replayed, name));
    return std.mem.eql(u8, a, b);
}

fn segment_unusable(base: u64) kvm.Segment {
    var segment = std.mem.zeroes(kvm.Segment);
    segment.base = base;
    segment.unusable = 1;
    return segment;
}

fn memory_equal(held: *const Snapshot, replayed: *const Snapshot) bool {
    const a = held.memory_fd;
    const b = replayed.memory_fd;
    const size = held.memory_size;
    var buffers: [2][1 << 20]u8 = undefined;
    var offset: u64 = 0;
    var pages_differing: u64 = 0;
    var xsave_headers: u64 = 0;
    while (offset < size) : (offset += buffers[0].len) {
        const length = @min(buffers[0].len, size - offset);
        const read_a = linux.pread(a, &buffers[0], length, @intCast(offset));
        const read_b = linux.pread(b, &buffers[1], length, @intCast(offset));
        if (read_a != length or read_b != length) return false;
        if (std.mem.eql(u8, buffers[0][0..length], buffers[1][0..length])) continue;
        // Each page that differs (the first few told): a page of zeros on one side is one a copy
        // missed; contents on both, memory that changed.
        const page = std.heap.page_size_min;
        var at: usize = 0;
        while (at < length) : (at += page) {
            const x = buffers[0][at..][0..page];
            const y = buffers[1][at..][0..page];
            if (std.mem.eql(u8, x, y)) continue;
            if (xsave_bits_only(buffers[0][0..length], buffers[1][0..length], at)) {
                xsave_headers += 1;
                continue;
            }
            pages_differing += 1;
            if (pages_differing > 8) continue;
            const first = std.mem.indexOfDiff(u8, x, y).?;
            std.debug.print("[determinismo] verify: page at {d} differs from byte {d}: {x} against " ++
                "{x}{s}{s}\n", .{
                offset + at,
                first,
                x[first..@min(page, first + 16)],
                y[first..@min(page, first + 16)],
                if (std.mem.allEqual(u8, x, 0)) " (held: all zeros)" else "",
                if (std.mem.allEqual(u8, y, 0)) " (replayed: all zeros)" else "",
            });
            rings_name(held, offset + at + first);
            page_dump(offset + at, x, y);
            mappings_name(held, offset + at);
        }
    }
    if (xsave_headers > 0) std.debug.print("[determinismo] verify: {d} pages differ only in an " ++
        "XSAVE header's x87/SSE in-use bits (the same registers either way)\n", .{xsave_headers});
    if (pages_differing > 0) std.debug.print("[determinismo] verify: {d} pages differ\n", .{pages_differing});
    return pages_differing == 0;
}

/// Whether the page at `at` differs only in the in-use bits of XSAVE headers whose components
/// are in their initial state. XSAVE writes XSTATE_BV from the processor's XINUSE tracking,
/// which may clear a component's bit once it holds its initial values; the host's own FPU
/// saves and restores of the guest (when its thread is preempted) do so at host-chosen moments,
/// so a guest task's saved x87 state reads XSTATE_BV 2 in one run and 3 in another. XRSTOR
/// gives back the same registers either way, and the guest cannot read XINUSE (XGETBV 1 is
/// hidden: cpuid.zig), so the two machines are the same.
fn xsave_bits_only(x: []const u8, y: []const u8, at: usize) bool {
    const page = std.heap.page_size_min;
    const header_size = 64;
    const legacy_size = 512;
    const in_use_bits: u64 = 0b11; // x87, SSE.
    assert(at % page == 0 and at + page <= x.len and x.len == y.len);
    var word = at;
    while (word < at + page) : (word += 8) {
        const a = std.mem.readInt(u64, x[word..][0..8], .little);
        const b = std.mem.readInt(u64, y[word..][0..8], .little);
        if (a == b) continue;
        // XSTATE_BV: a 64-byte aligned header after the 512-byte legacy area, its reserved
        // bytes zero (else XRSTOR faults), differing in in-use bits alone.
        if (word % header_size != 0 or word + header_size > x.len or word < legacy_size) return false;
        if ((a ^ b) & ~in_use_bits != 0) return false;
        if (!std.mem.allEqual(u8, x[word + 8 ..][0 .. header_size - 8], 0)) return false;
        if (!std.mem.allEqual(u8, y[word + 8 ..][0 .. header_size - 8], 0)) return false;
        const legacy = x[word - legacy_size ..][0..legacy_size];
        if (!std.mem.eql(u8, legacy, y[word - legacy_size ..][0..legacy_size])) return false;
        // The components whose bit differs hold their initial values.
        if ((a ^ b) & 0b01 != 0) {
            const control = std.mem.readInt(u16, legacy[0..2], .little);
            if (control != 0x037f or !std.mem.allEqual(u8, legacy[2..24], 0)) return false;
            if (!std.mem.allEqual(u8, legacy[32..160], 0)) return false; // ST0-ST7.
        }
        if ((a ^ b) & 0b10 != 0) {
            const mxcsr = std.mem.readInt(u32, legacy[24..28], .little);
            if (mxcsr != 0x1f80 or !std.mem.allEqual(u8, legacy[160..416], 0)) return false; // XMM0-XMM15.
        }
        word += header_size - 8; // The header's other words are equal (zero) on both.
    }
    return true;
}

test "xsave_bits_only: an x87 in-use bit in an XSAVE header, nothing else" {
    // As found on srv1: a task's XSAVE area at 704 in its page, x87 and SSE initial.
    var held: [2 * std.heap.page_size_min]u8 = @splat(0);
    std.mem.writeInt(u16, held[704..][0..2], 0x037f, .little);
    std.mem.writeInt(u32, held[704 + 24 ..][0..4], 0x1f80, .little);
    std.mem.writeInt(u32, held[704 + 28 ..][0..4], 0xffff, .little);
    held[1216] = 2;
    var replayed = held;
    replayed[1216] = 3;
    try std.testing.expect(xsave_bits_only(&held, &replayed, 0));
    // Not when the x87 state is in use (a register holds a value).
    var used_held = held;
    var used_replayed = replayed;
    used_held[704 + 32] = 1;
    used_replayed[704 + 32] = 1;
    try std.testing.expect(!xsave_bits_only(&used_held, &used_replayed, 0));
    // Not for another bit, nor at an unaligned place, nor for any other byte.
    replayed[1216] = 2 | 4;
    try std.testing.expect(!xsave_bits_only(&held, &replayed, 0));
    replayed[1216] = 2;
    replayed[1217] = 1;
    try std.testing.expect(!xsave_bits_only(&held, &replayed, 0));
    replayed[1217] = 0;
    replayed[1224] = 3;
    try std.testing.expect(!xsave_bits_only(&held, &replayed, 0));
}

/// Says which virtual addresses of the running address space (CR3, 4-level paging) map a guest
/// page, the kernel's direct map left out: a user address names a process's memory.
fn mappings_name(snapshot: *const Snapshot, page_address: u64) void {
    const fd = snapshot.memory_fd;
    const mask: u64 = 0x000f_ffff_ffff_f000;
    var told: u32 = 0;
    const pml4 = snapshot.sregs.cr3 & mask;
    for (0..512) |a| {
        const e4 = entry_read(fd, pml4, a) orelse continue;
        for (0..512) |b| {
            const e3 = entry_read(fd, e4 & mask, b) orelse continue;
            const va3 = canonical((a << 39) | (b << 30));
            if (e3 & 0x80 != 0) { // 1 GiB page.
                const base = e3 & 0x000f_ffff_c000_0000;
                if (page_address >= base and page_address < base + (1 << 30)) {
                    told += mapping_tell(va3 + (page_address - base), told);
                }
                continue;
            }
            for (0..512) |c| {
                const e2 = entry_read(fd, e3 & mask, c) orelse continue;
                const va2 = va3 | (c << 21);
                if (e2 & 0x80 != 0) { // 2 MiB page.
                    const base = e2 & 0x000f_ffff_ffe0_0000;
                    if (page_address >= base and page_address < base + (1 << 21)) {
                        told += mapping_tell(va2 + (page_address - base), told);
                    }
                    continue;
                }
                var table: [512]u64 = undefined;
                const length = std.mem.sliceAsBytes(&table).len;
                if (linux.pread(fd, std.mem.sliceAsBytes(&table).ptr, length, @intCast(e2 & mask)) != length) continue;
                for (table, 0..) |e1, d| {
                    if (e1 & 1 == 0 or e1 & mask != page_address) continue;
                    told += mapping_tell(va2 | (d << 12), told);
                }
            }
        }
    }
    if (told == 0) std.debug.print("[determinismo] verify: no mapping of it but the direct map (cr3 {x})\n", .{
        snapshot.sregs.cr3,
    });
}

fn entry_read(fd: linux.fd_t, table: u64, index: usize) ?u64 {
    var entry: u64 = 0;
    if (linux.pread(fd, std.mem.asBytes(&entry), 8, @intCast(table + index * 8)) != 8) return null;
    if (entry & 1 == 0) return null;
    return entry;
}

fn canonical(address: u64) u64 {
    return if (address & (1 << 47) != 0) address | 0xffff_0000_0000_0000 else address;
}

/// Tells one mapping (up to eight), the kernel's direct map left out; returns how many it told.
fn mapping_tell(address: u64, told: u32) u32 {
    const direct_map_start: u64 = 0xffff_8880_0000_0000;
    const direct_map_end: u64 = 0xffff_c880_0000_0000;
    if (address >= direct_map_start and address < direct_map_end) return 0;
    if (told >= 8) return 0;
    std.debug.print("[determinismo] verify: mapped at {x}{s}\n", .{
        address, if (address < (1 << 47)) " (user space)" else "",
    });
    return 1;
}

/// Writes both sides of a page that differs to /tmp/determinismo-verify-<pid>-<address>-{held,
/// replayed}, to read what it holds.
fn page_dump(address: u64, held: []const u8, replayed: []const u8) void {
    const sides = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "held", .bytes = held },
        .{ .name = "replayed", .bytes = replayed },
    };
    for (sides) |side| {
        var path_buffer: [128]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buffer, "/tmp/determinismo-verify-{d}-{d}-{s}", .{
            linux.getpid(), address, side.name,
        }, 0) catch return;
        const fd = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
        if (linux.errno(fd) != .SUCCESS) return;
        _ = linux.write(@intCast(fd), side.bytes.ptr, side.bytes.len);
        _ = linux.close(@intCast(fd));
    }
    std.debug.print("[determinismo] verify: page written to /tmp/determinismo-verify-{d}-{d}-{{held,replayed}}\n", .{
        linux.getpid(), address,
    });
}

/// Says which disk's virtqueue part holds a guest address, if one does (the parts the VMM and
/// the guest both write).
fn rings_name(snapshot: *const Snapshot, address: u64) void {
    for (snapshot.blocks[0..snapshot.block_count], 0..) |*block, disk| {
        const size: u64 = block.queue_size;
        const parts = [_]struct { name: []const u8, start: u64, length: u64 }{
            .{ .name = "descriptors", .start = block.queue_descriptors, .length = 16 * size },
            .{ .name = "available ring", .start = block.queue_available, .length = 6 + 2 * size },
            .{ .name = "used ring", .start = block.queue_used, .length = 6 + 8 * size },
        };
        for (parts) |part| {
            if (address < part.start or address >= part.start + part.length) continue;
            std.debug.print("[determinismo] verify: that is disk {d}'s {s}, byte {d} (the VMM's " ++
                "indices: available {d}, used {d})\n", .{
                disk, part.name, address - part.start, block.available_index, block.used_index,
            });
        }
    }
}

/// Releases a tree node's memory (never the setup snapshot's), once its branches ran.
fn node_free(snapshot: *const Snapshot, root: *const Snapshot) void {
    if (snapshot == root or snapshot.memory_fd < 0) return;
    close(snapshot.memory_fd);
    @constCast(snapshot).memory_fd = -1;
}

/// Antithesis's rewind: runs the branch to the first event matching --until, then moves the
/// moment `ns` of virtual time before it. Decisions come from the seed (or the replayed tape), so
/// the rerun reaches the earlier moment on the same path.
fn rewind(
    vm: *VM,
    options: *VM.Options,
    snapshot: *const Snapshot,
    exploration: *const Exploration,
    ns: u64,
) !void {
    assert(options.until != null);
    assert(exploration.strategy == null);
    var probe = options.*;
    probe.moment_command = null;
    probe.moment_continue = false;
    own_cpu.take();
    try vm.init_from_snapshot(&probe, snapshot);
    defer vm.deinit();
    if (exploration.replay) |replay| vm.overrides = replay.overrides;
    const outcome = try vm.run_until_exit();
    if (outcome != .moment_reached or !vm.until_hit) {
        std.debug.print("[determinismo] rewind: the condition does not hold in time\n", .{});
        return;
    }
    const at = (try vm.moment()).vtime_ns;
    const target = at -| ns;
    try moment_after_snapshot(snapshot, target);
    std.debug.print("[determinismo] rewind: the condition holds at {d}ns; the moment is {d}ns\n", .{
        at, target,
    });
    options.until = null;
    options.moment_vtime_ns = target;
}

fn events_file(arena: std.mem.Allocator, directory: []const u8, name: []const u8) !linux.fd_t {
    const path = try std.fs.path.join(arena, &.{ directory, name });
    return open_for_writing(arena, path);
}

/// Tells the strategy how the branch ended; returns true when it asks to stop.
const BranchResult = struct { index: u32, outcome: VM.Outcome };

fn strategy_branch_end(strategy: *Strategy, vm: *VM, branch: BranchResult) !bool {
    var failing_buffer: [64][]const u8 = undefined;
    var failing_count: u32 = 0;
    for (vm.events.properties[0..vm.events.property_count]) |*property| {
        if (property.passing()) continue;
        if (failing_count == failing_buffer.len) break;
        failing_buffer[failing_count] = property.name();
        failing_count += 1;
    }
    return strategy.branch_end(.{
        .index = branch.index,
        .outcome = @tagName(branch.outcome),
        .events = vm.events.count,
        .failing = failing_buffer[0..failing_count],
    });
}

fn open_tape(arena: std.mem.Allocator, directory: []const u8, index: u32) !linux.fd_t {
    assert(directory.len > 0);
    const path = try std.fmt.allocPrint(arena, "{s}/branch-{d}.jsonl", .{ directory, index });
    return open_for_writing(arena, path);
}

fn close(fd: linux.fd_t) void {
    assert(fd >= 0);
    _ = linux.close(fd);
}

/// What a timeline depends on besides its decisions: the kernel and initramfs bytes, the
/// command line (scenario included) and the disks. Disks are named by their content (image IDs,
/// system hashes), so their names stand for their bytes; other disks are hashed by path.
fn inputs_hash(options: *const VM.Options, arguments: *const Arguments) u64 {
    var hasher = std.hash.Wyhash.init(0x696e70757473);
    hasher.update(options.kernel);
    if (options.initrd) |initrd| hasher.update(initrd);
    hasher.update(options.cmdline);
    hasher.update(std.mem.asBytes(&options.timer_slack_ns)); // Where timer interrupts land.
    hasher.update(std.mem.asBytes(&options.branch_event)); // What time is made of.
    if (options.cpu_modulation) { // And how fast it runs.
        hasher.update("cpu-modulation");
        hasher.update(std.mem.asBytes(&VM.modulation_version));
    }
    for (arguments.disk_paths[0..arguments.disk_count]) |path| {
        hasher.update(std.fs.path.basename(path));
    }
    // Replays are guaranteed on the same CPU model and determinism ABI only (ARCHITECTURE.md §12).
    hasher.update(std.mem.asBytes(&VM.determinism_abi));
    hasher.update(std.mem.asBytes(&host_cpu_signature()));
    return hasher.final();
}

/// The host CPU's vendor and family/model/stepping (CPUID leaves 0 and 1): retired-branch
/// counts are only known to agree on the same model.
fn host_cpu_signature() [4]u32 {
    const vendor = cpuid_raw(0);
    const signature = cpuid_raw(1);
    return .{ vendor[1], vendor[3], vendor[2], signature[0] };
}

fn cpuid_raw(leaf: u32) [4]u32 {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (@as(u32, 0)),
    );
    return .{ eax, ebx, ecx, edx };
}

/// The seed branches derive theirs from: the exploration's, or for branches from a fork point,
/// one derived from it and the fork, so that every subtree has its own branches.
fn seed_base(exploration: *const Exploration) u64 {
    const fork = exploration.fork orelse return exploration.exploration_seed;
    const key = [3]u64{ exploration.exploration_seed, fork.branch, fork.vtime_ns };
    var hasher = std.hash.Wyhash.init(0x666f726b);
    hasher.update(std.mem.asBytes(&key));
    if (fork.exec) |command| hasher.update(command); // A changed system: other branches.
    return hasher.final();
}

/// Each branch's decisions derive from the exploration seed and the branch index only, so any
/// branch can be replayed alone with --branch.
fn branch_seed(seed: u64, index: u32) u64 {
    const key = [2]u64{ seed, index };
    return std.hash.Wyhash.hash(0x6272616e6368, std.mem.asBytes(&key));
}

fn parse_arguments(arena: std.mem.Allocator, argv: []const [:0]const u8) !Arguments {
    if (argv.len < 2) return error.Usage;
    if (argv.len > arguments_max) return error.Usage;
    var arguments = Arguments{ .command = std.meta.stringToEnum(Command, argv[1]) orelse {
        return error.Usage;
    }, .raw_argv = argv };
    var index: u32 = 2;
    while (index < argv.len) : (index += 1) {
        if (std.mem.eql(u8, argv[index], "--deterministic")) {
            arguments.deterministic = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--continue")) {
            arguments.moment_continue = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--cpu-modulation")) {
            arguments.cpu_modulation_given = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--no-cpu-modulation")) {
            arguments.cpu_modulation_given = false;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--verify-holders")) {
            arguments.verify_holders = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--holders-on-disk")) {
            arguments.holders_on_disk = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--archive") or std.mem.eql(u8, argv[index], "--no-archive")) {
            arguments.archive = std.mem.eql(u8, argv[index], "--archive");
            arguments.archive_given = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--prefer-sometimes") or std.mem.eql(u8, argv[index], "--no-prefer-sometimes")) {
            arguments.prefer_sometimes = std.mem.eql(u8, argv[index], "--prefer-sometimes");
            arguments.prefer_sometimes_given = true;
            continue;
        }
        if (std.mem.eql(u8, argv[index], "--resume")) {
            arguments.resume_run = true;
            continue;
        }
        if (index + 1 == argv.len) return error.Usage;
        try parse_option(arena, &arguments, argv[index], argv[index + 1]);
        index += 1;
    }
    assert(index == argv.len);
    if (arguments.kernel_path.len == 0) return error.Usage;
    if (arguments.memory_mib < memory_mib_min) return error.Usage;
    if (arguments.memory_mib > memory_mib_max) return error.Usage;
    if (arguments.time_budget_ns != null and !arguments.branches_given) {
        arguments.branches = branches_max;
    }
    if (arguments.branches == 0 or arguments.branches > branches_max) return error.Usage;
    if (arguments.command == .explore) arguments.deterministic = true;
    if (!arguments.pipeline_given and jobs_count(&arguments) <= arguments.generation_size) {
        arguments.pipeline = pipeline_depth_few_workers;
    }
    // A command runs at a moment: a virtual time, or the first event matching --until.
    const moment = arguments.moment_vtime_ms != null or arguments.until != null;
    const commands = arguments.moment_command != null or arguments.moment_script_path != null;
    if (commands and !moment) return error.Usage;
    if (arguments.moment_command != null and arguments.moment_script_path != null) {
        return error.Usage;
    }
    if (arguments.rewind_ms != null and arguments.until == null) return error.Usage;
    // A fresh future begins with the commands at the moment (det:reseed first).
    if (arguments.fresh_seed != null and !commands) return error.Usage;
    try branching_resolve(&arguments, moment or commands);
    if (arguments.rewind_ms != null and arguments.strategy_command != null) return error.Usage;
    if (!arguments.generation_given) {
        const base = tree.generation_base;
        const workers = std.mem.alignForward(u32, jobs_count(&arguments), base);
        arguments.generation_size = std.math.clamp(workers, base, tree.generation_max);
    }
    // From a moment: of a branch (`--from-branch`), or of the taped one (`--tape`).
    if (arguments.from_branch != null and arguments.from_vtime_ms == null) return error.Usage;
    if (arguments.from_vtime_ms != null and arguments.from_branch == null and arguments.tape_path == null) {
        return error.Usage;
    }
    // Saving: one replayed branch, saved where it runs (not from a moment of it).
    if ((arguments.save_directory == null) != (arguments.save_at_ms.len == 0)) return error.Usage;
    if (arguments.save_directory != null) {
        const single = arguments.tape_path != null or arguments.branch_only != null;
        if (!single or arguments.from_vtime_ms != null) return error.Usage;
    }
    // From a saved snapshot: flat branches from it (their memory is a file's, which holders'
    // copies cannot see in full), nothing replayed to it.
    if (arguments.from_snapshot != null) {
        const elsewhere = arguments.tape_path != null or arguments.from_branch != null or
            arguments.save_directory != null or arguments.rewind_ms != null;
        if (elsewhere or arguments.branching == .tree) return error.Usage;
    }
    arguments.cpu_modulation = arguments.cpu_modulation_given orelse (arguments.command == .explore);
    arguments.cmdline_given = arguments.cmdline;
    if (arguments.deterministic) {
        const parts = [_][]const u8{ arguments.cmdline, VM.cmdline_deterministic };
        arguments.cmdline = try std.mem.join(arena, " ", &parts);
    }
    assert(arguments.cmdline.len > 0);
    return arguments;
}

fn parse_option(
    arena: std.mem.Allocator,
    arguments: *Arguments,
    flag: []const u8,
    value: []const u8,
) !void {
    assert(flag.len > 0);
    const eql = std.mem.eql;
    if (eql(u8, flag, "--kernel")) {
        arguments.kernel_path = value;
    } else if (eql(u8, flag, "--initrd")) {
        arguments.initrd_path = value;
    } else if (eql(u8, flag, "--memory-mib")) {
        arguments.memory_mib = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--cmdline")) {
        arguments.cmdline = value;
    } else if (eql(u8, flag, "--append")) {
        arguments.cmdline = try std.mem.join(arena, " ", &.{ arguments.cmdline, value });
    } else if (eql(u8, flag, "--disk")) {
        if (arguments.disk_count == VM.disks_max) return error.Usage;
        arguments.disk_paths[arguments.disk_count] = value;
        arguments.disk_count += 1;
    } else if (eql(u8, flag, "--program")) {
        arguments.program_path = value;
    } else if (eql(u8, flag, "--script")) {
        arguments.script_path = value;
    } else if (eql(u8, flag, "--compose")) {
        arguments.compose_path = value;
    } else if (eql(u8, flag, "--kubernetes")) {
        arguments.kubernetes_path = value;
    } else if (eql(u8, flag, "--profile")) {
        arguments.profile = value;
    } else if (eql(u8, flag, "--scenario")) {
        arguments.scenario = value;
    } else if (eql(u8, flag, "--cache")) {
        arguments.cache_directory = value;
    } else if (eql(u8, flag, "--seed")) {
        arguments.seed = try std.fmt.parseInt(u64, value, 0);
    } else if (eql(u8, flag, "--margin-branches")) {
        arguments.margin_branches = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--branch-event")) {
        arguments.branch_event = try std.fmt.parseInt(u64, value, 0);
    } else if (eql(u8, flag, "--timer-slack-us")) {
        arguments.timer_slack_us = try std.fmt.parseInt(u64, value, 10);
    } else if (eql(u8, flag, "--events")) {
        arguments.events_path = value;
    } else if (eql(u8, flag, "--faults-record")) {
        arguments.faults_record_path = value;
    } else if (eql(u8, flag, "--events-dir")) {
        arguments.events_directory = value;
    } else if (eql(u8, flag, "--trace")) {
        arguments.trace_path = value;
    } else if (eql(u8, flag, "--branches")) {
        arguments.branches = try std.fmt.parseInt(u32, value, 10);
        arguments.branches_given = true;
    } else if (eql(u8, flag, "--mutant")) {
        arguments.mutant = value;
    } else if (eql(u8, flag, "--system")) {
        arguments.pinned = value;
    } else if (eql(u8, flag, "--faults")) {
        arguments.faults_added = value;
    } else if (eql(u8, flag, "--no-faults")) {
        arguments.faults_none = value;
    } else if (eql(u8, flag, "--branching")) {
        arguments.branching = std.meta.stringToEnum(@TypeOf(arguments.branching), value) orelse
            return error.Usage;
        arguments.branching_given = true;
    } else if (eql(u8, flag, "--time-budget")) {
        arguments.time_budget_ns = try duration_parse(value);
        arguments.time_budget_text = value;
    } else if (eql(u8, flag, "--timeline-limit")) {
        arguments.timeline_limit_ns = try duration_parse(value);
    } else if (eql(u8, flag, "--retroactive")) {
        if (arguments.retroactive_count == retroactive_max) return error.Usage;
        arguments.retroactive[arguments.retroactive_count] = value;
        arguments.retroactive_count += 1;
    } else if (eql(u8, flag, "--changed")) {
        arguments.changed = value;
    } else if (eql(u8, flag, "--changed-repository")) {
        arguments.changed_repository = value;
    } else if (eql(u8, flag, "--horizon")) {
        arguments.horizon_ns = try duration_parse(value);
        arguments.horizon_text = value;
    } else if (eql(u8, flag, "--pipeline")) {
        const depth = try std.fmt.parseInt(u32, value, 10);
        if (depth == 0 or depth > pipeline_depth_max) return error.Usage;
        arguments.pipeline = depth;
        arguments.pipeline_given = true;
    } else if (eql(u8, flag, "--generation")) {
        const size = try std.fmt.parseInt(u32, value, 10);
        const multiple = size % tree.generation_base == 0;
        if (!multiple or size == 0 or size > tree.generation_max) return error.Usage;
        arguments.generation_size = size;
        arguments.generation_given = true;
    } else if (eql(u8, flag, "--return-branches")) {
        const count = try std.fmt.parseInt(u32, value, 10);
        if (count == 0 or count > tree.generation_base) return error.Usage;
        arguments.return_branches = count;
    } else if (eql(u8, flag, "--timeline")) {
        arguments.timeline_ms = try duration_parse(value) / std.time.ns_per_ms;
        arguments.timeline_text = value;
    } else if (eql(u8, flag, "--branch")) {
        arguments.branch_only = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--from-branch")) {
        arguments.from_branch = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--from-exec")) {
        arguments.from_exec = value;
    } else if (eql(u8, flag, "--from-vtime-ms")) {
        arguments.from_vtime_ms = try std.fmt.parseInt(u64, value, 10);
    } else if (eql(u8, flag, "--save-snapshots")) {
        arguments.save_directory = value;
    } else if (eql(u8, flag, "--save-at-ms")) {
        var moments: std.ArrayList(u64) = .empty;
        var parts = std.mem.tokenizeScalar(u8, value, ',');
        while (parts.next()) |part| try moments.append(arena, try std.fmt.parseInt(u64, part, 10));
        if (moments.items.len == 0 or moments.items.len > saver_zig.moments_max) return error.Usage;
        arguments.save_at_ms = moments.items;
    } else if (eql(u8, flag, "--from-snapshot")) {
        arguments.from_snapshot = value;
    } else if (eql(u8, flag, "--shard")) {
        const slash = std.mem.indexOfScalar(u8, value, '/') orelse return error.Usage;
        arguments.shard_index = try std.fmt.parseInt(u32, value[0..slash], 10);
        arguments.shard_count = try std.fmt.parseInt(u32, value[slash + 1 ..], 10);
        if (arguments.shard_count == 0 or arguments.shard_index >= arguments.shard_count) {
            return error.Usage;
        }
    } else if (eql(u8, flag, "--record")) {
        arguments.record_path = value;
    } else if (eql(u8, flag, "--verify-replays")) {
        arguments.verify_every = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--jobs")) {
        arguments.jobs = try std.fmt.parseInt(u32, value, 10);
    } else if (eql(u8, flag, "--strategy")) {
        arguments.strategy_command = value;
    } else if (eql(u8, flag, "--tape-dir")) {
        arguments.tape_directory = value;
    } else if (eql(u8, flag, "--tape")) {
        arguments.tape_path = value;
    } else if (eql(u8, flag, "--at-vtime-ms")) {
        arguments.moment_vtime_ms = try std.fmt.parseInt(u64, value, 10);
    } else if (eql(u8, flag, "--data")) {
        arguments.data_directory = value;
    } else if (eql(u8, flag, "--run-directory")) {
        arguments.run_directory = value;
    } else if (eql(u8, flag, "--rewind-ms")) {
        arguments.rewind_ms = try std.fmt.parseInt(u64, value, 10);
    } else if (eql(u8, flag, "--exec")) {
        arguments.moment_command = value;
    } else if (eql(u8, flag, "--fresh-seed")) {
        arguments.fresh_seed = try std.fmt.parseInt(u64, value, 10);
    } else if (eql(u8, flag, "--exec-script")) {
        arguments.moment_script_path = value;
    } else if (eql(u8, flag, "--until")) {
        const condition = try arena.create(query.Condition);
        condition.* = try query.parse(arena, value);
        arguments.until = condition;
    } else {
        return error.Usage;
    }
}

fn open_disks(arena: std.mem.Allocator, paths: []const []const u8) ![]const VM.Disk {
    assert(paths.len <= VM.disks_max);
    const disks = try arena.alloc(VM.Disk, paths.len);
    for (paths, disks) |path, *disk| {
        const path_z = try arena.dupeSentinel(u8, path, 0);
        const result = linux.open(path_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(result) != .SUCCESS) {
            std.debug.print("[determinismo] cannot open disk {s}\n", .{path});
            return error.OpenFailed;
        }
        const fd: linux.fd_t = @intCast(result);
        const size = linux.lseek(fd, 0, linux.SEEK.END);
        if (linux.errno(size) != .SUCCESS) return error.DiskSize;
        if (size % 512 != 0) return error.DiskSizeNotSectors;
        disk.* = .{ .fd = fd, .size = size };
    }
    return disks;
}

/// A new results file (truncated once per process; scenarios of one run append to it).
/// `resumed`: a resumed run's file, kept, its last line ended if the interruption cut it; `kept`:
/// kept as it is.
fn open_for_appending(arena: std.mem.Allocator, path: []const u8, mode: enum { fresh, resumed, kept }) !linux.fd_t {
    assert(path.len > 0);
    const path_z = try arena.dupeSentinel(u8, path, 0);
    const flags: linux.O = .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .TRUNC = mode == .fresh,
        .APPEND = true,
        .CLOEXEC = true,
    };
    const result = linux.open(path_z, flags, 0o644);
    if (linux.errno(result) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(result);
    if (mode == .resumed) {
        const size = linux.lseek(fd, 0, linux.SEEK.END);
        if (linux.errno(size) != .SUCCESS) return error.SeekFailed;
        var last: [1]u8 = .{'\n'};
        if (size > 0) _ = linux.pread(fd, &last, 1, @intCast(size - 1));
        if (last[0] != '\n') _ = linux.write(fd, "\n", 1);
    }
    return fd;
}

/// This build of determinismo: a hash of its own executable, read through a small buffer (0
/// when it cannot be read).
fn host_build() u64 {
    const fd = linux.open("/proc/self/exe", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return 0;
    defer _ = linux.close(@intCast(fd));
    var hasher = std.hash.Wyhash.init(0);
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = linux.read(@intCast(fd), &buffer, buffer.len);
        if (linux.errno(count) == .INTR) continue;
        if (linux.errno(count) != .SUCCESS) return 0;
        if (count == 0) break;
        hasher.update(buffer[0..count]);
    }
    return hasher.final();
}

fn hex16(value: u64) [16]u8 {
    var text: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&text, "{x:0>16}", .{value}) catch unreachable;
    return text;
}

/// The scenario a command line runs (`det.scenario=`), if any.
fn scenario_of(cmdline: []const u8) ?[]const u8 {
    var words = std.mem.tokenizeScalar(u8, cmdline, ' ');
    while (words.next()) |word| {
        if (std.mem.startsWith(u8, word, "det.scenario=")) return word["det.scenario=".len..];
    }
    return null;
}

/// A script's non-empty lines as one moment command: separated by NUL bytes, which the VMM runs
/// one after the other.
fn commands_join(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var joined: std.ArrayList(u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOfScalar(u8, line, 0) != null) return error.BadScript;
        if (joined.items.len > 0) try joined.append(arena, 0);
        try joined.appendSlice(arena, line);
    }
    if (joined.items.len == 0) return error.BadScript;
    return joined.items;
}

fn open_for_writing(arena: std.mem.Allocator, path: []const u8) !linux.fd_t {
    assert(path.len > 0);
    const path_z = try arena.dupeSentinel(u8, path, 0);
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const result = linux.open(path_z, flags, 0o644);
    if (linux.errno(result) != .SUCCESS) return error.OpenFailed;
    assert(result <= std.math.maxInt(i32));
    return @intCast(result);
}

fn monotonic_ns() u64 {
    var time: linux.timespec = undefined;
    const result = linux.clock_gettime(.MONOTONIC, &time);
    assert(linux.errno(result) == .SUCCESS);
    return @as(u64, @intCast(time.sec)) * std.time.ns_per_s + @as(u64, @intCast(time.nsec));
}

test branch_seed {
    try std.testing.expect(branch_seed(1, 0) != branch_seed(1, 1));
    try std.testing.expectEqual(branch_seed(7, 3), branch_seed(7, 3));
}

test {
    _ = @import("kvm.zig");
    _ = @import("rtc.zig");
    _ = @import("pit.zig");
    _ = @import("serial.zig");
    _ = @import("vm.zig");
    _ = @import("cpuid.zig");
    _ = @import("decisions.zig");
    _ = @import("events.zig");
    _ = @import("tape.zig");
    _ = @import("fd_pass.zig");
    _ = @import("virtio_block.zig");
    _ = @import("prepare.zig");
    _ = @import("serve.zig");
    _ = @import("runs.zig");
    _ = @import("mcp.zig");
    _ = @import("merge.zig");
    _ = @import("script.zig");
    _ = @import("tla.zig");
    _ = @import("guest_memory.zig");
    _ = @import("query.zig");
    _ = @import("runs_cli.zig");
    _ = @import("duckdb.zig");
    _ = @import("store.zig");
    _ = @import("cpus.zig");
    _ = @import("holders.zig");
    _ = @import("checks.zig");
    _ = @import("causality.zig");
    _ = @import("mutate.zig");
    _ = @import("changed.zig");
    _ = @import("lines.zig");
    _ = @import("extract.zig");
    _ = @import("event_sets.zig");
    _ = @import("profile.zig");
    _ = @import("regex.zig");
    _ = @import("compose.zig");
    _ = @import("kubernetes.zig");
    _ = @import("yaml.zig");
    _ = @import("report.zig");
    _ = @import("snapshot.zig");
}

test "a finished timeline's summary is read whole even when its generation has no slot left" {
    var pipe: [2]linux.fd_t = undefined;
    try std.testing.expect(linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) == .SUCCESS);
    const pid = linux.fork();
    if (pid == 0) {
        // A worker: its results, one summary (larger than a pipe holds), then it exits.
        _ = linux.close(pipe[0]);
        const results = std.heap.page_allocator.create(report.Multiverse) catch linux.exit_group(1);
        results.* = .{};
        write_all(pipe[1], std.mem.asBytes(results));
        const count: u32 = 1;
        write_all(pipe[1], std.mem.asBytes(&count));
        const summary = std.heap.page_allocator.create(Summary) catch linux.exit_group(1);
        @memset(std.mem.asBytes(summary), 0);
        write_all(pipe[1], std.mem.asBytes(summary));
        linux.exit_group(0);
    }
    _ = linux.close(pipe[1]);
    // The pipe's read end held elsewhere too, as the explorer's other forks hold it: its close
    // alone never ends the worker's write.
    const held: linux.fd_t = @intCast(linux.dup(pipe[0]));
    defer _ = linux.close(held);
    const multiverse = try std.testing.allocator.create(report.Multiverse);
    defer std.testing.allocator.destroy(multiverse);
    multiverse.* = .{};
    const items = try std.testing.allocator.alloc(Summary, 1);
    defer std.testing.allocator.free(items);
    var summaries: Summaries = .{ .items = items, .count = 1 }; // Full: past the budget.
    const running = [_]Running{.{ .pid = @intCast(pid), .results = pipe[0], .place = undefined, .index = 0, .start_ns = 0 }};
    const finished = (try timeline_wait(&running, multiverse, &summaries, -1)).?;
    try std.testing.expectEqual(@as(usize, 0), finished.at);
    try std.testing.expectEqual(@as(u32, 1), summaries.count);
}
