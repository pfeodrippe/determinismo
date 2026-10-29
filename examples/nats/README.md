# NATS JetStream under determinismo

NATS Server v2.15.2 (2026-10-26, the release's binary, checksummed), three servers and one stream
replicated on all three, following Jepsen's NATS 2.12.1 analysis (2025): JetStream lost
acknowledged messages and split into diverging replicas after power failures, flushing to disk
only every two minutes by default. The test program is `nats_test.zig`, its client (the NATS
text protocol and the JetStream requests it needs) `client.zig`.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio \
  --program zig-out/bin/nats-test --profile sync --scenario queue --seed 1 --branches 64
```

Profiles:
- `sync`: `sync_interval: always`, every message flushed before it is acknowledged. Any lost
  acknowledged message is a bug.
- `default`: NATS's defaults (flushed every two minutes, acknowledged before): a power loss on
  enough servers loses acknowledged messages, as NATS now documents. Persistent divergence
  between replicas is still a bug (Jepsen's #7567).

Faults: Antithesis's set, restarts, graceful stops and power losses (each server's data on its
own disk), and at the servers' syncs, stalls and power losses (`sync_stall`, `durable_crash`).
Half of them aimed at the stream's leader, which each producer looks up as it starts
(`$JS.API.STREAM.INFO`'s `cluster.leader`, `sdk.fault_aim`), as Jepsen's nemeses target one.

| Property | How |
|---|---|
| Acknowledged publishes survive | producers note every acknowledged message with its stream sequence; after faults, a consumer reads the whole stream and finds each |
| Sequences are unique | no two acknowledged messages were given the same stream sequence |
| Reads in order, nothing made up | the consumer reads in sequence order, each sequence once, only messages that were published |
| Replicas converge | after faults, every server's own copy of the stream (its `/jsz`) has the same messages and last sequence |

## Atomic batches (scenario `batch`)

JetStream's atomic batch publishing (2.12.0, ADR-50): on a stream with `allow_atomic`, a batch's
messages carry `Nats-Batch-Id` and `Nats-Batch-Sequence`, the last `Nats-Batch-Commit: 1`; the
batch is stored all or nothing, its sequences contiguous. Producers publish batches of two to
five messages, each answered (a zero-byte ack, the commit's PubAck with the batch's count, or an
error), and note a batch begun, its commit sent, acknowledged or refused. Once faults stop, the
stream is read whole:

| Property | Breaks when |
|---|---|
| a batch is stored whole or not at all | some of a batch's messages are read, not all |
| a batch's messages are at consecutive sequences, in order | a whole batch is read with a gap or out of order |
| a batch never committed stores nothing | a batch whose commit was never sent (an error, a lost connection before it), or was refused, is read |
| an acknowledged batch is read back whole, at its sequence | an acknowledged batch's messages are missing (in `sync`; `default` may lose them by design), or its last is not at the acknowledged sequence |
| every stored message is of a batch begun | a message no producer began |

## Findings

None yet: 8 of 8 timelines pass with `sync`.
