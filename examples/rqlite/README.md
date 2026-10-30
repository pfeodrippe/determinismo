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
Each through a node drawn at random (followers forward to their leader); each driver aims the
injector at the leader a node names as it starts (`/leader`, `sdk.fault_aim`). Outcomes: committed;
not committed (no connection, a statement's error rolling it back, `leader not found`);
unknown otherwise (a leadership lost while committing, a timeout).

| Property | Breaks when |
|---|---|
| Elle finds no anomaly in the history (strict serializable) | a lost or reordered append, a stale linearizable read, a write read that never committed |
| every committed append is in the final read | an acknowledged write gone once faults stop (final reads at `level=linearizable`) |
| the final reads reach a node once faults stop | the cluster never serves again |

## Membership changes

A fourth node, `rq-4`, is a spare. The `member` driver takes one step at a time: the spare
started fresh when `/nodes` does not list it (it joins as a voter by itself, after a 30 s grace
for its join); listed, one time in two stopped and removed (`DELETE /remove`). Elle's checks and
the final reads hold through them.

## Found: a committed write applied twice (rqlite 10.6.6, under investigation)

The first membership smoke (srv3, 2026-10-30, seed 1, 4 timelines) failed Elle in branch 3:
`duplicate-elements`, key 0's list holding value 2560125673930752 twice. The history has one
transaction appending it (invoked at 2.49 s, acknowledged `ok` at 12.51 s); a read at 13.9 s
saw it once. Replays read every node's own copy (`level=none`): at 20 s rq-1, rq-2 and rq-3
all hold it twice, so the command was committed to the Raft log twice, not applied twice by
one node. In between: rq-4 joined at 11.8 s and was removed at 13.0 s, among partitions (append
and heartbeat RPCs failing, leaders stepping down). Our client sends each request once
(`sdk.tcp.http_with` never resends).

A candidate mechanism, in rqlite's own code: `cluster/client.go`'s `retry()` sets
`effectiveRetries := max(1, maxRetries)`, and on the last retry writes the command again on a
new connection ("Try a new connection if retries failed", 2026-03-28). So a request forwarded
to the leader with no retries (`/db/request`'s default) is still written twice when the first
attempt's answer is lost after it reached the leader. #1628 (duplicate inserts on packet loss)
was fixed in 8.18 by retrying nothing by default; #2759 (a failed snapshot restore
re-applying entries, found with Antithesis) is a follower's divergence, not this: here every
node agrees. To confirm: the forwarding node's `client_force_new_conn` counter, and which node
the request entered. Replay: `--seed 1 --branch 3 --scenario append`.

## Status

- 2026-10-29: written; first smoke next.
