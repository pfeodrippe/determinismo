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

What the logs show, in both timelines: an incarnation restored twice, two different views with
one id, and (timeline 3) n3's warning `Message from node that claims to come from same view but
is not in current view` 27 ms before n2's abort. Changing the timeline was less conclusive. A
replay of timeline 3 that runs `sync -f /var/lib/mysql` in n1 at 44.1 s (between its restore
and its power loss) and goes on with the timeline's randomness ends with no crash; the same
replay running `true` there instead takes another course (any command shifts the timing) and
fails on another crash, a general protection fault in libc at 164.8 s, not the abort. Futures
forked at 44.1 s with their own randomness (`explore --from-branch 3 --from-vtime-ms 44100
--from-exec ...`, 32 each, to 100 s): 0 aborts after the sync, 2 after a sync of /proc (the same
command, nothing made durable); in both, n1 or n3 restored an incarnation twice again after a
later restart (21 of 28 and 30 of 32 futures), since every restart writes the file again
unsynced. Consistent with the cause, not proof of it (p ≈ 0.25); a Galera built with the
directory fsync would be. Two fixes, either enough here: fsync gvwstate.dat's directory after the rename (a restart's
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

## Found blind: a joiner whose state transfer is cut starts a new cluster from its half-copied data

Hunt run 123 (srv3, 2026-10-29, `jepsen-dirsync`: MariaDB 12.1.2, galera-4 26.4.24, seed 3).
**Committed data lost**, read by replay (`POST /runs/123/replay`, `det-nodes exec <node> mariadb`):
in timeline 236 at 31.75 s, n1 and n2 are at `wsrep_last_committed` 8 (history `d5703534`) and
both hold the committed row `txn2` id 5 (`740831188221968`); in timeline 265 (branched from 236
at 46.75 s) at 68 s the primary component is n3 alone, serving a new history (`f1c25642`, seqno 2)
with empty tables.

How, from the nodes' error logs (timeline 265):

1. n3 rejoins at 46.16 s by state transfer, an rsync SST from n2 (`Group state: ea2ebd5f…:2`,
   `Local state: d5703534…:6`).
2. At 46.75 s n2 shuts down gracefully, mid-transfer. A graceful leave takes n2 out of the quorum,
   so n3, still a joiner, is left a primary component of one: `save pc into disk`, `New
   COMPONENT: primary = yes, … memb_num = 1`, `State: JOINER`, `Shifting JOINER -> OPEN`. Its
   gvwstate.dat now names a primary component of n3 alone.
3. n3 restarts (48.1 s) with no state (`Found saved state: 00000000-…:-1, safe_to_bootstrap:
   0`). `pc.recovery` (on by default) restores the saved component (`restore pc from disk
   successfully`), and with all its members present (itself) Galera bootstraps: `Quorum: No node
   with complete state`, `Bootstrapped primary … found: 1`, `Starting new group from scratch:
   ef20522b…` (51.12 s), `GCache history reset`. InnoDB starts on whatever the cut transfer left
   in the data directory, and the node serves (`ready for connections`, 67.83 s).
4. n2, which held the newest data, rejoins at 57.94 s into n3's new history and takes an SST
   from n3 (`Group state: f1c25642…:2`, `Local state: ea2ebd5f…:2`): its data is replaced by n3's.

Timeline 402 is the same path with another end. n2's SST from n3 is cut when n3 stops gracefully
(134.79 s; n3's rsync of the undo tablespaces fails). n2 is left a primary of one: gcomm saves
the primary view (`save pc into disk`) while GCS reports `Quorum: No node with complete state`,
`Failed to establish quorum`, `Received NON-PRIMARY`. n2 restarts, restores that view, and at
142.61 s starts a new group from scratch on a directory with n3's data files and redo log but
its own undo tablespaces. InnoDB refuses it (`log sequence number 78921 is in the future`, `you
may have copied the InnoDB tablespace but not the ib_logfile0`) and aborts. All 34 "no process
crashes: mariadbd" failures of the run are this: InnoDB in 25 (timelines 402-443, one lineage),
Aria in 9 (`Aria recovery failed`, timelines 340-375, another).

In the run, a node that had gone from joiner to open, with no state transfer received since,
started a new group from scratch 327 times in 130 of the 632 timelines. It came up serving within
20 s in 252 of them, and another node then joined its group in 134. The design restores the last
primary component when all its members are back: the last node standing, with the newest state,
starts again (timeline 236's n2 at 42.83 s, by design). A joiner without a complete state was never
meant to be one: `safe_to_bootstrap: 0` is not consulted on this path, and GCS itself reports no
node with complete state.

In the code (Galera's 4.x head, as in 26.4.24): `pc::Proto::handle_view` (pc_proto.cpp) promotes a
restored view when exactly its members are back, with `send_install(true)`, the bootstrap
install `--wsrep-new-cluster` sends; it looks at the view's members only. GCS then takes the
bootstrapping node as the group's first component, and with no history (`act_id_ < 0`) "starts a
new one" (`gcs_group.cpp`, "Starting new group from scratch"). Nothing on the way asks whether
that node ever had the group's state.

Elle found no anomaly: the workload reads keys only inside its random transactions (58
operations in timeline 265), and none read key 5 after the loss. Since then the workload ends
with final reads (a `finally` command, faults stopped): every committed append must be in its
key's list.

A caveat on the deployment: these nodes start as Jepsen's wrapper (`antithesis/db/bootstrap-wrapper`:
`exec /usr/sbin/mariadbd`) and the official image start them, without position recovery, so a
node that crashed reports seqno -1. MariaDB's systemd unit recovers the position from the storage
engine before every start (`galera_recovery`, `--wsrep-recover`). Without it a whole cluster that
crashed comes back through `pc.recovery` with no node holding a complete state and forms a new
history at once, every member declared synced with whatever its storage engine kept. The first
smoke of the final reads (run 154, timeline 1) did exactly that: n3, SIGKILLed 0.2 s after four
commits, lost them to the once-a-second log flush (n1 and n2 held them, read by replay at 32.5 s);
after faults stopped the three formed a group of nil history at 61.6 s (`Quorum: No node with
complete state`, `Bootstrapped primary 00000000-… found: 3`, no state transfer), and n3 served
without them: "every committed append is in the final read" failed. Jepsen's losses on
coordinated crashes may come partly from this. The `jepsen-recovered` profile (12.1.2 with dirsync)
and `default` (13.0.2) start with the systemd unit's recovery (`start`, `GALERA_RECOVER=1`):
whether the joiner's bootstrap and its losses remain there is the next hunt.

Known? Related: mariadb-corporation/galera#549 (open since 2019), "rsync crashed while syncing in
the donor node, receiver node become safe_to_bootstrap=1", where an operator could bootstrap
from a cut transfer's receiver. Here nothing asks an operator: `pc.recovery` bootstraps it. Not
found in MariaDB's Jira (searched `pc.recovery` with joiner, gvwstate with SST, "new group from
scratch"); Galera's own tracker (codership/galera-bugs) is not public. A fix: never save a
primary view to gvwstate.dat while the node's state is incomplete (a joiner), or have
`pc.recovery` bootstrap only a node with a complete state.

## Found blind: stateless nodes restore their component under a nil history, and a node that saves it never starts again

Hunt run 123 (`jepsen-dirsync`), timeline 459. At 98.4 s n2 and n3, both without a state (seqno -1
after crashes), restore their saved component (`pc.recovery`); GCS: `Quorum: No node with complete
state`, `Bootstrapped primary 00000000-… found: 2`, `group UUID =
00000000-0000-0000-0000-000000000000`, and both shift to SYNCED. The group runs under the nil
history: it orders actions (`Shifting JOINED -> SYNCED (TO: 1)` at 132.65 s, `(TO: 2)` at 141.31 s,
three members by then), and n3 serves as a donor in it. n3 saves `00000000-…:2`, and from 154.64 s
every start aborts (`Non-negative state seqno requires non-nil history UUID:
00000000-0000-0000-0000-000000000000:2`, `gcs init failed: Invalid argument`, `Aborting`): the node
never starts again without an operator editing grastate.dat. Run 123 has a node that will not
start for this in 59 of its 632 timelines; run 58 (`jepsen`) in 27 of 532; run 97 in 1 of 299.
Such a group also declares every member synced, whatever its data: in hunt run 148 (timeline 608
and its lineage) n3's rsync SST was cut at 75 s, the three nodes restored their component under
the nil history at 85.82 s (`found: 3`), n3 was `SYNCED (TO: 0)` with no transfer, and its InnoDB
refused the half-copied directory (`log sequence number 70661 is in the future`): all eight of
that run's crashes.

In the code (Galera's 4.x head): a first component of a single bootstrapping node with no
history gets a new history UUID (`gcs_group.cpp`, "Starting new group from scratch"); a
component of several takes the bootstrap quorum's as it is (`group_post_state_exchange`:
`group->group_uuid = quorum->group_uuid`, `act_id_ = quorum->act_id`), nil and -1 when no member
has a state, and the group goes on in it. Not found in MariaDB's Jira (the error's text: no issue)
or Galera's public issues. With the systemd unit's position recovery crashed nodes report their
positions, so fewer components form with no state at all: the `jepsen-recovered` hunt queued
will say whether it still happens.

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
- Hunt run 97 (srv3, 2026-10-29, `jepsen`, seed 3, with correlated power losses): 299 timelines,
  "no process crashes: mariadbd" failing in 114, every one Galera's by-design abort above (a
  state transfer's donor gone), its signal 11 inside `abort()` looking like any crash; the EVS
  aborts (three lineages) were among them. Since then a crash after a node printed one of its
  known exits counts with that exit (det-core matches the node's output as it crashes), and
  every profile declares "State transfer cannot be completed, need to abort": the crash property
  fails on other crashes alone.
- `jepsen-dirsync` (2026-10-29): 12.1.2 with `dirsync.c` preloaded, gvwstate.dat's rename made
  durable. Smoke (4 timelines): no node restored an incarnation twice (n2 restarted 19 times, 19
  incarnations), where without it most timelines repeat one. A hunt of it, against run 97, tells
  whether the rename causes the EVS abort.
- Hunt run 123 (srv3, 2026-10-29, `jepsen-dirsync`, seed 3 as run 97): 632 timelines, **no EVS
  abort** (run 97: 8 of 299) and no "claims to come from same view" warning (run 97: 6): with
  gvwstate.dat's rename durable, the abort is gone, as the cause predicts. Its 34 "no process
  crashes: mariadbd" failures are the finding above (storage engines refusing a data directory
  half copied from another node), not determinismo's disk model as first suspected: InnoDB
  writes no page before its redo is durable (`log_write_up_to(lsn, true)` on both of 12.1.2's
  page write paths, buf0flu.cc and buf0dblwr.cc), and the page "in the future" was another
  node's.
- Hunt run 148 (srv3, 2026-10-29, `jepsen`, seed 3, `--horizon 60s`): 954 timelines in the hour
  (run 97: 299) but no more behaviors (52 against 53, behind all along) and the EVS abort in 5
  timelines (run 97: 16): the horizon did not pay (docs/PLAN.md). Its 8 crash failures are one
  lineage, the nil-history group above.
- Final reads (2026-10-29, smokes of two timelines, seed 3): `jepsen-dirsync` failed them in one
  (run 154, timeline 1, the whole cluster crashed and came back with no position: the caveat
  above); `jepsen-recovered` passed them in both (run 158), every restart recovering its node's
  position (`WSREP: Recovered position d43f1730…:8`). A node that finds no primary component
  within gcomm's wait gives up starting (`failed to reach primary view`, by design, started
  again): a known exit.
- Hunt run 196 (srv3, 2026-10-29, `jepsen-dirsync` with final reads, seed 3, stopped at its
  plateau after 2 h): 715 timelines, 434 failing. "No primary component runs under a nil
  history" in 345 (the finding above); final reads never reaching a node in 210 (the cluster
  waiting for an operator after a whole-cluster crash with no position: the caveat above);
  **acknowledged appends lost in the final read in 120**, every one of them in a timeline where
  a node started a new group from scratch ("Starting new group from scratch", 109 also under a
  nil history), none elsewhere: the new history the joiner and nil-history findings above
  begin, not another loss. Unexpected exits (117) and mariadbd crashes (86) are the known exits
  and aborts above. Next: `jepsen-recovered` (run queued), whose restarts recover their
  position, against these.
