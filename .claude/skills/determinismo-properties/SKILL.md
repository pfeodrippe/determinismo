---
name: determinismo-properties
description: Find what a system must guarantee before testing it under determinismo. Use when asked what to test, which properties or assertions a service needs, or before writing a determinismo workload for a new system.
---

# Properties of a system, for determinismo

A determinismo run is only as good as its properties: faults and strategies find timelines, but
only assertions decide that one is wrong. Find the properties before writing the workload.

## Sources, in order

1. The system's own claims: README, docs, API contracts, consistency model ("linearizable",
   "at least once", "exactly once", "durable once acknowledged"), and its issue tracker's
   bugs (what broke before tends to break again).
2. Its code: invariants in comments, `assert`s, error paths that "cannot happen", retries,
   timeouts, and every place state crosses a process or a disk (writes, fsync, replication,
   leader changes, caches).
3. Its tests: what they check is a property; what they mock away (the network, the clock, a
   crash) is where determinismo's faults go.

## Write each one as an assertion kind

| Kind | Means | SDK (Zig / C / Python / JVM / Clojure) |
|---|---|---|
| always | true every time it is evaluated (safety) | `always` / `DET_ALWAYS` / `always` / `Determinismo.always` / `det/always` |
| sometimes | true at least once over the exploration (the test reaches it) | `sometimes` ... |
| reachable / unreachable | a line runs at least once / never | `reachable`, `assert_unreachable` ... |
| guidance | an always or sometimes over a comparison: how close a timeline came | `always_less_than`, `sometimes_all`, ... |
| eventually | after faults stop, the system recovers (a test command) | `s.eventually(...)` in the test program |

Pair every safety property with a `sometimes` that shows the interesting case happened (a
leader changed, a retry ran, a request raced another): a property never exercised passes
vacuously. Prefer properties a client can check from outside (the workload's view) over
internal ones; add internal assertions (in the service, through its SDK) where the bug would
be invisible from outside or found too late.

## Output

A short list, one line each: kind, message (the assertion's name: a sentence that is true when
it passes), where it is evaluated (workload driver, `eventually`, or a file in the service),
and the fault that threatens it. Then write the workload with the `determinismo-workload`
skill.
