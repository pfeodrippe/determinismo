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

- `default`: each broker's feature_flags file synced within a second of each change (start.sh
  keeps a loop for it): the finding below would otherwise brick the cluster in nearly every
  timeline (the guest writes nothing back unasked) and hide the rest. The second smoke (run
  76, four timelines) lost all three brokers to it in two, by 30 s.
- `flags-unsynced`: the file as RabbitMQ leaves it, the finding's profile.

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

## Status

- 2026-10-28: first timelines (srv3): the finding above, in both. Run 76 (enqueues noted
  before they are sent, the drain leaving out a node failing for a minute): no phantom
  dequeue in 4 timelines; every other failure the feature_flags finding's (all three brokers
  down, nothing left to drain). Hence the `default` profile's sync.
