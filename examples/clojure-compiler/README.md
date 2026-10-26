# The Clojure compiler and runtime under test

Clojure 1.12.6 (commit 31a3138) built from source with [clojure.patch](clojure.patch): the Java
SDK, copied into `clojure.lang`, asserts at the rare paths of the STM, agents, hash map nodes,
lazy seqs, the compiler and reflection (37 sites), and buggify points pause in their race
windows. The service ([app/compiler_check.clj](app/compiler_check.clj)) checks properties that
need no reference answer, one scenario each:

- `stm`: transfers between refs (alter, commute, ensure before or after a write, a validator) and
  write skew under `ensure`: the total conserved in every snapshot, each commit's agent send run
  once, the skew floor held.
- `forms`: generated forms (platform decisions) printing the same result under every compiler
  option set (direct linking, locals clearing), and bytecode the JVM accepts.
- `lazy`: one lazy seq realized from several threads, the same elements in each.
- `agents`: sends, nested sends held until an action finishes, a failure in `:fail` mode and
  restarts: each accepted send runs once, in the order sent; nested sends go out once.

    determinismo explore ... --program zig-out/bin/clojure-compiler-test --scenario all

## Found

**`ensure` collapses the STM's throughput under contention** (found by the `stm` scenario,
2026-10-26). In run 14 (eight hours, `--scenario all`), 56 of the first 160 timelines failed
"the service never answers again": thirty seconds after faults stopped, the service still did
not answer. A replay of one of them (timeline 64) with `--at-vtime-ms 160000 --exec "det-nodes
exec clojure jcmd 1 Thread.print"` showed 590 threads: 217 in `LockingTransaction.tryWriteLock`
(timed, from `alter`), 226 blocked without a timeout on a ref's read lock (186 in `doGet`, 40 in
`doEnsure`), and 133 request handlers waiting on them, over all eight account refs.

How, read from LockingTransaction.java: `ensure` takes a ref's read lock and holds it until the
transaction ends. A writer waits up to 100 ms for the write lock (`LOCK_WAIT_MSECS`), then
retries, without backoff; a transaction that finds a younger one writing waits 100 ms too
(`blockAndBail`). Meanwhile reads inside transactions (`doGet`) and other ensures (`doEnsure`)
take read locks with an untimed `lock()`, and `ReentrantReadWriteLock` makes new readers queue
behind a waiting writer. So a transaction holding ensure read locks can wait behind a writer that
is waiting for those very locks, until the writer's timeout; with many writers retrying, nearly
every commit costs a 100 ms timeout.

It is not specific to the simulation. On a laptop, stock Clojure 1.12, each thread looping
`(dosync (ensure a) @b (alter c inc))` over eight refs:

| threads | commits a second without `ensure` | with `ensure` |
|--------:|----------------------------------:|--------------:|
| 8       | about 1,160,000                   | about 100     |
| 128     | about 450,000                     | about 5       |

No transaction is wrong (the totals and the skew floor always held): it is liveness, and with a
few hundred contending threads a transaction takes minutes.
