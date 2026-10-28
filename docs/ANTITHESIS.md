# Antithesis parity map

determinismo follows the Antithesis documentation (https://antithesis.com/docs/llms.txt) as its
feature checklist. Each row is an Antithesis feature, where determinismo stands, and what is
next. ✅ done and tested by `zig build e2e`; 🟡 partial; ❌ missing. Update the row with the
change that moves it.

## Setup and the system under test

| Antithesis | determinismo | Status |
|---|---|---|
| Docker Compose setup | `--compose` importer: images, builds, env, depends_on, ports, mem_limit, privileged, ulimits | ✅ |
| Kubernetes setup | `--kubernetes <manifests directory>` (CLI, HTTP, MCP, the UI's New run): raw manifests (Helm rendered first) in a single-node K3s cluster with CoreDNS and local-path storage, no Traefik, ServiceLB or metrics-server; images fully qualified and taken from the host into the node (the guest has no network); applied until all apply, then every container given the SDK's output and everything rolled out and ready (kapp's readiness) before branching; test templates in any image run in its pod (`kubectl exec`); `examples/kubernetes`. K3s in a test program's node, or a three-node cluster: `examples/k3s` | 🟡 faults act on the K3s node (its processes, the pods' among them), not between pods; bare Pods do not get the SDK's output |
| Setup mode, `setup_complete` | snapshot at `setup_complete` (SDKs, composer, `setup_` template commands) | ✅ |
| The Antithesis environment (one vCPU, no rdrand, deterministic time) | patched KVM, branches clock, CPUID baseline | ✅ |
| Handling external dependencies | no network beyond the guest; [DEPENDENCIES.md](DEPENDENCIES.md): containers or mocks (MinIO, LocalStack, emulators, stripe-mock), names, readiness, storage, memory | ✅ |

## Writing tests

| Antithesis | determinismo | Status |
|---|---|---|
| Test templates, test commands (first, parallel/serial/singleton drivers, anytime, eventually, finally) | composer follows the reference | ✅ |
| Assertions: always, always-or-unreachable, sometimes, reachable, unreachable | Zig, C/C++, Python, JVM (Java, Clojure), JavaScript/TypeScript, Rust and Go SDKs, with Antithesis's names too (docs/SDKS.md); Antithesis SDK messages accepted. Judged as Antithesis does: a timeline violates only `always`-style properties and `unreachable`; `sometimes` (true in some timeline), `reachable`, and an `always` never hit are judged across the multiverse | ✅ |
| Assertion catalog (declared, not yet hit) | Automatic in every SDK, as code loads, before it runs: Zig (a section entry per call site, announced at startup), C (`DET_*` macros, same section, a constructor), JVM (a Java agent reads each class's bytecode as it loads: Java, Kotlin, Scala, AOT Clojure), Clojure (macros declare as the namespace compiles), Python (each module's syntax tree as it runs). A test program's catalog spans its scenarios and is judged over all of them; an assertion no timeline reaches fails | ✅ |
| Randomness (SDK random) | SDK random, `rng()`, `prng()`, `randomChoice` (Antithesis's name) and named decisions (`decide`, `randomBelowNamed`); kernel reseeded per branch. Beyond Antithesis: `buggify(name)`, FoundationDB's BUGGIFY: inside determinismo a point is active one two-second stretch in four (a named decision, per timeline), and then true one evaluation in four from its own generator (a hot point costs a decision a stretch); never outside. For rare paths a system can take anyway; `buggifyPause` (JVM) pauses one evaluation in 32 while active (every SDK: Zig, C, Python, Java, Clojure) | ✅ |
| Lifecycle | `setup_complete`, `guest_done` | ✅ |
| Coverage instrumentation | C, Zig, Rust (edges), Python, JVM (lines), Node.js (V8 block coverage); used by `mutate` and the tree explorer | 🟡 opt-in per language (build flags, `coverage_start`, a Java agent, `coverageStart`); edges never map back to source lines; Go through Antithesis's instrumentor |
| Antithesis's native library (`/usr/lib/libvoidstar.so`) and instrumentors | the nodes of imported Compose projects (and others with `antithesis_library`) have determinismo's libvoidstar.so there (no libc: any dynamically linked program can load it; not every node, since a static program with Antithesis's Go SDK, K3s through etcd, stops when the file is there and cannot load it): SDK messages (`fuzz_json_data`) become events, `fuzz_get_random` is a platform decision, `init_coverage_module`/`notify_coverage` from Antithesis's instrumentors give coverage as source lines through the module's symbol table (`/symbols/*.sym.tsv`; the Go instrumentor's), and clang's trace-pc-guard callbacks give edges (C/C++ linked against it). Antithesis's own Raft project reports its Go coverage unchanged | ✅ |
| Guidance assertions (`alwaysGreaterThan`, `sometimesLessThan`, ..., `alwaysSome`, `sometimesAll`) | In every SDK (Zig, C, Python, JVM, Clojure): the compared values in the details, and a guidance event with the distance to the interesting outcome; det-strategy-mutate keeps timelines that come closer (the sum maze: solved guided, missed in 300 random timelines) | ✅ |
| Assertion locations and ids; first pass and first failure per process | locations (file, line, function) in every SDK: C (macros), Python (the caller's frame), the JVM and Clojure (StackWalker, once per assertion), Zig (the return address and the program's debug info); in the report, the record and the UI. First pass and first failure per process, opt-in in every SDK (Zig `assertion_events = .first`, C `det_first_pass_first_failure`, Python `assertion_events = "first"`, JVM `firstPassFirstFailure`, Clojure `first-pass-first-failure!`); guidance sent only when it improves | ✅ |
| Fallback SDK (JSONL to a file) | `ANTITHESIS_SDK_LOCAL_OUTPUT=/opt/determinismo/sdk/output`: a regular file (detfs, from the guest module) whose writes go to the platform; it can be truncated, as Antithesis's Go SDK does | ✅ |

## Faults

| Antithesis | determinismo | Status |
|---|---|---|
| Partitions (stopped, slowed, jammed; groups; asymmetric) | `partition_groups`: the runner and nodes split into 2-3 groups, stopped, slowed or jammed (held, then delivered), both ways or (half the time) one way only; single links too | ✅ |
| Clogs (a node's inbound/outbound) | `clog`: a node's inbound, outbound or both, stopped, slowed or jammed; isolate (links down) | ✅ |
| Baseline latency, restore | `network_baseline`: delay, jitter and drops (ppm) drawn per timeline, on every link that allows degradation, all run long. Network faults overlap, each link carrying the most aggressive (down, then loss, then delay); `restore` heals them all at once (logged only when some were under way). Durable disks (crash and disk faults) have theirs: `disk_baseline`, 0 to 2 ms per I/O drawn per timeline, so a sync takes time and other threads run meanwhile | ✅ |
| Node throttling, pause, kill/stop and restart | throttle, pause, restart (a kill), stop (SIGTERM, a grace period, then a kill), crash, wipe, process_kill; one at a time on a node, several nodes at once (Antithesis's overlap rule); a restarted node may rejoin at a new address (`new_address`, on for Compose projects: every hosts file follows it) | ✅ |
| Clock skips | clock_skip, forward or back; a quarter permanent, so they stack | ✅ |
| Thread pausing | `thread_pause`: one thread stopped (ptrace), the rest of its process running; process_pause too | ✅ |
| CPU modulation | on by default (`--no-cpu-modulation`, MCP and HTTP `cpu_modulation: false`, turn it off): branches run up to twice as slow for stretches of 10-200 ms of virtual time, each speed a decision (a strategy can steer it, tapes replay it), so timer interrupts and preemption land at other points | 🟡 the clock only: Antithesis also changes particular instructions' relative speed, which virtual time made of retired branches (the one count the hardware keeps deterministic) cannot express |
| Disk faults (restarts that keep durably synced changes, or lose all) | `crash` (an ext4 disk per node, shut down without flushing: what was synced survives) and `wipe` (fresh from the image); `--faults +crash` | ✅ |
| Disk I/O faults (beyond Antithesis) | `disk`: the node's disk through device-mapper, its table swapped for a while: every I/O failing, writes failing, writes acknowledged and never stored (gone at the next crash, synced or not), corrupted reads, or slow I/O (dm-flakey, dm-delay). An exit meanwhile is expected; at the end a node that exited or whose filesystem went read-only starts again. `--faults +disk`, or `sdk.fault(.{ .kind = "disk", .failure = "lost_writes", ... })` | ✅ |
| Durability points (beyond Antithesis) | the guest module makes a node's fsyncs, fdatasyncs, msyncs and sync writes decisions while a fault lasts: `sync_stall` (on by default) holds the ones picked for a drawn time, up to a second, while the node's other threads run; `durable_crash` (with `+crash`) crashes the node at one, just before its data reaches the disk or just after. Any language or store: a kprobe on `vfs_fsync_range` | ✅ |
| Custom faults | `Faults.custom`: commands in a node the injector runs at random times (they can draw randomness); quiet periods hold them too. And any fault on request from a scenario: `sdk.fault(...)` (Zig, C, Python, JVM, Clojure) or `det-faults inject '<json>'` (any language): applied, logged and undone like a drawn one | ✅ |
| Pausing faults (quiet periods) | `$DETERMINISMO_STOP_FAULTS <seconds>` (also `$ANTITHESIS_STOP_FAULTS`) in every node and command: the fault under way ends, none but clock skips start, overlapping requests merge to the longest; faults only in the driver phase | ✅ |

## Exploration

| Antithesis | determinismo | Status |
|---|---|---|
| Branching from interesting states (every event a potential branch point; guidance toward new behavior) | `--branching tree` (the default): generations of timelines; those that reached behaviors no timeline had are returned to just after them (a snapshot there) and branched with new seeds, Go-Explore style; every timeline's path in its record and tape (it replays alone); why each branch point was chosen, shown in the UI | ✅ behaviors include code coverage where the SDK instruments (C, Zig, Python, JVM lines) and new kinds of output lines; strategies may choose the moments (`returns`) |
| Pluggable guidance | strategies over a JSON protocol, any language, local (`--strategy`), remote (`tcp://`) or uploaded to serve (`@name`): random, mutate (coverage and guidance), extremes (a bandit), an LLM (Claude Haiku 5.5); a strategy's reasons go with its decisions | ✅ |
| Run duration | `--time-budget` (CLI, serve, MCP): timelines until then, `--branches` at most | ✅ |

## Results

| Antithesis | determinismo | Status |
|---|---|---|
| Triage report: environment, utilization, findings, properties | web UI (`determinismo serve`, at `/`): runs, live progress, findings, utilization, properties; text report, JSONL record (and Environment: the resolved system recorded with each run) | ✅ |
| Properties grouped (setup, efficiency, performance, correctness, SDK kinds, test composer), examples with passing/failing moments | grouped (determinismo's, always, sometimes, reachability), All/Passed/Failed, filter, failing and passing examples at their moments, each opening its logs | ✅ |
| Findings across runs (new, ongoing, resolved, rare) | `GET /runs/<id>/findings` and the UI's Findings section: against the previous finished run of the same system and scenario; rare when one timeline showed it; resolved only when missing it by chance is under 5% ((1 - k/n)^m), else unseen | ✅ |
| New behavior discovery curve | `GET /runs/<id>/discovery`, in the UI's Utilization: distinct behaviors (assertion outcomes, events, coverage) after each branch | ✅ |
| Default properties: no unexpected container exits | nodes do not exit unexpectedly | ✅ |
| Default: commands finish with zero exit code | test commands exit successfully | ✅ |
| Default: all commands started / completed at least once | "test command started: X", "test command completed: X", declared for every command | ✅ |
| Default: no unexpected crashes (error signals) | "no process crashes" (segfault, illegal instruction, ... from the kernel's log); kernel warnings, BUGs, OOM kills | ✅ |
| Default: peak memory, virtual vs wall time, logging limited | "peak memory usage stays under 95% of the machine's memory" (cgroup memory.peak); "logging output stays under 200 MB per hour of virtual time" (over all timelines' output and virtual time, as Antithesis's ratio to the simulation's CPU time: no timeline fails it alone); virtual time per wall time in every report; "the fault injector started"; exits 0, 137 and 143 are expected | ✅ |
| Language properties (Go/Rust panics, Java uncaught exceptions) | "no panics (Go)", "no fatal errors (Go)", "no data races (Go)", "no panics (Rust)", "no uncaught exceptions (Java)": the guest's output forwarder asserts each where its line appears (an assert event after the output event: queries, a run's properties and the UI see it; shown when violated) | ✅ |

## Logs and queries

| Antithesis | determinismo | Status |
|---|---|---|
| Retroactive logging (verbose output to a black hole, regenerated by replay) | `explore --retroactive '<text>'` (repeatable; serve, MCP): output lines with it are not written while exploring, yet count (events hash, behaviors, the logging limit); replaying a timeline (`--branch`, a tape, a moment) writes them | ✅ |
| Event log: every event with its moment (vtime, timeline) | events JSONL with vtime and branches clock | ✅ |
| Container stdout/stderr as events | node and test command output, line by line, `{"output":{source, stream, text}}` | ✅ |
| Events of every timeline, queryable | `explore --events-dir`: setup, fork, and every branch, ingested as each timeline finishes into the run's events database (DuckDB 2.0, store.zig), where every search, panel, event set and notebook query runs; read-only SQL too (`POST /runs/<id>/sql`, MCP `sql`) | ✅ |
| Logs Explorer search: fields, operators, preceded by / followed by within N seconds | `determinismo query`, HTTP `POST /runs/<id>/query`, MCP `query`: paths, `= != ~ !~ =~ !=~ < <= > >= ? !?` (`=~` a regular expression), and/or, (not) preceded/followed by, within | ✅ |
| Event sets: matches, contains, filter, union, up_to(moment) | conditions, `or`, `--branch`, `--up-to-vtime` | ✅ |
| Event sets: map, fold, with_last, with_next, intersect, difference | `determinismo events` (HTTP, MCP): a JSON pipeline of filter, exclude, with_last, with_next (timeouts), union, intersect, difference, narrow, and `through`: any program as map, flatmap and fold | ✅ |
| Logs Explorer / multiverse map UI | web UI: search with temporal conditions, a timeline's logs up to a moment (with what it shares with its ancestors), the multiverse as a tree (shared prefixes, branch points, forks) with its faults and failures and tooltips saying why; run a command at any moment, fork from it | ✅ |

## Debugging (multiverse)

| Antithesis | determinismo | Status |
|---|---|---|
| Moment (timeline + vtime), `branch()` | `--from-branch N --from-vtime-ms T` | ✅ |
| `rewind`, `rewind_to` | moments by vtime; `--until <condition> --rewind-ms <ms>` (MCP/HTTP `rewind_ms`, the UI's rewind field) | ✅ |
| `wait(duration)` | `--at-vtime-ms` | ✅ |
| `wait_until(event set, timeout)` | `--until '<condition>'` (CLI, HTTP replay, MCP replay): the moment is the first matching event, with `--at-vtime-ms` as its timeout ("until: timed out"); with `--exec`, a command runs there | ✅ |
| bash on a branch (`run`, `run_in_background`), process output | `--exec` at a moment (in a node with `det-nodes exec`), `--continue` | ✅ |
| Counterfactuals (change something, see if the bug recurs) | `--from-exec` explores futures of a changed system | ✅ |
| `extract_file` | `determinismo extract` (and HTTP, the UI's "Extract the file" at any moment): a node's file at a moment, exact bytes | ✅ |
| `inject_file` | `determinismo inject`: a local file into a node at a moment, any size (`--exec-script` runs a moment's commands in order), then `--then` and `--continue` | ✅ |
| Profiler (`profiler.start/stop/report`, flame graph) | `determinismo profile`: det-profile samples a node's threads every interval of virtual time (ptrace, frame pointers, ELF symbols): top functions, folded stacks, an SVG flame graph; the same twice | ✅ |
| `containers.list`, `fault_injector.pause/unpause` | `det-nodes list` at a moment (name, state, pid, address, image); `det-stop-faults <seconds>` and `det-stop-faults 0` | ✅ |
| Core dumps | det-core (the kernel's core_pattern) keeps every crashed process's core in `/run/det/cores`, with a `core_dump` event; `extract --file runner:<path>` takes it out | ✅ |
| Debuggers (gdb, delve, jdb) | `determinismo stacks`: every thread's named stack at a moment (`thread apply all bt`, jstack); gdb and the like through `--exec` with the tools in the image, on the process or a core dump | ✅ |
| Causality analysis (bug probability over time; which events make the bug much more likely; a copyable curl command) | `determinismo causality` (CLI, HTTP job, MCP tool), and a button on every failing example in the UI, with a chart whose bars open the logs; the faults the futures went through, ranked by how much more often futures with one failed than without it (`fault_effects`); "copy as curl" | ✅ |
| Re-run a test | "Run again" on a finished run's page: its request, a fresh seed, the host's current build of its program | ✅ |
| Notebook | the UI's Notebook view of a run: Clojure cells evaluated in order by babashka on the server (`serve --bb`), with shared names: `run`, `query`, `events`, `md`, and actions run on a click (`replay`, `stacks`, `profile`, `extract`); kept with the run (`/runs/<id>/notebook`). A babashka nREPL server per run (`POST /runs/<id>/nrepl`) with the same names, for editors; there actions run at once. Branches grown from a moment step by step (advanced multiverse debugging): `(-> (branch {:branch 0 :at_vtime_ms 1550}) (bash "cmd" {:node "redis"}) (bash-bg "cmd") (wait 500) (wait-until "<condition>" {:timeout_ms 2000}) run-branch)` gives each step's end moment and every command as a process (`:output`, `:exit-code`, `:started-ns`, `:ended-ns`, `exited-by?`); over HTTP, `POST /runs/<id>/replay` with `steps`; on the CLI, `--exec-script` lines `det:background`, `det:wait`, `det:until` | 🟡 a branch's future keeps its timeline's randomness (fork gives new futures); no containers API in cells (`bash` with `det-nodes`, or a node) |
| Agent skills (research, workload, debug, mutation testing) | Claude Code skills in `.claude/skills/`: determinismo-properties, determinismo-workload, determinismo-debug, determinismo-mutants | ✅ |
| Mutation testing campaigns (agents write subtle mutants; caught, never ran, or ran unnoticed) | `determinismo mutate --mutants mutants.jsonl`: each mutant a patch to a node's build context, explored with the system's seed; caught, never ran (line coverage), or unnoticed; the determinismo-mutants skill writes them; the MCP `mutate` tool | ✅ |
| Targeted runs (a change's code, from a diff) | `explore --changed <diff file \| git range>` (CLI, serve, MCP): hunks matched to line coverage (repository and image paths reconciled), the tree returns first to timelines that ran changed code, and the report says which hunks ran in how many timelines and which never ran | 🟡 no distance to unreached changed code (directed fuzzing); C and Zig edges are not lines |
| Snouty CLI for agents (runs, properties, search, exec, debug) | `determinismo runs` (list, show, properties --details, logs, search, exec, start, stop: serve's API from a shell); MCP (`describe`, `explore`, `replay`, `fork`, `query`) | ✅ |
