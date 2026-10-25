# determinismo — architecture & plan

determinismo is a deterministic simulation platform in the spirit of Antithesis: run a whole
system (containers, network, clocks, randomness) inside one deterministic VM, explore many
timelines from shared snapshots, inject faults, and reproduce any moment exactly.

Priorities, in order: **correct determinism**, **maximum throughput**, **no tech debt**.
Code follows TigerStyle ([docs/STYLE.md](docs/STYLE.md)); strategy plugins speak
[docs/PLUGINS.md](docs/PLUGINS.md).

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
| Decision point | A point where an input may enter: a pull (guest request) or a push (exact branch count). |
| Profile | A complete, typed description of a system under test (nodes, artifacts, dependencies, networks, faults, scenarios), returned by a test program's `describe` phase (§10). |
| Node | One service instance in the guest: a root filesystem, a command, an identity on the guest network. Unit of fault scoping. |
| Scenario | A function listing test commands (setup, first, parallel drivers, ..., finally) that together form one family of timelines (Antithesis's test template). |

---

## 2. Big picture

```
                         ┌──────────────────────── control plane (Zig) ────────────────────────┐
  users / CI / UI ──HTTP─▶ controller ── explorer (multiverse tree) ── strategy plugins (any lang)│
                         │      │                      ▲ observations      │ decisions           │
                         └──────┼──────────────────────┼───────────────────┼─────────────────────┘
                                │ worker protocol (also implemented by a fake backend, §14)
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
             │ guest runtime: init, node runtime (crun), composer, fault injector, exec agent  │
             │ nodes of the SUT (from profiles; K3s later) + simulated network between them    │
             │ tests + SDKs → /dev/determinismo (assertions, events, randomness, lifecycle)    │
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
| D7 | **Guest I/O to the platform through one doorbell port** (a guest module writes a request page's physical address to port 0x510; one VM exit per message), plus an IRQ for pushed actions; minimal virtio-mmio devices for disk only. Implemented as a port rather than `VMCALL` because stock KVM handles `VMCALL` in-kernel. | One exit per message; no virtio queues for the control channel; any language reaches it through `/dev/determinismo`. |
| D8 | **No async device threads** (`ioeventfd`/`irqfd`). | Async completion timing is nondeterministic. |
| D9 | **Whole SUT in one VM; network simulated inside the guest.** No external virtio-net. | Faults apply per link between containers; nothing leaves the box. |
| D10 | **Guest memory backed by `memfd`** from day one; branches map it `MAP_PRIVATE` (COW). | Cheap branching now; swap to an in-kernel VM fork later behind the same interface. |
| D11 | **Tapes, not states, are the durable artifact.** | Any state is recomputable from base snapshot + tape (§12). |
| D12 | **Fixed CPUID baseline "determinismo VM v1"**, the intersection of the fleet's CPUs minus nondeterministic features. | Same guest-visible CPU everywhere; prerequisite for cross-model replay. |
| D13 | **Plugin protocol = one schema, two transports**: JSON lines over stdio (implemented, `docs/PLUGINS.md`), C ABI in-process (later). | Any language can write strategies/faults; hot strategies can go in-process. |
| D14 | **Controller ↔ worker only through a protocol**, never directly to KVM. | Lets determinismo test its own control plane with a fake backend (§14). |
| D15 | Languages: **Zig** (VMM, worker, controller, explorer), **C** (kernel module, C SDK), SDKs per language. | |
| D16 | **Open source, MIT.** Exceptions, marked per file with SPDX headers: patches to Linux files (KVM hook patch, guest-kernel patches) are `GPL-2.0-only`; `determinismo.ko` is our own code under `GPL-2.0-only OR MIT` with `MODULE_LICENSE("Dual MIT/GPL")`. Userspace talks to the kernel only via syscalls/ioctls (UAPI headers carry the Linux-syscall-note). No code copied from GPL userspace projects (e.g. QEMU); Apache-2.0/BSD code (Firecracker, Cloud Hypervisor, rust-vmm) may be reused with its notices. | Patches to GPL files can't be relicensed; everything we author can be MIT. Users, including companies, can use and embed the MIT parts freely. |
| D17 | **Systems are described by profiles.** A test program's `describe` phase runs on the host (it may be impure: read files, query registries, use the git commit) and returns one or more **profiles**: services, their artifacts, dependencies, networks, faults, test templates. Artifacts are typed sources (`image` = OCI ref, later `nix`, `directory`, `binary`); determinismo converts them into what it needs (flattened root filesystems on a guest disk, nodes run by crun with our own bridge networking). Compose is an importer into a profile; a plain profile file is allowed too. The resolved profile (image tags pinned to digests) is frozen into the run record; replay never re-runs `describe`. A timeline is profile + template + seed (+ tape overrides); snapshots are keyed by profile hash. The profile schema is versioned. | One source of truth for system shape, faults and tests, typed variants, any language (JSON schema), and exact replay despite an impure describe. |
| D18 | **Tests run inside the guest**; services never define drivers. Test commands (drivers, checks, setup) are ordinary programs in a client node; services may embed SDK assertions (`always`, `sometimes`, `reachable`, ...) and SDK randomness; third-party services stay unmodified and are judged black-box (test assertions plus built-in properties). | Only what is inside the VM is deterministic, snapshotted and branchable; a test's progress is part of every snapshot. |
| D19 | **No Docker in the guest; our own node runtime.** Images are flattened on the host into read-only erofs disks (virtio-blk); inside, `det-nodes` runs each node in its own namespaces (mount, PID, network, UTS, IPC) on an overlay of its disk and tmpfs, with one cgroup per node and a veth mesh (one link per pair of nodes). It is what crun or bwrap do, in a few hundred lines with direct syscalls. A real runtime (crun, containerd for K3s) can sit behind the same interface (start, kill, pause, resume, link up/down, exec). | Fast boot, no daemon, every fault primitive under our control (freeze, kill, per-link cuts); the VM, not the namespaces, is the isolation boundary. |
| D20 | **Our own guest kernel build**: the host kernel's version from source, `x86_64_defconfig` plus `guest/kernel/determinismo.config`, everything built in (virtio-mmio with command-line devices, erofs, overlay, veth, netem); only `det_guest.ko` is a module. | Distribution kernels lack virtio-mmio command-line devices (we have no ACPI or device tree); built-ins mean no module loading at boot; one pinned config for every run. |

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

- Counter source: **retired conditional branches** (`BR_INST_RETIRED.CONDITIONAL`, raw `0x01c4` on
  Skylake), as rr does. Measured in M0 on the E3-1275 v5: 50 runs × 8 CPUs gave identical branch
  counts, while retired instructions drifted by 1–12 per run (`bench/pmu/count_repeat.c`).
  Antithesis uses retired instructions plus workarounds; we don't need them.
- Known hardware limits (from Antithesis): ~1 in 10¹² instructions miscounted; PMI skid of dozens
  of instructions, variable. Mitigations: early overflow + MTF stepping; state-hash checkpoints
  in the tape to detect divergence on replay.
- **Measured skid** (KVM reports the largest per VM): at most 54 branches over hundreds of
  branches and full boots of Redis and Postgres. The margin defaults to 128 branches; every run
  reports its largest skid, and any overshoot (a stop past its target) is reported as a run that
  may not replay. Margins of 256, 128 and 64 gave identical timelines; 32 did not.
- **Two kinds of stops.** Moments (multiverse debugging) stop at their exact branch count. Timer
  interrupts are **soft**: KVM exits at the first RDTSC at or past the deadline (a free, exact
  point), with a hard stop at the deadline plus `--timer-slack-us` (100 µs) as a backstop for
  code that reads no clock. Interrupts are at most that late in virtual time; the slack is part of
  a timeline's inputs. This halved wall time on the examples (bank: 40 branches 15.9 s → 9.3 s).
- `vtime = f(instruction count, per-event charges, modulation parameters)`. The parameters are
  inputs too, which gives **CPU modulation** as a fault (clock-speed strobing, per-operation cost
  changes) for free.

### 4.5 Host configuration

Pinned LTS kernel; modules built out-of-tree against it in CI; Secure Boot off or modules signed;
vCPU threads pinned; `isolcpus`/`nohz_full` for VM cores; `mitigations=` and
`kvm-intel.vmentry_l1d_flush` reviewed for benchmarks; on hybrid CPUs, VMs only on P-cores.

---

## 5. Guest

- **Kernel** (implemented, D20): Linux 6.12 LTS, our config (`guest/kernel/`): virtio-mmio disks
  announced on the command line, no ACPI/PCI, no paravirtual clocks. Later, small patches for
  *steerability only* (determinism must never depend on them):
  - kernel RNG and vDSO `getrandom` pull from the platform;
  - scheduler hooks for thread-starvation faults;
  - `CLOCK_REALTIME` offsets for clock-skip faults (RDTSC is unaffected, as in Antithesis).
- **Guest runtime** (implemented in Zig, `guest/runtime/`):
  - `det-init` (PID 1): mounts, loads `det_guest.ko` (`/dev/determinismo`), mounts the system disk
    (`/det`: the program and `system.json`), starts the nodes, runs the scenario named by
    `det.scenario=`, reaps orphans, reboots at the end;
  - `det-nodes` (D19): starts nodes in profile order, waits for readiness (TCP), writes
    `/etc/hosts`; also the operations faults and tests use (pause, resume, kill, start, link);
  - `det-composer`: runs one timeline of a scenario, following Antithesis's test-command rules
    (setup, then `first`, parallel/serial/singleton/anytime drivers, `eventually`/`finally`);
    every choice is a decision; it signals `setup_complete` after the setup command;
  - `det-faults`: pauses (cgroup freeze), isolates, partitions single links, restarts nodes, as each
    node's profile allows, and skips the clock if the scenario asks; active during the driver
    phase only, and undoes each fault before the next;
  - `det-agent`: runs commands pushed at a moment (multiverse debugging), woken by IRQ 5.
- **Network simulation** inside the guest: a full mesh of veth pairs (nodes and the runner, where
  tests run); every link of a node carries its one /32 address. Implemented: link cuts (partition,
  isolation). Next: latency and loss per link and direction with netem.
- **CPUID (implemented in `src/cpuid.zig`)**: KVM's supported set minus everything that leaks host
  time, randomness or topology. Hidden: KVM paravirt leaves (kvmclock, async PF, steal time, PV
  EOI), RDRAND/RDSEED/RDTSCP/RDPID, TSC-deadline timer, TSC_ADJUST, APERF/MPERF, WAITPKG, TSX, the
  PMU (leaf 0xA), and **XSAVEOPT/XSAVEC/XSAVES/XGETBV(1)**. Fixed: APIC ID 0 and a 1-core topology
  (KVM otherwise reports the APIC ID of whichever host CPU asked), invariant TSC, and a 4 GHz TSC
  via leaves 0x15/0x16 so the guest never calibrates.
  - Found by testing: the XSAVE in-use (XINUSE) tracking is perturbed by host FPU save/restore at
    arbitrary moments, and glibc reads it (lazy-binding trampoline). With it exposed, about 1 in 5
    runs of the bank example diverged; with it hidden, every replay matched.
- **Guest entropy**: the VMM passes a 32-byte seed as `SETUP_RNG_SEED` (`random.trust_bootloader`),
  so the guest RNG is ready at boot and every random value derives from the run's seed.
- **Timer**: the guest boots with `nolapic_timer hpet=disable clocksource=tsc`; the VMM's PIT is the
  only clock-event device, fired at exact branch counts (§4.4).
- **Known limitation of 1 vCPU** (shared with Antithesis): no true parallelism, so bugs that need
  two CPUs at once are invisible: missing fences / store-buffer reordering, races inside
  preemption-disabled kernel sections, per-CPU data. Interleaving races in user code and
  preemptible kernel code are fully explorable.

---

## 6. Guest ↔ platform channel (`/dev/determinismo`)

The guest module `det_guest.ko` (`guest/module/`) owns one request page and rings the doorbell
(port 0x510) with its physical address; the VMM handles the request during that VM exit.

| Op | Direction | Purpose | Status |
|---|---|---|---|
| `emit` (1) | guest → platform | One JSON event: logs, assertions, lifecycle (`setup_complete` → snapshot). | ✅ |
| `random` (2) | platform → guest | Bytes for SDK randomness; every pull is a decision (strategies, tapes). | ✅ |
| `action` (3) | platform → guest | The command pushed at a moment; the VMM raises IRQ 5 first. | ✅ |
| `coverage_map` | guest → platform | Register a shared-memory coverage region (read at decision points). | later |

From userspace: `write()` emits, `read()` pulls randomness, an ioctl waits for actions. Any
language can use it with file I/O; SDKs wrap it (`sdk/zig/determinismo.zig`).

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
- **Plugin protocol** (implemented, `docs/PLUGINS.md`): JSON lines over stdio; requests `hello`,
  `branch`, `random` (with the default value), `event`, `branch_end`; overrides go to the branch's
  tape. Later: subscriptions, scheduled pushes, a C ABI for in-process plugins. Plugins only act at
  decision points or at vtimes they schedule; wall-clock time does not exist for them.
- **Interactive branches** (multiverse debugging): stop a branch at a moment and run a shell
  command (or nREPL form) in the guest; output streams back as events with their moments
  (implemented: `--at-vtime-ms`/`--exec`). Next: branch from that moment (nested snapshots) and
  continue several futures; run the command inside a chosen node.

---

## 10. Defining systems and tests

### 10.1 One program: describe + handlers

A **test program** (any language; Zig SDK first) holds everything about a system under test:

- a **`describe` phase**, run on the host before any VM exists (`<program> --describe`), which
  returns one or more **profiles** as a versioned JSON spec;
- **handlers** run inside the guest: `setup`, `first_*`, `parallel_driver_*`, `serial_driver_*`,
  `singleton_driver_*`, `anytime_*`, `eventually_*`, `finally_*`. Any number of each; the composer
  can run several copies of a parallel driver at once.

`describe` may be impure (read files, query registries, use the git commit): its **output** is
frozen into the run record, so replay never re-runs it.

### 10.2 Profiles

A profile describes *what* the system is; determinismo decides *how* to materialize it.

- **Nodes** with typed artifact sources, converted by determinismo:

  | Source | Conversion |
  |---|---|
  | `image` (OCI ref) | pull, pin to a digest, flatten into a root filesystem |
  | `build` (Dockerfile + context) | build on the host, then as `image` |
  | `directory` | copy as the root filesystem |
  | `binary` | wrap a static binary in a minimal root filesystem |
  | `nix` (later) | build the closure and copy it in |

- **Dependencies and health checks** (start order), **networks**, **faults** allowed per node,
  **scenarios**; tests run in the runner (the guest's root namespace), linked to every node.
- **Variants** are more profiles (`three-replicas`, `no-faults`): `--profile <name>`.
- **Compose is an importer** into a profile; a plain profile file (JSON/TOML) is allowed for
  projects that want no code.
- **Typed access** (Zig): the system's shape is a type shared by `describe` and handlers, e.g.
  `ctx.nodes.postgres.address`, `try ctx.nodes.redis.pause(.{ .ms = 200 })`; typos are compile
  errors, optional nodes are `?sdk.Node`. Other languages: types generated from the JSON schema, or
  name-based lookup (`sdk.node("postgres")`).
- Everything a run may use must be in the profile (the guest has no network or registry). At run
  time, tests act on declared nodes only: start, stop, restart, pause, partition, scale within
  declared limits.

### 10.3 Run record and caching

- A timeline is **profile + scenario + seed (+ tape overrides)**; the resolved profile (image tags
  pinned to digests) is stored with the run.
- Snapshots are keyed by profile hash: one `setup_complete` snapshot per profile, reused until the
  profile changes; when it changes, determinismo prints a diff of the profiles.
- `describe` runs arbitrary code on the host: fine locally and in CI; sandboxed if determinismo is
  ever offered as a shared or hosted service.

### 10.4 Where assertions live

- **Tests** drive and check from the outside, and may span several services (write through the
  API, read Postgres directly, check Kafka; cross-service `anytime_` invariants).
- **Services you own** may embed SDK assertions (`always` for internal invariants, `sometimes` for
  rare paths such as retries or elections, `reachable`/`unreachable`) and SDK randomness for
  internal choices (backoff jitter), which makes those choices steerable. They never define drivers.
- **Third-party services** (Postgres, Redis, Kafka) stay unmodified, judged by test assertions and
  built-in properties (planned: no unexpected node exit, no kernel panic or OOM kill; implemented:
  test commands exit successfully).
- The SDK works outside determinismo too (OS randomness, events to stderr), so a test can be run
  locally against local services.

### 10.5 Project layout and CLI

```
my-system/
  tests/                 # the test program: describe + handlers (or several programs)
  compose.yaml           # optional: imported by describe
determinismo explore --program zig-out/bin/my-tests --profile default --scenario bank --branches 64
```

---

## 11. Workflows: CI, mutation testing, agents, TLA+

### 11.1 Per-commit and nightly runs

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

### 11.2 Mutation testing

- Validates the *properties*: inject an artificial bug; some property must fail. Determinism makes
  killed/survived verdicts reproducible instead of flaky.
- **Rebuilt mutants**: new image → new base snapshot (setup cached by image digest).
- **Runtime mutants** for dynamic runtimes (Clojure via nREPL, JVM hot-swap, Python): applied as a
  push input right after `setup_complete`, so all mutants share one base snapshot and are cheap.

### 11.3 Agents

- One surface for humans, CI, and agents: HTTP API + CLI + MCP server over the same operations
  (launch, query events, rewind/branch/exec at a moment, findings, coverage, sometimes-assertion
  status, mutant results).
- What determinism gives agents: a reproducible reward signal (no flakes), bugs as tapes, "what
  if" at any moment, and weak-test signals (unreached sometimes-assertions, surviving mutants).
- Loop: research properties → write workload → run → triage → debug at moments → fix → re-run
  scenario → mutation-test the properties.

### 11.4 TLA+

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

## 12. Storage and retention

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

## 13. Hosting

- **Requirements**: bare metal, our own host kernel, Intel CPU with VMX + MTF + usable PMU.
  Normal cloud VMs only for builds/unit tests.
- **Dev now (in use)**: Hetzner Server Auction, **Xeon E3-1275 v5** (Skylake, 4 cores / 8
  threads, 64 GB ECC, 2× 480 GB SSD, FSN1), $81.90/month max, billed hourly, cancel any time. The
  EX44 originally planned was sold out; the Xeon is a better fit (server CPU, ECC, no hybrid cores).
  Provisioning is scripted (`infra/`), so cancelling and re-ordering costs only setup time.
- **Production-like**: Hetzner **EX131** (Xeon Gold 6731P, 32 cores, ECC, €279 setup).
- **Bursts later**: AWS `*.metal` (per-second), Vultr / Latitude.sh (hourly bare metal).
- **Replay portability**: guaranteed on the same CPU model only; cross-model replay is a later
  feature gated by the self-tests (§14).

---

## 14. Testing determinismo

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

## 15. Milestones

| M | Deliverable | Exit criteria |
|---|---|---|
| ✅ M0 | Host bring-up (done on a Xeon E3-1275 v5 auction box, not the EX44, which sold out): pinned LTS kernel, out-of-tree `kvm`/`kvm-intel` build + reload, benchmark harness. Optional: rr's test suite as a one-hour PMU sanity check (rr is never a dependency). | Modules reload cleanly; baseline exit costs measured. |
| ✅ M1 | Minimal Zig VMM: 1 vCPU, boot Linux (virtio-mmio console), exit statistics; counter study (instructions vs branches, skid). | Boots to shell; counter choice + CPUID baseline v1 decided. |
| ✅ M2 | KVM patch: branch-count clock, RDTSC in-kernel, PMI + MTF exact stops, HLT to userspace; VMM: deterministic PIT, RTC, CPUID, RNG seed, idle skip. Done as a self-contained patch to `kvm-intel` (not yet split into `determinismo.ko`), PIT instead of a vtime LAPIC timer, ioctls instead of a shared page. | Redis, Postgres and the bank example replay bit-identically (serial, events, decision trace). The 1000-run gate is still to be automated in CI. |
| M3 | Guest channel (`/dev/determinismo`, doorbell port) ✅, Zig SDK + composer ✅, events + properties ✅, decision trace ✅; tape v1 (seed + overrides + checkpoints), replay command, C SDK. | Record → replay matches all checkpoints. |
| M4 | Snapshot at `setup_complete` ✅ (vCPU, LAPIC, PIC/IOAPIC, MSRs, XSAVE, devices, decisions; frozen memfd), copy-on-write branches ✅, `determinismo explore` multiverse report ✅, single-branch replay (`--branch`) ✅; still to do: branch from arbitrary moments, nested branching, delta snapshots. | Branches replay exactly ✅ (bank example: 40 branches from one snapshot in 38 s, 11 find the bug, each replays bit-identically). |
| M5 | Plugin protocol v1 ✅ (`docs/PLUGINS.md`: JSON lines over stdio, decisions + events + branch lifecycle), reference plugins ✅ (`random`, `mutate`: greybox mutation over decision tapes), tapes of overrides ✅ (replay without the plugin); in-guest fault injector ✅ (`det-faults`: process pause, process restart, clock skip; configured per template in `faults.conf`; every choice is a decision, so strategies steer faults and tapes replay them; runs only during the driver phase); network faults: next. | A known-bug sample is found by exploration ✅ (bank lost update; `mutate` concentrates on it: 9 of 12 mutants of a failing timeline fail). |
| M6 | ✅ **Profiles and nodes**: read-only virtio-blk disks; our guest kernel; `det-nodes` (namespaces, overlay, cgroups, veth mesh); schema v1, `describe` and scenarios in the Zig SDK with typed nodes; `image`/`directory`/`binary` sources; node faults (pause, isolate, partition, restart); `--program`/`--profile`/`--scenario` (or `all`); the frozen profile on the system disk. Remaining: `build` sources, `exec` into nodes, netem latency/loss, Compose importer, profile diff on change, nix sources. | Done: the bank example (Redis from `redis:7.4-alpine`) explores 40 branches in 18.6 s, finds the lost update in 11, and every branch replays with identical event hashes, faults included. |
| M7 | Worker protocol, controller, HTTP API + CLI + MCP server, multi-VM per host, storage tiers. | Multi-host run; tapes and events in object storage; an agent can launch and triage a run. |
| M8 | Interactive branches (exec, nREPL: commands at a moment ✅ via `--at-vtime-ms`/`--exec`, delivered by IRQ to an in-guest agent, deterministic output), scenarios across commits, mutation testing (rebuilt + runtime mutants), more SDKs (JVM/Clojure, Go, Rust, Python). | A Compose app runs; a debug session patches a Clojure fn in a branch; a found bug re-runs as a scenario on the next commit. |
| M9 | Performance (RDTSC via direct PMC read in-kernel, measured skid to shrink the MTF margin), determinism gate in CI, host tooling moved from Bash to Zig, self-tests level 1 and 2. | Deterministic mode within 1.3× of plain KVM on the reference workloads; gates run on every commit. |
| Later | Nix sources, built-in properties beyond command exits, coverage feedback for strategies, AMD SVM backend, cross-model replay, K3s, in-kernel VM fork, C-ABI plugins, TLA+ trace validation + spec-guided strategy, nesting. | |

---

## 16. Open questions

- CPUID baseline across CPU models (only one model tested so far).
- Hard stops still single-step `margin - skid` branches (about 500 VM exits, ~1.5 µs each).
  Candidates: count taken branches and step with branch trapping (TF + DEBUGCTL.BTF, one exit per
  counted branch instead of per instruction); more soft stop points than RDTSC (the VMM's own
  port and MMIO exits).
- The counter is read through the event's PMU callback, as `perf_event_read_local` does (not
  exported to modules); the VM exit itself dominates RDTSC and MTF costs.
- Thread-pausing design: compiler-instrumentation callbacks as yield points vs guest-scheduler-only.
- vtime defaults: ns per instruction, per-event charges, idle skip rules.
- How much of the control plane needs a database vs. object storage + indexes.
- Profile schema details: how variants compose (`with_replicas`, `without_faults`), how runtime
  scaling bounds are declared, and how a profile pins non-image artifacts (content hashes).
- Scenario format: which high-level inputs survive a rebuild, and how faithfully a scenario
  reproduces a bug on a new commit.

---

## 17. Reference: what Antithesis publicly says

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
