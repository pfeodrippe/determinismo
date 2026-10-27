# Redis-Raft under determinismo

[Redis-Raft](https://github.com/RedisLabs/redisraft) at 2d1cf30 (2020-05-09) on Redis 6.0.3,
five nodes, following [Jepsen's analysis](https://jepsen.io/analyses/redis-raft-1b3fbf6) (2020,
21 issues from 1b3fbf6 to e0123a9), to measure what determinismo finds blind of what Jepsen
reported.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio \
  --program zig-out/bin/redisraft-test --scenario append --seed 1 --time-budget 30m
```

The image builds Redis 6.0.3 (checked against its published SHA-256) and Redis-Raft at that
commit with its git submodules (cmocka, for its tests, from its current home; `-fcommon` for
2020's C with today's compiler). Each node runs Redis with the module, its Raft log synced to its
disk (`raft-log-fsync=yes`); the test program forms the cluster (`RAFT.CLUSTER INIT` on node 1,
`JOIN` on the others).

Jepsen's workload, list-append: transactions of up to four appends (`RPUSH`) and reads (`LRANGE`)
in `MULTI`/`EXEC` on random nodes, recorded for Elle, which checks the history is strictly
serializable. `ok` when `EXEC` answered; `fail` on a refusal (`NOLEADER`, `TRYAGAIN`, ...: a
refusal that took effect after all is Jepsen's #23, aborted reads); `info` with no answer.

Faults: the default ones (pauses, partitions, degraded links, sync stalls, throttling), restarts
and power losses (each node's Raft log on its own disk). Membership changes, which several of
Jepsen's split-brains needed (#17, #28, #44), are next, as custom faults.

## Targets from Jepsen's analysis, in 2d1cf30

Jepsen found these in or before 2d1cf30, fixed only later (e0123a9) or never:

- #52: history rewritten (acknowledged elements deleted, duplicated, flip-flopping) by process
  crashes alone; perhaps related to #54.
- Crashes: #42 (`callRaftPeriodic` assertion, unresolved), #43 (startup panic: a snapshot index
  before the log's first entry), #48 (`raft_node_is_voting(me_)`), #49 (libuv
  `!uv__is_closing`), #50 (a segfault), #51 (`EntryCacheAppend`), #53 (`AppendEntries` term
  mismatch), #54 (the snapshot process's segfault in `RaftLogWriteEntry`).

#44 (split-brain from snapshot loading) was fixed in 2d1cf30 itself. Jepsen compacted the log
every 32 KB (about every 5 seconds); so does `start.sh` (at first it did not: 64 MB, no
snapshots in a timeline).

## Found blind (srv1, 2026-10-27)

A 30-minute exploration (seed 1, six workers): of its first 179 timelines, 115 had a node crash,
the first in timeline 2 (25 seconds of virtual time each; each replays from its tape, the same
events):

- `REDIS RAFT PANIC` / `Log refers to snapshot (term=0/index=1 which was not loaded, aborting`
  in timelines 2, 5, 12, 13 and 15, a node that cannot start again: **Jepsen's #43** (startup
  panic from a snapshot/log index mismatch).
- `raft.c:784: callRaftPeriodic: Assertion 'ret == 0' failed` in timelines 2 and 12: **Jepsen's
  #42**.
- `src/raft_server.c:1252: raft_handle_append_cfg_change: Assertion 'node' failed` (the bundled
  raft library) in timeline 13: not one of Jepsen's, known since 2019 (RedisLabs/redisraft#2:
  a node rejoining under an id the cluster has seen).

Elle found no anomaly in those timelines yet (#52, history rewritten, is the safety target): the
crashes leave nodes down, and clusters unavailable, early.
