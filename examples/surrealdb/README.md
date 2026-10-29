# SurrealDB on TiKV under determinismo

SurrealDB 3.3.5, its data in TiKV v8.5.8: three nodes, each running PD, TiKV and a SurrealDB
server. SurrealDB documents snapshot isolation for every transaction, on every storage backend
(TiKV included), a write conflict failing the later commit ("can be retried"). Jepsen never
analyzed SurrealDB.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio --memory-mib 10240 \
  --program zig-out/bin/surrealdb-test --scenario append --seed 1 --time-budget 1h
```

## The system

- The image (Dockerfile): TiKV's release image with PD's and SurrealDB's binaries (SurrealDB's
  own image is distroless); Jepsen's PD and TiKV configurations from examples/tidb (regions of at
  most 5 keys, splitting and merging all the time).
- `start`: PD, TiKV and `surreal start --unauthenticated tikv://127.0.0.1:2379` (HTTP on 8000),
  each started again when it exits.
- Faults: the default ones, process kills, power losses, graceful stops, in bursts with quiet
  stretches.

## The workload and its properties

List-append: every key a record `lists:k`, its list in `v`. A transaction is one `/sql` request:
`BEGIN TRANSACTION`, reads (`lists:k.v`: an expression, since a `RETURN` ends a transaction there
and commits it) and appends (`UPSERT lists:k SET v = array::append(v ?? [], x)`), `COMMIT
TRANSACTION`; through a node drawn each time. Outcomes: committed; not committed (no connection,
a statement's error, a conflict at the commit); unknown otherwise (no answer, any other error at
the commit).

| Property | Breaks when |
|---|---|
| Elle finds no anomaly in the history (snapshot isolation) | a lost or reordered append, a read of a write never committed, a read outside one snapshot |
| every committed append is in the final read | an acknowledged commit gone once faults stop |
| the final reads reach a node once faults stop | the cluster never serves again |

## Status

- 2026-10-29: written; the transaction's shape tried on a 3.3.5 server in memory (a `RETURN`
  inside a transaction ends it, committing what ran: reads are expressions). First smoke next.
