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

    determinismo explore --compose raft-poc/antithesis/config/docker-compose.yaml \
      --scenario raft --seed 1 --time-budget 60m \
      --no-faults raft-client,raft-monitor --faults +restart,+stop,+crash

(faults on the Raft nodes only, as their launch excludes the client and the monitor). The
client declares the setup once a leader is elected (`antithesis_setup`), where the snapshot is
taken; its Go SDK writes to detfs.

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

Two differences with Antithesis's setup, changed for the next runs. The POC is tuned for
15-minute timelines (snapshots every 5 s past 128 entries, 16 trailing logs, in raft-node's
main.go); ours were three minutes. And a node's durable disk lived in guest memory, so a sync
took no virtual time and no other goroutine ran during it: durable disks now take 0 to 2 ms per
I/O, drawn per timeline.

### Not found yet

Antithesis's post reports two more: double votes from the same off-loop heartbeats (election
safety), and a snapshot installation livelock (convergence; it needs snapshots and a follower
far behind, which long timelines now give).

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
order, have not happened yet.
