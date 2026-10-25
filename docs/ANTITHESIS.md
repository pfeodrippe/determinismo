# Antithesis parity map

determinismo follows the Antithesis documentation (https://antithesis.com/docs/llms.txt) as its
feature checklist. Each row is an Antithesis feature, where determinismo stands, and what is
next. ✅ done and tested by `zig build e2e`; 🟡 partial; ❌ missing. Update the row with the
change that moves it.

## Setup and the system under test

| Antithesis | determinismo | Status |
|---|---|---|
| Docker Compose setup | `--compose` importer: images, builds, env, depends_on, ports, mem_limit, privileged | ✅ |
| Kubernetes setup | K3s in a privileged node, or a three-node cluster (`examples/k3s`) | 🟡 no importer for your own manifests: the example is a template |
| Setup mode, `setup_complete` | snapshot at `setup_complete` (SDKs, composer, `setup_` template commands) | ✅ |
| The Antithesis environment (one vCPU, no rdrand, deterministic time) | patched KVM, branches clock, CPUID baseline | ✅ |
| Handling external dependencies | no network beyond the guest; [DEPENDENCIES.md](DEPENDENCIES.md): containers or mocks (MinIO, LocalStack, emulators, stripe-mock), names, readiness, storage, memory | ✅ |

## Writing tests

| Antithesis | determinismo | Status |
|---|---|---|
| Test templates, test commands (first, parallel/serial/singleton drivers, anytime, eventually, finally) | composer follows the reference | ✅ |
| Assertions: always, always-or-unreachable, sometimes, reachable, unreachable | Zig, C, Python, JVM SDKs; Antithesis SDK messages accepted. Judged as Antithesis does: a timeline violates only `always`-style properties and `unreachable`; `sometimes` (true in some timeline), `reachable`, and an `always` never hit are judged across the multiverse | 🟡 no Go, Rust or JavaScript SDK |
| Assertion catalog (declared, not yet hit) | Automatic in every SDK, as code loads, before it runs: Zig (a section entry per call site, announced at startup), C (`DET_*` macros, same section, a constructor), JVM (a Java agent reads each class's bytecode as it loads: Java, Kotlin, Scala, AOT Clojure), Clojure (macros declare as the namespace compiles), Python (each module's syntax tree as it runs). A test program's catalog spans its scenarios and is judged over all of them; an assertion no timeline reaches fails | ✅ |
| Randomness (SDK random) | SDK random, `rng()`, `prng()`; kernel reseeded per branch | ✅ |
| Lifecycle | `setup_complete`, `guest_done` | ✅ |
| Coverage instrumentation | C, Zig (edges), Python, JVM (lines); used by `mutate` | 🟡 opt-in per language (build flags, `coverage_start`, a Java agent); edges never map back to source lines |
| Guidance assertions (`alwaysGreaterThan`, `sometimesLessThan`, ..., `alwaysSome`, `sometimesAll`) | In every SDK (Zig, C, Python, JVM, Clojure): the compared values in the details, and a guidance event with the distance to the interesting outcome; det-strategy-mutate keeps timelines that come closer (the sum maze: solved guided, missed in 300 random timelines) | ✅ |
| Assertion locations and ids; first pass and first failure per process | locations (file, line, function) in every SDK: C (macros), Python (the caller's frame), the JVM and Clojure (StackWalker, once per assertion), Zig (the return address and the program's debug info); in the report, the record and the UI. First pass and first failure per process, opt-in in every SDK (Zig `assertion_events = .first`, C `det_first_pass_first_failure`, Python `assertion_events = "first"`, JVM `firstPassFirstFailure`, Clojure `first-pass-first-failure!`); guidance sent only when it improves | ✅ |
| Fallback SDK (JSONL to a file) | `ANTITHESIS_SDK_LOCAL_OUTPUT=/dev/determinismo` | ✅ |

## Faults

| Antithesis | determinismo | Status |
|---|---|---|
| Partitions (stopped, slowed, jammed; groups; asymmetric) | `partition_groups`: the runner and nodes split into 2-3 groups, stopped, slowed or jammed (held, then delivered); single links too, either direction | ✅ |
| Clogs (a node's inbound/outbound) | `clog`: a node's inbound, outbound or both, stopped, slowed or jammed; isolate (links down) | ✅ |
| Baseline latency, restore | `network_baseline`: delay, jitter and drops (ppm) drawn per timeline, on every link that allows degradation, all run long. Network faults overlap, each link carrying the most aggressive (down, then loss, then delay); `restore` heals them all at once (logged only when some were under way) | ✅ |
| Node throttling, pause, kill/stop and restart | throttle, pause, restart, process_kill | 🟡 no graceful stop: a restart always kills |
| Clock skips | clock_skip, forward or back; a quarter permanent, so they stack | ✅ |
| Thread pausing | `thread_pause`: one thread stopped (ptrace), the rest of its process running; process_pause too | ✅ |
| CPU modulation | `--cpu-modulation` (CLI, MCP, HTTP): branches run up to twice as slow for stretches of 10-200 ms of virtual time, each speed a decision (a strategy can steer it, tapes replay it), so timer interrupts and preemption land at other points | 🟡 opt-in; Antithesis turns it on with faults |
| Disk faults (the mutation campaign's) | none | ❌ |
| Custom faults | `Faults.custom`: commands in a node the injector runs at random times (they can draw randomness); quiet periods hold them too | ✅ |
| Pausing faults (quiet periods) | `$DETERMINISMO_STOP_FAULTS <seconds>` (also `$ANTITHESIS_STOP_FAULTS`) in every node and command: the fault under way ends, none but clock skips start, overlapping requests merge to the longest; faults only in the driver phase | ✅ |

## Exploration

| Antithesis | determinismo | Status |
|---|---|---|
| Branching from interesting states (every event a potential branch point; guidance toward new behavior) | `--branching tree` (default in the UI): generations of timelines; those that reached behaviors no timeline had are returned to just after them (a snapshot there) and branched with new seeds, Go-Explore style; every timeline's path in its record and tape (it replays alone); why each branch point was chosen, shown in the UI | 🟡 opt-in on the CLI; moments from coverage not yet; strategies cannot choose the moments yet |
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
| Default: peak memory, virtual vs wall time, logging limited | "peak memory usage stays under 95% of the machine's memory" (cgroup memory.peak); "logging output stays under 200 MB per hour of virtual time"; virtual time per wall time in every report; "the fault injector started"; exits 0, 137 and 143 are expected | ✅ |
| Language properties (Go/Rust panics, Java uncaught exceptions) | "no panics (Go)", "no fatal errors (Go)", "no data races (Go)", "no panics (Rust)", "no uncaught exceptions (Java)", from output events (shown when violated) | ✅ |

## Logs and queries

| Antithesis | determinismo | Status |
|---|---|---|
| Retroactive logging (verbose output to a black hole, regenerated by replay) | every line is stored | ❌ |
| Event log: every event with its moment (vtime, timeline) | events JSONL with vtime and branches clock | ✅ |
| Container stdout/stderr as events | node and test command output, line by line, `{"output":{source, stream, text}}` | ✅ |
| Events of every timeline, queryable | `explore --events-dir`: setup, fork, and every branch (serve and MCP record them) | ✅ |
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
| Causality analysis (bug probability over time) | `determinismo causality` (CLI, HTTP job, MCP tool), and a button on every failing example in the UI, with a chart whose bars open the logs | ✅ |
| Notebook | the UI's Notebook view of a run: Clojure cells evaluated in order by babashka on the server (`serve --bb`), with shared names: `run`, `query`, `events`, `md`, and actions run on a click (`replay`, `stacks`, `profile`, `extract`); kept with the run (`/runs/<id>/notebook`). A babashka nREPL server per run (`POST /runs/<id>/nrepl`) with the same names, for editors; there actions run at once | 🟡 no process objects, `run_in_background` or containers API in cells |
| Agent skills (research, workload, debug, mutation testing) | docs/AGENTS.md only | ❌ |
| Mutation testing campaigns (agents write subtle mutants; caught, never ran, or ran unnoticed) | one hand-made mutant in the e2e | ❌ |
| Targeted runs (a change's code, from a diff) | none | ❌ |
| Snouty CLI for agents (runs, properties, search, exec, debug) | CLI, MCP (`describe`, `explore`, `replay`, `fork`, `query`) | ✅ |
