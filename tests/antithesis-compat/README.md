# Antithesis-format projects

Systems as an Antithesis project has them: a Compose file, and test commands in an image under
`/opt/antithesis/test/v1/<template>/`, written in shell (`bank`), Python (`python`) and Java
(`java`). They are not how determinismo tests are written (see the test programs in
`examples/`): they check that the Compose importer runs such a project unchanged, its test
commands and Antithesis-format assertions included. `zig build e2e` explores them.

## Antithesis's own project: hashicorp-raft-poc

[antithesishq/hashicorp-raft-poc](https://github.com/antithesishq/hashicorp-raft-poc) (HashiCorp
Raft at their commit 142e831, three nodes, a client with Go SDK assertions, a Python monitor
checking Raft's safety properties) runs unchanged: its images built with its own
`antithesis/build.sh`, then

    determinismo explore --serve 127.0.0.1:7878 \
      --compose ~/raft-poc/antithesis/config/docker-compose.yaml --scenario raft --seed 1 \
      --time-budget 8h --timeline 15m --retroactive "Applied block" \
      --no-faults raft-client,raft-monitor --faults +restart,+stop,+crash [--cpu-modulation]

(faults on the Raft nodes only, as their launch excludes the client and the monitor; fifteen-
minute timelines; the FSM's line per applied block counted but written only by replays; CPU
modulation on in some runs, for the interleavings the double vote needs). The
client declares the setup once a leader is elected (`antithesis_setup`), where the snapshot is
taken; its Go SDK writes to detfs.

The images carry the tags of Antithesis's registry only because the Compose file names them so;
nothing is pulled. To run the very same system on another host (the same inputs, so the same
timelines), copy them rather than build them again: `podman save --multi-image-archive <the
four tags> | ssh <host> podman load`.

### Found, blind (before reading Antithesis's post)

**A leader that rejects every write, forever, after a leadership transfer was cut short**
(Antithesis's hashicorp/raft#696). 13 of the first 800 timelines of an hour's exploration
(about one in 60) fail `[workload-commit-progress] cluster failed to commit a fresh entry within
retry budget after health gate passed`: two minutes after faults stopped, a healthy leader
still answers every Apply with "leadership transfer in progress". Replaying one (`--branch 9`),
stopping it at 60 s and sending SIGQUIT to that leader dumped its goroutines, which show how:

1. As leader in term 8, node-1 is asked to transfer leadership to node-0 while a partition
   holds node-0 back. `leadershipTransfer` hands the replication goroutine a catch-up request
   through `triggerDeferErrorCh` (a buffer of one); a transfer that gives up (timeout, stop)
   before that goroutine took it leaves it in the buffer.
2. The next transfer to the same follower blocks on `repl.triggerDeferErrorCh <- err`
   (raft.go:1064): the buffer is full, and when node-1 steps down (it is paused, then
   isolated) the replication goroutine exits without draining it. The send is not in a
   `select` with `stopCh`, so it never returns.
3. The goroutine that clears `leadershipTransferInProgress` waits on `<-doneCh` (raft.go:786)
   forever. Nothing else clears the flag: `setupLeaderState` does not reset it.
4. A minute later node-1 is elected again (term 14) with the flag still set: it rejects every
   Apply and every transfer, and keeps heartbeating, so nobody replaces it. Only a restart of
   node-1 ends it.

Fixes: select on `stopCh` around that send (or drain the buffer on step-down), and reset the
flag in `setupLeaderState`.

**Two different entries at the same index and term: logs diverge** (Antithesis's
hashicorp/raft#695, its first mechanism). With three-minute timelines (`--timeline 3m`, the
project's configuration being written for long ones), timeline 93 of an exploration's first 110
fails the monitor's `[log-matching] entries agreeing on (index, term) agree on content`: at
index 1866, term 400, node-1's entry and node-2's differ. Its log shows how:

1. node-1 wins the election for term 399, and in that instant a pause fault freezes it for
   389 ms, before it entered leader state.
2. Meanwhile node-2 wins term 400 and sends node-1 heartbeats, which queue up.
3. node-1 thaws. Its main thread goes on into leader state for term 399 (`runLeader`), and
   dispatches the no-op entry a new leader writes (raft.go:624), stamped with
   `r.getCurrentTerm()` (raft.go:1310). Meanwhile its transport goroutine handles the queued
   heartbeats (`processHeartbeat` runs `appendEntries` off the main loop), which raised the
   current term to 400 first: node-1 writes its own entry with term 400, a term it never led.
4. node-2's entry at that index also has term 400: two different entries agree on (index,
   term). node-1 truncates its suffix a few milliseconds later, but nothing prevented it from
   replicating it in between.

Fix: the leader must stamp entries with the term it was elected in (kept in its leader state),
and heartbeats that change the term must go through the main loop.

That two-hour run (352 timelines of three minutes) shows where it leads: 3 timelines fail
log-matching, and in one (`--branch 351`) the wrong entry stays. node-2 is elected for term 257
holding, at index 1186, a term-256 entry with data where the committed one was the new leader's
empty no-op (the monitor's `[leader-completeness]`), and at the end the replicas sit at the same
applied index, 1984, with different state machines (1597 blocks on node-2, 1596 on the
others: `[fsm-convergence] cluster failed to converge`). Log matching, leader completeness and
state machine safety: the properties Antithesis's post lists for this bug.

### Exploration so far

Run 15 (2026-10-26): three hours, 1,872 timelines of three minutes (53 hours of simulated time),
with Go coverage through libvoidstar, faults lasting up to 10 s, and the tree weighing a
generation's finds by rarity. The divergence (#695) in 3 timelines, twice carried to
different state machines; the deadlock (#696) in 46. Snapshots were installed on followers in
most timelines and thousands of faults lasted seconds, yet neither bug below appeared.

Run 16 (2026-10-26, stopped after five hours): 2,574 timelines of three minutes. The
divergence in 12 timelines, five carried to different state machines; the deadlock in 27. It
showed a bug of ours: in 15 timelines a node did not come back from a crash, because a process
pause had stopped another node's launcher (just restarted, before it ran its program) while it
still held every node's mounts. Fixed (the launcher drops them first). No liveness failure was
among those 15 timelines.

Three differences with Antithesis's setup, changed for the next runs. The livelock (#697)
needs a follower whose stale, uncommitted entries reach the index of the leader's next
snapshot. In a three-node cluster only a cut-off leader keeps such entries: the writes it took
before stepping down, at most one per apply driver (each sends one write at a time and waits).
The snapshot reaches past the 16 trailing logs, so it needs 16 or more: with our composer's
four drivers at most, never. Timelines now draw 1 to 32 drivers at once (Antithesis bounds none). The POC is tuned for
15-minute timelines (snapshots every 5 s past 128 entries, 16 trailing logs, in raft-node's
main.go); ours were three minutes. And a node's durable disk lived in guest memory, so a sync
took no virtual time and no other goroutine ran during it: durable disks now take 0 to 2 ms per
I/O, drawn per timeline.

**A follower installs the same snapshot forever: the snapshot installation livelock**
(Antithesis's hashicorp/raft#697), found blind on 2026-10-26 in the first hour of a run with
fifteen-minute timelines and up to 32 parallel drivers (determinismo-2's run 3, timeline 38,
third generation: #15, from 446.2 s #27, from 689.2 s #38). node-0, a cut-off leader that had
taken writes nobody committed, kept entries up to index 1375; the new leader, its log compacted
past them, sent it snapshot 438-1358:

    node-0: Installed remote snapshot: last-index=1358 last-term=438
    node-1: failed to get previous log: previous-index=1358 last-index=1375 ...
    (previous-index 1357, 1356, ... down to 1346)
    node-1: installing snapshot on: peer=node-0 id=438-1358-...    (again)

node-0 keeps its stale entries 1359 to 1375 after installing the snapshot (the Raft paper's
"discard the entire log" is missing), rejects the next AppendEntries, and gets the same snapshot
again: 2,050 times between 696.6 s and 1,042.8 s, through the quiet period after faults stopped
at 912.7 s, until `eventually_fsm_convergence` gave up (node-0 at applied index 1358, the
others at 1470). Reaching it took a cut-off leader with 16 or more uncommitted writes (more
than the 16 trailing logs), which four drivers never gave (one write each at a time): runs 15
and 16 never left more than 7.

It replays: `POST /runs/3/replay {"branch":38}` on that host re-ran #15 and #27 to their moments
and #38 from there (its own 353.7 s of virtual time in 176 s), to the same 282,521 events
(events hash `b0cca81b8b4110f0`) and the same convergence failure.

### Not found yet

Antithesis's post reports one more: double votes from the same off-loop heartbeats (election
safety).

What the double vote needs, read from raft.go. A heartbeat runs `appendEntries` on the
transport's goroutine, beside the main loop. It checks the term (`a.Term > getCurrentTerm() ||
getState() != Follower`) and only then sets it (`setCurrentTerm(a.Term)`, which writes the
stable store first), so the term can go back:
1. B, a candidate that lost term T-1, gets the first heartbeat of T-1's leader just as C's vote
   request for T arrives.
2. The heartbeat passes its check while B is still at T-1. The main loop then moves B to T and
   votes for C (both written to the store), and the heartbeat writes T-1 after them.
3. B, a follower at T-1 that does not hear C's heartbeats (C to B cut), times out and runs for
   T, overwriting its vote for C with one for itself. If A has not voted in T, B wins T, which
   C already won: two `election won` at T.

The race opens only while a goroutine waits on a store write (fsync), and then needs a cut link
and a node that has not voted. Each step is common in our runs, but all four together, in that
order, have not happened yet: 938 timelines of runs 8 to 12, 45 and 46 evaluated election
safety, none failing.

### Found: the double vote (run 77 on srv2, timeline 22)

Blind, with the durability-point faults and CPU modulation (two-hour runs that repeat with fresh
seeds, all on one host's CPU pool): at 445.5 s of virtual time `[election-safety] at most one
leader per term` failed, term 180 with leaders node-1 and node-2. From the timeline's own logs:
node-2 won term 180 at 433.45 s with node-0's vote (node-1 was still at 179); node-1, after
power losses that each brought it back at term 179 (`recovered log from disk: last-term=179`),
kept campaigning in 180; at 445.49 s, partitioned from node-2, it won term 180 with node-0's vote
again. So node-0 voted twice in term 180. In between, at 440.32 s, node-0's stale vote requests
of terms 176 to 179 all completed at once as a partition healed. What made node-0 forget its vote
was not known then (it is now: below, "The double vote, found again and explained"): the timeline cannot be replayed any more, since srv2 was redeployed and its guest
image replaced (the tape says so: its inputs differ), and that run's image was built from a
working tree, not a commit. Its events, all of them, are in the run's database. Next: each run
keeps the files it booted (serve), so that a finding replays after any deploy; meanwhile the
hunts go on to find it again.

### The double vote, found again and explained (srv2, 2026-10-27)

Blind again, in 25 minutes: the strategy benchmark's default tree (bench/explore.py, seed 1,
generations of 48 on srv2's 36 threads) failed `[election-safety]` in timeline 4653, a fresh root
of generation 96, with `[log-matching]`, `[leader-completeness]`, `[state-machine-safety]` and
`[fsm-convergence]` after it: two leaders in term 22, node-1 and node-2. A root replays alone
(`--branch 4653 --branching flat`, the same events hash), so this time its mechanism could be
read off the timeline, at any moment of it:

- The monitor's own log (`determinismo extract` of raft-monitor's /opt/monitor/raft-monitor.log,
  which holds every node's DEBUG records): `node-2: vote granted: from="node-0" ... term=22`, then
  `node-1: vote granted: from="node-0" ... term=22`. node-0 voted twice in term 22.
- node-0's raft stable store (raft-boltdb's /var/lib/raft-node/raft.db, extracted at moments a
  few milliseconds apart, CurrentTerm / LastVoteTerm / LastVoteCand by bbolt transaction):
  28.650 s: 16 / 16 / node-0. 28.656 s: 22 / 22 (node-2's request for term 22, on the main loop).
  28.663 s: 21 / 22 / node-2: the vote for node-2 is persisted, and the term goes back to 21:
  the heartbeat handler (`processHeartbeat`, which calls `appendEntries` off the main loop, #695)
  had compared node-1's term-21 heartbeat with the old term, and its `setCurrentTerm(21)` landed
  after the main loop's 22 (node-0's DEBUG: `updated currentTerm: term=22`, then `term=21`).
  28.668 s: 21 / 21 / node-2, then 28.700 s: 21 / 21 / node-1: with its term back at 21, node-0
  took a late term-21 vote request from node-1 and voted, and raft keeps one vote record, so the
  term-22 vote was gone. 28.735 s on: node-1 asked in term 22, the record said term 21, and node-0
  voted again: 22 / 22 / node-1.

So: an off-loop term regression, then a stale lower-term vote overwriting the single vote record.
The evidence (events, tape, the stores at each moment, the monitor's log) is on srv2 in
~/findings/double-vote-2026-10-27; the timeline replays from its tape.

### Found again, and explained by causality analysis: run 93 (srv2, 2026-10-27)

Blind again, in run 93 (the tree explorer with CPU modulation and the durability-point faults,
no long timelines): `[workload-commit-progress]` (the leadership-transfer deadlock, #696) in
timeline 11 of the first generation, and `[log-matching]` (the divergence, #695) in timeline
4862 at 24.496 s. Causality analysis (snapshots of the timeline saved to disk, 16 futures from
each moment) says when each was decided:

- The deadlock (timeline 734, reported at 134.1 s): 0% just after setup (2.55 s), 100% from
  4.09 s on; narrowed to 3.830-4.087 s (19% to 100%), where one fault was injected: a degraded
  link (delay and loss) between raft-node-0 and the runner at 3.879 s. The workload only notices
  130 seconds later, when its retry budget runs out.
- The divergence (timeline 4862): under 25% through the faults before it (a partition at
  24.086 s, a power loss of raft-node-1 at 24.222 s: moments either side of each fault, the
  `faults` planner, change it within noise), 6% at 24.478 s, then decided in the last 18 ms, with
  no fault: node-1 was back from its power loss (`recovered log from disk: last-index=25
  last-term=11`), and at 24.4962 s node-0 entered follower state under node-2
  (`leader-id=node-2`) while rejecting node-2's vote because node-2's log was older (`our last
  term is greater ... last-term=11 last-candidate-term=9`). A node following a leader whose log
  is behind its own: the off-loop heartbeat of #695.

So the window itself is now a fault: `sync_stall` (on by default, ARCHITECTURE.md §9) holds a
node's fsyncs for a drawn time while its other goroutines run, and `durable_crash` (with
`+crash`) crashes the node at one. bbolt syncs every transaction (each `SetUint64` of the term
or the vote), so a stall there stretches the moment a goroutine waits on a raft store write from
microseconds to up to a second. Whether that is enough is what the next hunts measure.
