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
- Background work at test timescales: the failure detector at `phi_convict_threshold: 5` (the
  least Cassandra takes; 8 by default), so a paused or cut off node is convicted within a fault,
  and memtables flushed every minute (`memtable_flush_period_in_ms`), so sstables, their
  compactions and reads merging them happen within a timeline.

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

- 2026-10-29: written. First smoke: n1 was ready only once a peer gossiped with it, and the
  nodes start one after another (ready on the storage port since). Then (run 199, seed 1, 4
  timelines): Elle and the final reads pass in all four, a committed append judged in every
  one; timeline 2 lost n1 for good after a restart killed it while the image's entrypoint
  rewrote cassandra.yaml in place (`cat` over it): truncated, "Missing required directive
  CommitLogSync" at every start. The container's scaffolding, not Cassandra: start.sh restores
  the shipped configuration first since.
- 2026-10-29, first Accord smoke (6.0-alpha2; ran without faults, det-faults then crashed at
  start): setup failed. Ready on the storage port, n2 and n3 joined at once and chose the same
  tokens (the replication-aware allocator is deterministic, both from a ring of n1 alone); the
  cluster metadata service committed n2's join and refused n3's ("Rejecting this plan as some
  tokens are already assigned"), and n3 failed its startup for good. Cassandra asks for nodes
  added one at a time (CASSANDRA-16364 is the same race before TCM): ready on CQL's port since,
  which a node opens once it joined (up to 240 s: alone, the first waits 30 s for gossip). A
  transaction refused for a keyspace a node does not know yet (its metadata catching up) counts
  as refused, not malformed.
