# Strategy plugins (protocol v1)

A strategy decides what the guest gets at each decision point. determinismo runs it as a separate
process and talks to it over its stdin/stdout: one JSON object per line, strictly alternating
request (from determinismo) and response (from the plugin). Anything a plugin writes to stderr is
passed through to the user. Plugins can be written in any language: the reference plugins are in
`plugins/` (Zig, with `protocol.zig`), and `plugins/python/` has a helper for Python
(`determinismo_strategy.py`, standard library only) with an example that learns
(`extremes.py`: a UCB1 bandit over how often to push decisions to their extremes). The command
is split at spaces; a program without a slash is looked up in PATH, and the plugin inherits
determinismo's environment (so a strategy that asks a model can read its API key):

```
determinismo explore ... --strategy "det-strategy-mutate --sync-dir /tmp/corpus"
determinismo explore ... --strategy "python3 plugins/python/extremes.py"
determinismo explore ... --strategy "python3 plugins/python/llm.py"     # Claude Haiku 5.5
determinismo explore ... --strategy tcp://127.0.0.1:9000                # a plugin elsewhere
```

A plugin can be uploaded to `determinismo serve`: `PUT /strategies/<name>` with the executable
(or a script with a `#!` line) as the body, or the web UI's New run dialog; runs then name it
`@<name> [arguments]`, and `GET /strategies` lists them. It runs on the server like any
`--strategy` command, so serve should listen where only trusted users reach it. Nothing about
determinismo is rebuilt for a new strategy.

A plugin can run anywhere: `tcp://<address>:<port>` connects to one already listening (one
connection per exploration worker). `plugins/python/serve_tcp.py <port> <command>` serves any
plugin command that way, and an SSH tunnel brings it to the host from a laptop:
`ssh -N -R 9000:127.0.0.1:9000 det@<host>`. `plugins/python/llm.py` asks a language model
(Claude Haiku 5.5, through the `claude` command line) every few branches which labeled decisions
to favor, from what recent branches did; run it where `claude` is logged in.

## Messages

Every request has a `method`. Every response is a JSON object; `{}` always means "the default".

| Request | When | Response |
|---|---|---|
| `{"method":"hello","protocol":1,"exploration_seed":"<hex>"}` | Once, at start. | `{"name":"<plugin name>"}`; add `"decides":false` for a plugin that only chooses where the tree returns (it is then sent no `random` or `event` requests: no round trip per decision), and `"wants":["behaviors"]` to get each candidate's behaviors in `returns`. In Python: class attributes `decides = False`, `wants = ["behaviors"]`. |
| `{"method":"branch","index":I,"seed":"<hex>"[,"from":{"branch":P,"vtime_ns":T}]}` | Before each branch, with the branch's seed; `from` when it starts at a moment of branch `P` (the tree explorer), not at the setup snapshot. | `{}` |
| `{"method":"returns","generation":G,"count":K,"candidates":[{"branch","start_ns","end_ns","novel","moment_ns","label"},...]}` | With `--branching tree --strategy ... --tape-dir <dir>`, after each generation: its timelines, with how many behaviors each reached first (`novel`) and the explorer's own choice of moment (`moment_ns`, `label`); with `"wants":["behaviors"]`, also `behaviors`: those it reached itself, each `{"label","vtime_ns","new_in_generation","timelines_before"}` (how many timelines of the generation reached it when no earlier one had, 0 if known before; how many timelines reached it before). `plugins/python/tree_rarity.py` is the explorer's own rule as a plugin, a starting point for trying others without rebuilding. Choose up to `K` moments to branch the next generation from. Nodes replay their parents with their tapes, so what the strategy decided there stays. | `{}` to leave it to the explorer (the frontier), or `{"returns":[{"branch":B,"vtime_ns":T,"reason":"<why>"[,"horizon_ns":H]},...]}`; the reason is shown at the branch point, and `horizon_ns` (optional) is how long that return's branches run past the moment (instead of `--horizon`): short around a decision point, long where something builds up. In Python, `returns(generation, candidates, count)` returns `[(branch, vtime_ns, reason), ...]`. |
| `{"method":"random","pull":P,"size":N,"default":"<hex>","source":"<process>","vtime_ns":T,"branches":C[,"decision":{...}]}` | The guest asked for `N` random bytes; pull `P` of this timeline (counted from boot); `source` is the asking process's name (Linux's `comm`, e.g. `det-faults`, `det-composer`, a test command), so a strategy can tell decision streams apart. `decision` labels it when the guest named it (the SDKs' `decide` and `random_below_named`): `{"name":"fault","options":["pause raft-2","partition raft-1 raft-3",...]}` (answer the index, little endian) or `{"name":"fault.duration_ns","range":R}`. det-faults names its faults, waits and durations. | `{}` to use `default`, or `{"hex":"<2N hex digits>"[,"reason":"<why>"]}`: a reason (240 bytes at most) goes into the timeline as a `decision` event and into the tape, and the web UI shows it with what it chose (a fault's tooltip, say). In Python, return `(bytes, "reason")`. |
| `{"method":"event","vtime_ns":T,"branches":C,"source":"<process>","event":<guest event>}` | The guest emitted an event (assertions, lifecycle, logs); `source` is the writing process's name, as for decisions ("" for events near the size limit). | `{}` |
| `{"method":"branch_end","index":I,"outcome":"<outcome>","events":E,"failing":["<property>",...]}` | The branch ended. | `{}` to continue, `{"stop":true}` to end the exploration early |

Seeds are 64-bit and travel as 16 hex digits, since JSON numbers lose precision past 2^53.
`vtime_ns` and `branches` together are the moment (ARCHITECTURE.md §1). Decisions made before
the snapshot (boot and setup) are not sent: every branch shares them.

## Tapes

Every answer a plugin overrides is written to the branch's tape, so a branch replays without the
plugin, which may not be deterministic itself (ARCHITECTURE.md §7):

```
{"tape":2,"inputs":"<hex>","exploration_seed":"<hex>","branch":I,"branch_seed":"<hex>"}
{"pull":P,"hex":"..."}
{"checkpoint":{"events":N,"branches":B,"events_hash":"<hex>"}}
```

A checkpoint every 64 events records the branch's state (event count, branch count, running hash
of its events); a replay compares them as it goes and stops at the first that differs ("replay
diverged from its tape at event N").

`determinismo explore ... --tape <file>` replays one branch from its tape. `inputs` identifies what
the machine booted (kernel and initramfs bytes, command line, disks): a replay with different
inputs is refused, since it would be a different universe.

## Limits

Overridden values are at most 64 bytes (SDK pulls are 8). A plugin must answer every request; a
plugin that exits or writes a malformed line ends the exploration with an error.

## Coverage

Strategies see every event, so behavior is coverage: event names, assertion outcomes. Every
decision and event also says which guest process it came from (`source`), so a strategy can
tell the system's behavior from determinismo's own (`det-faults`, `det-composer`, ...) and the
decision streams of concurrent processes apart.

For code coverage:

- **C** (or anything C-compatible): build with `-fsanitize-coverage=trace-pc-guard` and
  `#define DETERMINISMO_COVERAGE` next to `DETERMINISMO_IMPLEMENTATION`. Each edge emits
  `{"event":"coverage","details":{"name":"edge N"}}` the first time a process runs it.
- **Zig**: set `sanitize_coverage_trace_pc_guard = true` and `use_llvm = true` on the program's
  compile step and reference `sdk.coverage` (`comptime { _ = sdk.coverage; }`); the whole
  compilation is instrumented, the standard library included.
- **Python** (3.12+): `determinismo.coverage_start(paths=[...])` reports each line under those
  prefixes the first time it runs (`"line <file>:<n>"`), through `sys.monitoring`; a reported
  line costs nothing afterwards.
- **JVM** (JDK 24+; Java, Clojure, Kotlin, ...): run with the agent in
  `sdk/java/DeterminismoCoverage.java`, `-javaagent:determinismo-coverage.jar=<class prefixes>`;
  each source line of those classes reports itself the first time it runs (`"line
  <class>:<n>"`), classes defined at run time included (see `tests/antithesis-compat/java`).

Coverage can also be semantic: any `{"event":"coverage","details":{"name":"..."}}` is a
feature, so a system can report an abstraction of its own state (a spec's abstract state, a
protocol phase, "two leaders seen") from any SDK, and strategies then search for timelines that
reach new abstract states, as spec-guided fuzzers do. Keep the abstraction small: a name per
distinct balance sheet, say, makes every timeline new and guides nothing.

`plugins/mutate.zig` keeps timelines that reach new features and mutates the decisions of the
process that reached them, around where it did. The benchmark is a maze (four digit checks, 1
in 10000 timelines by chance) in C and Zig (`tests/selftest/maze.c`, `maze.zig`), and in Python
and Java under faults (`tests/antithesis-compat/python` and `tests/antithesis-compat/java`, template `maze`);
`zig build e2e` checks each is solved and that the solving branch replays from its tape. First
solving branch, 6 seeds, 8 synced workers: C 24 to 211, Zig 24 to 225 (300 branches), Python 116
to 352, Java 65 to 224 (1000 branches).

Each worker runs its own strategy process; `mutate --sync-dir <dir>` makes them share one corpus
(each writes the timelines it keeps, with the features they reached first, and imports the
others'), as parallel fuzzers do: synced workers need about as many branches as one worker, run
8 at a time (unsynced, about twice as many). Give each exploration a fresh directory.

## Two levels of strategy

A plugin (this protocol) decides inside a run: it sees every event with its moment and may
override any randomness pull (scheduling choices of the composer, faults and their parameters,
test inputs). It may be written in any language and use any algorithm (a fixed policy, a
learned one, a language model); it does not need to be deterministic, because every override
it makes is written to the branch's tape, and the tape alone replays the branch.

An outer loop decides across runs: it drives determinismo through the MCP server or the HTTP
API (`describe`, `explore`, `replay`, `fork`), reads the JSON results, and chooses what to do
next: which scenario, how many branches, which branch and moment to fork from. Reinforcement
learning over whole timelines, or an agent forming and testing hypotheses about a failure,
lives here. See docs/AGENTS.md.

Both compose: an outer loop can run explorations whose branches are steered by a plugin.

What strategies cannot do well yet (choose where to put a fault, where to branch) and how they
will (labeled decisions, branching mid-timeline from a plugin, Go-Explore, fault scheduling, RL
and LLM strategies, `sometimes` assertions as targets): [PLAN.md](PLAN.md), "Strategy guidance".

## Fault schedules (nemeses)

A fault schedule is a strategy that decides: the fault injector names its decisions (`"fault"`
with its options, durations, waits), and a strategy that says `"decides": true` at hello is
asked each one and told every guest event. plugins/clojure/strategies.clj's `leader-faults`
follows the Raft leader in the logs (`entering leader state`) and, when a fault is drawn, picks
one aimed at the leader seven times in ten ("nemesis: pause raft-node-2, at the leader"), as
Jepsen's nemeses go for the leader: the moments a cluster is most fragile. Its state is per
connection (an exploration worker's timelines, one at a time), reset at each `branch`.

## Causality planners

A causality analysis (`determinismo causality`, the page's Causality button, `POST
/runs/<id>/causality`) measures a failure's probability at moments of the timeline where it
happened: snapshots of it saved to disk there, futures forked from each. Which moments, and how
many futures each, is a planner's choice, on the same transport as strategies (a command's
standard input and output, `tcp://host:port`, or `@<name>` uploaded to serve):

```
determinismo causality ... --planner tcp://127.0.0.1:9102            # the Clojure host's
determinismo causality ... --planner "python3 my_planner.py"
POST /runs/93/causality {"branch":4862,"property":"...","planner":"tcp://127.0.0.1:9102"}
```

| Request | When | Response |
|---|---|---|
| `{"method":"hello","protocol":1,"kind":"causality"}` | Once. | `{"name":"<planner>"}` |
| `{"method":"plan","round":R,"branch":N,"property":"<message>","snapshot_ms":S,"failure_ms":F,"futures":M,"points_asked":K,"jump_min":J,"gap_min_ms":G,"moments_left":L,"run_url":"http://host:port/runs/<id>"\|null,"tape":"<path>"\|null,"points":[{"vtime_ms","futures","failing","probability","low","high"},...]}` | Before each round (at most `--refine` rounds after the first), with every moment analyzed so far: its futures, how many failed, the probability and its 90% interval. `run_url` is the run's HTTP API: a planner may query the timeline's events there (its faults, its logs: `POST <run_url>/query`). | `{"moments":[{"vtime_ms":T,"futures":M},...],"note":"<why>"}`; no moments ends the analysis. Moments outside (S, F], already analyzed, or past `L` are left out. |

What counts as the bug in a future is pluggable too: the property failing by default, or any event
condition (`--verdict '<condition>'`, the page's verdict field, `"verdict"` in the request), on
which the timeline's replay and each future stop.

The built-in planner analyzes the moment just after the setup snapshot and K moments evenly to the
failure, then, each round, halfway inside the jumps of J or more until they are G wide.
plugins/clojure/strategies.clj serves planners on port 9102 (`--planner-port`), reloaded live
over its nREPL: `bisect` (the built-in rule), `faults` (inside each jump, a moment just before
and just after every fault injected there: whether that fault decided the bug) and `dense` (four
times the moments, one round). `(use-planner! :faults)` switches; `@plans` keeps every round asked
and answered. plugins/clojure/api.clj is the whole HTTP API from Clojure (runs, timelines,
query, replays, causality, uploads), for planners, strategies and scripts alike.
