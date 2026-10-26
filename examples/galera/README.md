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
