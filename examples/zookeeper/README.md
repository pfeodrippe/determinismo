# ZooKeeper under determinismo

ZooKeeper 3.9, an ensemble of three servers, under list-append transactions that Elle checks for
strict serializability. Jepsen tested ZooKeeper in 2013 (a CAS register: it held, but for
`sync`+read edge cases); since then its follower sync after restarts has lost committed
transactions more than once (ZOOKEEPER-4785, fixed in 3.9.2): power losses at the right sync
are what determinismo explores.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio --memory-mib 3072 \
  --program zig-out/bin/zookeeper-test --scenario append --seed 1 --time-budget 1h
```

## The system

- The image: the official `zookeeper:3.9.6` (profile `default`) or `3.9.1` (profile `known`,
  before ZOOKEEPER-4785's fix), with Python and kazoo for the client node.
- `start.sh server <id>`: a static ensemble of zk-1..3, its snapshots and log on the node's disk
  (`forceSync=yes`: the log synced before an acknowledgement).
- `start.sh client`: `zclient.py`, kazoo behind a line protocol, connected to the one server a
  request names (no failover), again after an error.
- Setup waits until every server answers a transaction.

## The workload and its properties

Each driver runs twenty transactions of one to four micro-operations (append a unique value to a
key, or read it), on keys that move with virtual time, through a server drawn each time. A
transaction reads its keys (`sync`, then `get`) and commits one `multi`: a version check of each
key it only read (for one it read as absent, a create and a delete: a `multi` cannot check a
missing znode, and a read of nothing that another transaction filled before the commit would be
a stale read of the client's, not ZooKeeper's), a versioned set (or a create) of each it
appended to. ZooKeeper applies a
`multi` whole or not at all; a version conflict retries from the reads. Recorded for Elle:
- `ok` with the reads, the commit answered;
- `fail`: nothing applied (refused, or no connection to send it on);
- `info`: the commit got no answer.

Once faults stop, every key is read again through each server, into the history: an
acknowledged append missing from those reads is lost.

| Property | Breaks when |
|---|---|
| Elle finds no anomaly in the history (strict serializable) | lost or reordered appends, stale reads that a commit's checks should have refused, ... |
| the ensemble serves again once faults stop | it never elects a leader or a server never catches up |

Faults: the default ones in bursts with quiet stretches, restarts, power losses (including at
the servers' syncs, and outages of several at once) and graceful stops; the client node's links
to the servers faulted, the drivers' calls into it not.

## Found blind: ZOOKEEPER-3220, a server that never starts again

The first smokes (srv3, 2026-10-29, runs 86 and 91) lost servers for good: after a power loss,
zk-1 refused to start, at every start, with `java.io.IOException: No snapshot found, but there
are log entries. Something is broken!` (`FileTxnSnapLog.restore`, from `QuorumPeer.loadDataBase`)
and exited 1. ZooKeeper syncs its transaction log but not its snapshots: the one it takes at
startup ("Make a clean snapshot", `ZooKeeperServer.loadData`) is `takeSnapshot()`, which is
`takeSnapshot(false)`, no fsync (3.9.4), and the refusal since ZOOKEEPER-2325 makes synced logs
without a snapshot unbootable. Run 91's power loss came within 30 s of the server's first start,
before any writeback: a real host loses it too. Known: ZOOKEEPER-3220 ("The snapshot is not
saved to disk and may cause data inconsistency", open since 2018); ZOOKEEPER-4005 (patch
available) is the same for a snapshot taken on a DIFF sync. The ensemble serves on with two.
The servers declare this exit known (`exits_known`, by its message): counted ("an exit the
system is known to make: ..."), it does not fail "no unexpected container exits", which then
says what else made a server exit.

## Status

- 2026-10-28: written; first timelines next.
- 2026-10-29: first smokes (runs 86, 91): transactions commit, Elle checks the histories. Fixed
  in the workload on the way: the client's kazoo calls waited for a server that never came back
  (now each bounded by the timeout), the final reads retried a dead server key by key until the
  timeline's hour ran out (a server that refuses a whole retry budget is down: its other reads
  fail at once), and a key read as absent is checked absent at the commit (a create and a
  delete in the multi). The servers' disks have a 30 s writeback window (`writeback_s`): their
  snapshots are never synced, and under the guest's strict model a power loss at any age left
  a server unbootable, not only within 30 s of a snapshot as on a real host.
- 2026-10-29, first hunt (run 178, 3.9.6, seed 1, tree): 490 timelines until its discovery
  plateaued (2 h 10 min), nothing failing; 16 of 16 replays the same. Next: the `known` profile
  (3.9.1, before ZOOKEEPER-4785's fix) for its blind rediscovery.
- 2026-10-29: profile `keeper`, ClickHouse Keeper 26.9.27.3 (ClickHouse's ZooKeeper-compatible
  coordination service, C++ on NuRaft) as the three servers, under the same client and checks
  (Dockerfile.keeper, `start.sh keeper <id>`; ready once Raft listens on 9234). First smoke next.
  The drivers aim half the faults at the leader they find as they start (zclient's `leader`: the
  server whose `srvr` says "Mode: leader"; `sdk.fault_aim`), ZooKeeper's and Keeper's alike.
