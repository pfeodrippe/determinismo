# Jepsen's systems, as determinismo workloads

Every system Jepsen analyzed is a candidate workload: the analysis names the guarantees worth
checking, the operations that check them, and the anomalies that were there. Sources: the 33
analyses on jepsen.io/analyses, Kyle Kingsbury's earlier Jepsen posts on aphyr.com (2013 to
2017), and the test suites in github.com/jepsen-io (one repository per system; their workload
files are listed below). What each found is summarized here in our own words; read the analysis
before building the workload.

What determinismo adds to each: the faults run inside one deterministic machine (so an anomaly
replays exactly, to the moment of every operation in its cycle), the durability-point faults
(`sync_stall`, `durable_crash`: Jepsen's LazyFS finds the same act-before-fsync bugs, by losing
unsynced writes), and exploration that returns to the moments that reached new behavior. Checks:
`sdk.elle` (list-append and rw-register histories, checkers/elle) plus cheap `always` properties
for guidance as the timeline runs. Anomalies a system is known to allow (Kafka's G0, from
Jepsen's Bufstream analysis) go in the check's `allowed`: found alone they are reported apart,
and the property stays free for what is not known.

## Workloads to port (from jepsen-io/jepsen and the suites)

| Workload | What it checks | Elle model |
|---|---|---|
| list-append | transactions appending to and reading lists: every isolation anomaly, real-time order | list-append |
| rw-register | transactions writing and reading registers | rw-register |
| linearizable register (cas) | single-key read, write, compare-and-set | rw-register (single key) |
| set | adds acknowledged, then all read back: lost or phantom elements | (direct) |
| bank | transfers between accounts: totals conserved (read skew, lost update) | (direct) |
| long fork | two writes seen in opposite orders by two readers (parallel snapshot isolation) | list-append |
| monotonic / sequential | per-client or global order of increments and reads | (direct) |
| counter | increments acknowledged against the final value | (direct) |
| queue | enqueued messages dequeued exactly once (or at least once), none lost | (direct) |
| lock / lease | mutual exclusion, fencing (often unsafe by design: report, not fail) | (direct) |
| watch | change streams in order, none skipped | (direct) |

## The systems

Open source (or freely runnable) and still developed come first: a current version is where new
bugs are. Status: ✅ running, 🟡 next, blank later.

| System | Jepsen | What Jepsen found (short) | Their workloads | Status |
|---|---|---|---|---|
| etcd | 3.4.3 (2020), jetcd 0.8.2 (2025), 2014 post | watches with revision 0 skipped events; locks unsafe by design; the Java client's retries ran transactions twice | append, register, set, lock, watch, wr | ✅ examples/etcd (v3.7.3): found blind a member losing applied writes after a power loss following a snapshot install (known upstream: etcd-io/etcd#22498, open) |
| NATS JetStream | 2.12.1 (2025) | write loss when a minority's files were truncated or corrupted; split-brain and lost writes after coordinated power loss or one OS crash with delays, from flushing every two minutes | queue | ✅ examples/nats (v2.15.2) |
| Redpanda / Kafka | Redpanda 21.10 (2022), Bufstream 0.1 (2024), Kafka post (2013) | duplicate writes, inconsistent offsets, aborted reads, lost/stale messages; in Kafka's transaction protocol itself, write loss and torn transactions (KAFKA-17754) | list-append (transactions), queue | ✅ Apache Kafka (KRaft, examples/kafka: KAFKA-20979 found blind); Redpanda v26.2.6 as its `redpanda` profile (the same client and checks), first timelines next |
| MySQL, MariaDB Galera, Percona | MySQL 8.0.34 (2023), Galera 12.1.2 (2026), 2015 posts | Repeatable Read allowing G2-item, G-single, lost update, non-monotonic views; Galera losing committed transactions on crashes (no flush before ack) and with partitions, lost update, stale read | append, mav, nonrepeatable-read, closed-predicate | ✅ examples/mysql (26.10.0), examples/galera (13.0.2, Jepsen's configuration from jepsen-io/mysql's `antithesis/`) |
| PostgreSQL (and Stolon, RDS) | 12.3 (2020), RDS 17.4 (2025), 2013 post | serializable allowing G2-item (fixed); RDS multi-AZ violating snapshot isolation (long fork); Stolon ledger | append, ledger | ✅ examples/postgres (18.6, single node); next: HA (Patroni or Stolon) |
| MongoDB | 4.2.6 (2020), 3.6.4, 3.4.0-rc3, earlier posts | transactions with read skew, cyclic information flow, duplicate effects from retries; lost majority writes in old replication protocols | list-append (single and multi-node) | ✅ examples/mongodb (9.0.4, Jepsen's replica set settings and workload, our own wire client) |
| TiDB | 2.1.7 (2019) | auto-retry re-applying conflicting updates: read skew, lost updates | bank, long fork, register, sequential, set, append | ✅ examples/tidb (v8.5.8, Jepsen's configurations from jepsen-io/tidb) |
| YugabyteDB | 1.1.9, 1.3.1 (2019) | read skew, lost inserts with partitions, DDL races (defaults as NULL), undercounting; in 1.3.1 G2-item in YSQL append when every master crashed (#2125) | append, bank, counter, long fork, set, rw | 🟡 examples/yugabyte (1.3.1, Jepsen's flags and YSQL append): YSQL backends crash on their way out and restart the node's backends (README); hunting #2125 with paced faults |
| Dgraph | 1.1.1 (2020) | with tablet moves only: missing values (#4534), read skew corrupting totals (#4543), lost inserts (#4538), lists read as numbers (#4601) | bank, set, upsert, delete, sequential, long fork | ✅ examples/dgraph (v1.1.1, Jepsen's bank and tablet mover): found blind in the first run an alpha restarting that panics on a tablet move (nil group node in MovePredicate; not in Jepsen's report, no tracker issue); run 37: a replica replaying its log after a tablet move skips the rest of a schema proposal at the moved predicate and serves `type_0` without its index ("not indexed" until the end; not in Jepsen's report, no tracker issue) |
| CockroachDB | beta 2016 | serializability violations | bank, register, sequential, sets, monotonic, adya | 🟡 examples/cockroachdb (v26.3.3) |
| ScyllaDB | 4.2-rc3 (2020) | LWT split-brain (healthy clusters, then with membership changes), aborted LWT reads, non-isolated writes | cas-register, list-append, counter, batch | ✅ rediscovered blind (srv2, seed 3, examples/scylla: 4.2.rc3, Jepsen's configuration and LWT list-append, our own CQL client): #7258, an LWT batch answered Unavailable whose appends were read (G1a, dirty update), 1 of the first 99 timelines (and 3 of 416 in seed 5's hunt); the power-loss question was determinismo's (README) |
| Redis (Raft, Sentinel, Valkey) | Redis-Raft (2020), 2013/2014 posts | Redis-Raft: data loss on failover, split-brain, stale and aborted reads; Sentinel/WAIT lose writes by design | append, raft, cluster | Valkey cluster, Redis 8 |
| TigerBeetle | 0.16.11 (2025) | crashes, latencies under single faults, a query predicate bug; strong against disk corruption | transfer, idempotence, lifecycle | interesting: Zig, deterministic itself |
| RabbitMQ | 2014 post | lost messages with mirrored queues under partitions | queue | 🟡 examples/rabbitmq (4.1.4, a quorum queue, Jepsen's queue checks); found blind in its first timelines: a node that never boots again after a power loss soon after its first boot (an empty feature_flags file) |
| ZooKeeper | 2013 post | sync+read not linearizable in edge cases | register | 🟡 examples/zookeeper (3.9.6; `known`: 3.9.1, before ZOOKEEPER-4785's fix), list-append in multis, Elle |
| Consul | 2014 post | stale reads (fixed with consistent mode) | register | BUSL |
| Elasticsearch / OpenSearch | 1.1.0, 1.5.0 posts | lost inserts and updates on partitions, pauses, crashes | sets, dirty read | 🟡 examples/opensearch (OpenSearch 3.9.0: list-append on documents with optimistic concurrency, Elle) |
| Aerospike | 3.99 (2018), 3.5.4 post | lost updates with more than k crashes or 27 s of pause/skew; a write reported failed that succeeded | cas-register, counter, set | Community edition |
| Hazelcast | 3.8.3 (2017) | maps, locks, queues, atomics and ID generators unsafe under partitions | lock, queue, map, ids | |
| Apache Ignite | (suite only) | | bank, register | |
| Datomic Pro | 1.0.7075 (2024) | stronger than claimed between transactions; concurrent semantics inside one | append, append-cas, internal, grant | free binaries |
| RethinkDB | 2.1.5, 2.2.3 (2016) | reconfiguration during partitions: stale and dirty reads, lost updates | document cas | |
| Tendermint / CometBFT | 0.10.2 (2017) | WAL corruption and recovery crash; safe below 1/3 byzantine | cas-register, set | |
| Orkes / Netflix Conductor | 5.3.2 (2025) | tasks running concurrently, workflows abandoned, lost, or completed without running | workflow | Netflix Conductor OSS |
| DuckDB | (suite: append, fkey register) | | append | single process |
| FaunaDB, VoltDB, Crate, NuoDB, Riak, Chronos, Radix DLT, RavenDB, Capela | various | | | closed, discontinued or unreleased |

## Blind rediscovery: what determinismo finds of what Jepsen reported

The measure of the explorer, as the Raft POC is (its four known bugs found without being told
where: the last, the double vote, in run 77 on srv2): each workload also runs, blind, against the
version Jepsen analyzed (its `jepsen` profile), and we record which of Jepsen's reported issues
determinismo rediscovers and how long it takes; the current version is then hunted for new ones.
Blind means blind to the results, not to the test: workloads follow Jepsen's published clients
(jepsen-io/stolon, jepsen-io/sql, ...), as anyone rerunning Jepsen's tests would.

| System | Version (profile `jepsen`) | Jepsen reported | Found blind |
|---|---|---|---|
| Raft (Antithesis's POC) | hashicorp/raft 4c8f61ac | leadership-transfer deadlock, log divergence, snapshot livelock, double vote | 4 of 4 |
| PostgreSQL | 12.3 | G2-item at Serializable | ✅ rediscovered blind in run 43 (srv3, seed 1, tree, Jepsen's workload shape): G2-item in 7 of the first 1,700 timelines, the first (timeline 623) about 14 minutes in; run 80's first 22 timelines (our first workload: one table, upserts by primary key) had none |
| NATS JetStream | 2.12.1, default sync | acknowledged writes lost and replicas split after power losses | ✅ rediscovered in the first hour (run 81 on srv2): acknowledged messages lost in 6 timelines, three sequences each acknowledged for two messages, `corrupt state file` on recovery after power losses |
| etcd | 3.4.3 | watches from revision 0 skipping events; locks unsafe | watches clean so far (149 timelines, run 83 on srv2). Found besides, blind: a member that cannot restart after a power loss (`panic: state.commit 367 is out of range [249, 259]`, timeline 87), known upstream (etcd-io/etcd#10219, fixed by #11888 in 2020, after 3.4.3) |
| MySQL | 8.0.34 | Repeatable Read allowing G2-item, G-single, lost update, non-repeatable reads | ✅ rediscovered on the current 26.10.0 already (srv1, seed 7): G2-item and G-single-item at Repeatable Read in 2 of the first 4 timelines, ~2.5 min of virtual time each; Serializable clean in 4 of 4. 8.0.34 (run 86 on srv2): ✅ G-single-item, G2-item and lost-update at Repeatable Read in 10 of the first 15 timelines, from the first |
| MariaDB Galera | 12.1.2 | committed transactions lost on coordinated crashes; lost update, stale read | not yet: run 58 (srv3, 2 h, 532 timelines, 86,970 operations) had no anomaly; its 22 mariadbd aborts are Galera's by design (a state transfer whose donor left). 13.0.2 clean in 8 timelines on srv1. Found blind besides (hunt run 97, with correlated power losses): galera-4 26.4.24 aborts on an uncaught `std::out_of_range` (index -1) in `gcomm::evs::Proto::populate_node_list`, building a JOIN, because two views share an id: a restart reuses its UUID's incarnation when a power loss undoes the unsynced rename of gvwstate.dat (read in the code and the logs; forked futures consistent, not conclusive); not in MariaDB's Jira or Galera's public issues, unchanged through 26.4.27 |
| TiDB | 2.1.7 | automatic retries breaking snapshot isolation: lost updates, read skew | ✅ rediscovered on srv1 (seed 3): G-single-item (read skew), lost-update and incompatible-order in 2 of the first 4 timelines, ~3 min of virtual time each |
| MongoDB | 4.2.6 | transactions with read skew, cyclic information flow, duplicated effects | ✅ rediscovered blind in the first hunt of the sharded cluster (srv2, seed 7): SERVER-48307, a committed transaction reported aborted on its commit's retry after a failover of a shard it only read from: in 2 of the first 89 timelines, both forms: timeline 80 at 221 s an aborted read (G1a, the client gave up on its reruns), timeline 61 an append committed twice (the rerun committed, Jepsen's duplicated effect) (examples/mongodb). The replica set: 9.0.4 clean in 4 timelines on srv1 |
| Raft (Antithesis's POC), again | hashicorp/raft 4c8f61ac | (as above) | the double vote again in 25 minutes (bench/explore.py's default tree, srv2, timeline 4653), and explained from the timeline (tests/antithesis-compat/README.md) |
| TigerBeetle | 0.16.13 | #2767: a reformatted replica losing committed transfers; #2739: one replica down stalling requests for up to ~100 s; #2544: multi-filter queries missing results | wipes of one replica (tb-2): no loss in the first 4 timelines; ✅ found blind, a further symptom of #2767's reformat: the reformatted replica asserts on rejoining when it had been the primary of the cluster's view (jump_view sends request_start_view to itself), traced to the line from a replay and a reproducible build (examples/tigerbeetle); #2544 needs far more data than a timeline makes |
| Redis-Raft | 2d1cf30 | #52 history rewritten by crashes alone; crashes #42, #43, #48-#54 (#44 fixed in 2d1cf30) | ✅ crashes rediscovered in the first minutes (srv1, seed 1): #43's snapshot/log panic (a node that cannot restart) in 5 of the first 16 timelines, #42's callRaftPeriodic assertion in 2; and a `raft_handle_append_cfg_change` assertion (known: redisraft#2). Elle: no anomaly yet |
| Apache Kafka | 3.8.0 (KRaft) | KAFKA-17754 (from the Bufstream analysis): a delayed EndTxn commits the next transaction partway: aborted reads, lost writes, torn transactions under process pauses | first timelines (examples/kafka, the Java client 3.8.0 behind a line protocol); found blind on the way, confirmed from exact replays (srv2, 40 of the first 64 timelines): a power loss within ~30 s of `kafka-storage format` leaves bootstrap.checkpoint empty (written without force(), renamed in), and 3.8.0 reads it at every start: the node never starts again; not reported upstream as such (examples/kafka). KAFKA-20979 rediscovered blind (srv3, 2026-10-28, 2nd timeline of a smoke test): a power loss after a clean shutdown leaves a time index untrimmed and zero-filled, and retention deletes committed data; KAFKA-20734 (4.3.0 and 4.4.0, the latest release; a blocker, its fix merged, unreleased) met blind in the second timeline of Kafka 4.4.0's first smoke (run 89): a partition without a leader for a moment taken for deleted, its commit marker skipped, a transaction hanging for good. KAFKA-18137 (fixed in 4.0.0) met blind in hunt run 68 (timeline 125): a coordinator elected and resigned at different epochs as it restarted installed an empty load, gave a transactional id a new producer id, and left the old producer's transaction hanging for good (the partition's last stable offset stuck); KAFKA-17754 not yet (the client's links were never faulted until 2026-10-28) |
| YugabyteDB | 1.3.1 | YSQL append G2-item when every master crashed or was paused (#2125); read skew, lost inserts (earlier versions) | not yet claimed: hunt run 77 (srv3, no outage then) had G2-item in timeline 15 after process pauses, and a lost committed insert in timeline 9; #2571's tablet-server abort (`mvcc.cc:340`) in 6 of 64 timelines; a master's abort open upstream as #30325 (its active WAL segment gone after a kill between a segment's rename and its header) in 1. Kill outages (#2125's first trigger) hunt next |

## Order

1. etcd: done; then its lock and lease checks (reported as by-design, not failures).
2. NATS JetStream (queue; lost and duplicate messages under `durable_crash`, disk faults).
3. Redpanda, then Apache Kafka with KRaft (list-append over transactions, queue).
4. MariaDB Galera and MySQL group replication (append under crashes at commit).
5. PostgreSQL single node (append at each isolation level), then an HA setup.
6. TiDB, YugabyteDB, CockroachDB (append, bank, long fork).
7. MongoDB (list-append across a replica set), ScyllaDB (LWT), Valkey cluster.
8. The rest as the table goes; each analysis read in full before its workload is written.
