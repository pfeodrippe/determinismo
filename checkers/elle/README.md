# Elle as a node

[Elle](https://github.com/jepsen-io/elle) (Jepsen's checker, EPL-2.0) infers the dependency graph
of a transactional history and reports every anomaly it finds: G0, G1a/b/c, G-single, G2, and
with real-time order, violations of strict serializability. Here it runs as a node any test
program can add, without faults (it judges, it is not under test):

```zig
default.node(.elle, .{
    .build = .{ .context = ".", .dockerfile = "checkers/elle/Dockerfile" },
    .ready = .{ .tcp = 7700 },
    .faults = .{ .pause = false, .isolate = false, .partition = false, .degrade = false,
        .throttle = false, .process_pause = false, .sync_stall = false },
});
```

Drivers append each operation to a history file in the runner as it happens (one line, one
write, so lines of parallel drivers never interleave), and a `finally` command posts the file:

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
every operation in its cycle. Used by `examples/etcd`.

Three things the image works around: the guest has one CPU, and a JVM that sees one sizes its
pools at one thread, with which Elle deadlocks (its history folds wait on tasks queued to the
same pool), even on an empty history, so the JVM runs with `-XX:ActiveProcessorCount=4`;
rhizome (Elle's Graphviz renderer) sets Swing up as it loads, which fails on a headless JVM, so
`src/rhizome/viz.clj` stands in for it (Elle draws only into a `:directory`, never given here);
and Elle 0.2.8's `elle.txn` loads unilog while declaring it for its dev profile only, so
`deps.edn` adds it.
