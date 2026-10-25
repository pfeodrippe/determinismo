# Antithesis parity map

determinismo follows the Antithesis documentation (https://antithesis.com/docs/llms.txt) as its
feature checklist. Each row is an Antithesis feature, where determinismo stands, and what is
next. ✅ done and tested by `zig build e2e`; 🟡 partial; ❌ missing. Update the row with the
change that moves it.

## Setup and the system under test

| Antithesis | determinismo | Status |
|---|---|---|
| Docker Compose setup | `--compose` importer: images, builds, env, depends_on, ports, mem_limit, privileged | ✅ |
| Kubernetes setup | K3s in a privileged node, or a three-node cluster (`examples/k3s`) | ✅ |
| Setup mode, `setup_complete` | snapshot at `setup_complete` (SDKs, composer, `setup_` template commands) | ✅ |
| The Antithesis environment (one vCPU, no rdrand, deterministic time) | patched KVM, branches clock, CPUID baseline | ✅ |
| Handling external dependencies | no network beyond the guest; [DEPENDENCIES.md](DEPENDENCIES.md): containers or mocks (MinIO, LocalStack, emulators, stripe-mock), names, readiness, storage, memory | ✅ |

## Writing tests

| Antithesis | determinismo | Status |
|---|---|---|
| Test templates, test commands (first, parallel/serial/singleton drivers, anytime, eventually, finally) | composer follows the reference | ✅ |
| Assertions: always, always-or-unreachable, sometimes, reachable, unreachable | Zig, C, Python, JVM SDKs; Antithesis SDK messages accepted. Judged as Antithesis does: a timeline violates only `always`-style properties and `unreachable`; `sometimes` (true in some timeline), `reachable`, and an `always` never hit are judged across the multiverse | ✅ |
| Assertion catalog (declared, not yet hit) | `hit: false` declares (`sdk.declare`): a declared `reachable`/`sometimes` that no timeline reaches fails | ✅ |
| Randomness (SDK random) | SDK random, `rng()`, `prng()`; kernel reseeded per branch | ✅ |
| Lifecycle | `setup_complete`, `guest_done` | ✅ |
| Coverage instrumentation | C, Zig (edges), Python, JVM (lines); used by `mutate` | ✅ |
| Fallback SDK (JSONL to a file) | `ANTITHESIS_SDK_LOCAL_OUTPUT=/dev/determinismo` | ✅ |

## Faults

| Antithesis | determinismo | Status |
|---|---|---|
| Partitions (stopped, slowed, jammed; groups; asymmetric) | `partition_groups`: the runner and nodes split into 2-3 groups, stopped, slowed or jammed (held, then delivered); single links too, either direction | ✅ |
| Clogs (a node's inbound/outbound) | `clog`: a node's inbound, outbound or both, stopped, slowed or jammed; isolate (links down) | ✅ |
| Baseline latency, restore | degrade flavors | 🟡 no always-on baseline, no explicit restore |
| Node throttling, pause, kill/stop and restart | throttle, pause, restart, process_kill | ✅ |
| Clock skips | clock_skip, forward or back; a quarter permanent, so they stack | ✅ |
| Thread pausing | `thread_pause`: one thread stopped (ptrace), the rest of its process running; process_pause too | ✅ |
| CPU modulation | ❌ | ❌ |
| Custom faults | `Faults.custom`: commands in a node the injector runs at random times (they can draw randomness); quiet periods hold them too | ✅ |
| Pausing faults (quiet periods) | `$DETERMINISMO_STOP_FAULTS <seconds>` (also `$ANTITHESIS_STOP_FAULTS`) in every node and command: the fault under way ends, none but clock skips start, overlapping requests merge to the longest; faults only in the driver phase | ✅ |

## Results

| Antithesis | determinismo | Status |
|---|---|---|
| Triage report: environment, utilization, findings, properties | web UI (`determinismo serve`, at `/`): runs, live progress, findings, utilization, properties; text report, JSONL record (and Environment: the resolved system recorded with each run) | ✅ |
| Properties grouped (setup, efficiency, performance, correctness, SDK kinds, test composer), examples with passing/failing moments | grouped (determinismo's, always, sometimes, reachability), All/Passed/Failed, filter, failing and passing examples at their moments, each opening its logs | ✅ |
| Findings across runs (new, ongoing, resolved, rare) | `GET /runs/<id>/findings` and the UI's Findings section: against the previous finished run of the same system and scenario; rare when one timeline showed it | ✅ (not yet statistical, as Antithesis's "resolved") |
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
| Event log: every event with its moment (vtime, timeline) | events JSONL with vtime and branches clock | ✅ |
| Container stdout/stderr as events | node and test command output, line by line, `{"output":{source, stream, text}}` | ✅ |
| Events of every timeline, queryable | `explore --events-dir`: setup, fork, and every branch (serve and MCP record them) | ✅ |
| Logs Explorer search: fields, operators, preceded by / followed by within N seconds | `determinismo query`, HTTP `POST /runs/<id>/query`, MCP `query`: paths, `= != ~ !~ < <= > >= ? !?`, and/or, (not) preceded/followed by, within | ✅ (no regex yet) |
| Event sets: matches, contains, filter, union, up_to(moment) | conditions, `or`, `--branch`, `--up-to-vtime` | ✅ |
| Event sets: map, fold, with_last, with_next, intersect, difference | `determinismo events` (HTTP, MCP): a JSON pipeline of filter, exclude, with_last, with_next (timeouts), union, intersect, difference, narrow, and `through`: any program as map, flatmap and fold | ✅ |
| Logs Explorer / multiverse map UI | web UI: search with temporal conditions, a timeline's logs up to a moment, a map of every timeline with its faults and failures; run a command at any moment | ✅ |

## Debugging (multiverse)

| Antithesis | determinismo | Status |
|---|---|---|
| Moment (timeline + vtime), `branch()` | `--from-branch N --from-vtime-ms T` | ✅ |
| `rewind`, `rewind_to` | moments by vtime; `--until <condition> --rewind-ms <ms>` (MCP/HTTP `rewind_ms`, the UI's rewind field) | ✅ |
| `wait(duration)` | `--at-vtime-ms` | ✅ |
| `wait_until(event set, timeout)` | `--until '<condition>'` (CLI, HTTP replay, MCP replay): the moment is the first matching event; with `--exec`, a command runs there | ✅ (no timeout yet) |
| bash on a branch (`run`, `run_in_background`), process output | `--exec` at a moment (in a node with `det-nodes exec`), `--continue` | ✅ |
| Counterfactuals (change something, see if the bug recurs) | `--from-exec` explores futures of a changed system | ✅ |
| `extract_file` | `determinismo extract` (and HTTP, the UI's "Extract the file" at any moment): a node's file at a moment, exact bytes | ✅ |
| `inject_file` | `determinismo inject`: a local file into a node at a moment, any size (`--exec-script` runs a moment's commands in order), then `--then` and `--continue` | ✅ |
| Profiler, core dumps, debuggers (gdb, delve, jdb) | possible through `--exec` with the tools in the image | 🟡 no helpers |
| Causality analysis (bug probability over time) | `determinismo causality` (CLI, HTTP job, MCP tool), and a button on every failing example in the UI, with a chart whose bars open the logs | ✅ |
| Notebook | web UI (logs, search, run a command at a moment), MCP tools, HTTP API, CLI | 🟡 no scripting notebook |
| Snouty CLI for agents (runs, properties, search, exec, debug) | CLI, MCP (`describe`, `explore`, `replay`, `fork`, `query`) | ✅ |
