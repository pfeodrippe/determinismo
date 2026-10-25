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
| Assertions: always, always-or-unreachable, sometimes, reachable, unreachable | Zig, C, Python, JVM SDKs; Antithesis SDK messages accepted | ✅ |
| Assertion catalog (declared, not yet hit) | `hit: false` entries are accepted | 🟡 not reported as "never reached" |
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
| Triage report: environment, utilization, findings, properties | text report, JSONL record, HTTP API | 🟡 no report UI |
| Properties grouped (setup, efficiency, performance, correctness, SDK kinds, test composer), examples with passing/failing moments | per-property pass/fail with an example branch | 🟡 no groups, one example |
| Findings across runs (new, ongoing, resolved, rare) | ❌ | ❌ |
| New behavior discovery curve | ❌ | ❌ |
| Default properties: no unexpected container exits | nodes do not exit unexpectedly | ✅ |
| Default: commands finish with zero exit code | test commands exit successfully | ✅ |
| Default: all commands started / completed at least once | ❌ | ❌ |
| Default: no unexpected crashes (error signals) | kernel warnings, BUGs, OOM kills | 🟡 no per-process crash signals |
| Default: peak memory, virtual vs wall time, logging limited | ❌ | ❌ |
| Language properties (Go/Rust panics, Java uncaught exceptions) | ❌ needs node output as events | ❌ |

## Logs and queries

| Antithesis | determinismo | Status |
|---|---|---|
| Event log: every event with its moment (vtime, timeline) | events JSONL with vtime and branches clock | ✅ |
| Container stdout/stderr as events | node output goes to a file only | ❌ next |
| Events of every timeline, queryable | `--events` records one branch | ❌ next |
| Logs Explorer search: fields, operators, preceded by / followed by within N seconds | ❌ | ❌ next: `determinismo query` |
| Event sets: matches, contains, filter, map, union, intersect, difference, fold, with_last, with_next, up_to(moment) | ❌ | ❌ next: `determinismo query` |
| Logs Explorer / multiverse map UI | ❌ | ❌ web UI in `serve` |

## Debugging (multiverse)

| Antithesis | determinismo | Status |
|---|---|---|
| Moment (timeline + vtime), `branch()` | `--from-branch N --from-vtime-ms T` | ✅ |
| `rewind`, `rewind_to` | moments by vtime | 🟡 no relative rewind |
| `wait(duration)` | `--at-vtime-ms` | ✅ |
| `wait_until(event set, timeout)` | ❌ | ❌ next: `--until <query>` |
| bash on a branch (`run`, `run_in_background`), process output | `--exec` at a moment (in a node with `det-nodes exec`), `--continue` | ✅ |
| Counterfactuals (change something, see if the bug recurs) | `--from-exec` explores futures of a changed system | ✅ |
| `extract_file`, `inject_file` | ❌ | ❌ |
| Profiler, core dumps, debuggers (gdb, delve, jdb) | possible through `--exec` with the tools in the image | 🟡 no helpers |
| Causality analysis (bug probability over time) | ❌ | ❌ next |
| Notebook | MCP tools, HTTP API, CLI | 🟡 no notebook |
| Snouty CLI for agents (runs, properties, search, exec, debug) | CLI, MCP (`describe`, `explore`, `replay`, `fork`) | 🟡 no search tool yet |
