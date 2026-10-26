# Elle, on the host

[Elle](https://github.com/jepsen-io/elle) (Jepsen's checker, EPL-2.0) infers the dependency graph
of a transactional history and reports every anomaly it finds: G0, G1a/b/c, G-single, G2, and
with real-time order, violations of strict serializability. To a test program it is a library:
a host check (ARCHITECTURE.md §10.4) from `sdk.elle`, run on every timeline's history.

```zig
// The program's checks: Elle on every timeline's history (a model per scenario if need be).
return System.main(init, .{ .describe = describe, .scenarios = .{ ... },
    .checks = .{ .elle = sdk.elle.check(.{ .consistency = "strict-serializable" }) } });

// A driver: each operation as it happens (sdk.elle.History records them for the check).
try history.invoke(arena, process, &asked);
try history.ok(arena, process, &done); // Or fail, or info.
```

Under it, Elle (Clojure, on the JVM) runs as one warm service per host, on 127.0.0.1:7700, built
from this directory and started by the first check that needs it: a JVM per check would cost
more than the check. The check posts the timeline's history to it and asserts the verdict. The
history is JSON lines, in the order operations happened:

```
POST /check?model=list-append&consistency=strict-serializable

{"process": 7, "type": "invoke", "f": "txn", "value": [["append", 3, 17], ["r", 4, null]]}
{"process": 7, "type": "ok", "f": "txn", "value": [["append", 3, 17], ["r", 4, [2, 9]]]}
```

- `type`: `invoke`, then the same process's `ok` (reads filled in), `fail` (it did not happen)
  or `info` (unknown: the process then goes on as another, Elle's one-operation-at-a-time rule).
  An invocation never completed (its driver stopped mid-call) is closed as `info`.
- `model`: `list-append` (`append k v` with values unique per key, `r k [v ...]`) or
  `rw-register` (`w k v`, `r k v`). `consistency`: any of Elle's models (`strict-serializable`,
  `serializable`, `snapshot-isolation`, `read-committed`, ...).
- The answer: `{"valid": true | false | "unknown", "anomaly_types": [...], "not": [...], "ops": n,
  "anomalies": "..."}` (the anomalies as Elle prints them, cut short).

Since the history is recorded inside the timeline, an anomaly replays exactly, to the moment of
every operation in its cycle. Used by `examples/etcd` and `examples/postgres`.

Three things the image works around: a JVM that sees one CPU (as in a guest, or a host pinned to
one) sizes its pools at one thread, with which Elle deadlocks (its history folds wait on tasks
queued to the same pool), even on an empty history, so the JVM runs with
`-XX:ActiveProcessorCount=4`;
rhizome (Elle's Graphviz renderer) sets Swing up as it loads, which fails on a headless JVM, so
`src/rhizome/viz.clj` stands in for it (Elle draws only into a `:directory`, never given here);
and Elle 0.2.8's `elle.txn` loads unilog while declaring it for its dev profile only, so
`deps.edn` adds it.
