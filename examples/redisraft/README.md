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

- #52: history rewritten (acknowledged elements lost, duplicated, reordered) by crashes alone.
- #44: split-brain and lost updates from loading snapshots.
- Crashes: #48 (`raft_node_is_voting(me_)`), #49 (libuv `!uv__is_closing`), #50 (a segfault),
  #51 (`EntryCacheAppend`), #53 (`AppendEntries` term mismatch), #54 (snapshot process
  segfault).

## Status

Image and program built; first exploration next.
