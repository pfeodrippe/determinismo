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

### Not found yet

Antithesis's post reports two more: log divergence and double votes from heartbeats handled
off the main loop (safety; the monitor's log-matching and election-safety assertions would
fail), and a snapshot installation livelock (convergence; it needs snapshots and a follower
far behind).
