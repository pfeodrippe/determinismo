# MariaDB Galera under determinismo

MariaDB 13.0.2 with Galera 4 (the official image), three nodes, set up as Jepsen's Galera test
(jepsen-io/mysql, `antithesis/`): its configuration (`galera.cnf`, `jepsen.cnf`: MariaDB's
recommended Galera settings, so the log is not flushed at each commit and durability rests on
the cluster), n1 starting the cluster, and list-append transactions at Repeatable Read through
random nodes, checked by Elle for snapshot isolation.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio \
  --program zig-out/bin/galera-test --scenario append --seed 1 --branches 64
```

Profiles: `default` (13.0.2) and `jepsen` (12.1.2, the version Jepsen analyzed: committed
transactions lost when nodes crash together, lost updates and stale reads).

n1 starts a new cluster on its first start only (`start`, a marker on its data disk); Jepsen's
wrapper meant the same, but a typo in it (`$SRAN_FILE`) made n1 start a new cluster at every
restart, splitting the cluster. Its general query log is left out (diagnostics only), and the
error log goes to stderr, into the run's events.

Faults: Antithesis's set, restarts, graceful stops and power losses (each node's data on its own
disk), and stalls and power losses at the nodes' syncs.

## Status

- Hunt run 58 (srv3, 2026-10-28, `jepsen` profile, 12.1.2, seed 2, 2 h): 532 timelines, Elle
  found no anomaly (Jepsen's lost updates and lost commits not rediscovered), and "no process
  crashes: mariadbd" failed in 22. Each is Galera's own abort: a node rejoining after a crash
  needed a state transfer whose donor left the group ("Donor ... is no longer in the group.
  State transfer cannot be completed, need to abort", then `abort()`; the signal 11 is glibc's
  last resort inside it): by design, not a bug. Elle had plenty to judge: 86,970 operations,
  about 1,000 of them of unknown outcome (1.2%: a `sometimes` true in most timelines says one
  happened, not that most did); the commit errors were all `Error while appending streaming
  replication fragment (provider status: Not connected to Primary Component)`.
