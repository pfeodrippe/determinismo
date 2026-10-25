# Plan

What is being built next, in order. Done work leaves this file (the parity map in
[ANTITHESIS.md](ANTITHESIS.md) and the commit log keep the record). Each item is done when `zig
build e2e` tests it.

## Now

1. **Tests are Zig programs, everywhere.** Every example in `examples/` is a test program
   (typed `describe`, scenarios as functions) using the SDK's common pieces (`sdk.tcp`,
   `sdk.retry`, `sdk.sleep_ms`, `node.exec_output`): bank, shop, clojure-bank and k3s done;
   the Antithesis-format projects moved to `tests/antithesis-compat` (they test the Compose
   importer). Left: run the clojure, tla, k3s, compose and coverage e2e checks on the new
   programs and paths.
2. **The assertion catalog, automatic in every SDK** (Antithesis's): built in Zig, C, the JVM
   (Java agent over bytecode), Clojure (macros) and Python (syntax trees as modules run); a
   test program's catalog is judged over all its scenarios. Left: the e2e checks
   (`check_catalog` and the rest) green on the server, then commit.
3. **Audit of ANTITHESIS.md**: done (rows judged by what a user gets; six marked partial and
   seven missing rows added). Its ❌ and 🟡 rows are the work in the sections below.
4. **A Raft workload, explored blind.** The Raft implementations of Antithesis's article
   (antithesis.com/blog/2026/finding-bugs-in-raft-implementations), explored without reading
   the article's findings first, then compared with what it reports. HashiCorp Raft first
   (examples/raft: a Go service with the article's "chain of blocks" state machine, written
   here, and a Zig test program checking agreement, progress and convergence); then OpenRaft
   (Rust), MicroRaft and Aeron Cluster (Java). More real systems after (etcd, a Jepsen-tested
   store).

## Antithesis parity found missing

From Antithesis's Java SDK (antithesis-sdk-java) and blog (2024 to 2026); none of these is a row
in ANTITHESIS.md yet.

1. **Guidance assertions**: done in every SDK, used by det-strategy-mutate and the LLM strategy.
   Left: guidance-aware Go-Explore cells (see "Strategy guidance").
2. **Assertion locations**: done for C, Python, the JVM and Clojure (report, record, UI). Left:
   Zig, through the return address and the binary's debug info (the same symbolization as
   coverage edges, below).
3. **First pass, first failure**: done in every SDK (opt-in; guidance only when it improves).
4. **Disk faults** (faults): Antithesis's mutation campaign turned on disk faults; find their
   documented forms (I/O errors, latency, lost unsynced writes at a crash, torn writes) and add
   them to det-faults through the nodes' disks.
5. **Retroactive logging**: verbose output (lines matching a regex, or whole nodes) goes to a
   black hole during exploration, not stored; replaying a branch regenerates it for the Logs
   view, a query, or a file. Antithesis measured virtual time per wall time going from 0.16 to
   1.01 on a verbose test.
6. **Agent skills**: properties, workload and debug are in `.claude/skills/`. Left: a
   mutation-testing skill (with item 7), and trying each on a system it has not seen.
7. **Mutation testing campaigns** (antithesis.com/blog/2026/mutation-testing): an agent reads the
   code and writes subtle mutants (races, wrong ordering; not syntax that only panics), one
   patch each; determinismo explores each mutant and reports per property whether it was
   falsified, with why not when it was not: the mutated code never ran (coverage), or it ran and
   no property noticed (a gap in the properties). `determinismo mutate` with an MCP tool, and the
   skill above to write the mutants. The e2e's single mutation check is the seed of this.

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
2. **Branching mid-timeline from the strategy.** Today the outer loop forks a branch at a moment
   (`fork`, replaying to it). Let a plugin answer an event with `{"branch_here": k}`: the VMM
   snapshots there (copy-on-write, as the setup snapshot) and runs k continuations from it. This
   is Go-Explore's "return": cells are feature sets, the strategy picks the cell to return to.
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
   overrides are in the tapes). Left: upload a strategy (a binary, a script, or an image) to
   `serve` and through MCP, and remote strategies over HTTP or a WebSocket, so a strategy can
   run anywhere (a laptop, a GPU box, a hosted service).
6. **Measure:** time to find the known bugs (bank, shop, clojure-bank, the maze, Raft) per
   strategy and per branch budget, in `bench/`, so changes to guidance are judged by numbers.

## Real systems: find real issues

Each gets a test program in `examples/` (or a separate repository when it grows), explored
blind, with its findings reported upstream.

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
3. **More systems**: etcd, a Jepsen-tested store, Kafka-compatible brokers.

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
3. **Targeted runs from a diff.** `determinismo explore --changed <git range>`: the diff's hunks
   become files and lines; coverage maps them to edges and lines in the programs; strategies
   reward timelines that reach changed code (directed fuzzing: distance to the changed lines in
   the call graph, as AFLGo does) and fault around it; the report says how many timelines ran
   each changed line and which properties those timelines checked. For CI: explore a pull
   request where it changed, and say what of the change no timeline ever ran.
4. **More languages.** Rust (an SDK crate over the C ABI, LLVM's coverage for edges), Go (an
   SDK, and coverage through Go's own `-cover` instrumentation or a source instrumentor, as
   Antithesis's Go instrumentor), JavaScript (an SDK; V8's coverage).

## Speed

- Virtual time per wall time on busy timelines (0.3 to 0.45 now): profile the VMM's exits and
  single-stepping for timers; cheaper timer delivery.
- Setup is one core before branches fan out: start branch workers as soon as the snapshot exists,
  and run independent e2e checks concurrently.

## Later

TLA+ counterexample replay, delta snapshots, nested virtualization, an AMD backend and replay
across CPU models.
