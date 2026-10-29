# Apache Ignite 3 under determinismo

Apache Ignite 3.1.0: three server nodes, a zone of three replicas. Ignite 3 is a rewrite (3.0 in
2025): tables replicated by Raft, primary replicas holding leases, MVCC transactions over hybrid
logical clocks, read-write ones serializable under locks, read-only ones read as of their start
time. Jepsen never analyzed Ignite.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio --memory-mib 8192 \
  --program zig-out/bin/ignite-test --scenario append --seed 1 --time-budget 1h
```

## The system

- The image (Dockerfile): the official `apacheignite/ignite:3.1.0` (Java 11), and the client
  node's IClient.java on Ignite's Java client 3.1.0 (Maven Central, at build time).
- `start.sh server <n>`: node `n<n>` through the image's entrypoint, a static node finder naming
  the three, a 768 MB heap. Setup initializes the cluster (`/management/v1/cluster/init`, all
  three in its management and metastorage groups), then creates the zone (`REPLICAS 3,
  PARTITIONS 8`) and the table through the client node.
- Profiles: `default`, Ignite's own settings (table partitions' Raft logs not synced before an
  entry is acknowledged, `raft.fsync = false`: no power losses); `power-loss`, `raft.fsync =
  true`, and power losses too.
- Faults: the default ones, process kills, graceful stops, in bursts with quiet stretches. The
  client node stands for the test's own client library: its links to the servers are faulted,
  the drivers' calls into it are not.

## The workload and its properties

List-append: every key a row of `LISTS (ID BIGINT PRIMARY KEY, VAL VARCHAR)`, its list the text
`v1,v2,...`. A transaction with an append is read-write, each append a get and a put of the key's
list in the transaction; one without is read-only. The drivers share one `IgniteClient` (no
retries), as an application server holds one: its observable timestamp covers every commit
acknowledged through it, so a read-only transaction begun after one reads it. (A read-only
transaction of a client with no observed timestamp reads at its clock less the maximum clock
skew and safe time's period: in the past, by design, IGNITE-21098.) Outcomes as Ignite documents them: an error before the commit, or a
`TransactionException` from the commit, is a rollback; any other error at the commit is unknown.

| Property | Breaks when |
|---|---|
| Elle finds no anomaly in the history (strict serializable) | a lost or reordered append, a stale read-only transaction, a write read from a transaction reported rolled back |
| every committed append is in the final read | an acknowledged commit gone once faults stop |
| the final reads reach a node once faults stop | the cluster never serves again |

## Status

- 2026-10-29: written; the client node compiles against Ignite's Java client 3.1.0. First smoke
  next.
