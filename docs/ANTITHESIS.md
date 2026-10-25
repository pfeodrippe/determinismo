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
| Handling external dependencies | no network beyond the guest; nodes get a default route through the runner | 🟡 no guidance doc yet |

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
| Partitions (stopped, slowed, jammed; groups; asymmetric) | per link, one or both directions; delay, loss | 🟡 no multi-node groups, no "jammed" |
| Clogs (a node's inbound/outbound) | isolate (all links of a node), degrade per direction | ✅ |
| Baseline latency, restore | degrade flavors | 🟡 no always-on baseline, no explicit restore |
| Node throttling, pause, kill/stop and restart | throttle, pause, restart, process_kill | ✅ |
| Clock skips | clock_skip (temporary) | 🟡 not permanent or stacking |
| Thread pausing | process_pause (whole process) | 🟡 not per thread |
| CPU modulation | ❌ | ❌ |
| Custom faults | ❌ | ❌ |
| Pausing faults (quiet periods) | faults only in the driver phase | 🟡 no API to pause/unpause |

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
| Default: peak memory, virtual vs wall time, logging limited | ❌ | ❌ |
| Language properties (Go/Rust panics, Java uncaught exceptions) | "no panics (Go)", "no fatal errors (Go)", "no data races (Go)", "no panics (Rust)", "no uncaught exceptions (Java)", from output events (shown when violated) | ✅ |

## Logs and queries

| Antithesis | determinismo | Status |
|---|---|---|
| Event log: every event with its moment (vtime, timeline) | events JSONL with vtime and branches clock | ✅ |
| Container stdout/stderr as events | node and test command output, line by line, `{"output":{source, stream, text}}` | ✅ |
| Events of every timeline, queryable | `explore --events-dir`: setup, fork, and every branch (serve and MCP record them) | ✅ |
| Logs Explorer search: fields, operators, preceded by / followed by within N seconds | `determinismo query`, HTTP `POST /runs/<id>/query`, MCP `query`: paths, `= != ~ !~ < <= > >= ? !?`, and/or, (not) preceded/followed by, within | ✅ (no regex yet) |
| Event sets: matches, contains, filter, union, up_to(moment) | conditions, `or`, `--branch`, `--up-to-vtime` | ✅ |
| Event sets: map, fold, with_last, with_next, intersect, difference | ❌ | ❌ |
| Logs Explorer / multiverse map UI | web UI: search with temporal conditions, a timeline's logs up to a moment, a map of every timeline with its faults and failures; run a command at any moment | ✅ |

## Debugging (multiverse)

| Antithesis | determinismo | Status |
|---|---|---|
| Moment (timeline + vtime), `branch()` | `--from-branch N --from-vtime-ms T` | ✅ |
| `rewind`, `rewind_to` | moments by vtime | 🟡 no relative rewind |
| `wait(duration)` | `--at-vtime-ms` | ✅ |
| `wait_until(event set, timeout)` | `--until '<condition>'` (CLI, HTTP replay, MCP replay): the moment is the first matching event; with `--exec`, a command runs there | ✅ (no timeout yet) |
| bash on a branch (`run`, `run_in_background`), process output | `--exec` at a moment (in a node with `det-nodes exec`), `--continue` | ✅ |
| Counterfactuals (change something, see if the bug recurs) | `--from-exec` explores futures of a changed system | ✅ |
| `extract_file` | `determinismo extract` (and HTTP, the UI's "Extract the file" at any moment): a node's file at a moment, exact bytes | ✅ |
| `inject_file` | a command at a moment (`--exec`, `--continue`) can write it | 🟡 no direct upload |
| Profiler, core dumps, debuggers (gdb, delve, jdb) | possible through `--exec` with the tools in the image | 🟡 no helpers |
| Causality analysis (bug probability over time) | `determinismo causality` (CLI, HTTP job, MCP tool), and a button on every failing example in the UI, with a chart whose bars open the logs | ✅ |
| Notebook | web UI (logs, search, run a command at a moment), MCP tools, HTTP API, CLI | 🟡 no scripting notebook |
| Snouty CLI for agents (runs, properties, search, exec, debug) | CLI, MCP (`describe`, `explore`, `replay`, `fork`, `query`) | ✅ |
