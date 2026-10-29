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

## Found blind: Galera 26.4.24 aborts on an uncaught std::out_of_range in EVS

Hunt run 97 (srv3, 2026-10-29, `jepsen` profile: MariaDB 12.1.2, galera-4 26.4.24, seed 3,
with correlated power losses), timeline 3 (and the 13 timelines branched from it): n2's mariadbd
died at 47.41 s with `terminate called after throwing an instance of 'std::out_of_range' what():
vector::_M_range_check: __n (which is 18446744073709551615) >= this->size() (which is 2)`: an
index of -1 into a vector of two. Symbolized from the image's libgalera_smm.so (its frames with
`addr2line`): `gcomm::evs::Proto::populate_node_list` (evs_proto.cpp), from
`Proto::create_join()` (:1854) and `send_join()`, in the gcomm thread (an `AsioTcpSocket` read
handler, then `Protostack::leave()`). `populate_node_list` asks the input map for each known
node's `safe_seq(node.index())` and `range(node.index())`, both `node_index_->at(index)`: a node
the current view counts as a member (or the node itself) had no index, -1. n2's last view, at
47.39 s, 20 ms before (non-primary, two members): n1's new incarnation `d309ba44-...-b089` joined
and its incarnation from before its crash at 35.8 s, `d309ba44-...-b088` (the same UUID but one
digit: a restart within moments), left, n3 partitioned. Just before, n2 went
through non-primary views of two members, one of them `unspecified`, after: an outage of n1 and
n3 (30.8 s), a crash of n1 (35.8 s), pauses of n2's process (6.6 s), n3 (8.6 s) and n1 (6.4 s),
partitions into groups (6.7 s), clogs. The function is unchanged on Galera's 4.x branch, through
26.4.27. Not in MariaDB's Jira (searched: `populate_node_list`, `create_join`,
`_M_range_check` with Galera) nor in Galera's public issues (mariadb-corporation/galera); the
nearest are older: MDEV-5088 (2013, Galera 3: `vector::_M_range_check` after a partition, fixed)
and galera#100 (2014: `std::out_of_range` from EVS on a gap message, fixed). Galera's own bug
tracker (codership/galera-bugs) is not public. Replay: run 97, timeline 3, at 47.4 s; serve's
replay of it is exact (events hash 060f1a0443c319fd, 9,444 events, the same abort). Again in
the same hunt, independently: timeline 51 (branched from timeline 20 at 250 s, another lineage),
n2 at 407.93 s, the same frames, an index of -1 into a vector of one.

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
