# Strategy plugins (protocol v1)

A strategy decides what the guest gets at each decision point. determinismo runs it as a separate
process and talks to it over its stdin/stdout: one JSON object per line, strictly alternating
request (from determinismo) and response (from the plugin). Anything a plugin writes to stderr is
passed through to the user. Plugins can be written in any language; the reference plugins are in
`plugins/` (Zig).

```
determinismo explore ... --strategy "plugins/mutate --corpus-max 64"
```

## Messages

Every request has a `method`. Every response is a JSON object; `{}` always means "the default".

| Request | When | Response |
|---|---|---|
| `{"method":"hello","protocol":1,"exploration_seed":"<hex>"}` | Once, at start. | `{"name":"<plugin name>"}` |
| `{"method":"branch","index":I,"seed":"<hex>"}` | Before each branch, with the branch's seed. | `{}` |
| `{"method":"random","pull":P,"size":N,"default":"<hex>","source":"<process>","vtime_ns":T,"branches":C}` | The guest asked for `N` random bytes; pull `P` of this timeline (counted from boot); `source` is the asking process's name (Linux's `comm`, e.g. `det-faults`, `det-composer`, a test command), so a strategy can tell decision streams apart. | `{}` to use `default`, or `{"hex":"<2N hex digits>"}` |
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
  <class>:<n>"`), classes defined at run time included (see `examples/compose-java`).

Coverage can also be semantic: any `{"event":"coverage","details":{"name":"..."}}` is a
feature, so a system can report an abstraction of its own state (a spec's abstract state, a
protocol phase, "two leaders seen") from any SDK, and strategies then search for timelines that
reach new abstract states, as spec-guided fuzzers do. Keep the abstraction small: a name per
distinct balance sheet, say, makes every timeline new and guides nothing.

`plugins/mutate.zig` keeps timelines that reach new features and mutates the decisions of the
process that reached them, around where it did. The benchmark is a maze (four digit checks, 1
in 10000 timelines by chance) in C and Zig (`tests/selftest/maze.c`, `maze.zig`), and in Python
and Java under faults (`examples/compose-python` and `examples/compose-java`, template `maze`);
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
