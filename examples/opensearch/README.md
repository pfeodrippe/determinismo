# OpenSearch under determinismo

OpenSearch 3, three nodes of one cluster and one index (one shard, two replicas), under
list-append operations on documents that Elle checks. Jepsen's Elasticsearch analyses (1.1.0 and
1.5.0, before the fork) lost acknowledged writes to network partitions; replication has since
taken sequence numbers and primary terms, and nobody has tested OpenSearch so.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio --memory-mib 4096 \
  --program zig-out/bin/opensearch-test --scenario append --seed 1 --time-budget 1h
```

## The system

- The image: the official `opensearchproject/opensearch:3.9.0` without its bundled plugins (the
  core's replication is what is tested; on one vCPU they slow every start). `start.sh <id>`
  writes the node's configuration (every node cluster-manager eligible and a data node, the
  cluster bootstrapped from all three, no index created by a write) and runs it with a 512 MB
  heap.
- Its data on the node's disk; the translog synced before a write is acknowledged (OpenSearch's
  default `request` durability).
- The guest sets `vm.max_map_count` to 262144, as OpenSearch's documentation asks of every host.
- Setup waits for the three nodes, creates the index, and waits until every copy started.
- The nodes' disks have a 30 s writeback window (`writeback_s`, as a host's flusher): OpenSearch
  writes its keystore at its first start without syncing it, and under the guest's strict model
  (nothing written back unasked) a power loss at any age left it truncated ("read past EOF:
  NIOFSIndexInput(path=".../opensearch.keystore")") and the node exited at every start (the
  first smoke, run 88). Within 30 s of that write, a real host loses it too.

## The workload and its properties

Each key is a document, its list in `v`. A read is a realtime GET; an append reads the document
and writes it back conditioned on what it read (`if_seq_no`, `if_primary_term`), again on a
conflict, creating it when it is not there (`op_type=create`). One operation a transaction.
Elle judges the history serializable, and a direct check holds what reads promise beyond that:
each lists every append acknowledged before it began. Recorded for Elle:
- `ok`: the write acknowledged, or the read answered;
- `fail`: nothing written (refused, a conflict five times, no answer to the read before it);
- `info`: the write got no answer.

Once faults stop, the index is refreshed and every document read again through each node, into
the history: an acknowledged append missing there is lost.

For triage: Elasticsearch's read model, which OpenSearch forked, documents dirty reads (a GET on
a primary sees a write before its replicas acknowledge it, and an isolated primary can expose a
write that is never acknowledged). A read of an append whose write got no answer (`info`), then
lists without it, is that, not a finding; an acknowledged append lost, or a stale read of
acknowledged ones, is.

| Property | Breaks when |
|---|---|
| Elle finds no anomaly in the history (serializable) | lost or reordered appends, a refused write that took effect, cycles |
| every append acknowledged before a read began is in it | a stale read of an acknowledged write, an acknowledged append lost (the final reads) |
| the cluster serves again once faults stop | it never elects a cluster manager or never assigns the shard |

Faults: the default ones in bursts with quiet stretches, restarts, power losses (at the nodes'
syncs too, and outages of several at once) and graceful stops.

## Status

- 2026-10-28: written; first timelines next.
- 2026-10-29: first smoke (run 88): every append refused (406: the workload's HTTP calls sent
  `application/octet-stream`; JSON since), and the keystore above. Second smoke (run 92): the
  keystore again, the writeback window started only after the setup's 77 s (the window now
  runs from the guest's start). Third (run 98): keystore kept; the final reads went to os-1
  alone, which was still restarting a minute after faults stopped: they now list the documents
  through any node, wait two minutes, and give up on a node down for good.
- 2026-10-29, first hunt (run 176, `opensearch.json`, 335 timelines in 50 minutes): 28 failed
  Elle at strict serializability, every one G-single-item-realtime. Timeline 19's: a read on
  one copy listed an append at 88.83 s, a read begun after it (89.09 s) on another copy did not,
  and the append was acknowledged only at 89.19 s: the documented read model (a write seen
  before its acknowledgment, copies apart until then), no acknowledged write missed. Since,
  Elle judges serializability and `realtime_reads` the reads' promise directly (above), so
  that a stale read of an acknowledged append still fails.
