# etcd under determinismo

etcd v3.7.3 (2026-10-22, the release's binaries, checksummed), three members, explored blind
through its v3 JSON gateway. The test program is `etcd_test.zig`; the Elle checker node is
`checkers/elle`.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio \
  --program zig-out/bin/etcd-test --scenario kv --seed 1 --branches 64 --timeline 15m
```

Faults: Antithesis's set (partitions, clogs, degraded links, pauses, thread and process pauses,
throttling, clock skips), restarts, graceful stops and power losses (each member's data on its
own ext4 disk: what was synced survives), and at the members' syncs, stalls and power losses
(`sync_stall`, `durable_crash`). A wipe is left out: a member that lost its data cannot rejoin as
itself, by design. Members snapshot every 100 entries, so followers catch up from snapshots and
restarts load them. Since 2026-10-29 also per-member clock skews (`clock_skew`), and half the
faults aimed at the leader the append drivers find as they start (`sdk.fault_aim`: the member
whose own id its status names as leader).

What is checked:

| Property | How |
|---|---|
| Acknowledged writes survive | drivers note every acknowledged put; after faults, every one is read back with its value |
| Reads see earlier writes | after each acknowledged put, a linearizable read on a random member must see it, at a revision at least the put's |
| Revisions grow | each acknowledged put of a driver has a higher revision than its earlier ones |
| The counter counts | compare-and-swap increments: the final value is at least the acknowledged ones, at most those and the unknown ones |
| Members agree | anytime: the members' `hashkv` at the lowest revision they all reached are equal |
| Watches miss nothing | a watch from the current revision, or up to 100 before it (etcd's catch-up path, as Jepsen's resumed watches), delivers events in revision order and every acknowledged write in its range |
| Recovery | after faults, a write commits and the members reach the same revision and hash |
| Strict serializability | list-append transactions (reads, then one txn guarded by every key's mod revision), the whole history checked by Elle at the end of each timeline |

## Membership changes

A fourth member, `etcd-4`, is a spare: prepared with the others, not started. The `member`
driver takes one step at a time (a lock file in the runner), from the member list a member
gives: the spare added (as a learner or a voter, a named decision) and started fresh; a learner
promoted once it caught up; a voter, one time in two, stopped and then removed. Every property
above holds through them; faults leave the spare alone while it is not running.

## Findings

### Found again: #22498 losing acknowledged increments, served by linearizable reads

The second membership smoke (srv3, 2026-10-30, `--scenario kv --seed 1`, branch 2, etcd
v3.7.3) failed "the counter counts every acknowledged increment and no more": the final
linearizable read, through etcd-1, gave 0 after 7 acknowledged increments. Replays read each
member's own copy (serializable reads): etcd-1 and the leader both held 7 at 16.3 s and 17.5 s;
at 32.5 s etcd-1 held "0" (mod revision 2, its setup value) and etcd-2 and etcd-3 held "7"
(mod revision 93), all three at applied index 119. etcd-1's log shows #22498's sequence (below):
- 17.86 s: it receives the leader's snapshot (index 107), saves `000000000000006b.snap.db`,
  installs it (`applySnapshot: opened snapshot backend`), and restores consistent index 107;
- 18.47 s: a power loss, 0.6 s later;
- 22.58 s: `restore consistentIndex 107`, `Skipping snapshot backend` (consistent index 107,
  snapshot index 107): it keeps the old file, which claims index 107 with data from before.
The same bug, reached blind again; here a member silently loses acknowledged writes and answers
linearizable reads from that state (it takes the leader's read index, then reads its own).
Replay: `--scenario kv --seed 1 --branch 2` (the membership driver's build).

### Found blind, known upstream: a member loses applied writes after a power loss that follows a snapshot install

Not new: reported on 2026-09-29 as etcd-io/etcd#22498 (against 3.7.2, reproduced by simulating
the lost rename with hard links), with fixes proposed (#22499, #22518) and not in 3.7.3.
determinismo found it on its own, without being told where to look, from a power loss at a
moment it chose, and showed what follows (below).

etcd v3.7.3, blind: `explore ... --scenario kv --seed 4 --timeline 2m`, timeline 0. After
faults stopped the members never converged: etcd-3, the leader, at revision 66 with applied index
111, the others at 68 with the same applied index; their keyspace hashes differ. etcd-3 had
silently lost two applied revisions, and every later write got a revision two lower there than
on the others: a permanent divergence of the state machine, on the member serving linearizable
reads. Its replay and files were on srv1 (~/findings/etcd-revision-loss-2026-10-26), gone with
that host (cancelled 2026-10-27); the timeline comes back from the run's seed on a host of the
same CPU model.

What happened to etcd-3, every step from its own logs, its files (extracted at moments of the
replay, read with bbolt and a WAL reader) and etcd's code:

1. 110.16 s, restarted after a stop: its backend `member/snap/db` has consistent index 97 and
   current revision 64.
2. 110.27 s: the leader sends a snapshot (index 101); etcd-3 saves it as
   `0000000000000065.snap.db` and installs it: `OpenSnapshotBackend` renames it over `db`
   (`os.Rename`, server/storage/backend.go) and syncs nothing (not the directory). Restored:
   consistent index 102, current revision 66.
3. 110.30 s: `applySnapshot` closes the old backend in a goroutine
   (server/etcdserver/server.go). Its last commit runs the pre-commit hook that saves the
   consistent index, already 102 from the new backend, into the old file, and syncs it. The old
   file now claims index 102 while its data stops at revision 64.
4. Entries 103 to 106 are applied on the new backend (entry 106 a put: revision 67); its WAL is
   synced as it goes. At 114.0 s: `db` has consistent index 106, revision 67.
5. 115.43 s, a power loss (5.1 s after the rename, no journal commit since): the rename is
   lost. After it, `db` is the old file again (consistent index 102, data to revision 64), and
   the newer backend is back under its old name, `0000000000000065.snap.db` (consistent index
   106, revision 67, the same 75 entries as at 114.0 s).
6. 122.38 s, restart: `restore consistentIndex 102`; `RecoverSnapshotBackend` compares it with
   the snapshot's index 101 and logs `Skipping snapshot backend`: it keeps the old file, and
   replays its WAL only past 102. Revision 65 (in the snapshot) and revision 66 (entry 102's
   txn) are gone for good; the next write, entry 106's put, becomes revision 65 there.

Two causes together: the rename that installs a snapshot backend is not made durable (the
directory is not synced), and closing the old backend writes the new consistent index into it.
Either alone would leave the member able to recover (with a durable rename the old file is gone;
with the old index kept, at 97, the restart recovers from the snapshot file). The same two
causes as etcd-io/etcd#22498.

### Found blind on 3.4.3, known and fixed upstream: a member that cannot restart after a power loss

The `jepsen` profile (etcd 3.4.3), run 83 on srv2, timeline 87: after a power loss etcd-1 panics
at every start, `state.commit 367 is out of range [249, 259]`: it recovered from the snapshot at
index 249 while its hard state says 367 were committed. A snapshot file can reach the disk without
its WAL record; the restart then picks a snapshot the WAL does not match. Reported as
etcd-io/etcd#10219 and fixed by #11888 (May 2020, after 3.4.3); Jepsen's 3.4.3 analysis did not
report it.

### Not findings: hunt run 64 (srv3, 2026-10-28, `jepsen` profile, kv)

4,325 timelines failed "no panics (Go)" in 246, "no unexpected container exits" in 230,
"test commands exit successfully" in 260 and "the counter counts every acknowledged increment
and no more" in 83. None is etcd's:
- The panics (`tocommit(78) is out of range [lastIndex(73)]. Was the raft log corrupted,
  truncated, or lost?`), the exits and the failed commands came from a determinismo bug: a
  durable crash that crashed a member twice left its disk dropping writes, and its next crash
  lost every write since. Every one of the 246 panicking timelines has such a failed crash in its
  history (300 timelines inherited one). Fixed (determinismo's commit "A failed crash left a
  node's disk dropping writes").
- The counter one over its acknowledged increments (none unknown) was the workload's: it noted
  an increment after the answer, and a driver the composer killed as its phase ended, during a
  committed increment, left it neither acknowledged nor unknown (timeline 2028: a 0.34 s driver
  phase, no increment noted, the counter at 1). Increments are now noted before they are sent.
