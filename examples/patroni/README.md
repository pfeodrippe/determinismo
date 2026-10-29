# Patroni under determinismo

PostgreSQL 18.6 made highly available by Patroni 4.1.0: three nodes, each an etcd 3.7.3 member
(Patroni's store, its DCS) beside a database, as small deployments run them. Jepsen tested
Stolon (2020: G2-item and lost writes on failover); Patroni, the most deployed of its kind, it
never did.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio --memory-mib 4096 \
  --program zig-out/bin/patroni-test --scenario serializable --seed 1 --time-budget 1h
```

## The system

- The image (Dockerfile): the official `postgres:18.6`, Patroni in a virtual environment of its
  own, etcd's release binaries checked against their SHA256SUMS.
- `start <id>`: node pg<id>'s etcd member (restarted if it exits, as its service would be), then
  Patroni, which runs PostgreSQL: the first node to take the bootstrap lock initializes the
  database, the others clone it and follow the leader. Failovers within seconds (ttl 15 s,
  loop_wait 3 s, retry_timeout 5 s), pg_rewind on, trust authentication inside the cluster.
- Profiles: `default`, `synchronous_mode` (a commit is acknowledged once a synchronous standby
  has it, and only such a standby is promoted); `async`, Patroni's own default (asynchronous
  standbys: a failover may lose up to `maximum_lag_on_failover` bytes of acknowledged commits,
  by design).
- A node is ready once etcd listens to its peers (2380): Patroni waits for an etcd quorum before
  anything else, which needs the nodes after it (the first smoke waited on pg1 alone).
- The nodes' disks have a 30 s writeback window (`writeback_s`): Patroni writes files of its own
  without syncing them; PostgreSQL and etcd sync their own.

## The workload and its properties

Jepsen's PostgreSQL workload (examples/sql/append.zig): list-append transactions over three
tables, SERIALIZABLE, through the primary whatever node it is now: a connection to a standby
(`pg_is_in_recovery()`) is dropped for another node, as a client following the leader does (a
standby's reads lag by design, its writes are refused). Drivers keep trying through about a
minute of refused connections in a row, a failover's length.

| Property | Breaks when |
|---|---|
| Elle finds no anomaly in the history (serializable) | a cycle, a read of an aborted write, a lost or reordered append among the ones read |
| every committed append is in the final read | a failover (or anything) loses an acknowledged commit: in `default`, a finding |
| the final reads reach a node once faults stop | the cluster never elects a primary again |

Faults: the default ones, restarts, graceful stops and power losses (each node's database and
etcd member on its own disk, outages of several at once), and stalls and power losses at syncs.

## Status

- 2026-10-29: written. First smoke: pg1 alone started, waiting on etcd (readiness was Patroni's
  REST API, which waits for a quorum): ready on etcd's peer port since. Second: setup in 17 s,
  2 timelines passed; in one no transaction ran (two nodes lost power at once, every driver gave
  up after ~11 s of refused connections): the SQL drivers count refusals in a row since, and
  Patroni's allow a minute of them. Third: still none, for 2,000 s: faults unpaced (the cluster
  never settled; paced in bursts since, as Kafka's and OpenSearch's) and every client refused,
  "no pg_hba.conf entry for host 10.0.0.1": Patroni writes the bootstrap's pg_hba.conf without
  syncing it, and a power loss soon after left initdb's local-only rules. The rules are in
  Patroni's local configuration since (`postgresql.pg_hba`), written at every start. Fourth
  (seed 1, 4 timelines): all passed, 702 operations in timeline 0's history.
- 2026-10-29, first hunt (run 189, seed 1, tree): 444 timelines until its discovery plateaued,
  replays 16 of 16 the same; no committed append lost, Elle clean. One failure, in 5 timelines
  (332, 352 to 355): "no process crashes: postgres", a standby's startup PANICking at every start
  ("invalid xl_info in checkpoint record", "could not locate a valid checkpoint record at
  0/2000150"). Timeline 332: Patroni ran pg_rewind on pg3 from the new primary at 83.3 s; pg3 was
  paused and isolated meanwhile, and pg_rewind failed partway ("unexpected result while fetching
  remote files"), its WAL already rewritten (segments 3 and 4 at 0 bytes, segment 2 cut to 3 MB,
  where at 57 s and 61 s, across a power loss, all three were whole). Patroni logged "Failed to
  rewind because primary pg2 become unreachable" and kept the rewind due (its guard against a
  damaged attempt, `can_rewind`, looks at pg_control's flags only); the retry at 114 s failed on
  the damage ("could not read file .../000000010000000000000004: read 0 of 8192"), "Failed to
  rewind from healthy primary", and Patroni started the standby on that directory, as its
  default promises ("Otherwise it will try to follow the new leader":
  `remove_data_directory_on_rewind_failure` off). PostgreSQL's documentation: a target whose
  pg_rewind failed partway is likely unrecoverable. Documented, not a finding: that PANIC is a
  known exit since (`exits_known`), so later hunts see the crashes it does not explain.
