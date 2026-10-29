# RabbitMQ under determinismo

RabbitMQ 4.1, three nodes of one cluster, and a quorum queue (Raft, three replicas), checked as
Jepsen's queue tests check one: every message the cluster confirmed is dequeued in the end;
nothing is dequeued that was never enqueued, or that the cluster refused. Jepsen's 2014 post
lost confirmed messages in mirrored queues under partitions; quorum queues replaced them.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio --memory-mib 4096 \
  --program zig-out/bin/rabbitmq-test --scenario queue --seed 1 --time-budget 1h
```

## The system

- The image: the official `rabbitmq:4.1.4`, with Python and pika for the client node.
- `start.sh broker <id>`: `rabbit@rabbit-<id>`, classic-config peer discovery (a node with no
  database joins the first peer it reaches, or forms the cluster), a shared Erlang cookie, its
  data in `/var/lib/rabbitmq` (the node's disk: power losses keep what it synced).
- `start.sh client`: `rclient.py`, pika behind a line protocol. Each connection is one client
  process; it connects to the node a request names, again after an error. Enqueues are
  persistent publishes with publisher confirms; dequeues take one message (basic.get) and
  acknowledge it.
- Setup waits until the three nodes run as one cluster, then declares the quorum queue.

## Profiles

- `default`: the brokers' disks with a 30 s writeback window (`writeback_s = 30`: synced that
  often, as a host's flusher writes dirty data back): RabbitMQ leaves its feature flags file and
  Mnesia's tables to writeback, and the guest's strict model (nothing written back unasked, as
  Antithesis keeps only "durably synced filesystem changes") bricked nodes after power losses at
  any age, hiding the rest: the second smoke (run 76, four timelines) lost all three brokers in
  two, by 30 s. A power loss within 30 s of a write still loses it, as on a real host.
- `flags-unsynced`: strict (no window), the feature flags finding's profile.
- `flags-synced`: the default, with the feature flags file kept as an atomic replace would
  keep it (start.sh: each new content synced and a good copy renamed in; an empty file at start
  gets the last good one back), to look past the feature flags finding: every boot rewrites the
  file, so a power loss within 30 s of any restart bricked a broker, in 476 of hunt run 100's
  ~700 timelines. Syncing within a second was not enough (a broker losing power again a second
  after a restart).

## The workload and its properties

Enqueue drivers publish twenty unique values each, through a node drawn each time; dequeue
drivers take twenty, the same way. Each operation is noted in the runner:
- `e`: an enqueue invoked, noted before it is sent (a driver killed as its phase ends may have
  published it); then `e+`: confirmed; `e-`: refused (nack); `e?`: no answer, it may be in the
  queue;
- `d`: dequeued and acknowledged; `d?`: got, the acknowledgement unknown (it comes back).

Once faults stop the queue is drained through every node, until each that answers said empty
three times running (a node failing every dequeue for a minute is left out: a quorum queue
serves from a majority), then:

| Property | Breaks when |
|---|---|
| every confirmed message is dequeued | lost write |
| nothing is dequeued that was never enqueued | phantom |
| no refused message is dequeued | a nack that stored the message |
| the queue can be drained once faults stop | the cluster never serves again |

A message dequeued twice is RabbitMQ's at-least-once delivery (one got and not acknowledged
comes back): counted (`sometimes`), not failed.

Faults: the default ones (pauses, partitions, degraded links, sync stalls, throttling) in
bursts with quiet stretches, plus restarts, power losses and graceful stops of the brokers. The
client node stands for Jepsen's clients: its links to the brokers are faulted, the drivers'
calls into it are not (`runner_links = false`).

## Findings

### Found blind: a power loss soon after a node's first boot leaves it unable to boot again

The first smoke (srv3, 2026-10-28, two timelines) failed both: nodes that lost power stopped
booting for good, `BOOT FAILED ... error:{case_clause,{ok,[]}}` in
`rabbit_feature_flags:try_to_read_enabled_feature_flags_list/0`. Timeline 1:
- 10.88 s: rabbit-3, on its first boot, writes `rabbit@rabbit-3-feature_flags` (635 bytes);
- 24.71 s: a power loss of rabbit-3; restarted at 24.95 s, again at 25.56 s and at 33.61 s;
- 25.5 s on (read by replay): the file is there, 0 bytes, its mtime still 10.88 s;
- 38.69 s: the boot fails, and every boot after.

The file is written with `file:write_file` (open with truncation, write, no fsync, no rename:
`do_write_enabled_feature_flags_list/1`), so after a power loss within the kernel's writeback
delay (30 s by default) it can be empty: its creation was journaled, its data was not. (The
guest writes nothing back unasked, so in determinismo any later power loss empties it; here it
came 14 s after the write, inside a real host's window too.) Reading
it, `file:consult/1` returns `{ok, []}`, which `try_to_read_enabled_feature_flags_list/0` has no
clause for. RabbitMQ fixed this very pattern for its serial file after rabbitmq-server#17
(2013): `rabbit_guid` reads `{ok, []}` as no serial ("a couple of users have reported startup
failures due to the file being empty"), and writes through `rabbit_file:write_term_file/2` (a
synced copy, renamed). The feature flags file has neither, in 4.1.4 and on main (checked
2026-10-28). Not found in rabbitmq-server's issues (searched: the error, the file, empty,
truncated, power). The same can follow any rewrite of the file (enabling a feature flag) on a
file system without ext4's replace-by-truncate heuristic.

### Observed: Mnesia unable to recover after a power loss soon after setup (not investigated)

The default profile's smoke (run 79, srv3, 2026-10-29, feature flags synced) failed "no
unexpected container exits" in 2 of 4 timelines. Timeline 0: rabbit-1 lost power at 13.26 s
(setup ended at 12.61 s, the cluster formed a few seconds before), and restarted at 13.47 s;
its dets files were repaired ("not properly closed"), Mnesia stopped and started again at
21.6 s, and at 25.5 s `** FATAL ** mnesia_controller crashed: {{{aborted, {no_exists,
rabbit_node_maintenance_states}}}` (in `mnesia_controller:node_has_tabs/3`, from
`update_whereabouts`, loading by force): its peers told it of a table its own schema had lost
(`schema.DAT` repaired, the table's creation never synced). Then `failed_waiting_for_tables ...
{node_not_running,'rabbit@rabbit-1'}`: the node exited at 31.7 s and boots no more. The power loss came within a real host's writeback window of the
cluster's formation, so this can happen outside determinismo too; the guest's writes never
written back unasked made it possible at any age: the default profile has a 30 s writeback
window since.
Not in rabbitmq-server's issues (searched: the abort, `failed_waiting_for_tables` with
`node_not_running`, the repair message); its Discussions not searched. Mnesia's, under RabbitMQ:
Khepri, RabbitMQ's replacement for it, is the next thing to run here.

### Found blind: after a power loss, a boot's throwaway Mnesia takes a schema update and dies (being read)

Hunt run 118 (srv3, 2026-10-29, `flags-synced`): with the feature flags finding out of the way,
26 of its first 203 timelines lose a broker for good the same way. Timeline 26: rabbit-2 lost
power at 16.43 s (a crash fault; restarted twice in the two seconds before), started again at
16.98 s, and at 27.1 s Mnesia, replaying its log, failed `** FATAL ** Schema update error`:
`{"Cannot create Mnesia dir", "/Mnesia.rabbit@rabbit-2", eacces}` in `mnesia_dumper`
(`insert_op`, `perform_update`) for the table `rabbit_node_maintenance_states`. That directory is
Mnesia's default (its working directory, here /), not the node's
`/var/lib/rabbitmq/mnesia/rabbit@rabbit-2`, which the same boot's Ra systems use. The boot then
fails (`BOOT FAILED ... {case_clause,{error,{node_not_running,'rabbit@rabbit-2'}}}`) and every
boot after. Not in rabbitmq-server's issues (searched: the error, the table, `mnesia_dumper`
with `eacces`).

Read by replay (serve's replay of timeline 26 with `rabbitmqctl eval` at moments): at 26.5 s and
26.85 s Mnesia's `dir` is unset, its `schema_location` `ram`, and the boot process (`<0.209.0>`)
is in `rabbit_mnesia:check_cluster_consistency/2` → `with_running_or_clean_mnesia/1` →
`mnesia:start()`. That function (4.1.4, rabbit_mnesia.erl:1016) checks a peer's protocol with a
throwaway Mnesia: dir unset, RAM schema, "to prevent joining cluster and/or corrupting data",
then restores both. At 27.1 s that throwaway Mnesia applies a schema update for a disc table
(`rabbit_node_maintenance_states`), which it can only put in its default directory, and dies;
the boot fails on it. Where the update comes from: most likely rabbit-1, booting at the same
time (both restarted after the faults): its own throwaway Mnesia stopped at 26.70 s
("Application mnesia exited with reason: stopped"), its boot proper began at 26.92 s ("Starting
broker"), and a booting broker makes sure its tables exist, a schema transaction across the
members it knows, rabbit-2 among them, whose throwaway Mnesia then took a disc table's update
0.2 s later. Shown by changing the timeline: a replay that holds rabbit-1's broker (SIGSTOP)
from 26.6 s for 3 s moves rabbit-2's failure by those 3 s, to 29.97 s, just after rabbit-1
goes on (its "Starting broker" later still, at 39.97 s: an earlier step of its boot, its
Mnesia starting with its directory, is the trigger); held for 0 s, the failure stays at
27.1 s. rabbit-2's throwaway Mnesia waits in `mnesia:start()` (Mnesia `stopping` meanwhile)
and dies on what rabbit-1's Mnesia sends it.
Also: `with_running_or_clean_mnesia` restores `dir` with no `try ... after`, so any exit from
its fun leaves the node's Mnesia settings at the throwaway ones.

## Status

- 2026-10-28: first timelines (srv3): the finding above, in both. Run 76 (enqueues noted
  before they are sent, the drain leaving out a node failing for a minute): no phantom
  dequeue in 4 timelines; every other failure the feature_flags finding's (all three brokers
  down, nothing left to drain). Hence the `default` profile's sync.
- 2026-10-29: hunt run 100 (srv3, `default` with its 30 s writeback window, ~700 timelines):
  the feature flags finding in 476 timelines (it follows every boot, not only the first: a power
  loss within 30 s of any restart), and "every confirmed message is dequeued" failing in 351, 61
  of them after a complete drain. Not RabbitMQ's: a dequeue driver killed as its phase ended
  could miss the answer to a dequeue the client node completed (the message got and
  acknowledged, noted nowhere). The client node now logs every dequeue it makes before
  answering, and the judge counts those; and a confirmed message is lost only after a complete
  drain (with no node serving, its fate is unknown, and the drain's property fails instead).
  Smokes (4 timelines each): confirmed messages accounted for in every drained timeline.
- 2026-10-29: hunt run 118 (`flags-synced`), first 508 timelines: no message lost, none
  dequeued that was never enqueued or refused. 160 lose a broker for good, by their whole
  histories (ancestors included): 82 the throwaway Mnesia's schema update above, 37 the
  `mnesia_controller` crash on `rabbit_node_maintenance_states` (observed above; timeline 68:
  rabbit-1's `schema.DAT`, a dets file Mnesia does not sync as it writes it, "not properly
  closed, repairing" after the power loss, without the table its peers then say they have), 36 other
  boots ending `mnesia_not_running` (a table load from a peer killed midway, for one), 5 other.
  Mnesia not coming back after power losses, in its several ways, is what is left.
