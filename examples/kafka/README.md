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

## The workload and its properties

Each driver is a client process: twenty transactions of one to four sends to random partitions,
one in five aborted on purpose. Each outcome is noted in the runner:
- `c`: committed, acknowledged;
- `a`: aborted on purpose;
- `f`: failed before its commit, then aborted;
- `u`: unknown (its commit timed out, or no answer).

Once faults stop, every partition is read from the beginning, `read_committed`:

| Property | Breaks when |
|---|---|
| no write of an aborted transaction is ever read | aborted read |
| every write of a committed transaction is read | lost write |
| a transaction's writes are read all or none | torn transaction |
| no write is read twice | duplicate |

Faults: the default ones (pauses, partitions, degraded links, sync stalls, throttling), plus
restarts, power losses and graceful stops of the brokers. The client node gets none.

## Status

- Readiness is the controller's port (9093): the broker's opens only once the quorum formed,
  which needs the nodes started after a node.
- First timelines (srv1): producers could not start under the first faults (transaction state
  being created), and **kafka-2 could not start again after power losses**: `No FeatureLevelRecord
  for metadata.version was found in the bootstrap metadata from the binary bootstrap metadata
  file: /data/kafka/bootstrap.checkpoint`, at every start. Kafka 3.8.0 writes that file at
  `kafka-storage format` (BatchFileWriter: no `force()`, then a rename, no fsync either) and reads
  it at every start: a power loss before the page cache reached the disk leaves it empty, the
  rename kept. Close to KAFKA-16541 (a checkpoint corrupted by a crash, fixed in 3.8.0) and
  KAFKA-4127 (directory fsyncs); trunk no longer has the file (KIP-1170). To confirm from a
  replay of the timeline, once replays of Kafka's timelines are exact (they were not: two VMs on
  sibling hyperthreads, and preemption while single-stepping, perturbed the guest's clock; both
  fixed, see docs/PLAN.md).
