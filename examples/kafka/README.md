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
| no transaction stays open once faults stop | a hanging transaction: a partition's last stable offset short of its high watermark a minute on |

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
