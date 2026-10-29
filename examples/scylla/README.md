# ScyllaDB under determinismo

ScyllaDB 4.2.rc3, the build of Jepsen's [analysis](https://jepsen.io/analyses/scylla-4.2-rc3)
(2020), five nodes configured as Jepsen's Scylla test
([jepsen-io/scylla](https://github.com/jepsen-io/scylla)), and its list-append workload over
lightweight transactions (LWT), checked by Elle for strict serializability.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio --memory-mib 8192 \
  --program zig-out/bin/scylla-test --scenario append --seed 1 --time-budget 1h
```

## What Jepsen found in 4.2-rc3

Without membership changes (this program makes none yet):
- **#7116**: two versions of a row coexisted in a healthy cluster. The row hash used to compare
  replicas stopped at the first null column, and the workload's `lwt_trivial` (always null)
  comes before `value`: a replica missing a write looked the same. Fixed in 4.2.
- **#7258**: LWT writes reported `Unavailable` that committed: reads saw values of writes
  reported failed (aborted reads), under partitions and crashes. Fixed in 4.1.9 and 4.2.1.
- Stale SERIAL reads (in healthy clusters too).
- #7113: a conditional batch's rows returned out of order, some missing.

With membership changes, later: #7243, #7351, #7359, #7611. By design, not bugs: #7082 (a
collection INSERT under clock skew discards concurrent updates) and #7170 (writes to one
partition are not isolated at equal timestamps).

## The system

- Jepsen's `scylla.yaml` (`start.sh` writes the settings it sets): batch commit log (1 ms
  window), `phi_convict_threshold` 2, `ring_delay_ms` 3000, `shadow_round_ms` 1000, request
  timeouts of 5 s (reads), 2 s (writes) and 1 s (CAS contention), hinted handoff on, developer
  mode. Seeds as Jepsen's: every node at the first start, every other node after.
- One shard per node (`--smp 1`; Jepsen's nodes had two) and `--overprovisioned`: five nodes
  share the machine's CPU. 768 MB each.
- Keyspace `jepsen_keyspace`, SimpleStrategy, replication factor 3. Table `lists (part int, id
  int, lwt_trivial int, value list<int>, PRIMARY KEY (part, id))`, size-tiered compaction: every
  key a row of partition 0.

## The workload

Each driver is one client bound to a random node, as Jepsen's clients were, and runs twenty
transactions, Jepsen's shapes (Scylla's CQL has no multi-row reads in an LWT):
- a read: `SELECT value ... WHERE part = 0 AND id = k` at SERIAL;
- an append: `UPDATE ... SET value = value + [v] WHERE part = 0 AND id = k IF lwt_trivial =
  null`, at LOCAL_ONE and SERIAL (the Java driver's defaults Jepsen kept);
- two to five appends in one conditional `BATCH`.

`cql.zig` is the client: the native protocol v4, no driver, no retries. Outcomes are taken as
Jepsen's client takes them:
- `Unavailable`, or a condition not applied: the write did not happen;
- a timeout, a write failure, a lost connection: it may have.

Elle checks the history for strict serializability. After faults stop (the drivers done), every
node must serve a SERIAL read again, and every committed append must be in its key's list, read
at SERIAL (final reads, since 2026-10-29: Elle takes a read missing one for an older state, and
the drivers may never read a key again). Faults: the default ones (pauses, partitions, degraded links, sync stalls,
throttling), process kills, restarts and graceful stops.

Profiles: `default`, Jepsen's nemeses (process kills and restarts, graceful stops: Scylla's own
supervision starts a killed Scylla again); `power-loss`, power losses too.

## Making it run

- Each node resolves its own name to IPv4 (`getent ahostsv4`): on a node, its own name also
  resolves (nss myhostname) to its link-local IPv6 address, first, and Scylla 4.2 then looked
  that up as an IPv4 name, forever (no nameserver answers in the guest).
- Supervised as the image's supervisord does (`autorestart=unexpected`): a Scylla that exits
  starts again.
- Every node a seed, itself too. Jepsen's join-seeds (every node but itself, after the first
  start) deadlock once faults take all five down together: a node not among its own seeds needs
  a live seed for its shadow round ("Unable to gossip with any seeds"), and none starts again.
- Found in determinismo on the way (fixed): node disks kept every block ever written (no
  discard), so Scylla's rotating commit log filled the guest's /run; and a node whose start
  failed partway ran without a pidfile, out of reach of every fault.

## Found: #7258, blind

The first hunt with the default profile (srv2, `--seed 3`, an hour, six at a time) failed
Elle's check in 1 of its first 99 timelines. Timeline 91 replayed to the same history; Elle
(run again on the history taken out of the guest at its end) found G1a and dirty updates:
- a conditional BATCH of four appends (keys 6, 5, 5, 4) was answered Unavailable ("Cannot
  achieve consistency level for cl SERIAL", as Scylla words it), which Jepsen's client and
  this one take as definite: it did not happen;
- three of its appends were then read, and later acknowledged appends to the same keys followed
  them (the dirty update).

That is #7258 as Jepsen reported it: LWT writes failing with "Not enough replicas available"
visible to later reads, under partitions and crashes; fixed in 4.1.9 and 4.2.1.

## Power losses (closed: determinismo's)

Under power losses a node once stayed down for good, its `pending_delete` log read back as zero
bytes. That was determinismo's power loss, not Scylla: after the crash's ext4 shutdown the
guest's kernel ran on, and ext4's commit callback discarded blocks a lost transaction freed,
punching holes in the disk's committed state (the same corruption Kafka's hunts showed as
checksum failures). A power loss now cuts the node's disk off first (7c21695): 52 power losses
over the power-loss profile's first timelines, no zero log, no checksum failure.
