# Plan

What is being built next, in order. Done work leaves this file (the parity map in
[ANTITHESIS.md](ANTITHESIS.md) and the commit log keep the record). Each item is done when `zig
build e2e` tests it.

## Pluggable everything

The rule: whatever decides *what to look at, where to go, or what it means* is a plugin (any
binary on standard input and output, `tcp://` to a process anywhere, the Clojure host reloaded
live over nREPL), and everything is inspectable and drivable over the HTTP API (a Clojure client,
scripts, agents over MCP). Only what makes a timeline deterministic stays in the core: plugins
choose, the core records their choices (tapes), and a replay needs no plugin.

Pluggable now:
- Exploration strategies: decisions inside timelines and where the tree returns (`returns`,
  with reasons); `--strategy <cmd> | tcp://`, uploads (`@name`), plugins/clojure/strategies.clj.
- Faults: which kinds each node allows (`--faults`, `--no-faults`), and when and which, through
  the strategy's decisions.
- Workloads and properties: test programs in any language (SDKs: Zig, C, Python, Java, Clojure,
  Go via Antithesis's), host checks (`<program> check`, Elle).
- Reading results: the HTTP API (query, event sets, SQL on DuckDB), notebooks (JavaScript, Clojure
  over nREPL), MCP for agents; `serve --archive "<cmd>"` for long-term storage.

To make pluggable (none changes what a timeline does, only what is looked at or chosen):
1. **Causality planners** (in progress): which moments to analyze and how many futures each;
   built in (even moments, then halfway inside jumps) or a plugin that sees every point, the
   failure and the run's API. Clojure planners: bisect, faults (moments either side of each
   fault inside a jump: which fault decided it), dense. Every parameter from the page too.
2. **Causality's verdict**: what counts as "the bug happened" in a future (the property failing
   by default; any query condition, or a plugin judging a future's events).
3. **Behaviors and cells**: what counts as a new behavior (events.zig's keys) and the
   Go-Explore archive's cell and score: today fixed in Zig; a plugin mapping a timeline's
   summary to cells and weights, offline (between generations), so timelines pay nothing.
4. **Fault schedules (nemeses)**: Jepsen-style schedules ("partition the leader after an
   election, heal after 5 s") as a plugin over the decision hook, with reasons.
5. **Horizons and timeline lengths per return**: the strategy's `returns` may say how long the
   branch runs.
6. **Run scheduling in serve**: which runs start, repeats, admission (memory), as API calls a
   script makes (the benchmark harness in Clojure over the API, not only bench/explore.py).
7. **Snapshot policy**: which failures get snapshotted, how densely, kept how long, archived
   where: serve's defaults, a hook to override.
8. **Triage**: findings (new / ongoing / resolved), rarity, grouping of failures by cause: a
   plugin over the API producing the report the page shows.
9. **A Clojure API client** (plugins/clojure/api.clj): runs, timelines, properties, query, event
   sets, replays, causality, snapshots, stop and start, from any REPL or program.

Stays in the core (determinism): the VMM (vCPU runs, virtual time and its TSC, timers, interrupt
delivery, devices, CPUID and MSR filtering, branch counting), the decision stream's mechanics
(seed and pulls; plugins only override values, which tapes record), fault mechanics (how a
partition, pause or crash is applied in the guest), snapshots and their restore, tapes and
event hashing, the guest module.

## Open issues (2026-10-27)

- Causality: planner protocol and Clojure planners (in progress); refinement deeper (up to six
  rounds, 40 moments, jumps narrowed to 20 ms); job pid files so a serve restart keeps a running
  analysis (built, not deployed); serve snapshotting a failure as soon as it is found.
- Disk snapshots (delta, `--save-snapshots`, `--from-snapshot`): the `saved` e2e check is
  written but not run yet; long-term archive later (QUESTIONS.md).
- e2e: the whole suite runs on srv1 against the new binary; then `-Donly=saved`, `-Donly=ui`
  (Playwright, tests/ui) and `-Donly=until` (causality's new output).
- UI: first load 5.4 s on run 93 through the tunnel (27 s before gzip and incremental
  timelines); timelines in parallel with the run's info (built); the chart larger; "1.8 h wall"
  is a sum of wall times; a minimap for thousands of timelines.
- srv2 leaks (fixed in serve and holders, deployed): holders now exit with their explorer, serve
  kills what a finished run leaves, adopts a live explorer whatever its record says. Run 93's
  explorer still runs the old binary.
- Benchmarks (QUESTIONS.md 3: A): stop run 93, run bench/explore.py's variants on srv2.
- Clojure strategies: their own archive (returns to any earlier timeline), inspectability.
- Flecs master: the readonly-table assert in flecs_table_ensure (30 of 32 timelines under
  determinismo, not natively), two model disagreements, the abort hook bypassed, SIGABRT ending
  in a GPF in nodes.
- srv2 memory: admission by available memory, holders given up oldest first.
- Findings: run 93's [log-matching] rediscovery, with its causality (a partition raft-node-2 ↔
  runner at 24.086 s, a durable crash of raft-node-1 at 24.223 s, the bug decided between them).
- Check: host checks' inputs (Events.check_buffer) in a tree's branches from in-run snapshots
  (the buffer travels by pointer, not by content).
- Holders: about 1 in 20 nodes from an in-run snapshot differed from the node a replay makes,
  by one byte of guest memory, always at 192 mod 512 in its page, 2 against 3. Explained
  (2026-10-27, from the page itself): a guest task's XSAVE header, its x87 state initial
  (FCW 037f, MXCSR 1f80), XSTATE_BV 2 or 3. XSAVE writes XINUSE, which the host's own FPU saves
  and restores of the guest (its thread preempted) may clear at host-chosen moments; the guest
  restores the same registers either way and cannot read XINUSE (XGETBV 1 hidden). Verification
  now accepts exactly that (xsave_bits_only, with a test); the tree e2e flaked on it.
- Snapshot copies took residency (mincore) for content: a page the host swapped out was copied
  as zeros. Copies now take every page mapped in the process (present or swapped, pagemap) or held
  by the memfd behind it (SEEK_DATA); srv1 and srv2 both swapped earlier (millions of pages).
- Tailscale: your Mac's install (QUESTIONS.md 4).

## Now

1. **e2e green on everything** (the tree check included: the same tree with one worker or four,
   a deep timeline replaying alone from its tape, with and without a strategy).
2. **The tree explorer** (Go-Explore over snapshots: generations, returns just after new
   behaviors, paths in tapes and records) is the default; strategies decide within timelines
   and choose the moments to return to (`returns`), with reasons. Behaviors: assertion
   outcomes, categorical events (coverage lines and edges included), guidance distances, and
   new kinds of output lines. Next steps for it:
   - Done: in-run snapshots (holders, ARCHITECTURE.md §8): a node is a memory copy instead of a
     replay of its parent to the moment (minutes with fifteen-minute timelines), each checked
     against a replay's node by `--verify-holders` in the e2e tree check. Next: return to more
     moments per generation now that a node costs little.
   - Done: holders with CPU modulation (Antithesis turns modulation on with faults, and the Raft
     double vote is an interleaving): stops computed from the effective time, the modulation
     stepped at the guest's own exits only, and carried on in a holder's replay.
   - Memory: runs on a host share its CPUs (src/cpus.zig) but not a memory budget; workers
     waiting for a turn and holders keep their VMs' memory, so runs added for CPUs exhaust it
     (srv2, 2026-10-26: about 1,000 explore processes, 0 GB available; stopping one run gave
     back 14 GB). Next: the pool admits a VM only with its memory available (MemAvailable less
     a reserve), and holders are given up oldest first when it runs short.
   - A generation waits for its slowest timeline: with fifteen-minute Raft timelines (median
     216 s of wall time, slowest 476 s) one run leaves 47% of its workers idle. Meanwhile:
     several runs per machine fill each other's gaps. Next: larger generations (`--generation`,
     several timelines per worker) and the next generation's roots started early (a quarter of
     it: the rest depends on its results); planning from whatever finished first would fill
     more but make the tree depend on timing.
   - Measured with bench/tree.py (the self-test maze, eight seeds; plugins/python/tree_rarity.py
     tries a rule without rebuilding). Kept: a generation's finds weighed by how few of its
     timelines found them (second digit 16.6 against 14.6). Dropped: rarity summed over all
     behaviors (2.5), returning to the least visited behavior when nothing is new (15.1),
     numbering the next roots first to run them during node making (4.6), and running them then
     with the numbering kept (the same tree, no clear wall-time gain: forking twice a generation
     costs what the overlap saves). Left: a budget split between depth and fresh starts learned
     from what found new behaviors.
   - Measured 2026-10-27, the maze (4 minutes, seeds 1 and 2, srv1, beside other runs): the
     built-in archive (`--archive --pipeline 1`) solved both (65 s, 5 s); the Clojure archive
     strategy one (170 s); Clojure's rarity none. The Raft POC on srv2 (40 minutes a seed, 36
     threads, generations of 48), bench/explore.py: the default tree found the deadlock in both
     seeds (48 s, 66 s) and, in seed 1, the double vote with three others (1,481 s, timeline 4653);
     the archive found the same in seed 1 (35 s; 1,768 s). But timeline 4653 is a fresh start
     (no path), its seed drawn from its index, the same in both: the double vote was the seed's,
     not the strategies'. Of 6,767 and 5,808 timelines, 1,799 and 1,560 started fresh; those from
     moments found the deadlock (39 and 29 times) and, once, in the archive's, the log divergence
     (timeline 5493, two moments deep, after the fresh one). So: count each variant's finds from
     moments apart from fresh ones, and compare variants over more seeds; the double vote needs
     returns that keep the off-loop heartbeat's timing (tests/antithesis-compat/README.md).
3. **Why, everywhere.** Done: the tree explorer's reason for every branch point, a strategy's
   `reason` with any answer (in the timeline as a `decision` event, and in its tape), the LLM
   strategy's reasons from the model; the UI's tooltips show them. Left: det-faults' own reasons
   when it is guided (`fault after "leader elected": partition the leader`), the mutate
   strategy's (which parent, which mutation), and reasons in the logs and the notebook.
4. **The UI.** Done: stat cards, discovery and failing-property charts, the multiverse tree with
   shared prefixes, branch points and forks, zoom and pan, live updates, styled tooltips, logs
   with the parents' events, Clojure notebooks (babashka) with a per-run nREPL server, fork
   from a moment, time budgets, strategy uploads. Left: a minimap for runs of thousands of
   timelines.
5. **clojure-cli.repl**: examples/clojure-cli-repl, its server beside plain nREPL 1.7.0. Found
   (README): an editor evaluation hangs while a watching terminal does not read (over ~100 KB
   of output); closed sessions are kept; one inspector view for all terminals. Left: rerun the
   editors scenario with the warm-up fix; interrupts and long evaluations racing watchers.
   Findings stay documented here (nothing is filed with other projects).
6. **Blind exploration of the real targets**: nREPL, the Clojure libraries, Raft (pinned commit,
   with restarts), with the tree explorer and the strategies; findings documented in each
   example's README. Antithesis's own Raft project (antithesishq/hashicorp-raft-poc) runs
   unchanged through the Compose importer (its Go SDK writes to detfs, a regular file; its
   client declares the setup, where the snapshot is taken). Found blind: the
   leadership-transfer deadlock (hashicorp/raft#696, first hour, explained by a replay's
   goroutine dump) and the log divergence from off-loop heartbeats (#695, with three-minute
   timelines and a pause right after an election), and the snapshot installation livelock
   (#697, with fifteen-minute timelines and up to 32 drivers; it replays from its tape);
   tests/antithesis-compat/README.md. And the double vote (#695's second mechanism), found in
   run 77 on srv2 (timeline 22: two leaders in term 180), with the durability-point faults and
   CPU modulation, in runs that repeat with fresh seeds on the host's shared CPU pool: all four of
   the POC's known bugs, blind.

## Antithesis parity found missing

From Antithesis's Java SDK (antithesis-sdk-java) and blog (2024 to 2026); none of these is a row
in ANTITHESIS.md yet.

1. **Guidance assertions**: done in every SDK, used by det-strategy-mutate and the LLM strategy.
   Left: guidance-aware Go-Explore cells (see "Strategy guidance").
2. **Assertion locations**: done in every SDK (Zig through the return address and its debug
   info); the platform's built-in properties carry none (they have no place in user code).
3. **First pass, first failure**: done in every SDK (opt-in; guidance only when it improves).
4. **Disk faults**: Antithesis documents restarts that keep durably synced changes or lose all
   of them: `crash` (an ext4 disk per node, shut down without flushing) and `wipe`. Beyond
   them, `disk`: I/O errors, write errors, lost writes, corrupted reads and latency through
   device-mapper. All in the e2e `disk` check.
   Fault types audited against antithesis.com/docs/.../fault_types (all present: partitions
   both ways or one way, clogs, restore, throttle, pause, kill and graceful stop, crash and wipe,
   thread pause, clock skips, CPU modulation, custom; network faults overlap, node faults one at
   a time per node; any fault on request from a scenario). Restarted nodes may take a new address
   (`new_address`). Left: CPU modulation changing the relative speed of instructions, not only
   the clock.
5. **Retroactive logging**: done (`--retroactive '<text>'`): verbose lines stay out of an
   exploration's events and come back in a replay.
6. **Agent skills**: properties, workload and debug are in `.claude/skills/`. Left: a
   mutation-testing skill (with item 7), and trying each on a system it has not seen.
7. **Mutation testing campaigns** (antithesis.com/blog/2026/mutation-testing): an agent reads the
   code and writes subtle mutants (races, wrong ordering; not syntax that only panics), one
   patch each; determinismo explores each mutant and reports per property whether it was
   falsified, with why not when it was not: the mutated code never ran (coverage), or it ran and
   no property noticed (a gap in the properties). `determinismo mutate` (patches to a node's
   build, caught / never ran / unnoticed), its e2e check, the MCP tool and the
   determinismo-mutants skill are done.

## Strategy guidance (next)

Strategies are pluggable (any language, over a JSON protocol; docs/PLUGINS.md) and three exist:
random, `mutate` (greybox mutation of decision tapes, frontier-focused, with synced workers) and
`extremes` (a UCB1 bandit, in Python). What they cannot do yet is decide well *where* to put a
fault and *where* to branch. Antithesis describes its guidance as reinforcement learning toward
"new and interesting states", every event a potential branch point, and `sometimes` assertions
as hints of where bugs hide. To get there:

1. **Labeled decisions**: done (`decide` and `random_below_named` in every SDK; det-faults names
   its faults, waits and durations; strategies get the label with the pull). An LLM strategy
   uses them (plugins/python/llm.py, Claude Haiku 5.5 through the `claude` CLI; remote over TCP).
2. **Branching mid-timeline**: done in the explorer itself (`--branching tree`, see "Now").
   Left: strategies choosing the moments to return to.
3. **Reference strategies with real guidance:**
   - Go-Explore: an archive of cells (the features reached, with the moment that reached them),
     pick by rarity, return by snapshot, explore with labeled decisions.
   - Fault scheduling: faults around the moments that matter (a leader elected, a commit, a
     `sometimes` hint reached), from event sets over past timelines; partition the node an event
     names.
   - RL: a policy over labeled decision points, rewarded by new features and failing properties
     (the bandit generalized to a contextual policy).
   - LLM: a model reads a timeline's summary (events, faults, assertions near misses) and proposes
     the next fault schedule or decisions, through the plugin protocol or the MCP outer loop.
     The reference one calls Claude Haiku 5.5 through the `claude` CLI (`claude -p --model
     claude-haiku-5-5`), so it runs wherever Claude Code is logged in; cheap enough to consult
     once per branch, and its answers are in the tapes like any override.
4. **Sometimes assertions as guidance:** a `sometimes` not yet true is a target; strategies get
   the catalog's open targets and reward timelines that move toward them.
5. **Strategies anyone can bring.** `--strategy "<command>"` already runs any program (any
   language, any API behind it), over JSON lines, and it need not be deterministic (its
   overrides are in the tapes); `tcp://` reaches one running anywhere, and `serve` takes uploads
   (`PUT /strategies/<name>`, `@name` in a run). Left: uploads through MCP, and container
   images as strategies (dependencies included).
6. **Measure:** time to find the known bugs (bank, shop, clojure-bank, the maze, Raft) per
   strategy and per branch budget, in `bench/`, so changes to guidance are judged by numbers.

## Real systems: find real issues

Each gets a test program in `examples/` (or a separate repository when it grows), explored
blind, with its findings documented in its README.

- **Faults at durability points** (done: `sync_stall`, `durable_crash`; ARCHITECTURE.md §9): the
  Raft POC's remaining bug (two leaders in a term) opens only while a goroutine waits on a store
  write (tests/antithesis-compat/README.md); random pauses had not hit it in 938 timelines. The
  guest module makes a node's fsyncs and sync writes seeded decisions: stalls there widen those
  windows, crashes there hit act-then-persist bugs. With them, the double vote was found (run 77,
  timeline 22). Any system's, not Raft's alone.

1. **Raft**: HashiCorp Raft (examples/raft, at the article's upstream commit 4c8f61ac), then
   OpenRaft, MicroRaft, Aeron Cluster.
2. **Clojure's most used libraries** (Clojars downloads, from ecosyste.ms, plus the core libraries
   on Maven Central), each under a workload that exercises what can break under concurrency,
   network faults and restarts, with the Clojure SDK's assertions and the catalog:
   - Servers and clients: nREPL (concurrent sessions, interrupts, evaluation under faults; and
     cider-nrepl), http-kit, ring-core with ring-jetty-adapter (and ring-codec, ring-defaults,
     ring-ssl, ring-anti-forgery, ring-headers), compojure, clout, clj-http, manifold, aleph.
   - Concurrency: core.async, manifold, com.taoensso/encore, timbre (asynchronous logging),
     com.stuartsierra/component (lifecycle under restarts), mount, integrant, ns-tracker, hawk.
   - Data and serialization (round trips with platform randomness): cheshire, jsonista,
     data.json, nippy, clj-yaml, instaparse, edamame, rewrite-clj, tools.reader, fipp, puget,
     camel-snake-kebab, org.flatland/ordered, medley, specter, clj-tuple.
   - Validation: malli, prismatic/schema, schema-tools, spec-tools, expound.
   - Time and security: clj-time, crypto-random, crypto-equality, buddy-core, buddy-sign,
     pandect.
   - Storage clients: next.jdbc (Postgres), carmine (Redis), core.cache and core.memoize.
   - Templates and the rest: hiccup, selmer, aero, environ, potemkin, riddley, slingshot,
     plumbing, primitive-math, io.aviso/pretty, test.check.
3. **The Clojure compiler and runtime** (clojure/clojure, the JVM implementation): a pinned
   fork with the Java SDK's assertions put where its rare paths are, so that they guide the
   exploration to them. Started: examples/clojure-compiler (Clojure 1.12.6 with clojure.patch:
   27 assertions in the STM, hash map nodes, lazy seqs, the compiler and reflection, and
   buggify points in the STM and lazy seqs; scenarios stm, forms and lazy; all properties hold
   so far). Next: agents and futures (send-off pools, binding conveyance), more compiler paths,
   and the reached-path counts as the measure of each addition. `sometimes` and `reachable` mark the paths worth reaching (the tree
   returns just after a timeline first reaches one, and a strategy can steer toward one not yet
   reached); `always` checks what must hold there. Candidates, read from the source:
   - Compiler.java: recur in tail and non-tail positions (loop, fn, try bodies), locals
     clearing (once-only closures, branches that clear differently), primitive locals and
     return hints (boxing, unchecked math, long/double fallbacks), reflection fallbacks,
     `case` with hash collisions (shift/mask, skip-check), keyword and protocol call-site
     caches, deftype mutable fields under closures, macroexpansion that throws.
   - The runtime: PersistentHashMap collision nodes and array-node packing, transients after
     persistent!, chunked seqs crossing chunk boundaries, LazySeq realized from several threads,
     STM (LockingTransaction retries, barging, commute and ensure, history growth), agents
     (send-off pool, errors, restart-agent), Var bindings conveyed to futures, locking.
   - The workload: a test program generates Clojure forms (test.check generators, Clojure's own
     test suite as a corpus) and evaluates them in the guest, with properties that need no
     reference answer: the same form gives the same result with direct linking on and off,
     locals clearing on and off, and interpreted against compiled (`eval` of the form and of
     `(fn [] form)`); STM transfers conserve their totals under contention; nothing throws an
     internal error (`ClassFormatError`, `VerifyError`, an NPE inside the compiler).
   - Threads, contention and preemption are what determinismo varies (CPU modulation, thread
     pauses), so the STM and lazy-seq paths are the likeliest to fail; the compiler's are the
     likeliest to need guidance to reach at all.
4. **core.async in depth** (clojure/core.async, a compiler and a concurrency library in one):
   a pinned fork with the Clojure SDK's assertions at its rare paths, buggify points in its race
   windows and alts!'s port order a platform decision. Started: examples/clojure-core-async
   (core.async 1.9.865 with core-async.patch, 20 sites in channels, alts!, the go runtime and
   macro, and timers; scenarios channels, alts, pipeline, mult, go and timeout, with what
   core.async promises as properties: nothing lost or duplicated, order per producer and through
   pipelines, every mult tap served, catch and finally after parks, no early timeout). Next:
   pub/sub and mix, put!/take! callbacks, the dispatch pools, more go macro forms (loops, case,
   nested try parking).
5. **More systems**: etcd, a Jepsen-tested store, Kafka-compatible brokers. Started:
   examples/etcd (etcd v3.7.3, three members with restarts, stops and crashes, and the
   durability-point faults): acknowledged writes survive, linearizable reads see earlier writes,
   revisions grow, a compare-and-swap counter counts, members' keyspace hashes agree, recovery;
   and list-append transactions whose whole history Elle checks for strict serializability
   (checkers/elle: Jepsen's checker as a node any workload can post its history to); watches
   deliver in revision order and miss no acknowledged write. All hold so far. Next: leases and
   locks (unsafe by design: reported, not failed). The rest of Jepsen's systems, ranked, with
   their workloads: docs/JEPSEN.md.

## Code: instrumentation, locations, targeted runs

What exists: code coverage as events, per language (C and anything LLVM through
`-fsanitize-coverage=trace-pc-guard` edges, Zig edges, Python lines through sys.monitoring, JVM
lines through a Java agent rewriting bytecode as classes load, Clojure's generated classes
included), used by strategies to keep timelines that reach new code. Edges are numbers, not
places, and assertions carry no location.

1. **Every event points at code.** Coverage edges symbolized to file, function and line (the
   compiler's PC table and the binary's debug info, read once per program file); assertions
   with their location (see "Antithesis parity found missing"); the platform's own properties
   with the command, scenario and process they came from (`test command completed: accounts` is
   the composer's, about the `accounts` command: the event says so, and links to the handler's
   source when the program has debug info).
2. **Causality down to code.** Causality analysis finds the moment a failure became likely; add
   what ran there: the lines first reached between the last moment with a low probability and
   the jump, and every thread's stack at that moment (det-profile), so the report names the
   code that decided the bug, not only when.
3. **Targeted runs from a diff.** Done: `explore --changed <diff file | git range>` (CLI, serve,
   MCP) matches the hunks to line coverage (Python, the JVM, Go through Antithesis's
   instrumentor and libvoidstar), returns first to timelines that ran changed code, just after
   they did, and reports which hunks ran in how many timelines and which never ran (e2e
   `changed`). Left: distance to the changed lines (directed fuzzing, as AFLGo does) for code
   no timeline reaches yet, faults aimed around it, and which properties the timelines that ran
   it checked; C and Zig edges mapped back to lines.
4. **More languages.** Rust (an SDK crate over the C ABI, LLVM's coverage for edges), Go (an
   SDK of our own; Antithesis's Go SDK and instrumentor already work, through libvoidstar),
   JavaScript (an SDK; V8's coverage).

## Speed

- The tree's generation barrier: a generation (16 timelines) runs, the explorer waits for all
  of them, then plans the next; Raft's timelines take 0.5 to 6.5 minutes, so most workers idle
  at each generation's tail (the CPU pool lends them to other runs, not to this one). Next:
  commit timelines in index order; when timeline i and all before it are done, judge it and
  plan its branches at once, and workers take planned work as they free up. Decisions depend on
  the committed prefix only: a seed still gives the same tree, with no wait but for a slow
  timeline next in order when nothing else is planned.
- One host, many runs (done, cpus.zig): workers take a CPU from one pool shared by every run on
  the host before a timeline (or a node's replay), pinned to it, physical cores first; never
  more VMs running than CPUs. Before it, every run pinned worker i to CPU i: seven runs of five
  workers shared CPUs 0-4 while 31 sat idle.
- Virtual time per wall time on busy timelines (0.3 to 0.45 now): profile the VMM's exits and
  single-stepping for timers; cheaper timer delivery.
- Setup is one core before branches fan out: start branch workers as soon as the snapshot exists,
  and run independent e2e checks concurrently.

## Later

TLA+ counterexample replay, delta snapshots, nested virtualization, an AMD backend and replay
across CPU models.
