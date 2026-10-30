# MongoDB under determinismo

MongoDB 9.0.4 (the official image), a three-node replica set set up as Jepsen's MongoDB test
(jepsen-io/mongodb): replica set `rs_jepsen` with 1 s heartbeat timeouts and elections, catch-up
1 s, takeover delay 3 s, priorities 3, 2, 1, the journal on, and a 500 ms heartbeat interval (newer
versions refuse 1 s elections with the default 2 s one). Clients run Jepsen's list-append
workload over MongoDB's wire protocol (`client.zig`, `bson.zig`: OP_MSG, no driver): one document
per key in `jepsendb.jepsencoll`, appended with `$push` (upsert), read by `_id`; one operation
alone at majority read and write concern, longer ones in a transaction at snapshot read concern
and majority write concern. Clients follow the primary as drivers do (`isMaster` names it). Elle
checks every timeline's history for snapshot isolation, what MongoDB's transactions claim.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio \
  --program zig-out/bin/mongodb-test --scenario append --seed 1 --branches 64
```

Outcomes are the server's: a transaction it reports aborted (`TransientTransactionError`) is a
failure, so one that happened anyway shows up as a read of an aborted write (G1a); a commit with
no clear answer (`UnknownTransactionCommitResult`, a write concern error, a lost connection) may
have happened. The client does not retry transactions (drivers' `withTransaction` does: Jepsen
saw its retries duplicate effects; here the server's misreported outcome is caught directly).

Profiles: `default` (9.0.4) and `jepsen` (4.2.6, the version Jepsen analyzed in 2020: read skew,
cyclic information flow and duplicated effects in transactions). The three nodes share the
machine: a 256 MB WiredTiger cache each.

Faults: Antithesis's set, restarts, graceful stops and power losses (each node's data on its own
disk), and stalls and power losses at the nodes' syncs.

## Membership changes

A fourth member, `n4`, is a spare. The `member` driver reconfigures the replica set one step at
a time through the primary (`replSetGetConfig`, then `replSetReconfig` with the version plus
one and the same settings): the spare started fresh (an initial sync) and added as a voter
(priority 0: never elected, as the drivers follow a primary among the first three) when the
configuration lacks it, after a 30 s grace; a member, one time in two stopped and removed.
Every refusal is a `member_refused` event (a reconfiguration still committing, a primary
stepping down).

Smokes (srv3, 2026-10-30, seed 1, 2 timelines): the first crashed its driver (a connection
closed twice when no primary answered); the second added the spare in both timelines and
removed it in one, Elle valid in both, every refusal MongoDB's own ("replSetReconfig should
only be run on a writable PRIMARY", "Stepped down when persisting new config").

## Sharded, as Jepsen tested 4.2.6

Jepsen's anomalies in 4.2.6 came from a sharded cluster, which MongoDB traced to SERVER-48307
(fixed in 4.2.8): a transaction that writes to one shard and reads from another, whose commit
the driver retries after a failover of the shard it only read from, is reported aborted though
it committed, and the driver's `withTransaction` runs it again. `sharded_test.zig` is that
cluster, from jepsen-io/mongodb: a config server replica set (`cfg1`-`cfg3`), two shards
(`s1a`-`s1c`, `s2a`-`s2c`), each a replica set with Jepsen's settings, and three routers
(`r1`-`r3`, mongos); the collection sharded by hashed `_id` in seven initial chunks.

```
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio --memory-mib 8192 \
  --program zig-out/bin/mongodb-sharded-test --profile jepsen --scenario append --seed 1
```

Its client runs transactions as `withTransaction` does: on a random router; a commit with no
clear outcome retried on any router with the recovery token from the router's last reply and
majority write concern; the whole transaction run again (the same appends) when the server says
it aborted (TransientTransactionError). A transaction that ran twice shows in Elle's check as a
duplicated element.

### Found: SERVER-48307, blind

The first hunt (srv2, `--seed 7`, 12 at once) failed Elle's check in 2 of its first 89
timelines, both replayed to the same history. Timeline 80, 221 s of virtual time: an aborted read
(G1a). A read of key 17 saw an append whose transaction the client had recorded failed. From
the nodes' logs, the transaction's session (all five runs of it under one session id):
- runs 1-3 aborted (`not master` from shard 2, a snapshot too old, a chunk epoch mismatch);
- run 4 read key 15 on shard 1, appended to key 17 on shard 2, and committed:
  `commitType:singleWriteShard`, `terminationCause:committed` at r1, after 13 s. During that
  commit, shard 1, which it only read from, failed over twice (s1c to s1b, then to s1a);
- the client's commit gave up at its 10 s timeout and was retried on r1 with the recovery
  token; the retry answered NoSuchTransaction ("transaction number 4 does not match any
  in-progress transactions"), a TransientTransactionError: aborted, run it again;
- run 5 aborted (epoch mismatch), the fifth and last attempt, so the transaction was recorded
  failed. It had committed, and later reads saw its append.

This is SERVER-48307 as its ticket states it: a transaction that writes to exactly one shard and
reads from others, a failover of a shard it only read from during the commit, and a commit retry
told it definitely aborted. Had run 5 committed, the append would have been there twice, as
Jepsen saw.

Timeline 61 (498 s) is that other outcome: Elle found an element of key 7 twice. Session
c343fbc3's transaction 1 wrote to shard 2, read from shard 1, and committed at r3 after 14.7 s,
shard 1 failing over (s1a to s1b) during the commit; the client's retry of the commit, through
r3 to shard 2's new primary s2a, answered that transaction 1 was not in progress; the client ran
it again: run 2 aborted, run 3 committed, and the append was there twice.

By the hunt's 185th timeline, three more had failed: 147 (G1a, and a dirty update: a committed
transaction appended after a write of one recorded failed), 167 (an element twice), and 174,
whose replay parted from its tape (srv2 still ran the guest kernel without
guest/kernel/patches/0001-accessed-bits.patch, under the load of 15 VMs).
