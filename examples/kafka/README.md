# Apache Kafka under determinismo

Apache Kafka 3.8.0, three KRaft nodes (each a broker and a controller), following Jepsen's
[Bufstream analysis](https://jepsen.io/analyses/bufstream-0.1.0) (2024). Jepsen found
**KAFKA-17754** there, in Kafka's transaction protocol itself, and showed it on Kafka:
- a producer's `EndTxn` (commit) is delayed in the network;
- the client moves on (its commit timed out, so it aborts, as the Java client's documentation
  says, then starts the next transaction with the same producer id and epoch);
- the late commit ends whatever transaction is open, partway.

Jepsen saw aborted reads, lost writes and torn transactions on Kafka under process pauses. The
issue is open (KIP-890, KAFKA-14402).

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio --memory-mib 8192 \
  --program zig-out/bin/kafka-test --scenario txn --seed 1 --time-budget 1h
```

## The system

- The image: Kafka 3.8.0 from Apache's archive (checked against its published SHA-512) on
  Debian with OpenJDK 17.
- `start.sh broker <id>` writes the KRaft configuration and formats the log (one fixed cluster
  id) the first time. The topic is `jepsen`: four partitions, replication factor 3,
  `min.insync.replicas=2`, transaction state replicated the same way, automatic topic creation
  off.
- `start.sh client`: the client node. `KClient.java` is compiled against the distribution's own
  `kafka-clients` 3.8.0, the Java client Jepsen used. It serves a line protocol to the drivers.
  Each connection is one client process with one long-lived transactional producer, set up as
  Jepsen's: `acks=all`, idempotence, 1,000 retries, short timeouts. Errors are handled as the
  Java client's documentation says: on a `KafkaException`, abort, even after a commit timed out.

## Profiles

- `default`: as Kafka is deployed, except that start.sh forces `bootstrap.checkpoint` to disk
  after formatting (the finding below would otherwise brick a broker in most timelines and hide
  the rest), and each write to disk before it counts (`log.flush.interval.messages=1`).
- `format-unsynced`: formatted as Kafka does it (that finding's profile), writes flushed.
- `kafka-4.4`: the default's on Kafka 4.4.0, the latest release (Dockerfile.4.4), brokers and
  client: transactions v2 (KIP-890: the producer's epoch bumped at each transaction's end, the
  partitions added by the leaders). Bugs found in 3.8.0 may be fixed there (KAFKA-18137, the
  hanging transaction below, in 4.0.0); new ones are found in a current release.
  `kafka-4.4-coverage`: the same with the coverage agent (Dockerfile.4.4.coverage), as
  `coverage` below: run 68, with it, found the hanging transaction; run 67, without, did not.
- `redpanda`: Redpanda v26.2.6 (Dockerfile.redpanda) as the brokers, under the same client and
  checks: it speaks Kafka's protocol, transactions included. One shard and a gigabyte each, a
  cluster formed from its three seeds, its log synced as Redpanda syncs it. Jepsen's Redpanda
  21.10 analysis (2022) found duplicated and lost writes, inconsistent offsets and aborted reads
  in transactions; 21.10 is no longer published (22.1.1 the oldest image). `--memory-mib 5120`.
  start.sh sets production mode: the image's redpanda.yaml is in developer mode, in which rpk
  starts Redpanda with `--unsafe-bypass-fsync=true`. The first smoke (run 83) ran so, and in one
  timeline kafka-1's controller looped from 101.9 s on "State machine for
  ntp={redpanda/controller/0} caught exception std::runtime_error (Reader cannot read before
  start of the log 0 < 19)", millions of times (4 GB of events): not a finding, its fsyncs
  bypassed; to look for again in production mode. start.sh also raises `crash_loop_limit`
  (5 by default: after five unclean shutdowns in a row Redpanda refuses to start until an
  operator removes a file): the faults killed all three brokers past it by 160 s (run 90).
- `coverage`: the default's, on Java 25 with determinismo's coverage agent on the brokers'
  transaction path (the transaction coordinator, ReplicaManager, Partition, UnifiedLog):
  each of their source lines reports itself the first time it runs, and the tree returns to
  timelines that ran new broker code. The whole broker instrumented started 9 times slower.
- `unflushed`: Kafka's flushing as it comes. Kafka leaves its log to the kernel's writeback and
  counts on its replicas: when every replica that took a write loses power before the kernel
  writes it back (30 s), the write is gone, though acknowledged. That is Kafka's design, and
  this profile shows it: hunt kf4 (seed 15, the default profile then unflushed) lost committed
  writes in 2 of 139 timelines. In timeline 29, the run's one committed transaction committed at
  21.5 s with kafka-3 stopped, and kafka-1 lost power at 21.9 s, kafka-3 (caught up meanwhile) at
  28.7 s and kafka-2 at 49.9 s: the topic read back empty.

## The workload and its properties

Each driver is a client process: twenty transactions of one to four sends to random partitions,
one in five aborted on purpose. Each outcome is noted in the runner:
- `c`: committed, acknowledged;
- `a`: aborted on purpose;
- `f`: failed before its commit, then aborted;
- `u`: unknown (its commit timed out, or no answer).

Once faults stop and every partition is stable (no transaction open), each is read from the
beginning, `read_committed`:

| Property | Breaks when |
|---|---|
| no write of an aborted transaction is ever read | aborted read |
| every write of a committed transaction is read | lost write |
| a transaction's writes are read all or none | torn transaction |
| no write is read twice | duplicate |
| no transaction stays open once faults stop | a hanging transaction: a partition's last stable offset short of its high watermark a minute on (its details name the partition's producers; the open one is then aborted, KIP-664, so the read past it judges the rest: a write the client saw committed and the abort removed counts as lost) |

Elle checks the same history for read committed: each partition a list, each send an append,
each partition's read once faults stop (as Jepsen's Kafka checker, Elle-based): transactions
ordered one way in a partition and the other way in another (G0, G1c), aborted reads (G1a).

Faults: the default ones (pauses, partitions, degraded links, sync stalls, throttling), plus
restarts, power losses and graceful stops of the brokers. The client node stands for Jepsen's
clients, which live in the test process: its links to the brokers are cut and degraded (a commit
lost and retransmitted after its producer moved on is KAFKA-17754's way in), the drivers' calls
into it are not (`runner_links = false`), and it is never paused or slowed. Until 2026-10-28 its
links got no faults at all, and KAFKA-17754 had no way to happen but through broker pauses.

Setup creates the topic and starts one producer before faults begin: Kafka creates the
transaction coordinators' topic at the first producer's start, and under faults that can take
the whole timeline (the coverage profile's slower brokers never got one).

Since 2026-10-29 the brokers' clocks are skewed too (`clock_skew`, one broker's realtime clock
ahead or behind by up to 10 s for a while, sometimes strobing): transaction coordinators expire
transactions by their wall clocks, and the logs' safety must not depend on clocks agreeing.

## Share groups (queues for Kafka)

Scenario `share`, on the `kafka-4.4` profiles (share groups are KIP-932, production-ready since
Kafka 4.2, enabled by 4.4's default format, `share.version=2`): producers (idempotent, acks=all)
send unique values to topic `queue` (three partitions, three replicas), share consumers of one
group poll it, acknowledge every record ACCEPT and commit (`commitSync`). SClient.java, beside
KClient on port 7001, is that client; the group reads from the beginning
(`share.auto.offset.reset=earliest`, set in setup, where the first poll also starts the share
coordinator). Each poll's deliveries are noted with the driver's clock just before its request
and just after its answer, so an order between two consumers' polls is certain. Once faults
stop, a drain polls until 45 polls in a row deliver nothing (past the 30 s acquisition locks of
consumers that went away), and:

| Property | Breaks when |
|---|---|
| a record whose acceptance committed is not delivered again | a poll sent after another consumer's commit of that record returned hands it out (Kafka: an acknowledged record is never acquired again) |
| every acknowledged record is delivered | a produced record no consumer or the drain ever gets (archived after the delivery limit counts too: 5 acquisitions without acceptance) |
| every delivered record was produced | a delivery of a value never sent |
| the queue drains once faults stop | consumers still get records after 600 polls |

Records delivered more than once before an acceptance committed are at-least-once delivery,
by design: counted in an event (`kafka_share_redelivered`).

## Status

- 2026-10-28 (srv3): the hunts so far hardly ran the workload. Run 56 committed a transaction
  in 9 of its 508 timelines (run 24: 10 of 327) and passed, a `sometimes` being satisfied by
  one: brokers restarted, crashed or stopped every two seconds or so never came back up, and
  KAFKA-17754 had no way in (no faults on the client's links). Now: faults in bursts with
  quiet stretches of up to 30 s, a producer started in setup, the client's links to the
  brokers faulted, the final read once every partition is stable, and runs flag a
  `sometimes` that held in under 5% of the timelines (`rarely true`).
- The same day, a timeline of the coverage profile failed "every write of a committed
  transaction is read" and "... all or none": the two transactions that committed had their
  commit markers written on two partitions of four 384 s later, 11 s after the faults
  stopped, while the final read ran. Not a Kafka bug: the read did not wait, and the
  coordinator had been sending those markers to its own broker in vain because determinismo's
  isolation cut a node from its own address (its address was on its links only, all down). A
  cut cable never does that: nodes now keep their address on `lo` too (e2e `inject` checks
  that an isolated node reaches itself), and the read waits for stable partitions (a
  transaction open a minute after faults stop fails "no transaction stays open once faults
  stop").
- Readiness is the controller's port (9093): the broker's opens only once the quorum formed,
  which needs the nodes started after a node.
- First timelines (srv1): producers could not start under the first faults (transaction state
  being created), and kafka-2 could not start again after power losses.

- Hunt run 67 (2026-10-28, default profile, seed 17, 2 h, the fixes above): 207 timelines,
  commits in most; Elle failed in 22, each time G0 alone (Jepsen's write cycles, now reported
  apart: `allowed`); one false data loss (below); no KAFKA-17754 yet.
- Hunt run 68 (2026-10-28, coverage profile, seed 17, 2 h): 175 timelines. In timeline 125 a
  transaction stayed open in partition 1 a minute after faults stopped (its last stable offset
  254, its high watermark 333; the producers' transactions time out after 10 s), so the
  read_committed final read stopped at 254: the 30 "lost" and 24 "torn" writes are past it.
  Before: kafka-1 stopped (1857.5 s), lost power twice (1878.4 s, 1879.3 s), was stopped 9 ms
  after a start (1879.8 s) and started again at 1882.1 s; partition 1's leader, kafka-2, lost
  power at a sync point at 1858.7 s. A replay asked Kafka (`kafka-transactions.sh
  describe-producers`) at 1965 s: partition 1's open transaction is producer 19000's, epoch 0,
  one batch (offset 254, at 1353.9 s), no coordinator marker ever (coordinator epoch -1). The
  coordinator's own log (kafka-2, `__transaction_state-14`, its leader from 1353.2 s) tells the
  rest: it gave `t3506608` producer 19000 at 1354.0 s; at 1365.0 s the commit's PrepareCommit
  append failed (the partition's in-sync replicas down to kafka-2 alone: NotEnoughReplicas),
  and so did every abort after it, the client's and the coordinator's timeout rollbacks ("failed
  to write an epoch fence transition ... The epoch was increased to 1 but not returned to the
  client"), until 1383.0 s; kafka-1 rejoined the in-sync replicas at 1383.2 s, but no rollback
  was tried again; between 1384 and 1416 s every broker restarted (kafka-2 from a stop whose
  controlled shutdown outlasted the 3 s grace: killed, its page cache intact). Restarted,
  kafka-2 replayed the cluster's metadata: at 1417.04 s it was elected coordinator of
  `__transaction_state-14` at epoch 38 (an old leadership) and scheduled its load; at 1417.17 s
  it resigned at epoch 39, and the load ran anyway: "Finished loading 0 transaction metadata ...
  Completed loading ... for coordinator epoch 38". Kafka 3.8.0's resignation
  (`removeTransactionsForTxnTopicPartition(partition, epoch)`) removes the loading entry of
  the new epoch (39), never the one loading (38), so the load, reading nothing from a log
  kafka-2 did not lead (`getLogEndOffset` is -1 then), installed an empty cache for the
  partition. What the partition held then (a replay at 1418 s decoding it with
  `kafka-dump-log.sh --transaction-log-decoder`, the same on kafka-1 and kafka-3): `t3506608`
  Empty (producer 19000, epoch 0) at offset 46, Ongoing on `jepsen-1` at 47, PrepareCommit at
  48 (the append the coordinator took for failed: written, then replicated), and PrepareAbort at
  epoch 1 at 49 (a timeout rollback's): a load of it would have finished the abort. kafka-2's
  leader-epoch checkpoint then had epoch 40 begin at offset 50: what it wrote after those, as the
  partition's leader with the empty cache, came after the abort, and the epoch-40 load knew
  `t3506608` as producer 20000 alone. From 1418 s
  the empty cache answered `t3506608`'s InitProducerId as a new transactional id: producer id
  20000, epoch 0, Empty; at 1419.96 s, its coordinator elected
  at epoch 40, kafka-2 loaded the partition again and finished it: "Initialized transactionalId
  t3506608 with producerId 20000 and producer epoch 1". Producer 19000's transaction, Ongoing
  on `jepsen-1` since 1353.9 s, is in no coordinator's state any more: nothing will abort it.
  This is KAFKA-18137 ("Unloading transaction state incorrectly removes loading partitions",
  fixed in 4.0.0; 3.8.x and 3.9.x have it), whose report says it "may not immediately cause a
  correctness issue": here it made a hanging transaction, the last stable offset of `jepsen-1`
  stuck at 254 for good (a read_committed consumer reads nothing past it). Not a new bug; its
  consequence, seen here, is not in its report. Related (read only): KAFKA-21349 (open:
  loads of records above the high watermark), KAFKA-18957 (open: hangs on 3.8.1 and 3.9.0),
  KAFKA-9307 (2019: a load left at a previous epoch).
- Kafka 4.4.0 (`kafka-4.4` profile, smoke run 89, srv3, 2026-10-29, seed 1, 4 timelines):
  KAFKA-20734 met blind in timeline 1. Partition 3 kept a transaction open 80 s after faults
  stopped (last stable offset 76, high watermark 79; producer 10001 at epoch 3 holding offset
  76), so "no transaction stays open once faults stop" failed. The coordinators' logs: at
  479.19 s kafka-2, completing `t5256495`'s commit (producer 10001, epoch 4, transactions v2),
  "Couldn't find leader endpoint for partitions Set(jepsen-3) while trying to send transaction
  markers for t5256495, these partitions are likely deleted already and hence can be skipped",
  then appended COMPLETE_COMMIT: the commit marker for jepsen-3 never written. kafka-3 (571.64 s)
  and kafka-1 (574.7 s), coordinators after it, did the same. A partition without a leader for a
  moment (faults) is taken for deleted: KAFKA-20734 ("Offline partition can cause loss of
  transaction markers", 4.3.0, 4.4.0: `metadataCache.getPartitionLeaderEndpoint` returns None
  for an offline partition since the KRaft metadata cache's rewrite), a blocker with its fix
  merged and not yet released (2026-10-28). Not new; in the latest release, and found in the
  second timeline of a four-timeline smoke. Since, a hang whose partition a coordinator logged
  as skipped this way is KAFKA-20734's: the property holds, a `kafka_known_hang` event counts
  it, and only the hangs it does not explain fail. Its loss too: in hunt run 173
  (`kafka-4.4-coverage`, 2026-10-29, 123 timelines) 7 timelines (27, 72, 100 to 103, 113) failed
  "every write of a committed transaction is read" and "a transaction's writes are read all or
  none", each a transaction committed and acknowledged whose writes on the hung partition were
  gone once the judge aborted the hang to read past it (the commit marker the coordinator
  skipped), each with its known hang aborted. Since, the
  log notes each write's partition, and a committed transaction whose unread writes all sit on
  partitions whose known hang was aborted is that bug's (a `kafka_known_loss` event), not a
  lost or torn one.
- Found blind: Redpanda 26.2.6 keeps a transaction open for good when its coordinator crashes
  between beginning it on the partitions and recording them. First hunt (run 177, `redpanda`
  profile, production mode, 2026-10-29): "no transaction stays open once faults stop" failed in
  timelines 23, 46 and 56 of the first 68 (46 with the same refusal below). 56 differs: its
  coordinator knew the transaction and was aborting it while partition 2 had no leader
  (751 s), then said nothing more, the partition open at 844 s; trace futures from 745, 750 and
  760 s all passed (a narrow window: causality next, if it comes back). Timeline 23, partitions 0 and 3 kept a transaction of
  producer 1004 (`t10626586`) at epoch 7 open (from offsets 297 and 282 of their logs) that its
  coordinator (`kafka_internal/tx/32`) held as "status: empty, partitions: {}"; the last stable
  offset never moved again. How, step by step:
  1. Causality (6 futures a moment): 1 future in 6 fails from 112.7 s, 2 from 116.17 s, all 6
     from 117.04 s. Between, at 116.49 s, kafka-1 and kafka-3 lost power together; kafka-3 led
     the coordinator's partition (`tx/32`).
  2. A future from 116.0 s with Redpanda's `tx` logger at trace on every broker (`rpk redpanda
     admin config log-level set tx --host localhost:9644 --level trace --expiry-seconds 0`, and
     `rpk.additional_start_flags` so restarts keep it), the timeline's own randomness after it,
     fails the same way, the same transaction at the same offsets. In it the coordinator (kafka-3)
     is adding partitions 0 and 3 for epoch 7: `do_add_partition_to_tx` sends `begin_tx` to each
     partition, which records the transaction ("Ignoring duplicate begin_tx" on each retry), and
     retries the round every 325 ms (116.7 to 117.7 s), another partition of the request
     answering a retryable error; the addition is persisted (`tm_stm::add_partitions`) only after
     that loop.
  3. At 118.0 s all three brokers lose power. Restarted, the coordinator replays its log:
     epoch 4 aborted, epoch 5 committed then aborted, epochs 6 and 7 empty. Epoch 7's partitions
     were never recorded.
  4. Each partition's transaction times out (10 s) and asks its coordinator to abort it
     (`rm_stm::do_try_abort_old_tx`): the coordinator finds it empty and refuses ("Can not update
     transaction state from empty to expired as this transition is invalid", from 138.7 s, again
     every pass), and on any error the partition keeps it open.
  Nothing of the disk model is involved: the addition was never written, and any crash of the
  coordinator in that gap does the same. Redpanda's code counts on the client retrying the
  addition (`begin_tx` is idempotent); a client gone meanwhile (here the driver's last
  transaction, its commit timed out) never does, and a coordinator that has no record of the
  transaction does not answer that it was aborted. Not TSB-2026-37 (an rm_stm deadlock in
  26.1.1 to 26.1.5), nor #8236 (group transactions refused `begin_group_tx`); the refusal's text
  appears in no Redpanda issue. To see it: run 177's timeline 23 from its tape, the command
  above at 116 s (`--at-vtime-ms 116000 --exec ... --continue`). Since, each Kafka command runs
  20 s at most (Redpanda's sat in the client's 10 s timeouts, 80 s a command, past the timeline's
  hour) and the known-hang loss is an event, not a sometimes (one never true failed this run);
  and the judge counts this hang apart as it does KAFKA-20734's (`kafka_known_hang`, issue
  `redpanda-orphan-begin-tx`: the partition's own "is unknown:tx::errc::invalid_txn_state"), so
  later hunts see the hangs it does not explain. By its end (177 timelines) the run had 19
  timelines with a transaction open for good; 28 "the guest finishes" (the commands' 80 s,
  fixed since), 9 injector stalls (a thread pause waiting on its thread, fixed since), and three
  judge artifacts: timeline 83's one "lost" committed write sat behind such a hang, which the
  judge could not abort (Redpanda has no KIP-664 abort: "The node does not support
  WRITE_TXN_MARKERS"; writes behind a hang the judge cannot clear are unjudged since), and
  timelines 157 and 172 were G0 (allowed, as for Kafka) beside Elle's cycle search timing out
  (no anomaly since, an `elle_cycle_search_timeout` event).
- Not a finding, a platform bug: hunt run 67 (default profile) failed "every write of a
  committed transaction is read" in timeline 111, 92 committed transactions on no broker. A
  durable crash with two of kafka-3's threads at durability points crashed it twice; the
  second crash found it down, failed (NotADurableDisk) after switching its disk to dropping
  writes, and left it so. From 340.7 s kafka-3's writes went nowhere while it read them back
  from memory; its power loss at 477.8 s took its log back to offset 152, it led, and the
  others truncated to it. Fixed in determinismo (a node crashes once a fault; a crash never
  leaves the disk dropping writes); runs 55, 56 and 67's data losses are not evidence.

### Found: a power loss after a clean shutdown deletes committed data (KAFKA-20979)

Rediscovered blind, srv3, 2026-10-28: the second timeline of the coverage profile's first
smoke test (`--profile coverage --seed 1 --branches 2`, timeline 1; run 66 in the store),
failing "every write of a committed transaction is read": 30 of its 304 committed transactions
were never read, every partition stable. It replays exactly. At moments of it:
- kafka-1 is stopped gracefully at 150.3 s and shuts down cleanly (153.1 s), then loses power
  at 153.8 s (a `crash`: its disk keeps what was synced);
- started again, it finds the clean-shutdown file and skips recovery (175.9 s); its
  `jepsen-0/00000000000000000000.timeindex` is 10,485,756 bytes (the preallocated size) and
  reads `timestamp: 0 offset: 0`, beside a 2,587-byte segment;
- at 213.5 s: `Deleting segment LogSegment(baseOffset=0, size=2587, ...,
  largestRecordTimestamp=0) due to log retention time 604800000ms breach`, for every
  partition (log start offsets 36, 50, 37, 32);
- kafka-1 leads the four partitions at the end: what both other replicas hold below those
  offsets, committed transactions among it, is gone from what consumers read, and the
  followers delete it after it.

The mechanism is KAFKA-20979's ("Potential data loss caused by time index truncation", fixed
in 4.4.0 and 4.3.2, reported on 4.1.0 and 4.3.0): a clean shutdown flushes the time index at
its preallocated, zero-filled size, then trims it with `setLength()` and never syncs the
trim. A power loss before writeback leaves the zero-filled index, which a clean start
trusts; a segment under 4 KB has no index entries of its own (`index.interval.bytes`), so
its largest timestamp reads 0 and time retention deletes it. Kafka 3.8.0 has it too.
Related: KAFKA-19200 (indexes not sanity-checked at startup), KAFKA-13773, KAFKA-10207.

### Found: a power loss soon after `kafka-storage format` bricks the node

The first hour on srv2 (`--seed 11`, exact replays) failed "nodes do not exit unexpectedly" in
40 of its first 64 timelines, each a broker that could not start again:
`No FeatureLevelRecord for metadata.version was found in the bootstrap metadata from the binary
bootstrap metadata file: /data/kafka/bootstrap.checkpoint`. Timeline 63 replayed to the same
events, and at moments of it:
- kafka-1 was formatted at 2 s (`start.sh`, its first start), stopped gracefully at 18.96 s,
  then lost power at sync points (24.75 s, 27.87 s, 28.49 s) and crashed at 30.31 s;
- at 33.0 s, restarted, its `/data/kafka/bootstrap.checkpoint` is there, made at 00:00:02, and
  empty (size 0); Kafka exits on it at 33.35 s, and at every start after.

Kafka 3.8.0 writes the file at `kafka-storage format` (BootstrapDirectory.writeBinaryFile:
BatchFileWriter into a temporary file, no force(), then an atomic rename, no directory fsync)
and reads it at every start, even once the cluster's metadata log has its features. The rename
is journaled; the data waits for writeback (about 30 s on Linux), so a power loss in that
window leaves an empty file and a node that never starts again. `meta.properties`, written
beside it, is fsynced.

Not reported upstream as such (searched: KAFKA-19192 / KAFKA-19191, servers reading old
bootstrap files once bootstrapped, resolved; KAFKA-16541, a checkpoint corrupted by a crash,
another file; KAFKA-4127, directory fsyncs). Trunk no longer has the file (KIP-1170).
