# Apache Ignite 3 under determinismo

Apache Ignite 3.1.0: three server nodes, a zone of three replicas. Ignite 3 is a rewrite (3.0 in
2025): tables replicated by Raft, primary replicas holding leases, MVCC transactions over hybrid
logical clocks, read-write ones serializable under locks, read-only ones read as of their start
time. Jepsen never analyzed Ignite.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio --memory-mib 8192 \
  --program zig-out/bin/ignite-test --scenario append --seed 1 --time-budget 1h
```

## The system

- The image (Dockerfile): the official `apacheignite/ignite:3.1.0` (Java 11), and the client
  node's IClient.java on Ignite's Java client 3.1.0 (Maven Central, at build time).
- `start.sh server <n>`: node `n<n>` through the image's entrypoint, a static node finder naming
  the three, a 768 MB heap. Setup initializes the cluster (`/management/v1/cluster/init`, all
  three in its management and metastorage groups), then creates the zone (`REPLICAS 3,
  PARTITIONS 8`) and the table through the client node.
- Every JVM's JIT stops at C1 (`JAVA_TOOL_OPTIONS=-XX:TieredStopAtLevel=1`). C2 took a third of
  a server's CPU 150 s into a timeline, compiling again in every timeline and every restarted
  JVM, and the servers restarted too slowly to serve. Side by side (2026-10-30, seed 1, two
  timelines each), C1's first timeline committed 77 transactions. C2's committed none, even with
  2,000 warm-up transactions in setup. C1's setup also took half the wall time.
- Profiles: `default`, Ignite's own settings (table partitions' Raft logs not synced before an
  entry is acknowledged, `raft.fsync = false`: no power losses); `power-loss`, `raft.fsync =
  true`, and power losses too.
- Faults: the default ones, process kills, graceful stops, in bursts with quiet stretches. The
  client node stands for the test's own client library: its links to the servers are faulted,
  the drivers' calls into it are not.

## The workload and its properties

List-append: every key a row of `LISTS (ID BIGINT PRIMARY KEY, VAL VARCHAR)`, its list the text
`v1,v2,...`. A transaction with an append is read-write, each append a get and a put of the key's
list in the transaction; one without is read-only. The drivers share one `IgniteClient` (no
retries), as an application server holds one: its observable timestamp covers every commit
acknowledged through it, so a read-only transaction begun after one reads it. (A read-only
transaction of a client with no observed timestamp reads at its clock less the maximum clock
skew and safe time's period: in the past, by design, IGNITE-21098.) Outcomes as Ignite documents them: an error before the commit, or a
`TransactionException` from the commit, is a rollback; any other error at the commit is unknown.

| Property | Breaks when |
|---|---|
| Elle finds no anomaly in the history (strict serializable) | a lost or reordered append, a stale read-only transaction, a write read from a transaction reported rolled back |
| every committed append is in the final read | an acknowledged commit gone once faults stop |
| the final reads reach a node once faults stop | the cluster never serves again |

## Status

- 2026-10-29: written; the first smoke (run 205) passed.
- 2026-10-30: a JIT comparison found the first failure, below. 3.1.0 is still Ignite's latest
  release. A hunt is queued.

## A committed write that every later reader misses, then a partition with no primary

Found in run 215, timeline 1. This was a 2-timeline comparison, not a hunt: profile `default`,
seed 1. "Elle finds no anomaly in the history" failed with G-single-item-realtime. The history
came out with `extract` (`runner:/tmp/det-check-elle.jsonl` at 1080 s).

**What happened to key 20** (table partition `21_part_5`, Raft group `20_part_5`):

- **96.4 s:** n1 leads group `20_part_5` and holds its lease. n2 has no replica of it; n2 was
  restarted at 70.4 s, and n1 logs "Peer id not found: n2".
- **99.455 s:** a transaction appends `…089` to key 20 (it also reads key 19 and key 20 twice).
- **99.705 s:** it commits, and its own reads show four elements ending in `…089`.
  Its id is most likely `019b76dc-2c49`: ids begin with their start's hybrid timestamp, which
  dates it to about 99.6 s.
- **From 99.82 s:** read-write transactions on key 20 fail in two ways. One is "Failed to acquire
  a lock due to a possible deadlock", with `2c49` as the holder after its commit was
  acknowledged. The other, 22 times, is `TxIdMismatchException: Mismatched transaction id
  [expectedTxId=019b76dc-2c49…]`, an internal storage error that reaches the client.
- **From 100.494 s:** every read-only transaction of key 20 reads the three elements before
  `…089`, through 104.5 s. That includes one by the same client process, begun after the commit
  was acknowledged. All of them go through one `IgniteClient`, and explicit read-only
  transactions carry its observable timestamp, so each should see the commit. Ignite's docs:
  read-only transactions "always check the data for the moment they were started".
- **106.9-122.1 s:** n1 is stopped, then n2 and n3 are restarted. Group `20_part_5` loses its
  quorum. Its replicas start again around 168 s, n3 leads it from 170.7 s, and its lease is
  accepted at 171.1 s.
- **182-1085 s, faults over:** every final read of key 20 fails, 164 times in 15 minutes.
  83 of them say "Failed to get the primary replica [tablePartitionId=21_part_5]". Keys 15, 22
  and 19 read fine.

**In Ignite's tracker:**

- `TxIdMismatchException` after a write intent is resolved: IGNITE-27255 and IGNITE-27864,
  fixed for 3.2, which is unreleased.
- No primary after a node restarts with an open transaction: IGNITE-24016 and IGNITE-21619,
  both closed "Cannot Reproduce". This timeline reproduces it, and it replays exactly.
- Unclear whether the 3.2 fixes also cover the invisible committed write. A write intent
  resolved as aborted while its transaction had committed would explain both that and the
  `TxIdMismatchException`.

**Next:** a causality analysis of timeline 1 to find where it was decided, and the queued hunt.
