# SDKs

A program under test reports properties and draws randomness through an SDK: one per language,
the same capabilities in each, in that language's idiom.

| SDK | Where | How it is used |
|---|---|---|
| Zig | `sdk/zig/determinismo.zig` | the `determinismo` module (workloads, test programs) |
| C, C++ | `sdk/c/determinismo.h` | one header: `#define DETERMINISMO_IMPLEMENTATION` in one file |
| Python | `sdk/python/determinismo.py` | one file, standard library only |
| Java | `sdk/java/Determinismo.java` | one class; the catalog agent `DeterminismoCatalog` (`-javaagent`) |
| Clojure | `sdk/clojure/determinismo.clj` | wraps the Java SDK; assertions are macros |
| JavaScript, TypeScript | `sdk/javascript/` | one file for Node.js 18+, types in `determinismo.d.ts` |
| Rust | `sdk/rust/` | the crate `determinismo` (`serde_json` details) |
| Go | `sdk/go/` | the package `github.com/pfeodrippe/determinismo/sdk/go`; its catalog from `go generate` (`cmd/determinismo-catalog`) |

## What every SDK has

| Capability | Zig | C | Python | Java | Clojure | JavaScript | Rust | Go |
|---|---|---|---|---|---|---|---|---|
| Random bytes, u64, below n | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Random choice | `random_choice` | (`det_random_below`) | `random_choice` | `randomChoice` | `choice` | `randomChoice` | `random_choice` | `RandomChoice` |
| Random float in [0, 1) | `random_float` | `det_random` | `random_float` | `random` | `random-float` | `random` | `random` | `Random` |
| A generator drawing from the platform | `rng` (std.Random) | `determinismo::random_engine` (C++) | `rng` (random.Random) | `rng` (java.util.Random) | `rng` | `rng` | `rng` (RngCore) | `Source()` (math/rand/v2) |
| A generator seeded once | `prng` | `det_prng`, `prng_engine` (C++) | `prng` | `prng` | `prng` | `prng` | `prng` (RngCore) | `Prng()` (math/rand/v2) |
| Named decisions | `decide`, `random_below_named` | `det_decide`, `det_random_below_named` | ✓ | ✓ | ✓ | `decide`, `randomBelowNamed` | ✓ | `Decide`, `RandomBelowNamed` |
| Buggify, and its pauses | `buggify`, `buggify_pause` | `det_buggify`, `det_buggify_pause` | ✓ | `buggify`, `buggifyPause` | ✓ | `buggify`, `buggifyPause` | ✓ | `Buggify`, `BuggifyPause` |
| always, always_or_unreachable, sometimes, reachable, unreachable | ✓ | `DET_*` macros | ✓ | ✓ | macros | ✓ | macros | ✓ |
| The assertion's place in the code | debug info | `__FILE__`, `__LINE__` | the frame | the stack | the stack | the stack | `file!`, `line!`, `column!` | `runtime.Caller` |
| Guidance comparisons (8) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| always_some, sometimes_all | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ (`NamedBool`) |
| Every evaluation an event, or first pass and first failure | `assertion_events` | `det_first_pass_first_failure` | `assertion_events` | `firstPassFirstFailure` | `first-pass-first-failure!` | `setAssertionEvents` | `set_assertion_events` | `SetAssertionEvents` |
| The catalog, announced before assertions run | det_catalog section | det_catalog section | source scan | class scan (agent) | macro expansion | source scan (CommonJS) | det_catalog section | generated `init` (`go generate`) |
| Declare one at run time | `declare` | `det_declare` | `declare` | `declare` | (the macros) | `declare` | `declare` | `Declare` |
| List the catalog | `catalog_assertions`, `catalog_write` | `det_catalog_write` | `catalog_assertions`, `catalog_write` | `catalogAssertions`, `catalogWrite` | `catalog-assertions`, `catalog-write` | `catalogAssertions`, `catalogWrite` | `catalog::assertions`, `catalog::write` | `CatalogAssertions`, `CatalogWrite` |
| setup_complete, event | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Raw output (any JSON object) | `output` | `det_output` | `output` | `output` | `output` | `output` | `output` | `Output` |
| Quiet periods, faults from the scenario | `stop_faults`, `fault` | ✓ | ✓ | ✓ | ✓ | `stopFaults`, `fault` | ✓ | `StopFaults`, `Fault` |
| Code coverage for strategies | trace-pc-guard | trace-pc-guard | sys.monitoring | the coverage agent | (Java's) | V8 precise coverage | trace-pc-guard (feature `coverage`) | (Go's own `-cover`) |
| Outside determinismo: local output file, else stderr | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

Outside determinismo (a local run, a unit test), randomness comes from the OS and events go to
the file `DETERMINISMO_SDK_LOCAL_OUTPUT` names (Antithesis's `ANTITHESIS_SDK_LOCAL_OUTPUT` too), one
JSON object a line, else to stderr. Buggify points are always false there, and nothing is
announced; the catalog still lists.

## Antithesis's SDKs

Programs written against Antithesis's SDKs run under determinismo as they are: their libvoidstar
is determinismo's (`antithesis_library` on a node), and imported Compose projects have it. The
SDKs above also take Antithesis's names, so such code ports by changing an import:

- JavaScript: `alwaysGreaterThanOrEqualTo`, `alwaysLessThanOrEqualTo`, the `sometimes...` ones,
  `sendEvent` (Antithesis's TypeScript SDK).
- Rust: `assert_always!`, `assert_always_greater_than_or_equal_to!`, ..., `get_random`,
  `send_event`, `AntithesisRng`, `antithesis_init` (Antithesis's crate `antithesis_sdk`).
- Python: `get_random`, `send_event`, `always_greater_than_or_equal_to`, ...
- Java: `getRandom`, `sendEvent`, `alwaysGreaterThanOrEqualTo`, ...
- Go: `GetRandom`, `SendEvent`, `AlwaysGreaterThanOrEqualTo`, `NamedBool`, `Source` (Antithesis's
  Go SDK's), and the build tag `determinismo_off` for no-op builds (theirs: `no_antithesis_sdk`).

What determinismo's SDKs add to Antithesis's: named decisions (strategies see what they steer),
buggify points, faults and quiet periods from the scenario, a seeded generator, catalog listing in
every SDK (Antithesis's Rust SDK has one), and raw output.

## The protocol (any language, no SDK)

Inside determinismo a process opens `/dev/determinismo` read-write.

- Randomness: `read(fd, buffer, n)` with n at most 4080 returns n random bytes, each read a
  platform decision (replayed from tapes, steered by strategies).
- Events: `write(fd, json, n)`, one JSON object per write, at most 4080 bytes:
  - `{"assert":{"type":"always","message":"...","condition":true,"details":{...},"location":{"file":"...","line":1,"function":"..."}}}`
    (types: always, always_or_unreachable, sometimes, reachable, unreachable);
  - `{"assert":{"type":"...","message":"...","hit":false}}`: declared, not evaluated (the catalog);
  - `{"guidance":{"message":"...","distance":1.5}}`: how far from the interesting outcome;
  - `{"decision":{"name":"...","options":["a","b"]}}` or `{"decision":{"name":"...","range":10}}`
    before the read that draws it;
  - `{"lifecycle":"setup_complete","details":{...}}`;
  - `{"event":"name","details":{...}}`; and any other object (raw output).
- Faults: `/opt/determinismo/faults-control`, a FIFO, opened write-only non-blocking: an 8-byte
  little-endian u64, nanoseconds of quiet (0 ends it), or `(1 << 63) | n` followed by n bytes of a
  JSON fault (guest/runtime/faults.zig lists the kinds); one write each.
