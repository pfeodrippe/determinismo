# Using determinismo from an agent

determinismo is built to be driven by programs as much as by people: every timeline replays
exactly, results are JSON, and a Model Context Protocol server exposes the main operations.

## Connect

```
determinismo mcp --kernel <vmlinuz> --initrd <base.cpio> --memory-mib 2048 --cache <dir>
```

Tools: `describe`, `explore`, `replay`, `fork`, `query`, `events`, `causality`, `mutate` (schemas in
`src/mcp_tools.json`). Every exploration is a run of the host's, in its run store
(`~/.determinismo`, src/runs.zig), with its record, events and tapes: people follow it in
`determinismo serve`'s web UI however it was started (explore prints its run's number and
directory). Without MCP, use `determinismo query` and `determinismo events` on a run's
directory, or the HTTP API (`determinismo serve`).

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
   `det-nodes exec redis redis-cli get key`. The output is identical on every replay.
6. **Narrow down**: `causality` measures, at moments of the failing branch, how likely the
   failure was (futures forked there that fail): the bug was decided where the probability
   jumps; query the branch's events just before. `replay` with `until` stops at the first event
   matching a condition (its first violation, say) to look there, and with `rewind_ms` that long
   before it. `fork` from any moment
   explores its futures.
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

- Exploration is a tree (Antithesis's "every event a potential branch point"): after each
  generation of 16 timelines, the ones that first reached something (an assertion outcome, a
  fault kind, a closer guidance distance, a new kind of output line) are returned to just after
  it, and new timelines branch from there. Each timeline's `why` says why it starts where it
  does. `--branching flat` starts every timeline at the setup snapshot; strategies plan flat
  unless asked for a tree (`--branching tree --strategy ... --tape-dir ...`).
- Disk faults: a node that allows `crash` gets an ext4 disk of its own; a crash is a power loss
  (what it synced survives, the rest is lost; the journal keeps the filesystem consistent), a
  `wipe` starts it fresh from its image. `disk` makes its disk fail for a while (I/O errors,
  write errors, lost writes, corrupted reads, slowness); an exit then is expected, and a node
  that exited or whose filesystem went read-only starts again at the fault's end.
  `--faults +restart,+crash,+disk` adds kinds to every node,
  `--no-faults client,monitor` takes them all from some (an Antithesis launch's
  `exclude_faults`).
- Verbose systems: `explore --retroactive 'Applied block'` leaves such output lines out of the
  events (queries stay fast); replay a timeline (`--branch`, its tape) to see them.
- Targeted runs: `explore --changed <diff file | git range>` aims the tree at a change's lines
  (line coverage: Python, the JVM, Go built with Antithesis's instrumentor) and reports which
  hunks ran in how many timelines and which never did (`{"changed":...}` in the record).
- Mutation testing: `determinismo mutate <explore options> --mutants mutants.jsonl` explores the
  system and each mutant (a patch to a node's build context, `{"name","node","patch"}` per
  line) with the same seed: each is caught (a property fails that passes without it), never ran
  (coverage shows its lines never ran), or unnoticed (a gap in the properties).
- A run's notebook is Clojure (babashka on the server: `query`, `events`, `run`, `replay`,
  `stacks`, ...); `POST /runs/<id>/nrepl` starts a babashka nREPL server with the same names.
- `POST /runs/<id>/stop` stops a run (its timelines so far stay; state `stopped`). A restarted
  `serve` adopts the runs still going (each run's `pid` file).

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
  `--cpu-modulation` (MCP and HTTP `cpu_modulation`) makes branches run at varying speeds: other
  interleavings of the same seed; pass it to replays of such a run too (tapes refuse without).
- Exit status of explore: 0 every property passed, 3 some failed, anything else an error.
- Built-in properties come with every system (Antithesis's defaults): nodes do not exit
  unexpectedly (0, SIGKILL and SIGTERM are expected), the guest finishes its scenario, no process
  crashes, the kernel kills no process for lack of memory and reports no warnings, BUGs or hung
  tasks, peak memory stays under 95%, logging stays under 200 MB per hour of virtual time, the
  fault injector started, and no panics or uncaught exceptions in output (Go, Rust, Java). A kernel property's failure carries the log line and the
  kernel's timestamp (`kernel_us`, virtual time) in its details.
