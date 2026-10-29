# YugabyteDB under determinismo

YugabyteDB 1.3.1.0-b16, the release of Jepsen's [analysis](https://jepsen.io/analyses/yugabyte-db-1.3.1)
(2019), as its YSQL tests ran it (jepsen-io/jepsen, `yugabyte/`): list-append transactions over
YSQL, PostgreSQL's protocol, checked by Elle for serializability.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio --memory-mib 8192 \
  --program zig-out/bin/yugabyte-test --scenario append --seed 1 --time-budget 1h
```

## What Jepsen found in 1.3.1 (YSQL)

- **#2125**: G2-item cycles (anti-dependency cycles, each with several) in append
  transactions, reading and updating by primary key only, when every master crashed and
  restarted together, or masters paused. Fixed in 1.3.1.2.
- #2021: DEFAULT columns (`NOW()` and the rest) read as NULL in tables just created.
- #1962, #1993: duplicate keys in the catalog during CREATE TABLE across a master election;
  #1991: concurrent `CREATE TABLE IF NOT EXISTS` failing; #1995: a master crash creating a
  table soon after startup.
- #1992: recoveries from partitions taking over 100 s; #2075: leaked PostgreSQL workers.

## The system

- Three nodes, each a master and a tablet server (Jepsen's five had masters on three); RF 3.
- `start.sh` passes Jepsen's flags: masters with the initial system catalog snapshot and
  `--load_balancer_max_concurrent_adds 10`; tablet servers with YSQL's PostgreSQL proxy on
  5433 and `--rpc_slow_query_threshold_ms 1000`; four shards per tablet server; 1 GB of memory
  for a tablet server, 512 MB for a master (Jepsen's 2 GB each: three nodes share the machine;
  1 GB masters ended long timelines in OOM kills). Each process starts again when it exits, as
  Jepsen's nemesis restarted the ones it killed.
- WAL segments of 4 MB (`--log_segment_size_mb 4`, 64 by default): a node's disk lives in the
  VM's memory, and each tablet preallocates its next segment whole and keeps its segments
  300 s; with 64 MB segments, run 77 ended 7 of 64 timelines in OOM kills.
- Readiness is the master's port: YSQL waits on a quorum of masters, which needs the nodes
  started after.
- Profile `current` (2026-10-29): YugabyteDB 2026.1.2.0-b137, the latest release
  (Dockerfile.2026.1), the same start script and flags, a 1 GB master and a 2 GB tablet server
  (`--memory-mib 12288`); its YSQL backends' crashes are not known ones. First smoke next.

## The workload

examples/sql/append.zig with Jepsen's YSQL choices: five tables, appends that update and insert
when no row matched (directly: 1.3 has no savepoints, so an insert that loses a race fails its
transaction, as in Jepsen's client), rows found by their primary key, SERIALIZABLE,
transactions of one statement alone and longer ones between BEGIN and COMMIT. (Jepsen's rows
held two keys each, `v0` and `v1`; ours hold one.)

Faults: the default ones, kills of yb-master and yb-tserver (`process_kill_names`), restarts and
graceful stops, paced: stretches of faults up to 10 s and quiet ones up to 10 s. No power
losses: YugabyteDB 1.3 does not sync its write-ahead log by default (`durable_wal_write`), so a
power loss may take what it acknowledged; the first runs with them had masters whose catalogs
read back corrupt ("no meta-n..." from RocksDB).

Why the kills are named and the faults paced: a kill of any process took YSQL's PostgreSQL
backends too, and a backend's abnormal death makes its postmaster restart every backend, by
design; with a fault every 10 to 300 ms, YSQL was always restarting ("the database system is
starting up", "shutting down", "in recovery mode") and no transaction got through. Without
faults, histories are valid and nothing crashes.

## Found blind: yugabyte-db#2571

A single fresh timeline (srv3, 2026-10-28, seed 3, `--scenario append`, faults on) aborted yb3's
tablet server at 41.3 s of virtual time with `mvcc.cc:340] Check failed: result >=
enforced_min_time`: a read's safe time below the minimum the tablet enforces. Known upstream as
[#2571](https://github.com/yugabyte/yugabyte-db/issues/2571) (October 2019, 1.3, closed).

## Found: committed transactions reported as serialization failures (G1a)

Run 18 (srv3, 2026-10-28, seed 7, 215 timelines): Elle found G1a, aborted reads, with dirty
updates, in three timelines (44, 47, 94): a transaction read an element appended by one its
client had seen fail. In timeline 47, a stop fault sent yb3 SIGTERM at 371.23 s; its YSQL
backend, shutting down, could not schedule a COMMIT's status update (`Failed to schedule ...
UpdateTransaction`), the YugabyteDB client logged `transaction.cc:326] Abort of committed
transaction`, and the client got `ERROR: Error during commit: Aborted: ...` with SQLSTATE 40001.
In 1.3.1, `YBCHandleCommitError` (pg_yb_utils.c) reports every commit error as 40001, a
serialization failure, which tells a client the transaction was rolled back, whatever its
outcome: here it had committed, and a later read saw its write. Current YugabyteDB commits
through `HandleYBStatus`, which gives each status its own SQLSTATE: fixed since, in code that
no longer exists.

## Hunt run 77 (srv3, 2026-10-28, seed 3, in progress)

Kills, stops and pauses, no power losses (the log is not synced by default). In its first 16
timelines, Elle found:
- timeline 15: G2-item at serializable, an anti-dependency cycle between two committed append
  transactions (166.6 s and 190.0 s), after pauses of the nodes' processes: #2125's other
  trigger was paused masters. Which processes were paused, the fault events did not say then
  (they name the process since); not yet claimed as #2125.
- timeline 9: incompatible-order on key 38: one read `[…160]`, a later one `[…193, …208,
  …209]`. Appends only concatenate to a row (or insert it when there is none), so the row that
  held 160 vanished and was inserted again: a lost committed insert.
The run had no outage: kill outages (every node killed at once, #2125's first trigger) came
after it. At 64 timelines, besides "no process crashes: postgres" in every one (YSQL's
backends, below: known crashes since), it failed:
- "no process crashes: yb-tserver" in 6: aborts in `mvcc.cc:340` (`Check failed: result >=
  enforced_min_time`, a write's safe time below the tablet's minimum), #2571 above.
- "no process crashes: yb-master" in 1 (timeline 17): a master killed and restarted found its
  newest sys-catalog WAL segment, `wal-000000051`, with "12 initial NULL bytes instead of
  magic and header length" (renamed into place, its header never written: the kill came
  between the two), and 20 s after it started, rolling over to its next segment, it could
  not open its active one, `wal-000000051`: "No such file or directory" (`log.cc:1068`, in
  `SwitchToAllocatedSegment`), and aborted. The same abort, in the same function, is open
  upstream as #30325 (2026-02, 2.29, under kernel shutdowns): here after a process kill alone.
- "the kernel kills no process for lack of memory" in 7: the VM's memory, filled by the WAL's
  preallocated 64 MB segments (a node's disk is memory): a replay of timeline 16 at 770 s, just
  before its OOM kill, found 6.6 GB of the VM's 7.1 GB in its disks (Shmem) and 186 MB
  available, the tablet servers' WALs 1.36 and 1.45 GB (72 tablets each), their data 483 MB.
  4 MB segments since.

## Observed (1.3.1, not investigated further)

- YSQL backends segfault as they exit, in `yb::rpc::ThreadPool::Impl::Shutdown()`, popping a
  task from libcds's BasketQueue with the thread's hazard pointers gone
  (`cds::gc::dhp::thread_hp_storage::alloc`, `dhp.h:134`; libyrpc.so+0xe9a67), the kernel's
  `segfault at 0 ... in libyrpc.so`. Each such death restarts the node's backends.
- Tablet servers segfault (exit 139) within seconds of a node stop and a partition.
- The same exit crash in a backend's YugabyteDB client threads (`rpc_tp_Transact`, in
  `yb::HostPort::ParseStrings`, net_util.cc:249, a destroyed flag string; `pggate_ybclient`):
  run 18 named them as properties of their own until crash properties named the process.

Both are in a release from 2019, in code that has changed much since; neither names an issue
in YugabyteDB's tracker.
