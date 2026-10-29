# TigerBeetle under determinismo

[TigerBeetle](https://github.com/tigerbeetle/tigerbeetle) 0.16.13, three replicas, following
[Jepsen's analysis](https://jepsen.io/analyses/tigerbeetle-0.16.11) (2025), to measure what
determinismo finds blind of what Jepsen reported.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio --memory-mib 12288 \
  --program zig-out/bin/tigerbeetle-test --scenario ledger --seed 1 --time-budget 30m
```

Each replica is a node built from the release binary (checked against its SHA-256);
`start.sh` formats its data file when there is none, as an operator would bring back a replica
that lost its disk, then runs it (`--development`, a 64 MiB grid cache: a replica is about
0.75 GB, and its data file 1.1 GB from the start, a write-ahead log of 1,024 slots of 1 MiB:
hence 12 GiB VMs).

Drivers create accounts and transfers through `tigerbeetle repl`, in a random replica's node,
and note in the runner every transfer before it is sent and every one TigerBeetle
acknowledged; one sent and never acknowledged has an unknown fate (no answer within 10 seconds:
a TigerBeetle client never gives up, Jepsen's #206; or its driver killed as its phase ended).
Once faults stop: every acknowledged account and transfer is there as created, and each
account's posted debits and credits are its acknowledged transfers plus some unknown ones.

Faults: the default ones (pauses, partitions, degraded links, sync stalls, throttling), restarts,
graceful stops, power losses (a replica's disk keeps what it synced) and wipes (a replica loses
its disk; `start.sh` reformats it).

## Targets from Jepsen's analysis

- **#2767**: a replica reformatted after losing its disk can make the cluster lose committed
  transfers (five in one of Jepsen's runs); fixed in 0.16.43 by `tigerbeetle recover`, the safe
  way back. The wipe fault and `start.sh` are that scenario.
- **#2544** (missing query results with two filters, before 0.16.17): a pure read-path bug that
  needs index trees over several LSM tables. Natively, 60,000 accounts and every two-filter
  query over them came back right on 0.16.13; it needs far more data than a timeline makes.
- Found on the way: the repl panics ("reached unreachable code") on a command over about 8 KB
  (300 accounts in one `create_accounts`), 0.16.13.
- **Found blind: the reformatted replica can also crash on rejoining** (srv1, seed 2, timeline 3;
  a third symptom of #2767's procedure, beside the data loss and the version panics that issue
  lists). tb-2 was wiped and reformatted while tb-0 and tb-1 were in a view change whose primary
  was replica 2 (tb-0's queue to it full of `start_view_change` and `do_view_change`). The new
  tb-2 started in view 0, the queued messages arrived, and 0.16 ms after the first one it
  panicked (`reached unreachable code`, TigerBeetle's message for any failed assertion in a
  release build). The assertion: `jump_view` (inlined in `on_message`), on a `prepare` or
  `commit` of a view whose primary is replica 2 itself, asks that view's primary for its
  `start_view`, and `send_message_to_replica_base` asserts a replica never sends
  `request_start_view` to itself. Only `recovering_head` is checked for that case (still so on
  main); the old replica 2 had been that view's primary, which a reformatted file forgets.
  `tigerbeetle recover` (0.16.43) is the supported way back now.

  How the stack was found: the replay stopped at the panic (140.162 s) and read the main
  thread's stack from `/proc/<pid>/mem` (ptrace could not stop it there); the frame-pointer
  chain gave ten return addresses. The release binary is stripped, but its build is
  reproducible: TigerBeetle 0.16.13 built with its release flags is byte-identical (SHA-256
  a4ad1a5b...), and the same build also emitting its assembly still is. `symbolize.py` names
  each return address by finding the instructions before it in that assembly: `debug.panicImpl`
  ← `send_message_to_replica_base` ← `send_header_to_replica` ← `on_message` (the header's
  command byte, 13, is `request_start_view`; its destination, the view modulo three) ← the
  message bus's receive ← `IO.Completion.complete` ← `IO.flush` ← `IO.run_for_ns` ← `main`.

## Status

- 6 GiB VMs ran out (three 1.1 GB data files and three replicas in guest memory): 12 GiB.
- A power loss while `tigerbeetle format` wrote its 1.1 GB left a data file with no superblock,
  which TigerBeetle cannot start from (`panic: superblock not found`: the replica down for good).
  Expected of an unfinished format; `start.sh` now formats aside and renames, as an operator
  would.
- Every panic ends in `segfault at 0`: the replica is its PID namespace's init (as in a
  container), which ignores its own SIGABRT, so Zig's `abort()` falls back to writing address 0.
  Not a second bug.
- With that replica down for good, the cluster did not answer for over 30 seconds once faults
  stopped: Jepsen's #2739's symptom (ring replication stalls on one replica down). The check now
  waits up to five minutes and asserts an answer within one.
- With wipes on every replica (22 in one timeline, two replicas within seconds), acknowledged
  accounts and transfers were lost: expected when two of three replicas lose their disks. Wipes
  are now tb-2's alone, where any loss is #2767.
