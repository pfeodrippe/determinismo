# Plan

What is being built next, in order. Done work leaves this file (the parity map in
[ANTITHESIS.md](ANTITHESIS.md) and the commit log keep the record). Each item is done when `zig
build e2e` tests it.

## Pluggable everything

The rule: whatever decides *what to look at, where to go, or what it means* is a plugin (any
binary on standard input and output, `tcp://` to a process anywhere, the Clojure host reloaded
live over nREPL), and everything is inspectable and drivable over the HTTP API (a Clojure client,
scripts, agents over MCP). Only what makes a timeline deterministic stays in the core: plugins
choose, the core records their choices (tapes), and a replay needs no plugin.

Pluggable now:
- Exploration strategies: decisions inside timelines and where the tree returns (`returns`,
  with reasons); `--strategy <cmd> | tcp://`, uploads (`@name`), plugins/clojure/strategies.clj.
- Faults: which kinds each node allows (`--faults`, `--no-faults`), and when and which, through
  the strategy's decisions.
- Workloads and properties: test programs in any language (SDKs: Zig, C, Python, Java, Clojure,
  Go via Antithesis's), host checks (`<program> check`, Elle).
- Reading results: the HTTP API (query, event sets, SQL on DuckDB), notebooks (JavaScript, Clojure
  over nREPL), MCP for agents; `serve --archive "<cmd>"` for long-term storage.

To make pluggable (none changes what a timeline does, only what is looked at or chosen):
1. **Causality planners** (in progress): which moments to analyze and how many futures each;
   built in (even moments, then halfway inside jumps) or a plugin that sees every point, the
   failure and the run's API. Clojure planners: bisect, faults (moments either side of each
   fault inside a jump: which fault decided it), dense. Every parameter from the page too.
2. **Causality's verdict**: what counts as "the bug happened" in a future (the property failing
   by default; any query condition, or a plugin judging a future's events).
   Causality's explanation, done (2026-10-29): `--explain-exec '<command>'` (serve:
   `explain_exec`) ends the analysis with futures from a quarter, half and three quarters into
   the narrowest jump to failure, the command (one that turns the system's logs up) run at
   their moment and the timeline's own randomness after it, each one's events kept and whether
   it failed (`{"explained": [...]}`; e2e `until`). By hand it explained Redpanda's open
   transaction (run 177: `tx` at trace from 116 s). The UI's analysis view takes the command
   ("explain with") and lists the futures, each one's logs filtered by a text (serve's
   `/causality/<n>/explained/<k>/logs`); checked in Chrome on run 179.
3. **Behaviors and cells**: what counts as a new behavior (events.zig's keys) and the
   Go-Explore archive's cell and score: today fixed in Zig; a plugin mapping a timeline's
   summary to cells and weights, offline (between generations), so timelines pay nothing.
4. **Fault schedules (nemeses)**: Jepsen-style schedules ("partition the leader after an
   election, heal after 5 s") as a plugin over the decision hook, with reasons.
5. **Horizons and timeline lengths per return**: the strategy's `returns` may say how long the
   branch runs.
6. **Run scheduling in serve**: which runs start, repeats, admission (memory), as API calls a
   script makes (the benchmark harness in Clojure over the API, not only bench/explore.py).
7. **Snapshot policy**: which failures get snapshotted, how densely, kept how long, archived
   where: serve's defaults, a hook to override.
8. **Triage**: findings (new / ongoing / resolved), rarity, grouping of failures by cause: a
   plugin over the API producing the report the page shows.
9. **A Clojure API client** (plugins/clojure/api.clj): runs, timelines, properties, query, event
   sets, replays, causality, snapshots, stop and start, from any REPL or program.

Stays in the core (determinism): the VMM (vCPU runs, virtual time and its TSC, timers, interrupt
delivery, devices, CPUID and MSR filtering, branch counting), the decision stream's mechanics
(seed and pulls; plugins only override values, which tapes record), fault mechanics (how a
partition, pause or crash is applied in the guest), snapshots and their restore, tapes and
event hashing, the guest module.

## Open issues (2026-10-29)

- Assertions guide the tree (2026-10-29, on by default, Antithesis's sometimes-assertions page):
  a `sometimes` or `reachable` made true weighs 4 times another new behavior in a timeline's
  novelty, its moment is the frontier's return point ahead of rarer output lines, and its
  archive cell ranks as one 4 times rarer and keeps up to 4 timelines' moments that reached it,
  returns going to each in turn (the same rare state from different pasts, as Antithesis
  restarts tests wherever an assertion is hit, not only where it first was). Antithesis SDK assertions are behaviors now (they
  were not: a Compose project's own `sometimes` never guided the tree). Rare states marked for
  it: det-faults marks the aimed node moving (a leader or primary changed, for every SDK's
  `fault_aim`; computed, so no system is failed for never moving it), and the SQL driver a
  driver connecting again after refusals. `--no-prefer-sometimes`
  (serve: `prefer_sometimes: false`) for the benchmark: queued first in the hunt list, the Raft
  POC (its Antithesis SDK assertions now behaviors) 20 minutes each way, seed 1, timelines to
  each of its known bugs. A horizon stays off: measured, it hurt (Galera, below).

- Redpanda's second finding (run 177's timeline 56): a partition leader restarted from a local
  snapshot never arms `rm_stm`'s auto-abort timer for the open transactions the snapshot holds
  (only a fence batch or a sweep arms it), so with the coordinator's abort given up, the
  transaction stays open and the last stable offset stuck. Causality's explanation futures (the
  profile's `explain` command, the `tx` logger at trace inside the jump) showed it; one of
  them is its own control (partitions with new transactions after the restart sweep, the one
  without never does). Present in `dev`; recorded in examples/kafka's README.

- The Elle service ran every request on its HTTP server's one thread: a long check kept
  `/version` from answering within 2 s, and the next check replaced the service (`podman rm
  -f`), closing the histories it was checking ("host checks run to completion" failed in Group
  Replication's run 200, timeline 151). Fixed: a pool of 4 threads, and the SDK never replaces a
  service that is busy (only one absent or of another version), checking again a history whose
  connection closed. Timeline 151 replayed to judge its history.

- Faults aimed at a node (2026-10-29): `sdk.fault_aim(name)` in every SDK (`det-faults aim`
  underneath for those that run commands): half the injector's draws then pick among the
  faults involving that node, each a named decision. Workloads aim at the node that matters:
  the primary (SQL's `node_names`: Patroni, Group Replication; MongoDB), the transaction
  coordinator (Kafka, Redpanda), the leader (etcd, rqlite, ZooKeeper, ClickHouse Keeper, the NATS
  stream's, PD's for TiDB and SurrealDB). The selftest's `aim` check measures it. Next: whether
  aimed hunts find what unaimed ones did, sooner: Redpanda's re-hunt (seed 1, 2 h, first in the
  queue) against run 177 without aims, whose first failures came at its 27th timeline (no
  transaction stays open), 80th (every committed write read) and 151st (Elle) of 185.

- Per-node clock skew (2026-10-29): every node in a time namespace of its own, the guest
  kernel's patch 0005 giving namespaces a realtime offset changeable while tasks run (the vDSO,
  the syscalls, absolute deadlines: clock_nanosleep, timers, timerfd, futexes), and the
  `clock_skew` fault (one node's CLOCK_REALTIME ahead or behind, 1 ms up to the node's
  `clock_skew_ms_max`; one in four strobing). The selftest's `inject` check measures it (a
  5 s skew back, absolute sleeps and futex waits keeping their time, the skew gone at the
  fault's end) and passed on the patched kernel. On in Cassandra, ScyllaDB, MongoDB, etcd,
  TiDB, SurrealDB, rqlite, and below the documented maximum offsets in YugabyteDB's current
  release (400 ms), CockroachDB (300 ms) and Ignite (400 ms). Next: the full e2e suite on the
  deployed kernel (when the reserved cores are idle).

- Redpanda: timeline 56 of run 177, a transaction its coordinator knew and was aborting while a
  partition had no leader, open for good; trace futures from 745 to 760 s all passed (a narrow
  window): causality, then a future inside its jump with the tx logger up.
- e2e under load: coverage (synced workers), parallel, script, ending and ui's causality analysis
  fail when other units share the reserved cores (2026-10-29's suite beside smokes); coverage
  passed alone, the others to run alone too.
- Hunts: Galera's run 196 done (README); MySQL Group Replication (run 200) running, then Galera
  jepsen-recovered, RabbitMQ Khepri ra-synced, the hyperthreads run, then srv3's
  ~/hunts/next-list.txt (read when its turn comes): Cassandra 6's Accord, Ignite, ScyllaDB's
  current release, SurrealDB, Kafka share groups, YugabyteDB's current release, Cassandra 5,
  NATS batches, rqlite, ClickHouse Keeper, Redpanda and Patroni again (with clock skews),
  ZooKeeper known, YugabyteDB outages, OpenSearch; smokes, one after another: Cassandra 5.0.9 (ready on its storage port since its first
  smoke), its Accord scenario (6.0-alpha2), ClickHouse Keeper, rqlite (`snapshots`), Apache
  Ignite 3.1, SurrealDB 3.3 on TiKV, Kafka 4.4's share groups: new systems and features Jepsen
  never analyzed (docs/JEPSEN.md).

- Causality: planner protocol and Clojure planners (in progress); refinement deeper (up to six
  rounds, 40 moments, jumps narrowed to 20 ms); job pid files so a serve restart keeps a running
  analysis (built, not deployed); serve snapshotting a failure as soon as it is found.
- Disk snapshots (delta, `--save-snapshots`, `--from-snapshot`): the `saved` e2e check passed
  (srv3, 2026-10-29: two snapshots along a branch, the futures loaded from each the ones a replay
  forks there); long-term archive later.
- e2e: `saved` and `until` (causality's output, extract, inject, rewind) passed on srv3
  (2026-10-29); `ui` (Playwright, tests/ui, 8 of 8) too.
- Kafka (2026-10-28): the hunts hardly ran the workload. Run 56 committed in 9 of 508
  timelines and passed (a sometimes needs one): brokers killed every two seconds never came
  back. KAFKA-17754 had no way in either (it needs an EndTxn delayed on its way to the
  coordinator, and the client node's links were never faulted). Fixed: `Faults.runner_links`
  (client links faulted, the drivers' calls spared), bursts with quiet stretches up to 30 s, a
  producer started in setup, the final read once every partition is stable (new property: no
  transaction stays open once faults stop), and runs flag a sometimes held in under 5% of the
  timelines ("rarely true"). A default timeline now commits ~460 transactions. Found on the
  way, in the platform: isolation cut a node from its own address (fixed: the address on lo),
  which stalled Kafka's commit markers and made a false "torn transactions". Then, in the
  second timeline of a smoke test: KAFKA-20979 rediscovered blind (a power loss after a clean
  shutdown leaves a zero-filled time index; retention deleted 30 committed transactions).
  Hunt run 67 (default, seed 17): commits in 50 of its first 87 timelines; Elle's failures
  were G0 alone (Jepsen's known Kafka behavior), now `allowed` in the check and reported apart.
  The `coverage` profile (Java 25, the agent on the transaction path) hunted next on the same
  seed and budget (run 68): in its timeline 125 a transaction hung for good, KAFKA-18137 met
  blind (fixed in 4.0.0; a coordinator elected and resigned at different epochs as it
  restarted installed an empty load and gave the transactional id a new producer id). Next:
  the `kafka-4.4-coverage` profile (Kafka 4.4.0, the latest release, transactions v2, the
  coverage agent; `kafka-4.4` without), whose bugs would
  be new. Rust SDK coverage lines: its coverage.c has the C SDK's
  lookup, copied (a packaged crate cannot include sdk/c); a Rust maze in
  tests/antithesis-compat/rust (release builds need `debug = true`, `strip = false`).
- A false data loss, a platform bug (2026-10-28): a durable crash with two threads at
  durability points crashed the node twice; the second failed after switching its disk to
  drop writes and left it so, and the next crash lost everything written since (Kafka run 67,
  timeline 111: 92 committed transactions). Fixed: one crash a fault, the table restored on
  any failure, no crash of a node already down; selftest durability covers two durability
  points at once. Runs with NotADurableDisk failures (55, 56, 58, 62, 64, 65, 67): their
  durability failures are not evidence. Run 55's lost and torn Kafka transactions, put down
  to hyperthreads, may be this instead.
- Faults leave nothing behind (2026-10-28): when the injector stops, every node is checked as
  the kernel has it (cgroup frozen, a thread stopped, its disk dropping writes) and the
  injector's own state (a durability point armed, links down): built-in property "faults leave
  nothing behind once they stop". Two false findings came from effects outliving faults today.
- Worker utilization (2026-10-28): Kafka hunt run 67's 16 workers ran 8.8 timelines at once by
  their wall times; trees now integrate timelines running over the loop's wall time and print,
  record (summary: workers, at_once, memory_wait_ns) and show it live (status.json, the UI's
  Utilization). Measured (2026-10-29): 15.0 to 15.4 of 16 workers busy in runs 173 (Kafka
  4.4), 176 (OpenSearch), 177 (Redpanda) and 178 (ZooKeeper): nothing left to act on.
- Reserved cores need memory (2026-10-28): a Kafka hunt held all but 9 GiB of srv3's 125
  (VMs and holders), so the checks on the reserved cores ran one VM at a time (e2e parallel
  failed at 1.0 timelines at once; ui's causality analysis did not finish in 15 minutes).
  Runs now leave 6 GiB per reserved core free (DETERMINISMO_SESSIONS_MEMORY_MIB, set by
  serve.sh), holders included, but only while a session's VM waits for memory (it holds the
  pool's `memory-priority` shared): held back always, it would have kept holders from being
  made (run 67 made none in 180 of its 207 timelines, at 15 GB available of the 16 they want,
  and replayed its returns' nodes instead, minutes each, while most workers waited); branch lines show `memory_wait=` when a VM waited for memory,
  and the parallel check skips, saying so, when its VMs mostly waited. The other way round
  too (2026-10-28): the sessions had a CPU cap and no memory cap. They run with
  `MemoryMax=24G` now, and determinismo admits VMs and makes holders by its cgroup's limit
  (total and available the lesser of the host's and the limit's; the reserve an eighth of a
  smaller limit), so a check never grows into the hunt's memory. Their e2e scratch is on disk
  (`~/.cache/determinismo-e2e`), not in /tmp's tmpfs, where failed checks' files had held
  16 GB of memory.
- verify: a replay that could not start said "replayed nothing" (the 17:05 hyperthreads
  experiment: 64 refused, TapeInputsDiffer, its script missing serve's --cpu-modulation and
  pin). It prints how the replay ended now, and `verify --run <dir>` takes a run's options as
  serve's replays do; `--timeline <n>` replays the ones named (MCP: `verify`).
- A divergence under investigation (2026-10-28): Kafka run 68's timeline 98 ("the fault
  injector never stalls": a 34 s stall) does not replay; two fresh replays part from its tape at
  the same checkpoint (event 334,144), 10 s after its branch point (from timeline 30 at
  1,375.86 s), while kafka-1 recovers its logs after a power loss. Its generation's nodes were
  all made from in-memory holders; a replay makes its node by replaying from the start. Queued:
  12 of run 68's timelines replayed (`verify`), and a 32-timeline Kafka run checking every
  holder's node against a replay's (`--verify-holders`); then timeline 98 replayed again with
  the divergence report (its last 64 events, to compare with the run's).
- srv3 (2026-10-28, day), found and fixed:
  - Language properties (a Go panic, ...) failed timelines but no run's properties, stats, UI or
    queries showed them (Dgraph run 31: 159 timelines failing "no panics (Go)", every property
    listed passing): the guest's output forwarder now asserts them, as events.
  - Serve refused to replay runs started from a shell: their machine.json kept the command line
    with --deterministic's part, which the replay added again (other inputs). Kept as given now;
    17 runs repaired. `runs exec` takes `--until` and `--rewind-ms`. Quint run 32's same-seed
    failure, replayed so: quint-co/quint#2036 (known); run 25's "internal error" was the
    workload taking a specification's trace for a JavaScript stack frame.
  - Dgraph run 31's explorer died an hour into its two, without a trace (no OOM kill, nothing in
    its output). Not explained: serve now keeps how an explorer ended (`runs/<id>/exit`), a
    holder pid of 0 or less is never signalled (kill(0) is the explorer's own group), and a
    worker's summary counts only once read whole. Dgraph to explore again.
  - Memory admission counts a tree's snapshot nodes (`nodes-<pid>` claims, up to half the
    host per run); holders say when memory stops them.
  - CPU modulation is on by default, as Antithesis's with faults (`--no-cpu-modulation`).
  - The e2e checks that stop in bank's violating timeline find it (the TLB patch made the old
    one keep its money).
  - Kubernetes manifests imported as Antithesis runs them (`--kubernetes`): a single-node K3s,
    images from the host, kapp's readiness as the setup, templates run in their pods, faults on
    single pods (freeze, kill, cut off, degrade). Next: partitions between two given pods.
  - Branches from a moment step by step (advanced multiverse debugging): commands run or in the
    background, waits, wait-untils; HTTP replay `steps`, MCP, the notebook's branch functions.
    Next: a branch's future with fresh randomness (fork's), and containers in notebook cells.
  - The serve self-test (controller) failed 7 of 16: three serve bugs under concurrency and
    restarts (fixed), and its fake explorer out of date.
  - The Raft POC benchmark (20 minutes a seed, seeds 1 and 2, the whole host): the default tree
    found the leadership-transfer deadlock at 67 s and 73 s, the archive at 906 s and 236 s;
    neither found the other three in that time. Every run counts finds from moments apart now
    (`found_from_moment`).
- srv3 (2026-10-27, night), found and fixed:
  - Nodes ran with the kernel's 1024 open files: YugabyteDB's tablet servers aborted on "Too many
    open files" in every timeline (run 1's 39 failures were that). det-init now gives Docker's
    1048576. Earlier hunts (Kafka, Dgraph) ran under the same limit: their findings to recheck.
  - A crash fails "no process crashes: <process>": a known crash (YugabyteDB's YSQL backends on
    exit) no longer hides another.
  - The tree's scheduler is a pull queue: a generation is the next `size` timelines to finish,
    recorded and judged again on resume; cores were busy 78% (12.5 of 16) with fixed index
    generations, 100% since. The tree's shape now follows finishing order; every timeline still
    replays exactly from its seed and path.
  - Branch points: a run from a node signals det-faults (det-agent's det:branch), which ends the
    pacing's quiet stretch and draws a fault at once, aimed at the node behind the snapshot's
    newest behavior (a fault involving it, when any does: `fault.branch_aim`). Every run from a
    node has it (timelines, node replays, chained replays alike); causality's futures do not.
  - Busy guests: 19% of a YugabyteDB VM's time was outside the guest (perf kvm, srv3, 15 s):
    single-steps 4.76M x 0.31 us = 1.50 s; port I/O 226k x 3.13 us = 0.71 s (userspace PIT and
    port 0x80 ~5 us, the in-kernel PIC ~1 us); RDTSC 704k x 0.52 us = 0.37 s; the rest 0.23 s.
    Each exit is as cheap as VMX allows (a bhyve-like hypervisor pays the same); their number
    is the cost. Hard stops (a timer no clock read caught within the slack) were ~920/s, each
    ~440 single-steps (the 128-branch margin). The guest took ~5,400 timer interrupts a second
    (hrtimers), each two PIT writes and a stop. Done: `io_delay=none` (a third of the I/O exits
    were the port 0x80 delay); the clock state read once per exit (several ioctls each).
    Measured (a fresh timeline each, same seed): slack 1 ms 0.99x vs 0.62x at 100 us (now the
    default); `highres=off` 0.87x; the margin stays 128 (skid up to 65 branches: margin 64
    overshot once, 32 4,172 times, and an overshoot is another timeline). Done too: the PIT
    count in one 16-bit write (guest kernel patch 0003, `det_pit_word=1`): one exit per timer
    reprogram, not two.
  - First failures on disk at once: the explorer's ladder (the timeline's holders), or, when no
    holders could be made (a big system's memory), serve's save-only replay on one CPU; an
    analysis from the page starts from them. Analyzing every first failure automatically, beside
    the hunt, is `serve --failure-analysis`, off by default (four cores of the hunt for curves
    nobody may look at); our hosts leave it off.
  - Deadlock found by the tree e2e on a pool of two CPUs: the explorer waited for a holder that
    waited for a CPU, both CPUs held by a node maker and a holder blocked writing answers (1.3 MB
    snapshots) the explorer had not read yet. Makers and holders now give their CPU back before
    answering. Checks and benchmarks run on the run cores (`systemd-run -p AllowedCPUs=...`)
    when no hunt does: a session's pool is two CPUs.
  - Failure ladders: the first failing timeline of each property has its holders written to disk
    (b<timeline>-<ms>, each diffed against the one before) as it is judged; causality starts
    from them (its first moments snap to saved ones).
  - Causality: the failure's moment from the run's events (no `--until` replay, which never saw
    host checks' failures, Elle's), CPU priority over hunts, futures from one coarse-first
    queue over every moment, each updating its moment's point as it lands. Elle's history now
    records each operation's time, and its failures say when their anomalies formed
    (`window_ns`): causality takes the window's end as the failure's moment.
  - e2e: every check names the conditions it failed and keeps its outputs; it copies the guest
    at its start (a deploy rewrote ~/guest under a running suite).
  - Determinism, YugabyteDB (2026-10-28): run 18's in-run replays parted in 3 of 6 timelines
    (run 1's in 2 of 3), with every clock hazard at zero. Timeline 95 replayed exactly on the
    reserved cores (2 of 2) and parted 1 in 3 beside the hunt, always at event 18432. The full
    RDTSC log (`DETERMINISMO_RDTSC_LOG_CAP`) put it between two `sched_clock` reads right after
    an event write (442 branches, or 3,337), and the instruction trace of that interval
    (`DETERMINISMO_ITRACE_AT`) showed it: returning from the syscall, the recorded run's user
    instruction faulted and waited for the mmap lock, held by another thread in the middle of
    munmap or mprotect; the parted replay's went through a TLB entry that thread had changed
    but not flushed yet. x86 Linux flushes when such an operation is done and may be preempted
    before; whether another thread of the process still finds the entry depends on what the
    host's activity evicted. Guest kernel patch 0004: every switch into an address space
    flushes the TLB (the same process's threads included): no measurable cost (fresh
    timelines beside the hunt: 0.89x virtual per wall second, 0.84x before). Run 19 (seed 8,
    every timeline replayed beside run 18's hunt): every replay the same.
  - Hyperthreads (2026-10-28): with the guest's TLB fixes, VMs on a core's two hyperthreads
    replay exactly (four replays on CPUs 0, 18, 1 and 19 of a 39 s and a 382 s YugabyteDB
    timeline: every one the same through its last tape checkpoint). They had been excluded for
    Kafka divergences that were, by the evidence, the same guest TLB dependence (150-branch
    spurious faults). Kafka too, where the divergence was first seen: three timelines, four
    replays each on CPUs 0, 18, 1 and 19, every one the same; Dgraph's hunt with them, its
    first 7 replays the same. A VM with a busy sibling runs at about 0.7x, a core does about
    1.4x. But twice the VMs outgrew memory: admission claims each VM's guest, not its in-run
    snapshots and holders, and from 40 minutes in the host ran out (53 Dgraph timelines
    killed). Off by default again (`--siblings on`, DETERMINISMO_SMT=1) until admission
    counts snapshots and holders. Next: that accounting.
  - Fault injector deadlock (2026-10-28, Kafka run 24, 1 timeline of 68): no fault for the
    last 69 s of timeline 63, a crashed node never started again, an isolation never ended.
    Found by replaying the timeline to 60 s and dumping det-faults' threads and /proc/locks:
    the durability listener waited for the device-mapper flock while holding the durability
    lock the main loop waited for; the flock's holder was a node's output forwarder, forked
    from the main thread while the listener held it. Fixed (explicit unlock; forwarders close
    what they inherited). Also from that run: crash properties are named by process now.
  - Saving a ladder by replay: 9 moments of a YugabyteDB timeline took 25 minutes on an earlier
    build; with the exit fixes, run 18 (srv3) saved 10 moments over 85 virtual seconds in 88 s,
    the replay's own pace. Open: a ladder once stopped after 2 of 9 moments (timeline 5 of run
    2, an earlier build).
- Hosts (2026-10-27, night): srv2 was cancelled by mistake in Robot (its runs and ~/findings
  gone with it), srv1 hung and is being cancelled; a W-2295 twin of srv2 from the auction is
  next (infra/host/setup.sh builds its guest kernel itself). Waiting on it: the holders' memory
  fix (a holder goes by itself under 8 GB available: 18 YugabyteDB timelines and their holders
  filled srv2) and its tree e2e, then the hunt queue (YugabyteDB, Kafka, Dgraph).
- Determinism (2026-10-27). Kafka's timelines (JVMs) did not replay. Found and fixed, in turn:
  VMs on a core's two hyperthreads perturb each other's branch counters (one VM per core);
  speculative page walks set Accessed bits the guest branched on (guest patch 0001); x86 Linux
  upgrades a page's access without a TLB flush, so a later write took a spurious fault or not as
  the host's activity left the TLB (guest patch 0002, found with the KVM instruction trace).
  Under 8 busy processes beside six runs of a Kafka timeline: 12 of 12 the same through 30 s.
  Tools: the KVM patch's RDTSC log (--trace: where two runs part, between which RDTSCs) and its
  instruction trace (DETERMINISMO_ITRACE_AT: which instruction), the clock's hazard counters on
  every divergence, snapshot-diff, `determinismo verify` (a run's sample replayed beside other
  work), and every run with a record and tapes now replays every 16th timeline as it goes
  ("timelines replay to their recorded history"): hunts are determinism tests on real loads.
- Benchmarks (bench/explore.py on srv2, Raft POC, 40 minutes a seed, tree / archive / short
  branches): seed 1's safety bugs came from one fresh timeline (4653) in every variant; seed 2:
  the deadlock in all, and the log divergence only in the short-branch variant, from a moment
  two deep (timeline 2508, 582 s): the first find of a strategy's own. bench/explore.py now
  counts finds by origin. These runs used sibling threads (above): rerun after the fix.
- Clojure strategies: their own archive (returns to any earlier timeline), inspectability.
- Flecs master: the readonly-table assert in flecs_table_ensure (30 of 32 timelines under
  determinismo, not natively), two model disagreements, the abort hook bypassed.
- Check: host checks' inputs (Events.check_buffer) in a tree's branches from in-run snapshots
  (the buffer travels by pointer, not by content).
- ScyllaDB 4.2.rc3 (examples/scylla): #7258 rediscovered blind; the zero pending_delete log
  was determinismo's power loss (discards after the shutdown), fixed in 7c21695.
- Hunting harness, found by running real systems (2026-10-27): power losses discarded blocks
  after the crash (writes now dropped once power is lost); a node start failed on a peer killed
  but not reaped (ESRCH: now skipped); cores filled /run (now 512 MB in all and a quarter of free
  space); process kills took supervising shells and start-script helpers, nodes down for good
  (`process_kill_names`); a fault every 10-300 ms left systems that recover in seconds (Dgraph,
  YugabyteDB) no window to work in (a scenario's `pacing`); the in-run verifier now finishes its
  pending replays at a run's end (short runs are checked too) and replays a copy of the program
  (a rebuild mid-hunt no longer reads as nondeterminism); serve shows its verdict.
- Dgraph v1.1.1 (examples/dgraph): an alpha restarting panics on a tablet move, found blind in
  the first run (README); hunting Jepsen's #4534/#4543 next. The tablet mover counted every
  move a failure (zero answers a move in plain text, not JSON): fixed; moves did happen.
- Runs (2026-10-27, evening): every exploration is a run of the host's store (~/.determinismo,
  src/runs.zig), serve shows them all; a tree's live status (status.json: running, done,
  failing, generation), progress lines every 30 s, the page's Output section; times and pace
  on the run page; the page in one wave of requests. A run without --jobs used ONE core: the
  explorer read its CPUs pinned to the one it booted on (cpus.zig keeps the given mask now;
  e2e parallel checks the cores stay busy): also why causality's e2e failed all day.
- srv2 hunts: one at a time, trees, no --jobs (the pool is elastic), infra/host/hunt-queue.sh
  rotating when discovery plateaus (an hour in, nothing new over the last 100 timelines or the
  last quarter). Dgraph (run 111) at ~4 timelines/min on 18 cores; then YugabyteDB, Kafka.
- YugabyteDB 1.3.1 (examples/yugabyte): YSQL backends crash on exit (libcds in
  ThreadPool::Shutdown) and restart their node's backends; with paced faults and kills of
  yb-master and yb-tserver only, transactions get through: hunting #2125.
- Kafka 3.8.0: lost acknowledged writes under correlated power losses are its design (no fsync);
  the default profile flushes every write, `unflushed` keeps Kafka's. KAFKA-17754 not found in
  177 flushed timelines.
- Resume for tree runs (serve's default): record each timeline's summary; on resume, judge the
  recorded generations again from them (no node making), and make nodes, by replay along the
  path, only for timelines still to run.
- Correlated power losses (2026-10-28): `outage`, several nodes losing power at once (all, or
  a group of two or more), beside one node's crash. Galera's run 58 could not lose a committed
  transaction without it: Jepsen's loss needs the nodes to crash together. Galera's hunt again
  with it next. Kill outages too (2026-10-28), for nodes that allow restarts but not power
  losses: YugabyteDB's hunt (run 77) had no outage at all, and Jepsen's #2125 came from every
  master killed together.
- Known crashes (2026-10-28): a node may declare processes whose crashes the system is known to
  have (`crashes_known`): such a crash is counted ("a process crash the system is known to
  have: <name>", a sometimes), not failed. YugabyteDB 1.3.1's YSQL backends crash on their way
  out in every timeline, so run 77's 31 timelines were all "failing" and the count said
  nothing; another process's crash still fails (e2e `properties`). Known exits too
  (2026-10-29, `exits_known`): an exit whose node's last output holds a declared text (ZooKeeper's
  "No snapshot found, but there are log entries", ZOOKEEPER-3220) is counted, not failed.
- New systems (2026-10-28), smokes queued on srv3, hunts after: ZooKeeper 3.9.6
  (examples/zookeeper: list-append in multis through kazoo, Elle; `known` profile 3.9.1, before
  ZOOKEEPER-4785's fix, for blind rediscovery), OpenSearch 3.9.0 (examples/opensearch:
  list-append on documents with optimistic concurrency, Elle; never Jepsen-tested under its
  name), Redpanda v26.2.6 (kafka-test's `redpanda` profile: Kafka's protocol, the same client and
  checks), Kafka 4.4.0 (kafka-test's `kafka-4.4` and `kafka-4.4-coverage` profiles). First hunts
  (2026-10-29): Kafka 4.4 (run 173) only KAFKA-20734 (now counted apart); OpenSearch (run 176,
  460 timelines) no finding, judged as its reads promise since; Redpanda (run 177) found blind:
  a coordinator crashing between begin_tx and recording the partitions leaves the transaction
  open for good (examples/kafka/README.md), explained with causality and a trace-logged future
  from inside its jump (a command at the moment raising the logger, kept across restarts).
  Patroni 4.1.0 (examples/patroni, 2026-10-29): PostgreSQL 18.6 with etcd beside it on each of
  three nodes, synchronous_mode, Jepsen's list-append through the primary; smokes fixed a start
  deadlock (Patroni waits for an etcd quorum: nodes ready on etcd's peer port) and its unsynced
  bootstrap pg_hba.conf (clients refused after an early power loss); first hunt (run 189, 444
  timelines): no loss; its one failure Patroni's documented default after an interrupted
  pg_rewind (README). MySQL Group Replication 26.10.0 (examples/mysql-gr): single primary,
  BEFORE_ON_PRIMARY_FAILOVER, a start script that rejoins or re-forms the group after a
  complete outage as MySQL Shell does; smoke 4 of 4, hunt queued. Apache Cassandra 5.0.9
  (examples/cassandra): the Scylla LWT workload (the CQL client a shared module now) with final
  reads at SERIAL; and Cassandra 6.0-alpha2's Accord transactions (`accord` profile and
  scenario: Elle's list-append across partitions in BEGIN TRANSACTION blocks).
- Writeback windows (2026-10-29, the user's choice): the guest writes nothing back unasked, so a
  power loss drops every write never synced, however old (Antithesis keeps "durably synced
  filesystem changes" too). Strict stays the default; a node may declare `writeback_s` (its disk
  synced that often by `det-nodes writeback`, as a host's flusher), for systems that leave their
  own metadata to writeback and were bricked at any age: RabbitMQ (feature flags, Mnesia's
  tables), ZooKeeper (its snapshots, never synced: ZOOKEEPER-3220), OpenSearch (its keystore).
  30 s each. e2e `disk`: a node with a window keeps across a crash what it wrote before it.
- Checks beside a hunt (2026-10-29): the cgroup-aware memory (memory_total the unit's limit)
  made claim_fits compare every run's VM claims on the host with a session's 24 GB: a check's VM
  never fit while a hunt ran (the coverage check sat through YugabyteDB's hunt, the tapes check
  through Galera's). Claims go against the host's memory again; the cgroup bounds what is
  available. And a session waiting for memory says so (after 30 s, then every 5 minutes).
- Scripts (2026-10-29): a scripted timeline dropped every fault on the runner's links (the
  runner is no node of the system's: run_script took it for gone). Found by the e2e script
  check's new condition, its own timeline following the script's commands and faults in order
  (it had required the same failure: a coin flip, the seed deciding the drivers' draws).
- Findings (2026-10-29): Kafka 4.4.0's KAFKA-20734 in its first smoke (a known blocker,
  unreleased fix; counted apart since); Galera 26.4.24's abort on an uncaught std::out_of_range
  in `gcomm::evs::Proto::populate_node_list` in three timelines of hunt run 97 (not in public
  trackers, unchanged through 26.4.27; examples/galera); ZOOKEEPER-3220 (snapshots never
  synced) in ZooKeeper's first smokes. Galera's root cause found by changing the timeline: two
  views with one id, a restart reusing its UUID incarnation after a power loss undid gvwstate.dat's
  unsynced rename (code and logs; futures forked with and without a sync: 0 and 2 aborts of 32,
  consistent, not conclusive: every later restart recreates the hazard).
- Steps over a tape (2026-10-29): a replay with a command at a moment, then a wait or an until,
  went back to checking the tape after the command and parted from it at the next checkpoint
  (Galera's sync-then-until replay). Checks stop once the moment's commands begin; e2e tapes
  covers it.
- Logging property for older runs (2026-10-29): the schema 4 migration left the timelines'
  output empty, and every run ingested before it showed no logging property; ingest fills it
  from timelines.jsonl.
- Tetris (2026-10-29): djblue/tetris's jank build under a player's moves, as Antithesis's
  Tetris quest (examples/tetris). Found: one hard drop places two pieces (a piece stuck at the
  spawn row, player-drop's loop on y), djblue/tetris#7's symptom. Guidance per depth ("no holes
  after N pieces") lifted games a little and plateaued: a better tactic or a keep-the-best
  strategy is next for deep games. jank 0.1 met: no read-line or flush (thrown, segfaulting when
  uncaught in -main), a segfault joining what sort returns for nothing, its compiler segfaulting
  at -O 2.
- RabbitMQ (2026-10-29): run 100's lost confirmed messages were the workload's (a dequeue
  driver killed before noting what the client node had acknowledged): the client node now logs
  its dequeues, and losses are judged after a complete drain only. flags-synced (answered B)
  looks past the feature flags finding (476 of ~700 timelines): a good copy kept, as an atomic
  replace would; hunted next.
- Galera, found blind (2026-10-29, run 123): a joiner whose state transfer is cut is left a
  primary component of one (its donor left gracefully), saves it, and after a restart
  `pc.recovery` starts a new history from its half-copied data; nodes with newer data join it by
  SST (committed row lost, read by replay; examples/galera/README.md). Not the disk model, first
  suspected. Done since: the SQL append workloads (Galera, MySQL, PostgreSQL, CockroachDB, TiDB,
  YugabyteDB) end with final reads, a `finally` command: every committed append must be in its
  key's list. Next: a Galera hunt with them (queued after next.sh) for how often.
- Determinism (2026-10-29): RabbitMQ Khepri hunt run 164 had 1 of its 16 sampled replays
  diverge (timeline 159, a fresh start from the setup snapshot, no holder): the replays agree
  with each other (events hash 17185dcd09e975dd, twice), the run's own execution was the odd one
  (f4f42fedaf402bf6). Same 1,695 events; the first difference at seq 1666 (rabbit-2's output at
  94.85 s: 0.7 µs later and 34,262 branches fewer in the replay), after a stretch of 30 s with no
  event at all (from 64.14 s), so it cannot be placed closer after the fact: the original keeps
  no trace. Recent hunts: 1 diverged of 96 sampled (runs 97, 118, 123, 148, 160, 164). Done
  since: a checkpoint at the first timer past each second of virtual time (vtime, branches) in
  every timeline's events, neither counted nor hashed, and a replay that parts from the run says
  where (the last checkpoint both passed, the first differing line on each side), its events kept
  beside the tapes. The hyperthreads control (2026-10-29 08:55): run 56's 64 sampled timelines
  replayed one VM per core, as with hyperthread siblings shared: 38 of 64 both times, the same
  26 failing at the same events (timeline 49 at event 6080 in both). Not hyperthreads: a
  difference between the build that recorded run 56 (2026-10-28) and today's, the same every
  time. Old runs replayed by a newer host part from their tapes; new runs replay (1 of 96
  sampled parted, above). Done since: tapes and the run's record carry the build that made them
  (`host`, a hash of the explorer's executable), and a replay by another build says so. Kafka's
  holders against replays (next.sh's check, a tree of 32 timelines, holders on disk as memory
  was short): 6 holder nodes made and each the same as the node a replay makes ("verify #20 at
  698.17 s: the same"); run 68's timeline 98, which parted from every replay, not seen again.
- `eventually` endings kill the drivers as soon as the composer reaches them (after its 4 to 63
  starts, pauses under 20 ms): RabbitMQ's run 118 drove a median 26.6 s, under 10 s in 274 of
  1,494 timelines. Antithesis's composer may start one any time after a driver started, killing
  the rest, so short drives are part of the parity; a check that needs its drivers done is a
  `finally` command (the SQL final reads: an `eventually` one cut Galera's drivers at 0.1 s).
- RabbitMQ findings (2026-10-29, hunt run 118, flags-synced, 1,498 timelines): confirmed
  messages lost when two quorum queue members restart as new ones (Ra's names.dets registration
  not synced, kills within half a second of the declaration; timeline 1005, 23 of 34, exact
  replay); a quorum queue whose three members all do never serves again (21 timelines); a boot's
  throwaway Mnesia dying on a peer's schema update (82), shown by holding the peer in a replay.
  Queued: ra-synced (Ra syncing each registration) against run 118; queue_khepri.
- Known crashes by output (2026-10-29): det-core matches a crashing process's node output
  against its known exits; Galera declares its by-design abort (all 114 of run 97's crash
  failures), so the crash property fails on other crashes alone.
- Links left down (2026-10-29): run 100's timeline 360 ended its faults with a link down and no
  word why; failed link changes are events now, and the property names the links.
- Short branches (2026-10-29): Antithesis's multiverse map shows mostly short branches past the
  branch point, a few extended; determinismo's `--horizon` does that, unused by hunts. Queued:
  Galera's run 97 again with a 60 s horizon (timelines per hour, behaviors, the EVS abort's
  rate), and with jepsen-dirsync (does the abort go with gvwstate.dat's rename made durable?).
- Core isolation (2026-10-29, answered A, not applied): measured first, preemption of VM
  threads was 1.1 per second in all, and the interrupts on the runs' cores (timer, IPIs from
  our own memory changes, our PMU, NVMe completions on the submitting CPU) cost about 0.2% of
  a VM's time; the live changes could move almost none of them.
- Output floods (2026-10-29): Redpanda's controller looped on an exception and wrote 4 GB of
  events in one timeline (run 83; its page slow while serve took them in; the node's log file in
  guest memory). The guest's output forwarder keeps 8 MB and then 200 MB an hour of virtual time
  per node start or command (the logging property's rate), drops the rest and says so
  (`output_dropped`, counted by the property). serve now shows the logging property as the
  explorer judges it (it listed it passing: run-level, no failing timeline).
- Node disks are memory (2026-10-28): YugabyteDB's WAL preallocates each tablet's next 64 MB
  segment whole and keeps its segments 300 s; run 77 ended 7 of 64 timelines in OOM kills
  (processes of ~100 MB killed). 4 MB segments since. A system's disk use is VM memory: size
  segments, logs and retention for it.
- RabbitMQ 4.1.4 (2026-10-28, examples/rabbitmq): a quorum queue under Jepsen's queue checks
  (confirmed messages dequeued, no phantoms, no refused ones), power losses at durability
  points among the faults. Its first two timelines found, blind, a node that never boots again
  after a power loss soon after its first boot (its feature_flags file written without a sync,
  then empty: `case_clause {ok,[]}`); enqueues are noted before they are sent, and the drain
  leaves out a node that stays down. A hunt next.
- Jepsen, blind: Redis-Raft #52 (crashes alone: the `crashes` profile, 60 s timelines, to rerun);
  MongoDB 4.2.6 sharded: SERVER-48307 found (2 of the first 89 timelines, both its forms);
  ScyllaDB 4.2.rc3 (examples/scylla: LWT list-append, Jepsen's configuration, own CQL client)
  next, then Kafka's hunt again (bootstrap.checkpoint) on exact replays; Redpanda 21.10 is gone
  (22.1.1 the oldest image).
- Done today: holders' one-byte difference explained (an XSAVE header's x87 in-use bit, which
  host FPU saves flip; accepted exactly) and the tree e2e stable; snapshot copies of swapped-out
  pages; memory admission; cores past 256 MiB keep their stacks; `stacks` reads threads ptrace
  cannot stop; TigerBeetle's rejoin crash traced to the line through a reproducible build;
  Tailscale on the Mac and srv2.

## Now

1. **e2e green on everything** (the tree check included: the same tree with one worker or four,
   a deep timeline replaying alone from its tape, with and without a strategy).
2. **The tree explorer** (Go-Explore over snapshots: generations, returns just after new
   behaviors, paths in tapes and records) is the default; strategies decide within timelines
   and choose the moments to return to (`returns`), with reasons. Behaviors: assertion
   outcomes, categorical events (coverage lines and edges included), guidance distances, and
   new kinds of output lines. Next steps for it:
   - Done: in-run snapshots (holders, ARCHITECTURE.md §8): a node is a memory copy instead of a
     replay of its parent to the moment (minutes with fifteen-minute timelines), each checked
     against a replay's node by `--verify-holders` in the e2e tree check. Next: return to more
     moments per generation now that a node costs little.
   - Done: holders with CPU modulation (Antithesis turns modulation on with faults, and the Raft
     double vote is an interleaving): stops computed from the effective time, the modulation
     stepped at the guest's own exits only, and carried on in a holder's replay.
   - Memory: done: a VM starts only within the host's claims (every VM's memory, and since
     2026-10-28 every tree's snapshot nodes, `nodes-<pid>` claims) and with its memory available
     now (MemAvailable less an 8 GB reserve); a run's nodes stop at half the host; holders are
     made with 16 GB available and give themselves up below 8 GB; timelines the kernel kills
     anyway run again (64 at most). Hyperthreads (DETERMINISMO_SMT) tried on a hunt (Kafka run
     55, srv3, 2026-10-28, once serve passed the variable on: it never had): 2 of 9 sampled
     replays diverged (no clock hazard), against 33 of 33 exact without them: off again. Next:
     find what a sibling VM still perturbs (the guest kernel's TLB-dependent paths, patches
     0001, 0002, 0004, were the last), with replays of a timeline beside a busy sibling. So far:
     run 55's timeline 15 is the original that parted (a lone replay and the in-run one agree,
     diverging from its tape at the same event: seq 19819, 326 more branches in the 75 ms after
     the broker's restart began); four replays on two cores' four hyperthreads all matched the
     lone one. The original ran beside 31 VMs with 14 GB of the host's memory available: next,
     32 replays at once with hyperthreads on the whole host between two hunts (determinismo
     verify on run 55), then the RDTSC log and instruction trace of a parted one.
   - A generation waits for its slowest timeline: with fifteen-minute Raft timelines (median
     216 s of wall time, slowest 476 s) one run leaves 47% of its workers idle. Meanwhile:
     several runs per machine fill each other's gaps. Next: larger generations (`--generation`,
     several timelines per worker) and the next generation's roots started early (a quarter of
     it: the rest depends on its results); planning from whatever finished first would fill
     more but make the tree depend on timing.
   - Measured with bench/tree.py (the self-test maze, eight seeds; plugins/python/tree_rarity.py
     tries a rule without rebuilding). Kept: a generation's finds weighed by how few of its
     timelines found them (second digit 16.6 against 14.6). Dropped: rarity summed over all
     behaviors (2.5), returning to the least visited behavior when nothing is new (15.1),
     numbering the next roots first to run them during node making (4.6), and running them then
     with the numbering kept (the same tree, no clear wall-time gain: forking twice a generation
     costs what the overlap saves). Left: a budget split between depth and fresh starts learned
     from what found new behaviors.
   - Measured 2026-10-27, the maze (4 minutes, seeds 1 and 2, srv1, beside other runs): the
     built-in archive (`--archive --pipeline 1`) solved both (65 s, 5 s); the Clojure archive
     strategy one (170 s); Clojure's rarity none. The Raft POC on srv2 (40 minutes a seed, 36
     threads, generations of 48), bench/explore.py: the default tree found the deadlock in both
     seeds (48 s, 66 s) and, in seed 1, the double vote with three others (1,481 s, timeline 4653);
     the archive found the same in seed 1 (35 s; 1,768 s). But timeline 4653 is a fresh start
     (no path), its seed drawn from its index, the same in both: the double vote was the seed's,
     not the strategies'. Of 6,767 and 5,808 timelines, 1,799 and 1,560 started fresh; those from
     moments found the deadlock (39 and 29 times) and, once, in the archive's, the log divergence
     (timeline 5493, two moments deep, after the fresh one). So: count each variant's finds from
     moments apart from fresh ones, and compare variants over more seeds; the double vote needs
     returns that keep the off-loop heartbeat's timing (tests/antithesis-compat/README.md).
   - Measured 2026-10-29, bench/tree.py (the maze, 400 timelines, seeds 1-8, srv3, my cores):
     `--return-branches` 4 (3 moments a generation) reached the digits in 161.5, 110.6 and 69.1
     timelines on average, 2 (6 moments) in 165.2, 115.2 and 73.0 (per seed: ahead in 6, 5 and
     5 of 8, about +4 each, paired t 2.1-2.5), 1 (12 moments) in 136.9, 91.6 and 55.5 (behind on
     every seed). Two is a small, consistent gain on a toy; the default stays 4 until a known
     bug in a real system agrees (Raft's deadlock, etcd's #22498 timelines to first find). The
     Raft POC's deadlock (bench/explore.py, 20 minutes a seed, 4 CPUs on srv3): seed 1 found in
     52 s (39th timeline) by 4, 77 s (31st) by 2; seed 2 not found in 369 timelines by 4, found in
     547 s (230th) by 2. One each way, and throughput itself varied threefold (369 to 1,080
     timelines): no verdict, the default stays.
   - Measured 2026-10-29, `--horizon 60s` on Galera (run 148 against run 97: `jepsen`, seed 3,
     an hour each, stopped by the plateau rule): 954 timelines against 299, but 52 behaviors
     against 53 and behind at every point of the hour (46 against 51 at 5%), and Galera's EVS
     abort in 5 timelines against 16. Not a clean pair (known exits and the link fix landed in
     between), but nothing for a horizon: hunts keep none.
3. **Why, everywhere.** Done: the tree explorer's reason for every branch point, a strategy's
   `reason` with any answer (in the timeline as a `decision` event, and in its tape), the LLM
   strategy's reasons from the model; the UI's tooltips show them. Left: det-faults' own reasons
   when it is guided (`fault after "leader elected": partition the leader`), the mutate
   strategy's (which parent, which mutation), and reasons in the logs and the notebook.
4. **The UI.** Done: stat cards, discovery and failing-property charts, the multiverse tree with
   shared prefixes, branch points and forks, zoom and pan, live updates, styled tooltips, logs
   with the parents' events, Clojure notebooks (babashka) with a per-run nREPL server, fork
   from a moment, time budgets, strategy uploads, and a minimap for big runs (checked on etcd
   run 64's 4,325 timelines, 2026-10-28: drawn whole, zoomed, moved from the minimap).
5. **clojure-cli.repl**: examples/clojure-cli-repl, its server beside plain nREPL 1.7.0. Found
   (README): an editor evaluation hangs while a watching terminal does not read (over ~100 KB
   of output); closed sessions are kept; one inspector view for all terminals. Left: rerun the
   editors scenario with the warm-up fix; interrupts and long evaluations racing watchers.
   Findings stay documented here (nothing is filed with other projects).
6. **Blind exploration of the real targets**: nREPL, the Clojure libraries, Raft (pinned commit,
   with restarts), with the tree explorer and the strategies; findings documented in each
   example's README. Antithesis's own Raft project (antithesishq/hashicorp-raft-poc) runs
   unchanged through the Compose importer (its Go SDK writes to detfs, a regular file; its
   client declares the setup, where the snapshot is taken). Found blind: the
   leadership-transfer deadlock (hashicorp/raft#696, first hour, explained by a replay's
   goroutine dump) and the log divergence from off-loop heartbeats (#695, with three-minute
   timelines and a pause right after an election), and the snapshot installation livelock
   (#697, with fifteen-minute timelines and up to 32 drivers; it replays from its tape);
   tests/antithesis-compat/README.md. And the double vote (#695's second mechanism), found in
   run 77 on srv2 (timeline 22: two leaders in term 180), with the durability-point faults and
   CPU modulation, in runs that repeat with fresh seeds on the host's shared CPU pool: all four of
   the POC's known bugs, blind.

## Antithesis parity found missing

From Antithesis's Java SDK (antithesis-sdk-java) and blog (2024 to 2026); none of these is a row
in ANTITHESIS.md yet.

1. **Guidance assertions**: done in every SDK, used by det-strategy-mutate and the LLM strategy.
   Left: guidance-aware Go-Explore cells (see "Strategy guidance").
2. **Assertion locations**: done in every SDK (Zig through the return address and its debug
   info); the platform's built-in properties carry none (they have no place in user code).
3. **First pass, first failure**: done in every SDK (opt-in; guidance only when it improves).
4. **Disk faults**: Antithesis documents restarts that keep durably synced changes or lose all
   of them: `crash` (an ext4 disk per node, shut down without flushing) and `wipe`. Beyond
   them, `disk`: I/O errors, write errors, lost writes, corrupted reads and latency through
   device-mapper. All in the e2e `disk` check.
   Fault types audited against antithesis.com/docs/.../fault_types (all present: partitions
   both ways or one way, clogs, restore, throttle, pause, kill and graceful stop, crash and wipe,
   thread pause, clock skips, CPU modulation, custom; network faults overlap, node faults one at
   a time per node; any fault on request from a scenario). Restarted nodes may take a new address
   (`new_address`). Left: CPU modulation changing the relative speed of instructions, not only
   the clock.
5. **Retroactive logging**: done (`--retroactive '<text>'`): verbose lines stay out of an
   exploration's events and come back in a replay.
6. **Agent skills**: properties, workload, debug and mutants are in `.claude/skills/`. Left:
   trying each on a system it has not seen.
7. **Mutation testing campaigns** (antithesis.com/blog/2026/mutation-testing): an agent reads the
   code and writes subtle mutants (races, wrong ordering; not syntax that only panics), one
   patch each; determinismo explores each mutant and reports per property whether it was
   falsified, with why not when it was not: the mutated code never ran (coverage), or it ran and
   no property noticed (a gap in the properties). `determinismo mutate` (patches to a node's
   build, caught / never ran / unnoticed), its e2e check, the MCP tool and the
   determinismo-mutants skill are done.
8. **The kernel's log as events** (Antithesis's `environment.journal.events`): done, the
   kernel's console lines as output events from source `kernel` at their moments (the console's
   writes are the guest's own exits). Events hashes changed with it: replays of runs recorded
   before differ by those events alone.

## Strategy guidance (next)

Strategies are pluggable (any language, over a JSON protocol; docs/PLUGINS.md) and three exist:
random, `mutate` (greybox mutation of decision tapes, frontier-focused, with synced workers) and
`extremes` (a UCB1 bandit, in Python). What they cannot do yet is decide well *where* to put a
fault and *where* to branch. Antithesis describes its guidance as reinforcement learning toward
"new and interesting states", every event a potential branch point, and `sometimes` assertions
as hints of where bugs hide. To get there:

1. **Labeled decisions**: done (`decide` and `random_below_named` in every SDK; det-faults names
   its faults, waits and durations; strategies get the label with the pull). An LLM strategy
   uses them (plugins/python/llm.py, Claude Haiku 5.5 through the `claude` CLI; remote over TCP).
2. **Branching mid-timeline**: done in the explorer itself (`--branching tree`, see "Now"),
   and strategies choose the moments to return to (`returns`, docs/PLUGINS.md; a short answer
   filled by the explorer's own).
3. **Reference strategies with real guidance:**
   - Go-Explore: an archive of cells (the features reached, with the moment that reached them),
     pick by rarity, return by snapshot, explore with labeled decisions.
   - Fault scheduling: faults around the moments that matter (a leader elected, a commit, a
     `sometimes` hint reached), from event sets over past timelines; partition the node an event
     names.
   - RL: a policy over labeled decision points, rewarded by new features and failing properties
     (the bandit generalized to a contextual policy).
   - LLM: a model reads a timeline's summary (events, faults, assertions near misses) and proposes
     the next fault schedule or decisions, through the plugin protocol or the MCP outer loop.
     The reference one calls Claude Haiku 5.5 through the `claude` CLI (`claude -p --model
     claude-haiku-5-5`), so it runs wherever Claude Code is logged in; cheap enough to consult
     once per branch, and its answers are in the tapes like any override.
4. **Sometimes assertions as guidance:** a `sometimes` not yet true is a target; strategies get
   the catalog's open targets and reward timelines that move toward them.
5. **Strategies anyone can bring.** `--strategy "<command>"` already runs any program (any
   language, any API behind it), over JSON lines, and it need not be deterministic (its
   overrides are in the tapes); `tcp://` reaches one running anywhere, and `serve` takes uploads
   (`PUT /strategies/<name>`, `@name` in a run). Left: uploads through MCP, and container
   images as strategies (dependencies included).
6. **Measure:** time to find the known bugs (bank, shop, clojure-bank, the maze, Raft) per
   strategy and per branch budget, in `bench/`, so changes to guidance are judged by numbers.

## Real systems: find real issues

Each gets a test program in `examples/` (or a separate repository when it grows), explored
blind, with its findings documented in its README.

- **Faults at durability points** (done: `sync_stall`, `durable_crash`; ARCHITECTURE.md §9): the
  Raft POC's remaining bug (two leaders in a term) opens only while a goroutine waits on a store
  write (tests/antithesis-compat/README.md); random pauses had not hit it in 938 timelines. The
  guest module makes a node's fsyncs and sync writes seeded decisions: stalls there widen those
  windows, crashes there hit act-then-persist bugs. With them, the double vote was found (run 77,
  timeline 22). Any system's, not Raft's alone.

1. **Raft**: HashiCorp Raft (examples/raft, at the article's upstream commit 4c8f61ac), then
   OpenRaft, MicroRaft, Aeron Cluster.
2. **Clojure's most used libraries** (Clojars downloads, from ecosyste.ms, plus the core libraries
   on Maven Central), each under a workload that exercises what can break under concurrency,
   network faults and restarts, with the Clojure SDK's assertions and the catalog:
   - Servers and clients: nREPL (concurrent sessions, interrupts, evaluation under faults; and
     cider-nrepl), http-kit, ring-core with ring-jetty-adapter (and ring-codec, ring-defaults,
     ring-ssl, ring-anti-forgery, ring-headers), compojure, clout, clj-http, manifold, aleph.
   - Concurrency: core.async, manifold, com.taoensso/encore, timbre (asynchronous logging),
     com.stuartsierra/component (lifecycle under restarts), mount, integrant, ns-tracker, hawk.
   - Data and serialization (round trips with platform randomness): cheshire, jsonista,
     data.json, nippy, clj-yaml, instaparse, edamame, rewrite-clj, tools.reader, fipp, puget,
     camel-snake-kebab, org.flatland/ordered, medley, specter, clj-tuple.
   - Validation: malli, prismatic/schema, schema-tools, spec-tools, expound.
   - Time and security: clj-time, crypto-random, crypto-equality, buddy-core, buddy-sign,
     pandect.
   - Storage clients: next.jdbc (Postgres), carmine (Redis), core.cache and core.memoize.
   - Templates and the rest: hiccup, selmer, aero, environ, potemkin, riddley, slingshot,
     plumbing, primitive-math, io.aviso/pretty, test.check.
3. **The Clojure compiler and runtime** (clojure/clojure, the JVM implementation): a pinned
   fork with the Java SDK's assertions put where its rare paths are, so that they guide the
   exploration to them. Started: examples/clojure-compiler (Clojure 1.12.6 with clojure.patch:
   27 assertions in the STM, hash map nodes, lazy seqs, the compiler and reflection, and
   buggify points in the STM and lazy seqs; scenarios stm, forms and lazy; all properties hold
   so far). Next: agents and futures (send-off pools, binding conveyance), more compiler paths,
   and the reached-path counts as the measure of each addition. `sometimes` and `reachable` mark the paths worth reaching (the tree
   returns just after a timeline first reaches one, and a strategy can steer toward one not yet
   reached); `always` checks what must hold there. Candidates, read from the source:
   - Compiler.java: recur in tail and non-tail positions (loop, fn, try bodies), locals
     clearing (once-only closures, branches that clear differently), primitive locals and
     return hints (boxing, unchecked math, long/double fallbacks), reflection fallbacks,
     `case` with hash collisions (shift/mask, skip-check), keyword and protocol call-site
     caches, deftype mutable fields under closures, macroexpansion that throws.
   - The runtime: PersistentHashMap collision nodes and array-node packing, transients after
     persistent!, chunked seqs crossing chunk boundaries, LazySeq realized from several threads,
     STM (LockingTransaction retries, barging, commute and ensure, history growth), agents
     (send-off pool, errors, restart-agent), Var bindings conveyed to futures, locking.
   - The workload: a test program generates Clojure forms (test.check generators, Clojure's own
     test suite as a corpus) and evaluates them in the guest, with properties that need no
     reference answer: the same form gives the same result with direct linking on and off,
     locals clearing on and off, and interpreted against compiled (`eval` of the form and of
     `(fn [] form)`); STM transfers conserve their totals under contention; nothing throws an
     internal error (`ClassFormatError`, `VerifyError`, an NPE inside the compiler).
   - Threads, contention and preemption are what determinismo varies (CPU modulation, thread
     pauses), so the STM and lazy-seq paths are the likeliest to fail; the compiler's are the
     likeliest to need guidance to reach at all.
4. **core.async in depth** (clojure/core.async, a compiler and a concurrency library in one):
   a pinned fork with the Clojure SDK's assertions at its rare paths, buggify points in its race
   windows and alts!'s port order a platform decision. Started: examples/clojure-core-async
   (core.async 1.9.865 with core-async.patch, 20 sites in channels, alts!, the go runtime and
   macro, and timers; scenarios channels, alts, pipeline, mult, go and timeout, with what
   core.async promises as properties: nothing lost or duplicated, order per producer and through
   pipelines, every mult tap served, catch and finally after parks, no early timeout). Next:
   pub/sub and mix, put!/take! callbacks, the dispatch pools, more go macro forms (loops, case,
   nested try parking).
5. **More systems**: etcd, a Jepsen-tested store, Kafka-compatible brokers. Started:
   examples/etcd (etcd v3.7.3, three members with restarts, stops and crashes, and the
   durability-point faults): acknowledged writes survive, linearizable reads see earlier writes,
   revisions grow, a compare-and-swap counter counts, members' keyspace hashes agree, recovery;
   and list-append transactions whose whole history Elle checks for strict serializability
   (checkers/elle: Jepsen's checker as a node any workload can post its history to); watches
   deliver in revision order and miss no acknowledged write. All hold so far. Next: leases and
   locks (unsafe by design: reported, not failed). The rest of Jepsen's systems, ranked, with
   their workloads: docs/JEPSEN.md.

## Code: instrumentation, locations, targeted runs

What exists: code coverage as events, per language (C and anything LLVM through
`-fsanitize-coverage=trace-pc-guard` edges, Zig edges, Python lines through sys.monitoring, JVM
lines through a Java agent rewriting bytecode as classes load, Clojure's generated classes
included), used by strategies to keep timelines that reach new code. Edges are numbers, not
places, and assertions carry no location.

1. **Every event points at code.** Coverage edges symbolized to file, function and line (the
   compiler's PC table and the binary's debug info, read once per program file); assertions
   with their location (see "Antithesis parity found missing"); the platform's own properties
   with the command, scenario and process they came from (`test command completed: accounts` is
   the composer's, about the `accounts` command: the event says so, and links to the handler's
   source when the program has debug info).
2. **Causality down to code.** Causality analysis finds the moment a failure became likely; add
   what ran there: the lines first reached between the last moment with a low probability and
   the jump, and every thread's stack at that moment (det-profile), so the report names the
   code that decided the bug, not only when. Done in the UI (2026-10-28): each jump lists the
   code first run in it (its coverage events' lines) and takes every thread's stacks in a node
   at its end (a replay with det-profile); agents get both from `query` and `replay` (AGENTS.md,
   the determinismo-debug skill); `determinismo causality` prints each jump's faults and code
   first run ("where it was decided", `{"decided":[...]}` with --json).
3. **Targeted runs from a diff.** Done: `explore --changed <diff file | git range>` (CLI, serve,
   MCP) matches the hunks to line coverage (Python, the JVM, Go through Antithesis's
   instrumentor and libvoidstar), returns first to timelines that ran changed code, just after
   they did, and reports which hunks ran in how many timelines and which never ran (e2e
   `changed`); by commit, range or release of the system's repository, local or fetched by its
   URL (`--changed-repository`, 2026-10-28; the UI's New run form). The report says each hunk's
   first timeline, and for a hunk no timeline ran, how near (lines before it) one came. Heading
   the tree there (returning first to timelines that came nearer) was measured on two mazes, one
   a distractor (tests/changed/mazes.diff, srv3, 400 timelines, four seeds): first solved in
   #144/#55/#147/#122 without, #160/#55/#103/#145 with: no gain, not kept (a generation's
   returns already go to its most novel timelines, which are the nearest ones). Next to try:
   more of a generation's nodes for the nearest one. Left: distance to the changed lines (directed fuzzing, as AFLGo does) for code
   no timeline reaches yet, faults aimed around it, and which properties the timelines that ran
   it checked; our C and Zig SDKs' edges mapped back to lines (code built for Antithesis, C, C++
   and Rust through libvoidstar and /symbols, reports lines since 2026-10-28: e2e `lines`).
4. **More languages.** Rust (an SDK crate over the C ABI, LLVM's coverage for edges), Go (an
   SDK of our own; Antithesis's Go SDK and instrumentor already work, through libvoidstar),
   JavaScript (an SDK; V8's coverage).

## Speed

- The tree's generation barrier: gone (a pull queue: a generation is the next `size`
  timelines to finish; cores 100% busy, 2026-10-27).
- One host, many runs (cpus.zig): one CPU pool for every run, a core's first thread only
  (hyperthreads off again since 2026-10-28: a Kafka hunt with them replayed 7 of 9 checked
  timelines; the experiment, 2026-10-29: Kafka run 56's 64 sampled timelines replayed 32 at once with
  hyperthreads on, 38 replayed, 26 parted from their tapes at various events with no clock
  hazard counted; the control with them off, 2026-10-29: the same 38, the same 26 at the same
  events, so a difference of builds, not hyperthreads; one per core stays until a fresh run
  with siblings shared replays every timeline by the same build: queued, after-next3); memory
  admission by claims and by what is available now, the sessions' room held back while one of
  their VMs waits.
- Busy guests: about 0.85-1x virtual per wall second now (0.3-0.6 before the exit work of
  2026-10-27: `io_delay=none`, one PIT write, a 1 ms timer slack, RDTSC in KVM's fastpath).
  Remaining exits: PIC port I/O, single-steps for hard stops.
- Big systems: holders (parked VMs that make branching cheap) need memory that a YugabyteDB
  hunt (7 GB VMs) leaves too little of; branching then replays to the moment. Kafka's hunts
  made none in 180 of 207 timelines (run 67) and in all of run 68's (15 GB available of the 16
  they want; 19 GB of srv3's tmpfs /tmp were stale check files): each new timeline replayed
  its parent from the start, minutes, while workers waited (8.8 of 16 busy). Done
  (2026-10-28): while memory runs low, holders go to the run's directory instead
  (holders.Disk): a child forked at the hold point writes the moment's pages changed since the
  timeline's previous one, the timeline going on meanwhile; a node maker loads it, replaying on
  from there as a holder would; a timeline's files go with its holders. `--holders-on-disk`
  puts every holder there (the e2e tree check verifies each such node against a replay's).
  Next: measure a Kafka hunt with them (timelines per hour, workers busy). Measured unbounded
  (2026-10-29): Kafka's run 173 kept 355 GB of them (1,094 files of 3 GB VMs, diffs or not) and
  filled srv3's disk, every run's writes failing (the e2e suite's with NoSpaceLeft); stopped,
  it left 209 GB (SIGTERM runs no defers). Since, holders and ladders on disk leave their
  filesystem the larger of 100 GB and 10% free (past it a node costs a replay, as with no
  memory), and serve deletes a run's holders once its explorer ended. OpenSearch's run 176
  kept 82 GB in 20 minutes, 36 files: most timelines keep one holder, and a timeline's first
  is a whole dump (a fresh chain: 2.3 GB of a 4 GB VM's nonzero pages), siblings returned to
  the same moment writing nearly the same pages. Done (2026-10-29): a timeline whose node was
  made from a disk holder saves its first one against that holder (its page hashes are saved
  beside it, `.hashes`), the pages changed since alone; the explorer keeps a holder's files
  while timelines saved against them are (holders.Lineage), and a chain through timelines
  stops at 24 snapshots (a fresh dump past it). Group Replication's run 200 had kept 34 files,
  most of them whole dumps of 1.4 to 1.9 GB, four siblings at one moment among them. The e2e
  tree check (holders on disk, every node verified against a replay's) covers it. Next: its
  effect on a big hunt's holders (files, gigabytes, nodes made from disk).
- Setup is one core before branches fan out: measured, not worth it (YugabyteDB's run 77: boot
  and setup 13.6 s of a 2 h hunt, 0.2%).
- Efficiency, measured (2026-10-29, Antithesis's "Optimizing"): every run reports virtual per
  wall time per node (their rule of thumb: above 1), the share of virtual time idle and skipped
  (little: a busy-wait), clock reads per virtual second, and CPU time by node (det-init's
  `node_cpu` events; serve's "CPU by node"); the live status carries the first three. Cassandra's
  smoke: 0.46 virtual per wall second, x 3 nodes 1.4; 38,000 clock reads per virtual second, 98%
  in KVM's fastpath (not what slows it). Next: the idle share and CPU by node of each system's
  next run, and what the slow ones (Cassandra, Redpanda, YugabyteDB) spend it on.
- Background work test-sized (2026-10-29): CockroachDB's ranges split at 64 KiB (512 MiB by
  default) and its time series off; YugabyteDB current's automatic tablet splitting from 128
  KiB (memtables flushed at 128 KiB); ScyllaDB current's keyspace on tablets (it was
  SimpleStrategy's vnodes: its tablets never ran) of 64 KiB, flushed every minute; Cassandra's
  failure detector at phi 5 and its memtables flushed every minute. Smokes queued.

## Later

TLA+ counterexample replay, delta snapshots, nested virtualization, an AMD backend and replay
across CPU models.
