# Apache Cassandra under determinismo

Apache Cassandra 5.0.9, three nodes, under Jepsen's Scylla workload (examples/scylla:
list-append over lightweight transactions, Paxos v2 since 4.1). Jepsen last tested Cassandra in
2013 (2.0: LWT lost and duplicated writes).

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio --memory-mib 6144 \
  --program zig-out/bin/cassandra-test --scenario append --seed 1 --time-budget 1h
```

## The system

- The image (Dockerfile): the official `cassandra:5.0.9`; `start.sh <node>` through the image's
  entrypoint and its `CASSANDRA_*` settings: every node a seed, IPv4 addresses (a node's own name
  also resolves to its link-local IPv6 address first), a 512 MB heap (three JVMs share the
  machine).
- Profiles: `default`, Cassandra's own settings (the commitlog synced every 10 s: a power loss
  may take acknowledged writes, by design), under Jepsen's faults (kills, restarts, graceful
  stops; no power loss); `power-loss`, the commitlog synced before a write is acknowledged
  (`commitlog_sync: batch`), and power losses too, at syncs as well.
- Faults in bursts with quiet stretches (JVMs restart in tens of seconds); process kills only of
  Cassandra's JVM.

## The workload and its properties

As examples/scylla: every key a row of partition 0 in `lists (part, id, lwt_trivial, value
list<int>)`; an append is `UPDATE ... SET value = value + [v] ... IF lwt_trivial = null` (a
condition always true, for a Paxos round), several appends a conditional BATCH, a read a SELECT
at SERIAL. Outcomes as Jepsen's client takes them: Unavailable, or a condition not applied, means
the write did not happen; a timeout, a write failure, a lost connection may have.

| Property | Breaks when |
|---|---|
| Elle finds no anomaly in the history (strict serializable) | a lost or reordered append, a stale SERIAL read, an aborted write read |
| every committed append is in the final read | an acknowledged LWT gone once faults stop (SERIAL reads of every key) |
| the final reads reach a node once faults stop | the cluster never serves SERIAL reads again |

## Status

- 2026-10-29: written; first smoke next.
