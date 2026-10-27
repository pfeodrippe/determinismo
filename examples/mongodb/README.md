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
