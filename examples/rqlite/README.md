# rqlite under determinismo

rqlite 10.6.6 (Raft, hashicorp/raft, over SQLite 3.53.4; Go): three voting nodes. Jepsen never
analyzed it. It promises linearizable writes (every one through the Raft log, synced before it
is acknowledged) and, at `level=linearizable`, linearizable reads (the leader confirms a quorum
still follows it, then reads once it applied the commit index it saw).

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio --memory-mib 3072 \
  --program zig-out/bin/rqlite-test --scenario append --seed 1 --time-budget 1h
```

## The system

- The image (Dockerfile): the official `rqlite/rqlite:10.6.6`; `start.sh <id>`: `rqlited` with
  HTTP on 4001 and Raft on 4002, advertised at the node's IPv4 address, the three bootstrapping
  together (`-bootstrap-expect 3`, each joining through the others); a node with state rejoins
  from it.
- Profiles: `default`, rqlite's own settings; `snapshots`, a Raft snapshot every 64 entries (or
  64 KiB of SQLite WAL), checked every second, so a timeline snapshots and truncates its log
  many times (the default waits for 8,192 entries or a 4 MiB WAL).
- Faults: the default ones (pauses, partitions, degraded links, sync stalls, throttling),
  process kills, power losses and graceful stops, in bursts with quiet stretches.

## The workload and its properties

Jepsen's list-append in SQL: every key a row of `lists (id INTEGER PRIMARY KEY, value TEXT)`,
its list the text `v1,v2,...`. A transaction is one request to the unified endpoint
(`/db/request?transaction`): reads and appends (an upsert concatenating `,v`) in one SQLite
transaction; with an append it goes through the Raft log, read-only at `level=linearizable`.
Each through a node drawn at random (followers forward to their leader). Outcomes: committed;
not committed (no connection, a statement's error rolling it back, `leader not found`);
unknown otherwise (a leadership lost while committing, a timeout).

| Property | Breaks when |
|---|---|
| Elle finds no anomaly in the history (strict serializable) | a lost or reordered append, a stale linearizable read, a write read that never committed |
| every committed append is in the final read | an acknowledged write gone once faults stop (final reads at `level=linearizable`) |
| the final reads reach a node once faults stop | the cluster never serves again |

## Status

- 2026-10-29: written; first smoke next.
