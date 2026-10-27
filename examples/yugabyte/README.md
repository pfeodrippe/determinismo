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
  each (Jepsen's 2: three nodes share the machine). Each process starts again when it exits, as
  Jepsen's nemesis restarted the ones it killed.
- Readiness is the master's port: YSQL waits on a quorum of masters, which needs the nodes
  started after.

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

## Observed (1.3.1, not investigated further)

- YSQL backends segfault as they exit, in `yb::rpc::ThreadPool::Impl::Shutdown()`, popping a
  task from libcds's BasketQueue with the thread's hazard pointers gone
  (`cds::gc::dhp::thread_hp_storage::alloc`, `dhp.h:134`; libyrpc.so+0xe9a67), the kernel's
  `segfault at 0 ... in libyrpc.so`. Each such death restarts the node's backends.
- Tablet servers segfault (exit 139) within seconds of a node stop and a partition.

Both are in a release from 2019, in code that has changed much since; neither names an issue
in YugabyteDB's tracker.
