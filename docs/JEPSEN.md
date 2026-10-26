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
for guidance as the timeline runs.

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
| Redpanda / Kafka | Redpanda 21.10 (2022), Bufstream 0.1 (2024), Kafka post (2013) | duplicate writes, inconsistent offsets, aborted reads, lost/stale messages; in Kafka's transaction protocol itself, write loss and torn transactions (KAFKA-17754) | list-append (transactions), queue | 🟡 Redpanda and Apache Kafka (KRaft) |
| MySQL, MariaDB Galera, Percona | MySQL 8.0.34 (2023), Galera 12.1.2 (2026), 2015 posts | Repeatable Read allowing G2-item, G-single, lost update, non-monotonic views; Galera losing committed transactions on crashes (no flush before ack) and with partitions, lost update, stale read | append, mav, nonrepeatable-read, closed-predicate | ✅ examples/mysql (26.10.0), examples/galera (13.0.2, Jepsen's configuration from jepsen-io/mysql's `antithesis/`) |
| PostgreSQL (and Stolon, RDS) | 12.3 (2020), RDS 17.4 (2025), 2013 post | serializable allowing G2-item (fixed); RDS multi-AZ violating snapshot isolation (long fork); Stolon ledger | append, ledger | ✅ examples/postgres (18.6, single node); next: HA (Patroni or Stolon) |
| MongoDB | 4.2.6 (2020), 3.6.4, 3.4.0-rc3, earlier posts | transactions with read skew, cyclic information flow, duplicate effects from retries; lost majority writes in old replication protocols | list-append (single and multi-node) | ✅ examples/mongodb (9.0.4, Jepsen's replica set settings and workload, our own wire client) |
| TiDB | 2.1.7 (2019) | auto-retry re-applying conflicting updates: read skew, lost updates | bank, long fork, register, sequential, set, append | ✅ examples/tidb (v8.5.8, Jepsen's configurations from jepsen-io/tidb) |
| YugabyteDB | 1.1.9, 1.3.1 (2019) | read skew, lost inserts with partitions, DDL races (defaults as NULL), undercounting | append, bank, counter, long fork, set, rw | |
| CockroachDB | beta 2016 | serializability violations | bank, register, sequential, sets, monotonic, adya | 🟡 examples/cockroachdb (v26.3.3) |
| ScyllaDB | 4.2-rc3 (2020) | LWT split-brain (healthy clusters, then with membership changes), aborted LWT reads, non-isolated writes | cas-register, list-append, counter, batch | |
| Redis (Raft, Sentinel, Valkey) | Redis-Raft (2020), 2013/2014 posts | Redis-Raft: data loss on failover, split-brain, stale and aborted reads; Sentinel/WAIT lose writes by design | append, raft, cluster | Valkey cluster, Redis 8 |
| TigerBeetle | 0.16.11 (2025) | crashes, latencies under single faults, a query predicate bug; strong against disk corruption | transfer, idempotence, lifecycle | interesting: Zig, deterministic itself |
| RabbitMQ | 2014 post | lost messages with mirrored queues under partitions | queue | quorum queues today |
| ZooKeeper | 2013 post | sync+read not linearizable in edge cases | register | |
| Consul | 2014 post | stale reads (fixed with consistent mode) | register | BUSL |
| Elasticsearch / OpenSearch | 1.1.0, 1.5.0 posts | lost inserts and updates on partitions, pauses, crashes | sets, dirty read | OpenSearch (Apache 2.0) |
| Aerospike | 3.99 (2018), 3.5.4 post | lost updates with more than k crashes or 27 s of pause/skew; a write reported failed that succeeded | cas-register, counter, set | Community edition |
| Hazelcast | 3.8.3 (2017) | maps, locks, queues, atomics and ID generators unsafe under partitions | lock, queue, map, ids | |
| Apache Ignite | (suite only) | | bank, register | |
| Dgraph | 1.0.2, 1.1.1 | SI violations, lost inserts, duplicate upserts, corruption | bank, long fork, set, upsert, delete | |
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
| PostgreSQL | 12.3 | G2-item at Serializable | none in run 80's first 22 timelines, on our first workload (one table, upserts by primary key); running on Jepsen's workload shape (run 85 on srv2) |
| NATS JetStream | 2.12.1, default sync | acknowledged writes lost and replicas split after power losses | ✅ rediscovered in the first hour (run 81 on srv2): acknowledged messages lost in 6 timelines, three sequences each acknowledged for two messages, `corrupt state file` on recovery after power losses |
| etcd | 3.4.3 | watches from revision 0 skipping events; locks unsafe | watches clean so far (149 timelines, run 83 on srv2). Found besides, blind: a member that cannot restart after a power loss (`panic: state.commit 367 is out of range [249, 259]`, timeline 87), known upstream (etcd-io/etcd#10219, fixed by #11888 in 2020, after 3.4.3) |
| MySQL | 8.0.34 | Repeatable Read allowing G2-item, G-single, lost update, non-repeatable reads | ✅ rediscovered on the current 26.10.0 already (srv1, seed 7): G2-item and G-single-item at Repeatable Read in 2 of the first 4 timelines, ~2.5 min of virtual time each; Serializable clean in 4 of 4. 8.0.34 (run 86 on srv2): ✅ G-single-item, G2-item and lost-update at Repeatable Read in 10 of the first 15 timelines, from the first |
| MariaDB Galera | 12.1.2 | committed transactions lost on coordinated crashes; lost update, stale read | running (run 87 on srv2; examples/galera, Jepsen's configuration; 13.0.2 clean in 8 timelines on srv1) |
| TiDB | 2.1.7 | automatic retries breaking snapshot isolation: lost updates, read skew | next (examples/tidb, Jepsen's configurations) |
| MongoDB | 4.2.6 | transactions with read skew, cyclic information flow, duplicated effects | next (examples/mongodb) |

## Order

1. etcd: done; then its lock and lease checks (reported as by-design, not failures).
2. NATS JetStream (queue; lost and duplicate messages under `durable_crash`, disk faults).
3. Redpanda, then Apache Kafka with KRaft (list-append over transactions, queue).
4. MariaDB Galera and MySQL group replication (append under crashes at commit).
5. PostgreSQL single node (append at each isolation level), then an HA setup.
6. TiDB, YugabyteDB, CockroachDB (append, bank, long fork).
7. MongoDB (list-append across a replica set), ScyllaDB (LWT), Valkey cluster.
8. The rest as the table goes; each analysis read in full before its workload is written.
