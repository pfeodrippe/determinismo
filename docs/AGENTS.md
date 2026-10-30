# Using determinismo from an agent

determinismo is built to be driven by programs as much as by people: every timeline replays
exactly, results are JSON, and a Model Context Protocol server exposes the main operations.

## Connect

```
determinismo mcp --kernel <vmlinuz> --initrd <base.cpio> --memory-mib 2048 --cache <dir>
```

Tools: `describe`, `explore`, `replay`, `fork`, `query`, `events`, `sql`, `causality`, `mutate`,
`verify` (schemas in `src/mcp_tools.json`). Every exploration is a run of the host's, in its run store
(`~/.determinismo`, src/runs.zig), with its record, events and tapes: people follow it in
`determinismo serve`'s web UI however it was started (explore prints its run's number and
directory). Without MCP, use `determinismo runs` (serve's runs from a shell, as Antithesis's
Snouty), `determinismo query` and `determinismo events` on a run's directory, or the HTTP API
(`determinismo serve`):

```
determinismo runs list
determinismo runs show 24
determinismo runs properties 24 --details        # failing ones with their first examples
determinismo runs logs 24 63 120.5               # timeline 63 up to 120.5 s (ancestors too)
determinismo runs search 24 'event=fault details.node="kafka-1"' --limit 20
determinismo runs exec 24 63 58 --node kafka-1 'cat /proc/net/route'
determinismo runs exec 32 9 --until 'assert.message="..." assert.condition=false' --rewind-ms 5000 \
  --node quint 'ps -eo etime,args'               # 5 s before timeline 9's violation
determinismo runs start --program zig-out/bin/bank-test --scenario bank --time-budget 1h
determinismo runs stop 24
```

`--url http://host:port` or `DETERMINISMO_URL` for a serve elsewhere (127.0.0.1:7878 by default).
A replay through `runs exec` takes the run's own inputs (its kernel, initramfs, command line,
memory, faults, tape): prefer it to an `explore` command line put together by hand, which the
tape refuses when anything differs.

## Skills

Claude Code skills in `.claude/skills/` (as Antithesis's antithesis-skills):
`determinismo-properties` finds what a system must guarantee, `determinismo-workload` writes its
test program, `determinismo-debug` investigates a failure. Copy them to `~/.claude/skills/` to
use them in other repositories.

## A debugging loop that works

1. **Describe** the program: its profiles (nodes, faults allowed) and scenarios (test commands).
2. **Explore** a scenario with enough branches (32 to 128) and a fixed seed. Read the summary:
   which properties failed, in how many branches, and an example branch for each.
3. **Query** the multiverse: every branch's events (assertions, faults, commands, and what each
   node printed) are in the exploration's `events_dir`. Ask what the failures have in common:
   `query {condition: "assert.condition=false", preceded_by: "event=fault", within: 1,
   output: "branches"}` lists the timelines where a failure came within a second of a fault;
   `not_preceded_by` the ones where it did not. Each match carries its moment. For more, `events`
   takes a pipeline (Antithesis's event sets): `[{"filter": "assert.condition=false"},
   {"with_last": {"fault": "event=fault"}}]` gives each failure with the last fault before it
   (`last_fault`), to filter or group on; `with_next` with a `timeout` finds what followed (or
   did not, in time); `through` runs any program over the set (JSON lines in and out) for maps
   and folds.
4. **Replay** a failing branch: same seed, `branch` = the example. It is the same timeline,
   every time, so its events (with virtual times) are evidence, not noise. Explorations branch
   as a tree by default: a timeline past the first 16 started inside another (its `path` in the
   results), so replay it from its tape: MCP `replay` with `tape` = `<tape_dir>/branch-<n>.jsonl`
   (explore returns `tape_dir`), or `explore --tape` on the command line.
5. **Look at a moment**: replay with `at_vtime_ms` just before the first failure and an `exec`
   command, e.g. `det-nodes exec postgres psql -U postgres -c 'select ...'` or
   `det-nodes exec redis redis-cli get key`. The output is identical on every replay. To watch
   what happens next, grow a branch from the moment step by step (HTTP replay `steps`, the
   notebook's `branch`/`bash`/`bash-bg`/`wait`/`wait-until`/`run-branch`, or `--exec-script`
   lines): start a monitor in the background (`det:background redis-cli monitor`), let time
   pass (`det:wait 500`) or wait for an event (`det:until 2000 <condition>`), run a command;
   each step's end is a moment, and each command a process with its output and exit code.
   Add `--fresh-seed <n>` (HTTP and MCP `fresh_seed`; the notebook's branches by default) for
   the branch's own future: new randomness from the moment, as Antithesis's branches, the same
   for the same seed; without it the branch keeps the timeline's.
6. **Narrow down**: `causality` measures, at moments of the failing branch, how likely the
   failure was (futures forked there that fail): the bug was decided where the probability
   jumps. A future that has not failed by the failure's moment plus its distance from the setup
   snapshot ends there, counted as not failing (`--horizon-ms`, serve's `horizon_ms`; 0 runs every
   future to its end): a bug decided early in a long timeline costs futures that long, not the
   timeline's length. With `--verdict '<condition>'` (`verdict`) the bug is an event condition
   instead of the property, and futures stop at it. Query the branch's events just before, and inside the jump the code first run there
   (`event=coverage`: each line once, the first time a process runs it; the UI lists them per
   jump) and every thread's stack at its end (`replay` with `exec` "/opt/determinismo/bin/det-profile
   <node> --stacks"; the UI's "stacks" on a jump). `replay` with `until` stops at the first event
   matching a condition (its first violation, say) to look there, and with `rewind_ms` that long
   before it. `fork` from any moment
   explores its futures. When the system's logs are too quiet to show the mechanism,
   `--explain-exec '<command that turns them up>'` (serve: `explain_exec`) ends the analysis
   with futures from inside the narrowest jump to failure, the command run at their moment and
   the timeline's own randomness after it, each one's events kept: a failing one shows the
   mechanism step by step (Redpanda's open transaction, run 177). A test program's profile may
   declare that command (`profile.explain`): serve then runs it in every analysis of the run.
   **Try a change**: `replay` with `exec` and `continue` makes a change at a moment (data, a
   setting, a function redefined through a REPL) and lets the branch play out; `fork` with
   `exec` explores many futures of the changed system. `determinismo extract` takes a node's
   file out at a moment (a data file, a core dump); `determinismo inject` puts a local file in
   (a patched binary, a config), then `--then` and `--continue`. `determinismo profile --node
   <node> --ms <duration>` samples where the node spends its CPU from the moment on (`--all`
   for waiting threads too, `--svg` for a flame graph); `determinismo stacks --node <node>`
   prints every thread's stack at the moment; `det-nodes list` at a moment lists the
   nodes, their state and pid. A crashed process leaves a `core_dump` event whose `path`
   `determinismo extract --file runner:<path>` takes out (for gdb with the binary).
7. **Fix and verify**: change the code, explore again with the same seed and more branches; the
   property should pass in all of them. A replay of an old failing branch is not proof (the
   inputs changed, so it is a different timeline); exploration is.

## Facts worth knowing

- A system is a test program (`--program`), an Antithesis Compose project (`--compose`), or
  Kubernetes manifests (`--kubernetes <dir>`, the MCP and HTTP `kubernetes`): a single-node K3s
  cluster runs them, images fully qualified and taken from the host, deployed and ready before
  branching; test templates in any image run in their pod. Its faults include single pods
  (`pod_pause`, `pod_kill`, `pod_isolate`, `pod_degrade`, `pod_partition`), named in each fault
  event. examples/kubernetes is one.
- Exploration is a tree (Antithesis's "every event a potential branch point"): after each
  generation of 16 timelines, the ones that first reached something (an assertion outcome, a
  fault kind, a closer guidance distance, a new kind of output line) are returned to just after
  it, and new timelines branch from there. A `sometimes` or `reachable` made true comes first
  (the frontier's moment, a heavier archive cell): put one on each rare state worth building on
  (a failover, a retry path, a recovery), and the tree returns there. For progress that builds
  up (a growing backlog, a longer partition, more uncommitted entries), `sdk.optimize(message,
  bucket, value, .maximize)`: each bucket keeps its best state so far and the tree returns
  there, climbing (Antithesis's Metroid exploration). Each timeline also draws its own mix of
  fault kinds (swarm testing; `fault_swarm` says which). Each timeline's `why` says why it starts where it
  does. A generation of 16 is 4 fresh starts and 3 moments with 4 branches each:
  `--return-branches 2` makes it 6 moments with 2 (serve's `return_branches`), and `--horizon
  60s` stops each returned branch a minute past its moment unless it found something new
  (short branches, the promising ones extended). `--branching flat` starts every timeline at the setup snapshot; strategies plan flat
  unless asked for a tree (`--branching tree --strategy ... --tape-dir ...`).
- Disk faults: a node that allows `crash` gets an ext4 disk of its own; a crash is a power loss
  (what it synced survives, the rest is lost; the journal keeps the filesystem consistent), a
  `wipe` starts it fresh from its image. `disk` makes its disk fail for a while (I/O errors,
  write errors, lost writes, corrupted reads, slowness); an exit then is expected, and a node
  that exited or whose filesystem went read-only starts again at the fault's end.
  `--faults +restart,+crash,+disk` adds kinds to every node (`+clock_skew`: one node's realtime
  clock ahead or behind for a while, for systems that order by clocks; any system, a Compose
  project's too),
  `--no-faults client,monitor` takes them all from some (an Antithesis launch's
  `exclude_faults`).
- Efficiency (Antithesis's "virtual time per wall time"): every run reports how many virtual
  seconds a wall second simulates (one core), that times the system's nodes (Antithesis's rule
  of thumb: above 1), the share of virtual time the guest was idle and skipped (little: something
  busy-waits or polls, so idle time is not fast-forwarded), clock reads per virtual second (each
  an exit to the VMM), and each node's CPU time over the uptime (det-init's `node_cpu` events at
  a timeline's end; serve's run page, "CPU by node"). A slow system: lower its background work
  to test sizes (compaction, splits, heartbeats, failure detectors), find the busy node, then
  `determinismo profile` at a moment.
- A timeline not finished by `--timeline-limit` (1 h of virtual time by default) ends as hung
  ("the guest finishes its scenario" fails). The composer starts no driver past half of it
  (a `drivers_stopped` event): those running finish, then the ending and the checks, so only a
  command that never finishes is a hang, not a slow system's many drivers.
- Verbose systems: `explore --retroactive 'Applied block'` leaves such output lines out of the
  events (queries stay fast); replay a timeline (`--branch`, its tape) to see them.
- Targeted runs: `explore --changed <diff file | git range>` aims the tree at a change's lines
  (line coverage: Python, the JVM, Go built with Antithesis's instrumentor, and C, C++ or Rust
  built for Antithesis with the binary in the image's /symbols) and reports which
  hunks ran in how many timelines and which never did (`{"changed":...}` in the record). With
  `--changed-repository <directory | URL>` the range is in the system's repository: a commit
  alone is that commit's change, `a..b` a range, `v1.6.0..v1.7.0` a release.
- Mutation testing: `determinismo mutate <explore options> --mutants mutants.jsonl` explores the
  system and each mutant (a patch to a node's build context, `{"name","node","patch"}` per
  line) with the same seed: each is caught (a property fails that passes without it), never ran
  (coverage shows its lines never ran), or unnoticed (a gap in the properties).
- A run's notebook is Clojure (babashka on the server: `query`, `events`, `run`, `replay`,
  `stacks`, ...); `POST /runs/<id>/nrepl` starts a babashka nREPL server with the same names.
- `POST /runs/<id>/stop` stops a run (its timelines so far stay; state `stopped`). A restarted
  `serve` adopts the runs still going (each run's `pid` file).
- Determinism checks: every run replays every 16th timeline from its tape as it goes and judges
  "timelines replay to their recorded history" (`explore --verify-replays <n>`, HTTP
  `verify_replays`; 1 replays them all). `priority: true` (HTTP) gives a run's VMs the CPUs
  before other runs': a check beside a hunt, which goes on with the CPUs left. A timeline that
  did not replay keeps its output beside the tapes (`replay-<n>.log`), its events
  (`replay-<n>-events`), and its line in the results says where it parted from the run's events:
  the last checkpoint both passed and the first line that differs on each side (the events carry
  a `{"checkpoint":{"vtime_ns","branches"}}` line at the first timer past each second of virtual
  time, neither counted nor hashed, so a divergence is placed within a second even where no
  event comes for long). Tapes and the run's record carry the build that made them (`host`, a
  hash of the explorer's executable): a replay by another build says so, as parting from a tape
  can then be the build's doing (run 56, recorded the day before: the same 26 of 64 parted at the
  same events every time) rather than nondeterminism. After the fact,
  `determinismo verify --run <run directory> [--sample <n>] [--timeline <n>]...` replays a
  sample of a run's timelines, or the ones named; a replay that parts from its tape prints the
  last events before the checkpoint it failed, to compare with the run's. To find where it
  parts, replay it with `--trace` (`DETERMINISMO_RDTSC_LOG_CAP` for long timelines), then
  `DETERMINISMO_ITRACE_AT=<RDTSC exit>` for the instructions of that interval.

- A branch is identified by (inputs, seed, branch index[, fork point]). Inputs are the kernel,
  initramfs, command line (scenario included), timer slack and disks; `explore` prints their hash.
- Tapes (`--tape-dir`) record strategy overrides; `--tape` replays a branch without its strategy
  and refuses to run on different inputs.
- Virtual time is not wall time: idle time is skipped, so timeouts and sleeps cost nothing.
- Faults happen only during the driver phase; `finally` and `eventually` commands see a system
  without faults, which is where recovery is checked. Within it, any node or command can ask for
  a quiet period: `"$DETERMINISMO_STOP_FAULTS" 5` (also `$ANTITHESIS_STOP_FAULTS`): the fault
  under way ends and none but clock skips start for 5 seconds (`0` ends a quiet period). Every
  link that allows degradation carries a baseline (a small delay with jitter, rare drops) for
  the whole run, as Antithesis's baseline latency; faults end by returning links to it.
  Durable disks have a baseline too (`disk_baseline`: 0 to 2 ms per I/O, per timeline).
  Branches run at varying speeds by default (CPU modulation, as Antithesis's with faults: other
  interleavings of the same seed); `--no-cpu-modulation` (MCP and HTTP `cpu_modulation: false`)
  turns it off. A run keeps its setting and serve's replays follow it; a replay by hand of a run
  without it needs `--no-cpu-modulation` (its tape refuses otherwise).
- Exit status of explore: 0 every property passed, 3 some failed, anything else an error.
- Built-in properties come with every system (Antithesis's defaults): nodes do not exit
  unexpectedly (0, SIGKILL and SIGTERM are expected), the guest finishes its scenario, no process
  crashes, the kernel kills no process for lack of memory and reports no warnings, BUGs or hung
  tasks, peak memory stays under 95%, logging stays under 200 MB per hour of virtual time, the
  fault injector started, and no panics or uncaught exceptions in output (Go, Rust, Java). A kernel property's failure carries the log line and the
  kernel's timestamp (`kernel_us`, virtual time) in its details. The kernel's console lines are
  events too, output from source `kernel` at their moments (ext4 aborting a journal at a power
  loss, the OOM killer, a hung task): query them as any node's output (`output.source=kernel`).
