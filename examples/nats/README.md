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

| Property | How |
|---|---|
| Acknowledged publishes survive | producers note every acknowledged message with its stream sequence; after faults, a consumer reads the whole stream and finds each |
| Sequences are unique | no two acknowledged messages were given the same stream sequence |
| Reads in order, nothing made up | the consumer reads in sequence order, each sequence once, only messages that were published |
| Replicas converge | after faults, every server's own copy of the stream (its `/jsz`) has the same messages and last sequence |

## Findings

None yet: 8 of 8 timelines pass with `sync`.
