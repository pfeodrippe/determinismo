# determinismo

Deterministic simulation testing for whole systems, in the spirit of
[Antithesis](https://antithesis.com): run your services in one deterministic VM, explore many
timelines from a snapshot, inject faults, and replay any timeline exactly.

Design: [ARCHITECTURE.md](ARCHITECTURE.md). Style: [docs/STYLE.md](docs/STYLE.md).
Strategy plugins: [docs/PLUGINS.md](docs/PLUGINS.md). Agents: [docs/AGENTS.md](docs/AGENTS.md).
Where we stand against Antithesis, feature by feature: [docs/ANTITHESIS.md](docs/ANTITHESIS.md).
What comes next: [docs/PLAN.md](docs/PLAN.md).
Databases, cloud services and other dependencies inside the machine: [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md).

## What works today

Everything below is exercised by `zig build e2e` (real VMs on the patched KVM).

- **A deterministic machine**: a Zig VMM on a patched KVM where guest time is a function of
  retired branches; idle time is skipped, timer interrupts land at exact points, and every
  timeline replays bit-identically (checked from fresh boots, under an adversarial stress guest).
  A whole system (boot, Postgres, tests) runs at 1.31x plain KVM.
- **Systems described in code or Compose**: typed profiles whose nodes come from OCI images,
  Dockerfiles, directories or binaries, run in the guest by our own node runtime (namespaces, a
  read-only disk with a tmpfs overlay, a veth mesh, a cgroup per node with optional memory
  limits); or a Compose file with Antithesis test templates. Kubernetes too: K3s in a
  privileged node, or a three-node K3s cluster with pods spread over it (`examples/k3s`), under
  the same faults (partitions between Kubernetes nodes included), replayed exactly.
- **Tests as scenarios**: functions listing test commands (Antithesis's rules), assertions and
  steerable randomness from SDKs for Zig, Python, C (and FFI) and the JVM, or any Antithesis SDK
  (every node has a `libvoidstar.so` of determinismo's, so programs built with Antithesis's
  instrumentors report their coverage, as source lines for Go);
  Antithesis's default properties built in (nodes do not exit unexpectedly, no process crashes,
  no OOM kills, kernel warnings, panics or uncaught exceptions, test commands start, finish and
  exit 0, peak memory under 95%, logging under 200 MB per virtual hour, the fault injector
  started), and virtual time per wall time.
- **Exploration**: snapshot at `setup_complete`, copy-on-write branches on every CPU, shards across
  hosts, branching from any moment of a branch, strategy plugins in any language (decisions and
  events) and outer-loop control through MCP or HTTP.
- **Faults as decisions**: pause, isolate, clog, partition (into groups too: stopped, slowed or
  jammed) and restart nodes; delay, loss, duplication,
  corruption, reordering and congestion per link direction; CPU throttling; process and thread
  pauses; process kills (a crash for a supervisor or kubelet to recover from); power losses
  (`crash`: a node's ext4 disk keeps what was synced) and wipes; disk faults (`disk`: every I/O
  failing, writes failing, writes acknowledged and never stored, corrupted reads, or a slow
  disk, through device-mapper); graceful stops; clock skips, some
  permanent; custom faults (your programs, run in a node at random times); a baseline of
  latency, jitter and rare drops on every link, always on; CPU modulation (`--cpu-modulation`:
  stretches of a slower machine, so preemption lands elsewhere); quiet periods requested from
  any node or command (`$DETERMINISMO_STOP_FAULTS <seconds>`, or the Antithesis name
  `$ANTITHESIS_STOP_FAULTS`; 0 ends one).
- **Exact replay and its records**: tapes with checkpoints (a replay stops where it diverges)
  that refuse other inputs (kernel, disks, CPU model, determinism ABI); JSON results; regression
  scripts that carry a failure's shape to new seeds and new builds.
- **Debugging in the multiverse**: causality analysis (how likely the bug was at each moment
  of a failing timeline, from forked futures: where it jumps is where it was decided); stop a
  branch at the first event matching a condition (`--until`), or some time before it
  (`--rewind-ms`); run a command in the guest or
  inside a node at an exact moment;
  let the branch continue after a change (`--continue`), or explore futures of a changed system
  (`--from-exec`), e.g. a function redefined through a service's REPL; take a node's file out at
  any moment (`determinismo extract`) or put one in (`determinismo inject`); profile a node from
  a moment on (`determinismo profile`: the functions with the most samples and a flame graph,
  the same on every replay); every thread's stack there (`determinismo stacks`); list the nodes
  there (`det-nodes list`); a crash's core dump is
  kept (`core_dump` event) for `extract --file runner:/run/det/cores/...` and gdb.
- **Coverage-guided exploration**: strategies see behavior (events, with the process behind each
  event and decision) and code coverage (C and Zig edges, Python and JVM lines); `mutate` keeps
  timelines that reach something new and changes the decisions of the process that got there
  (it solves a 1-in-10000 maze in about 100 branches, in Python or Java under faults in about
  200), and parallel workers share one corpus.
- **Searching the multiverse**: every branch's events, node and command output included, with
  `determinismo query` (HTTP, MCP too): conditions on any field, and Antithesis-style temporal
  ones, "failures preceded by a fault within 1s", "with no fault before", each match with the
  moment to branch from; Antithesis's event sets with `determinismo events` (filter, with_last,
  with_next with timeouts, union, intersect, difference, narrow, and any program as map or
  fold).
- **Oracles beyond assertions**: TLA+ trace validation of a branch's abstract states with TLC;
  mutation testing with mutant profiles.
- **A web UI** (`determinismo serve`, then open it): runs live, properties with their failing
  and passing examples, a multiverse map of every timeline with its faults and failures,
  search, a timeline's logs up to any moment, and a command run at that exact moment; a
  notebook per run (JavaScript cells: queries, event sets, replays, stacks, profiles, files),
  kept with the run.
- **For people, CI and agents**: CLI, HTTP API (`serve`), MCP server (`mcp`), CI workflow.

## A test program

```zig
const Nodes = struct { postgres: sdk.Node, redis: sdk.Node };
const System = sdk.System(Nodes);

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.postgres, .{
        .image = "docker.io/library/postgres:17-alpine",
        .env = &.{"POSTGRES_HOST_AUTH_METHOD=trust"},
        .ready = .{ .tcp = 5432 },
    });
    default.node(.redis, .{ .image = "docker.io/library/redis:7.4-alpine", .ready = .{ .tcp = 6379 } });
}

fn prices(s: *System.Scenario) void {
    s.setup("catalog", catalog); // fn catalog(context: *System.Context) !void
    s.parallel_driver("reprice", reprice);
    s.parallel_driver("browse", browse);
    s.finally("coherent", coherent); // sdk.always(cached == database, ...)
}

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{ .prices = prices } });
}
```

Every example is a test program like this one, written in Zig against the SDK (`sdk.tcp`,
`sdk.retry`, `node.exec_output` and the rest keep them about the system, not the plumbing):
[examples/bank](examples/bank) (Redis, a lost update), [examples/shop](examples/shop) (Postgres
and Redis, a stale cache), [examples/clojure-bank](examples/clojure-bank) (a JVM service with
the Clojure SDK, debugged by redefining a function through its REPL at a moment),
[examples/k3s](examples/k3s) (Kubernetes: one node, or a three-node cluster),
[examples/raft](examples/raft) (HashiCorp Raft, three nodes replicating a chain of blocks),
[examples/nrepl](examples/nrepl) (nREPL, the protocol Clojure editors speak, under concurrent
sessions and interrupts), [examples/clojure-cli-repl](examples/clojure-cli-repl) (the Clojure
CLI's REPL: editors, watching terminals and the inspector over its nREPL middleware, with plain
nREPL as the reference) and [examples/clojure-libs](examples/clojure-libs) (Clojure's most used
libraries: core.async, manifold, round trips through cheshire, jsonista, data.json, nippy,
clj-yaml, and malli; one scenario per library).

The services themselves use the SDK of their language for their own assertions, events and
randomness (every SDK announces its program's assertions as the code loads, before they run, so
one that no timeline reaches is judged too; guidance assertions such as `always_less_than` tell
strategies how close a timeline came; `decide` names a decision and its options for them; and
assertions carry their place in the code): Zig ([sdk/zig](sdk/zig)), C ([sdk/c](sdk/c), one header, for C, C++ and any FFI),
Python ([sdk/python](sdk/python), one file), the JVM ([sdk/java](sdk/java), one file) and Clojure
([sdk/clojure](sdk/clojure), over the JVM one, with Clojure data), or any Antithesis SDK (see
below).

## Randomness

Each branch has its own seed (from the exploration seed and the branch index), and every
decision in it derives from that seed:

- **SDK randomness** (`random_below`, `random_choice`, ... in Zig, C, Python and the JVM): every
  value is a platform decision, which strategies can steer and tapes replay. Use it in drivers
  and for choices that matter in services (which account, retry jitter, timeouts). Code that
  takes an RNG can receive one: `sdk.rng()` is a standard generator (`std.Random`,
  `random.Random`, `java.util.Random`) whose every draw is a decision, and `sdk.prng()` a fast
  one seeded from a single decision, for hot loops.
- **The OS's randomness** (`getrandom`, `/dev/urandom`, generators seeded from them): the guest
  kernel's generator is reseeded from a decision as each branch starts, so it differs per
  branch and replays exactly, but its values are not steered one by one.
- A process that seeded its own generator before the snapshot keeps that state in every
  branch: draw through the SDK, or seed after the snapshot, where variety matters.

## Coming from Antithesis

Bring the same project: a Compose file, and test commands in an image under
`/opt/antithesis/test/v1/<template>/` (`first_*`, `parallel_driver_*`, `finally_*`, ...). Each
template becomes a scenario whose commands run inside that service; assertions in the Antithesis
SDK's format (written to `$ANTITHESIS_SDK_LOCAL_OUTPUT`, which points to determinismo) count as
properties. [tests/antithesis-compat](tests/antithesis-compat) holds such projects (test
commands in shell, Python and Java), which `zig build e2e` runs to keep the importer honest.

```
determinismo explore ... --compose tests/antithesis-compat/bank/compose.yaml --scenario bank --branches 40
```

## Quickstart (on the host)

```
infra/hetzner/install-os.sh <ip>          # Debian 13 on a fresh Hetzner box (rescue mode)
infra/host/bootstrap.sh <ip>              # packages, user `det`, SSH hardening, firewall
# On the host, in the repository:
sudo infra/host/m0-check.sh               # hardware qualification
infra/host/build-kvm.sh                   # KVM with kernel/patches/*.patch
sudo infra/host/load-kvm.sh               # swap in our KVM modules
guest/kernel/build.sh ~/guest             # the guest kernel and det_guest.ko
zig build -Drelease                       # the VMM, the guest runtime, the examples
zig-out/bin/det-initramfs --bin zig-out/bin --module ~/guest/det_guest.ko --busybox /usr/bin/busybox --out ~/guest/base.cpio
```

Then explore a system (images are pulled and cached under `--cache` on first use):

```
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio --memory-mib 2048 \
  --program zig-out/bin/bank-test --scenario all --seed 7 --branches 40
determinismo explore ... --program zig-out/bin/bank-test --scenario bank --seed 7 --branch 0
determinismo explore ... --strategy zig-out/bin/det-strategy-mutate --tape-dir /tmp/tapes
determinismo explore ... --tape /tmp/tapes/branch-16.jsonl
```

Branches run on every CPU (`--jobs`, same timelines as one worker). Explore from an interesting
moment of a branch: it is replayed to that moment, snapshotted there, and branched again:

```
determinismo explore ... --program zig-out/bin/bank-test --seed 7 --from-branch 2 \
  --from-vtime-ms 1200 --branches 32
```

Results as JSON lines (`--record results.jsonl`). An HTTP API keeps runs, results and tapes, and
replays branches; an MCP server gives agents the same powers:

```
determinismo serve --listen 127.0.0.1:7878 --data ~/runs --kernel ... --initrd ... --cache ~/cache
curl -X POST localhost:7878/runs -d '{"program":"zig-out/bin/bank-test","scenario":"bank","branches":40}'
curl localhost:7878/runs/1                       # state, branches, properties
curl -X POST localhost:7878/runs/1/replay -d '{"branch":3}'
determinismo mcp --kernel ... --initrd ... --cache ~/cache   # tools: describe, explore, replay, fork, query, events, causality, mutate
```

Multiverse debugging: stop a branch at a moment and run a command there (output streams back,
and is identical every time):

```
determinismo explore ... --program zig-out/bin/shop-test --seed 3 --branch 37 --at-vtime-ms 3610 \
  --exec "det-nodes exec postgres psql -U postgres -c 'select * from price'"
```

Regression scripts: `determinismo script <events of a failing branch>` writes the branch's shape
(which test commands started when; which faults hit what, when, for how long) as editable JSON;
`explore --script <file>` makes new seeds follow it, also on later builds where tapes no longer
apply (bank: 16 of 16 seeds fail with the script, 5 of 16 without, on a different build).

TLA+ trace validation: a system emits its abstract states (`event "tla"`), and
`determinismo tla --spec Spec.tla --events <branch events>` asks TLC whether they are a behavior
of the spec; it reports the first state the spec cannot reach
([examples/clojure-bank/tla](examples/clojure-bank/tla)).

Targeted runs: `--changed <diff file | git range>` aims the exploration at a change's lines and
says which of them ran, in how many timelines, and which never did.

Mutation testing: give mutants as profiles (`--profile default,mutant` or `--profile all`) and
see which ones the tests catch; or apply a runtime mutant after setup with `--from-exec`, so
every mutant shares one snapshot.

"What if": `--exec "<cmd>" --continue` makes a change at a moment and lets the branch run on;
`--from-branch B --from-vtime-ms T --from-exec "<cmd>"` explores many futures of the changed system.

`zig build test` runs the unit tests (on Linux); `zig build tidy` checks style; `zig build e2e`
boots the examples and checks exploration, exact replays from fresh boots, and tapes (on the host,
about 40 s).
