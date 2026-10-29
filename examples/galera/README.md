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
whose join (or leave) message names the current view as its source view had no index, -1 (the
check `index() != invalid_index` that `evs_proto.cpp:954` makes, this function does not).

**Root cause: two different views with the same id**, after a restart that reuses a UUID's
incarnation. With `pc.recovery` (the default) a node restarting reads gvwstate.dat, increments
its UUID's incarnation (`rst_uuid_.increment_incarnation()`), writes the file back and starts
EVS at the restored view's sequence + 1. `ViewState::write_file` fsyncs a temporary file and
renames it over gvwstate.dat, but never syncs the directory: the rename is not durable. A power
loss soon after the restart (seconds: ext4 commits its journal every 5 s by default) brings the
old file back, the next restart increments the same incarnation again, and the node forms views
with ids it already used with other members. Timeline 3: n1 restored incarnation `b089` at
33.9 s, 43.9 s and 45.9 s, losing power within seconds each time (at 44.45 s, 0.55 s after its
restore); at 34.4 s n1 and n3 formed view `(d309ba44-b089, 6)`; at 47.39 s n1 and n2 formed a view
with the same id, n3 logging `Message from node that claims to come from same view but is not in
current view` for n2's messages; n3's join, naming its view `(d309ba44-b089, 6)`, reached n2 as one
from n2's own current view, where n3 has no index: the abort, 27 ms later. Timeline 51, the same:
n2 restored `9d42` at 397.8 s, formed `(d6e45c20-9d42, 26)` with n3, lost power at 402.1 s (4.3 s
after its restore), restored `9d42` again, formed a view of its own with the same id, and aborted
at 407.93 s on n3's join (its input map of one).

Shown by changing the timeline: a replay of timeline 3 to 44.1 s (between n1's restore and its
power loss) that runs `sync -f /var/lib/mysql` in n1 there and goes on with the timeline's
randomness ends with no crash at all; the same replay running `true` there fails "no process
crashes: mariadbd". (`determinismo runs exec`, or serve's `POST /runs/97/replay {"branch": 3,
"at_vtime_ms": 44100, "exec": "det-nodes exec n1 sync -f /var/lib/mysql", "continue": true}`.)
Two fixes, either enough here: fsync gvwstate.dat's directory after the rename (a restart's
incarnation then never repeats), and have `populate_node_list` (like line 954) skip a node without
an index rather than read the input map with -1. The function is unchanged on Galera's 4.x branch, through
26.4.27, and neither fix is on Galera's 4.x heads (codership, mariadb-corporation). Not in MariaDB's
Jira (searched: `populate_node_list`, `create_join`, `_M_range_check` with Galera; gvwstate: 110
issues, none on its durability, MDEV-30881 a rename refused for permissions, MDEV-39650 a
segfault in replication filters) nor in Galera's public issues (mariadb-corporation/galera); the
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
