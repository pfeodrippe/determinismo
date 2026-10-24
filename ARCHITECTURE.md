# determinismo — architecture & plan

determinismo is a deterministic simulation platform in the spirit of Antithesis: run a whole
system (containers, network, clocks, randomness) inside one deterministic VM, explore many
timelines from shared snapshots, inject faults, and reproduce any moment exactly.

Priorities, in order: **correct determinism**, **maximum throughput**, **no tech debt**.

---

## 1. Terminology

| Term | Meaning |
|---|---|
| Hypervisor | The whole stack that runs VMs: host KVM + `determinismo.ko` + the Zig VMM. |
| VMM | The userspace process (Zig) that owns guest memory, devices, the vCPU loop, snapshots. |
| Guest | The Linux VM running the system under test (SUT). |
| Determinism | Same inputs → same instruction-level execution. Provided by the hypervisor. |
| Steerability | The ability to change an input at a chosen point. Provided by routing entropy and actions through the platform. |
| Input | Anything that enters the guest from outside: a pulled value or a pushed event. |
| Tape | The recorded inputs of a timeline. A timeline *is* (base snapshot + tape). |
| vtime | Virtual time; a pure function of the guest's execution history. |
| Moment | `(tape hash, vtime)` — an immutable instant in the multiverse. |
| Branch | A timeline that forks from a moment and continues with different inputs. |
| Decision point | A point where an input may enter: a pull (hypercall) or a push (exact instruction count). |

---

## 2. Big picture

```
                         ┌──────────────────────── control plane (Zig) ────────────────────────┐
  users / CI / UI ──HTTP─▶ controller ── explorer (multiverse tree) ── strategy plugins (any lang)│
                         │      │                      ▲ observations      │ decisions           │
                         └──────┼──────────────────────┼───────────────────┼─────────────────────┘
                                │ worker protocol (also implemented by a fake backend, §13)
             ┌──────────────────▼──────────── one bare-metal host ────────────────────────────┐
             │ worker (Zig): N VMs, one per physical core                                      │
             │   ┌──────────────────────────┐   ┌──────────────────────────┐                  │
             │   │ Zig VMM #1  (core 0)     │   │ Zig VMM #2  (core 1) ... │   userspace      │
             │   └────────────┬─────────────┘   └────────────┬─────────────┘                  │
             │ ───────────────┼── /dev/kvm + shared pages ───┼──────────────────── kernel ──── │
             │   KVM (kvm.ko + kvm-intel.ko, small hook patch) + determinismo.ko (C)           │
             └─────────────────────────────────────────────────────────────────────────────────┘
                                │ VM entry/exit
             ┌──────────────────▼─────────── guest (1 vCPU) ──────────────────────────────────┐
             │ Linux LTS (our config + small steerability patches)                             │
             │ guest agent (init, container runtime, fault actuators, exec/nREPL bridge)       │
             │ containers of the SUT (Compose; K3s later) + simulated network between them     │
             │ SDKs → hypercalls (assertions, events, randomness, lifecycle, coverage)         │
             └─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Key decisions

| # | Decision | Why |
|---|---|---|
| D1 | **KVM on Linux**, not a bhyve fork. | Ecosystem, hardware support, runs on any bare metal where we control the kernel. |
| D2 | **Patch KVM minimally** (hook points in `kvm-intel`); all logic in our own **`determinismo.ko`** (C). | Kernel upgrades = re-apply a tiny patch, not port logic. Zig in-kernel would itself be debt. The patch must also export the hook API to `determinismo.ko`: upstream limits KVM's internal exports to `kvm-intel`/`kvm-amd` (`EXPORT_SYMBOL_FOR_KVM_INTERNAL`). |
| D3 | **No "stock KVM + cooperating guest" mode.** | Stock KVM cannot do RDTSC exiting or MTF (`vmx.c` clears `CPU_BASED_RDTSC_EXITING` and `CPU_BASED_MONITOR_TRAP_FLAG`); building around that is throwaway work. |
| D4 | **Intel VMX first**, clean seam for an AMD SVM backend later (not built now). | Most reliable PMU; same choice as Antithesis. |
| D5 | **One vCPU per VM, one VM per physical core.** | Instruction-level determinism; throughput comes from parallel VMs. |
| D6 | **Hot exits handled in-kernel; only decisions go to userspace.** | 7µs userspace exits × 1M RDTSC/s = 8× slowdown; in-kernel ≈ 0.5µs. |
| D7 | **Guest I/O to the platform via `VMCALL` hypercalls**; minimal virtio-mmio devices for disk/console only. | One exit per message; no virtio queues for the control channel. |
| D8 | **No async device threads** (`ioeventfd`/`irqfd`). | Async completion timing is nondeterministic. |
| D9 | **Whole SUT in one VM; network simulated inside the guest.** No external virtio-net. | Faults apply per link between containers; nothing leaves the box. |
| D10 | **Guest memory backed by `memfd`** from day one; branches map it `MAP_PRIVATE` (COW). | Cheap branching now; swap to an in-kernel VM fork later behind the same interface. |
| D11 | **Tapes, not states, are the durable artifact.** | Any state is recomputable from base snapshot + tape (§11). |
| D12 | **Fixed CPUID baseline "determinismo VM v1"**, the intersection of the fleet's CPUs minus nondeterministic features. | Same guest-visible CPU everywhere; prerequisite for cross-model replay. |
| D13 | **Plugin protocol = one schema, two transports**: JSON-RPC over stdio (now), C ABI in-process (later). | Any language can write strategies/faults; hot strategies can go in-process. |
| D14 | **Controller ↔ worker only through a protocol**, never directly to KVM. | Lets determinismo test its own control plane with a fake backend (§13). |
| D15 | Languages: **Zig** (VMM, worker, controller, explorer), **C** (kernel module, C SDK), SDKs per language. | |
| D16 | **Open source, MIT.** Exceptions, marked per file with SPDX headers: patches to Linux files (KVM hook patch, guest-kernel patches) are `GPL-2.0-only`; `determinismo.ko` is our own code under `GPL-2.0-only OR MIT` with `MODULE_LICENSE("Dual MIT/GPL")`. Userspace talks to the kernel only via syscalls/ioctls (UAPI headers carry the Linux-syscall-note). No code copied from GPL userspace projects (e.g. QEMU); Apache-2.0/BSD code (Firecracker, Cloud Hypervisor, rust-vmm) may be reused with its notices. | Patches to GPL files can't be relicensed; everything we author can be MIT. Users, including companies, can use and embed the MIT parts freely. |

---

## 4. Host side: KVM patch + `determinismo.ko`

### 4.1 Exit taxonomy

| Exit | Where handled | Behaviour |
|---|---|---|
| `RDTSC` / `RDTSCP` | kernel | Return virtual TSC computed from the instruction counter. |
| `RDRAND` / `RDSEED` | kernel | Return values from the timeline's seeded PRNG (counted as pulls, §7). |
| PMU overflow (PMI) | kernel | Arrives early by a safety margin; enable MTF and single-step to the exact count. |
| MTF step | kernel | Advance to the target count; at target, deliver the pending event or exit to the VMM. |
| LAPIC timer | kernel | Deadline expressed in vtime; fires at an exact instruction count. |
| `HLT` | kernel | Skip vtime ahead to min(next timer deadline, next device event published by the VMM). |
| `CPUID` | kernel (stock) | Fixed table set from the VMM (baseline v1). |
| `VMCALL` | VMM | Hypercall ABI (§6). |
| virtio-mmio kicks | VMM | Handled synchronously at the exit point; batched by queue design. |
| Push-event target reached | VMM | Inject the decided event, then resume. |

### 4.2 KVM determinism audit (disable or control)

- In-kernel LAPIC timer on host hrtimers → replaced by vtime-driven timer.
- APICv / posted interrupts → `enable_apicv=0`.
- kvmclock, async page faults, steal time, PV EOI, PV TLB flush → hidden in CPUID.
- TSX → `tsx=off` on hosts; never advertised.
- Halt polling → off (wastes CPU; HLT skips ahead instead).
- Host interrupts, EPT faults, SMIs → invisible to guest state; only affect speed.

### 4.3 Kernel ↔ VMM interface

- One **shared page per vCPU**: virtual clock state, next device deadline, instruction count,
  pending push target, per-exit-reason counters and timings. No ioctl per tick.
- New ioctls behind a capability flag: enable determinism mode, set vtime function parameters,
  arm a push target (instruction count), read/write checkpoint state hash.

### 4.4 Instruction counting and virtual time

- Counter source: **retired instructions** (Antithesis's choice) vs **retired conditional branches**
  (rr's choice). M1 benchmarks both; pick one before M2 is frozen.
- Known hardware limits (from Antithesis): ~1 in 10¹² instructions miscounted; PMI skid of dozens
  of instructions, variable. Mitigations: early overflow + MTF stepping; state-hash checkpoints
  in the tape to detect divergence on replay.
- `vtime = f(instruction count, per-event charges, modulation parameters)`. The parameters are
  inputs too, which gives **CPU modulation** as a fault (clock-speed strobing, per-operation cost
  changes) for free.

### 4.5 Host configuration

Pinned LTS kernel; modules built out-of-tree against it in CI; Secure Boot off or modules signed;
vCPU threads pinned; `isolcpus`/`nohz_full` for VM cores; `mitigations=` and
`kvm-intel.vmentry_l1d_flush` reviewed for benchmarks; on hybrid CPUs, VMs only on P-cores.

---

## 5. Guest

- **Kernel**: Linux LTS, our config: virtio-mmio, no ACPI/PCI, io_uring on. Small patches for
  *steerability only* (determinism must never depend on them):
  - kernel RNG and vDSO `getrandom` pull from the platform;
  - scheduler hooks for thread-starvation faults;
  - `CLOCK_REALTIME` offsets for clock-skip faults (RDTSC is unaffected, as in Antithesis).
- **Guest agent** (PID 1 + helpers): starts the container runtime (crun; Compose semantics first,
  single-node K3s later), carries out pushed actions (exec, nREPL, kill/pause container, network
  fault changes), forwards stdout/stderr and the output sink as events.
- **Network simulation** inside the guest: per-container network namespaces on a controlled
  bridge; latency/drop/partition/clog per link and per direction, driven by platform inputs.
- **CPUID baseline v1** (to finalize in M1): x86-64-v3 (AVX2, BMI1/2, FMA, MOVBE) + AES-NI/PCLMUL;
  no AVX-512 (EX44 lacks it; XCR0 enforces it), no TSX, no RDRAND/RDSEED/RDTSCP/RDPID advertised
  (still trapped), `hypervisor` bit set, 1 core / 1 thread.
- **Known limitation of 1 vCPU** (shared with Antithesis): no true parallelism, so bugs that need
  two CPUs at once are invisible: missing fences / store-buffer reordering, races inside
  preemption-disabled kernel sections, per-CPU data. Interleaving races in user code and
  preemptible kernel code are fully explorable.

---

## 6. Hypercall ABI (`VMCALL`)

| Op | Direction | Purpose |
|---|---|---|
| `emit_event` | guest → platform | Logs, structured events (JSONL), assertion results. |
| `pull_random` | platform → guest | Entropy for kernel RNG, `/dev/urandom`, SDK random. Small chunks. |
| `pull_decision` | platform → guest | Typed choices (which test command next, fault now?, etc.). |
| `lifecycle` | guest → platform | `setup_complete` (→ base snapshot), custom lifecycle points. |
| `agent_poll` | platform → guest | Pending pushed actions for the guest agent. |
| `coverage_map` | guest → platform | Register a guest shared-memory coverage region (read at decision points, no exit per edge). |

Language-agnostic fallback: a guest kernel module exposes `/dev/determinismo` (and an output-sink
directory), so any language can participate with plain file I/O; native SDKs use the fast path.

---

## 7. Inputs, tapes, steerability

**Two kinds of input:**

- **Pull** — the guest asks at a hypercall. The VM is paused while the answer is produced, so
  latency costs throughput, never determinism. On replay the n-th pull gets the n-th answer.
- **Push** — the strategy schedules an event at an exact instruction count (fault, exec, nREPL
  call, CPU modulation change). The VMM stops there precisely and injects it.

**Rules:**

1. Inputs enter only at decision points.
2. Every input is recorded on the tape. Replay reads the tape and never asks the decider again,
   so deciders (strategies, RL, LLMs, humans) may be nondeterministic.

**Tape v1:**

- Header: format version, determinism-ABI version, hypervisor build id, host CPU model +
  microcode, CPUID baseline, guest image digest, base snapshot id, root seed.
- Default answers to pulls come from a PRNG keyed by `(root seed, pull index)`; the tape stores
  only **overrides** `(position, kind, payload)` plus push events `(instruction count, payload)`.
- Checkpoints: `(instruction count, state hash)` at intervals, for divergence detection.
- Timeline id = hash of the tape. Moment = `(tape hash, vtime)`.

**Steering granularity = granularity of pulls.** Route all entropy through the platform, keep
pulls small, and only consult plugins for decision kinds they subscribed to.

---

## 8. Snapshots and branching

- Guest RAM in a `memfd`; a snapshot = frozen memfd + vCPU/LAPIC/device state + tape position.
- Branch = new VM, snapshot memory mapped `MAP_PRIVATE` (COW), state restored, EPT refilled lazily.
  KVM rejects VM fds from another process (`kvm->mm != current->mm`), so `fork()` is not enough.
- Dirty tracking via KVM dirty ring → cheap delta snapshots.
- Base snapshot taken at `setup_complete`; every exploration starts from it.
- Expected cost: milliseconds per branch. If it becomes the bottleneck → in-kernel VM fork
  (ownership level 2) behind the same "branch" interface.

---

## 9. Exploration, faults, plugins

- **Explorer** keeps the multiverse tree: branch points, observations (coverage, assertion
  states, events, state hashes), and schedules segments on workers.
- **Strategy plugins** choose where to branch and which inputs to apply. **Fault plugins** decide
  what to inject and when. Built-ins first: random, coverage-guided, swarm-style fault mixes.
- **Fault set** (target): network latency/partition/clog/restore, node pause/kill/stop/throttle,
  clock skips, CPU modulation, thread pausing (needs instrumentation), custom faults (user
  scripts, e.g. nREPL calls), disk I/O errors in virtio-blk.
- **Concurrency strategy** (later): trace memory accesses in instrumented code, find
  *communication points* (overlapping accesses from different threads, at least one a write;
  SKI / Project Zero's MAccConc), and preempt exactly there. Because the VM is deterministic, every
  ordering we force is fully specified and replayable.
- **Plugin protocol**: JSON-RPC 2.0 over stdio, methods roughly `init`, `subscribe`,
  `observe`, `decide`, `choose_branch`, `schedule_push`. The same schema is exposed later as a
  C ABI for in-process plugins. Plugins only act at decision points or at vtimes they schedule;
  wall-clock time does not exist for them.
- **Interactive branches** (multiverse debugging): open a branch at any moment, run a shell
  command or an nREPL form inside a container, continue, inspect. Each is a push input, so the
  branch itself is replayable.

---

## 10. Workflows: CI, mutation testing, agents, TLA+

### 10.1 Per-commit and nightly runs

- Short runs on every commit/PR (smoke + regression), long runs nightly on main.
- Findings tracked per property across runs: New / Resolved / Rare / Ongoing.
- **Two recording levels:**
  - **Tape** (§7): exact replay, *same build only*. A new binary changes the instruction stream,
    so instruction-count positions and pull order no longer line up.
  - **Scenario**: the high-level inputs (test commands, faults with vtimes, choices per decision
    kind). Re-applicable to a new build: deterministic for that build, but not the same timeline.
    This is how a found bug becomes a regression check on future commits.
  - Push points inside a scenario are anchored by **count-augmented stack traces** ("2nd call to
    X inside the 1st call to Y, then the 1st memory access at Z", from MAccConc) rather than
    instruction counts, so they survive unrelated code changes.

### 10.2 Mutation testing

- Validates the *properties*: inject an artificial bug; some property must fail. Determinism makes
  killed/survived verdicts reproducible instead of flaky.
- **Rebuilt mutants**: new image → new base snapshot (setup cached by image digest).
- **Runtime mutants** for dynamic runtimes (Clojure via nREPL, JVM hot-swap, Python): applied as a
  push input right after `setup_complete`, so all mutants share one base snapshot and are cheap.

### 10.3 Agents

- One surface for humans, CI, and agents: HTTP API + CLI + MCP server over the same operations
  (launch, query events, rewind/branch/exec at a moment, findings, coverage, sometimes-assertion
  status, mutant results).
- What determinism gives agents: a reproducible reward signal (no flakes), bugs as tapes, "what
  if" at any moment, and weak-test signals (unreached sometimes-assertions, surviving mutants).
- Loop: research properties → write workload → run → triage → debug at moments → fix → re-run
  scenario → mutation-test the properties.

### 10.4 TLA+

- **Oracle (trace validation)**: the SUT emits abstract-state events through the SDK; TLC checks
  each timeline's trace against the spec. Every violation comes with an exact reproduction.
- **Guide (strategy plugin)**: map observed abstract states to spec states and steer toward spec
  states/actions not yet covered (ideas from Mocket, SandTable). TLC is too slow to call on every
  decision: precompute the state graph or consult it at coarse decision points only.
- **Counterexample replay**: turn a TLC counterexample into a scenario (commands + faults) and try
  to reproduce it in the real system.
- **Spec determinismo itself**: explorer/worker protocol, branch/tape semantics, retention.
- Cost: someone writes the spec and the implementation→spec abstraction mapping (agents can help).

---

## 11. Storage and retention

A run can touch terabytes of memory state, but almost none of it needs to be kept, because
determinism makes state recomputable.

| Tier | What | Lifetime |
|---|---|---|
| RAM (COW pages) | Live branch memory, recent snapshots | Seconds–minutes, LRU |
| Local NVMe | Spilled snapshots and dirty-page deltas | Hours, LRU; recomputed on miss |
| Object storage (S3-compatible) | Tapes, event/log index, coverage summaries, bug reports, base snapshots, guest images | Long term |
| Pinned artifacts | Full snapshot at a bug moment (core dumps, memory) | Kept only when requested |

- Durable data per run is small: tapes are KBs–MBs; logs dominate (budget per vtime hour, with
  retroactive/suppressed verbose logging recoverable by replay).
- Long-term replayability requires pinning: determinism-ABI version, hypervisor build, host CPU
  model, guest kernel + images, CPUID baseline. **A change to the vtime function or exit
  semantics is a new determinism-ABI version**; old versions stay runnable, or the bug moment is
  pinned as a full snapshot.

---

## 12. Hosting

- **Requirements**: bare metal, our own host kernel, Intel CPU with VMX + MTF + usable PMU.
  Normal cloud VMs only for builds/unit tests.
- **Dev now**: Hetzner **EX44** (i5-13500, 6 P + 8 E cores, €59/mo, hourly up to the monthly cap,
  no setup fee). VMs on P-cores only. Note: non-ECC memory — fine for development, a risk for
  long production runs (bit flips look like nondeterminism).
- **Production-like**: Hetzner **EX131** (Xeon Gold 6731P, 32 cores, ECC, €279 setup).
- **Bursts later**: AWS `*.metal` (per-second), Vultr / Latitude.sh (hourly bare metal).
- **Replay portability**: guaranteed on the same CPU model only; cross-model replay is a later
  feature gated by the self-tests (§13).
- EX44 can do real runs; it is ~5× fewer parallel VMs than an EX131, so the same exploration
  takes proportionally longer.

---

## 13. Testing determinismo

- **Determinism gate (CI, on bare metal)**: N runs of the same tape → identical instruction
  count, guest memory hash, and output at every checkpoint.
- **Performance gates**: microbenchmarks for in-kernel exit, userspace exit, RDTSC exit,
  PMI-to-exact-count latency; `perf kvm stat` profiles of reference workloads (Go service,
  JVM/Clojure service).
- **Self-test level 1 — control plane as SUT**: controller, explorer, storage, plugin host run as
  containers inside determinismo against a **fake worker backend**; inject partitions/crashes.
- **Self-test level 2 — adversarial guests**: guests that hammer RDTSC/RDRAND/CPUID, interrupts,
  page faults, timers, I/O; VMM and `determinismo.ko` instrumented for coverage and fed to the
  strategy; property: replay of any tape matches all checkpoints.
- **Level 3 — full nesting** (determinismo inside determinismo): needs deterministic nested VMX
  and a virtual PMU. Deferred.

---

## 14. Milestones

| M | Deliverable | Exit criteria |
|---|---|---|
| M0 | Host bring-up on EX44: pinned LTS kernel, out-of-tree `kvm`/`kvm-intel` build + reload, benchmark harness. Optional: rr's test suite as a one-hour PMU sanity check (rr is never a dependency). | Modules reload cleanly; baseline exit costs measured. |
| M1 | Minimal Zig VMM: 1 vCPU, boot Linux (virtio-mmio console), exit statistics; counter study (instructions vs branches, skid). | Boots to shell; counter choice + CPUID baseline v1 decided. |
| M2 | KVM hook patch + `determinismo.ko`: RDTSC/RDRAND in-kernel, PMI + MTF exact stops, vtime LAPIC timer, HLT skip-ahead, shared page. | Determinism gate: 1000 identical runs of boot + workload. |
| M3 | Hypercall ABI, guest agent, C SDK, tape v1 with checkpoints, replay. | Record → replay matches all checkpoints. |
| M4 | memfd snapshots, branching, moment addressing, delta snapshots. | Branch from any moment; branches replay exactly. |
| M5 | Plugin protocol (stdio), built-in strategies, fault set incl. in-guest network sim. | A known-bug sample is found by exploration. |
| M6 | Worker protocol, controller, HTTP API + CLI + MCP server, multi-VM per host, storage tiers. | Multi-host run; tapes and events in object storage; an agent can launch and triage a run. |
| M7 | OCI/Compose ingestion, interactive branches (exec, nREPL), scenarios across commits, mutation testing (rebuilt + runtime mutants), more SDKs (JVM/Clojure, Go, Rust, Python). | A Compose app runs; a debug session patches a Clojure fn in a branch; a found bug re-runs as a scenario on the next commit. |
| M8 | Self-tests level 1 and 2 in CI. | Both run continuously. |
| Later | AMD SVM backend, cross-model replay, K3s, in-kernel VM fork, C-ABI plugins, TLA+ trace validation + spec-guided strategy, nesting. | |

---

## 15. Open questions

- Instructions retired vs conditional branches as the time base (M1).
- Exact CPUID baseline v1 contents for the EX44 + EX131 fleet (M1).
- Skid safety margin per CPU model; MTF steps per stop in practice (M2).
- Thread-pausing design: compiler-instrumentation callbacks as yield points vs guest-scheduler-only.
- vtime defaults: ns per instruction, per-event charges, idle skip rules.
- How much of the control plane needs a database vs. object storage + indexes.
- Scenario format: which high-level inputs survive a rebuild, and how faithfully a scenario
  reproduces a bug on a new commit.

---

## 16. Reference: what Antithesis publicly says

- Hypervisor ("the Determinator") is a bhyve fork on modern Intel server CPUs with VMX; the PMU
  instructions-retired counter drives the clock; one VM per physical core; VMCALL-based I/O;
  inputs form a tree, later with interrupt injection for pushed inputs.
  <https://antithesis.com/blog/deterministic_hypervisor/>
- Guest: tuned Linux 6.x, 1 vCPU, "Antithesis VM v1" CPUID (Skylake-ish, no rdrand/rdseed/rdtscp
  /TSX advertised), 10 GB default memory, no nested virtualization, RDTSC/RDRAND trapped and
  slower, idle time fast-forwarded, `/dev/(u)random` and kernel RNG controlled by the platform.
  <https://antithesis.com/docs/configuration/the_antithesis_environment.md>,
  <https://antithesis.com/docs/configuration/cpuid.md>
- Faults, multiverse, moments `(input_hash, vtime)`, SDK lifecycle (`setup_complete` → snapshot):
  <https://antithesis.com/docs/llms.txt> (index of all docs as raw markdown).
