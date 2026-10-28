# Dgraph under determinismo

Dgraph v1.1.1, the release of Jepsen's [analysis](https://jepsen.io/analyses/dgraph-1.1.1)
(2020), with its bank workload (jepsen-io/dgraph, `bank.clj`) and its tablet mover.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio --memory-mib 12288 \
  --program zig-out/bin/dgraph-test --scenario bank --seed 1 --time-budget 1h
```

## What Jepsen found in 1.1.1

Every anomaly needed tablet moves (a predicate's data moved from one group of alphas to another);
healthy clusters, clock skew, process kills and partitions alone passed.

- **#4534** (and #4540): reads missing values: an account with no amount, and non-monotonic
  reads in the sequential workload.
- #4575: the same, rarely.
- **#4543**: read skew, the bank's total corrupted for good (98 or 102 instead of 100).
- #4538: a window of acknowledged inserts lost (UID set workload); #4601: a list read back as
  a single number.

## Found: an alpha restarting panics on a tablet move (blind, first run)

Not in Jepsen's report, and no issue in Dgraph's tracker names it. An alpha that has just
started again (a restart, a process kill) serves its worker's gRPC before it has joined its
group's Raft: a MovePredicate from the zeros' leader in that window reaches
`worker.(*grpcWorker).MovePredicate` (`predicate_move.go:179`), whose `groups().Node` is still
nil, and `n.AmLeader()` dereferences it:

```
panic: runtime error: invalid memory address or nil pointer dereference
github.com/dgraph-io/dgraph/worker.(*node).AmLeader(0x0, ...)    worker/draft.go:1452
github.com/dgraph-io/dgraph/worker.(*grpcWorker).MovePredicate(...)    worker/predicate_move.go:179
```

The alpha exits (status 2) and starts again, and can meet the next move the same way. Found in
the first run (seed 1, flat, 4 timelines, faults every 10 to 300 ms): timeline 2 panicked three
times (dg1 at 67.0 s, dg2 at 226.7 s, dg1 at 284.3 s), timeline 1 once. In timeline 2, dg1 was
restarted at 60.4 s, its alpha was up again at 64.3 s, and dg5, the zeros' leader, was moving
group 1's tablets (`Starting move: predicate:"amount_2" source_gid:1 dest_gid:2`), the first
calls answered "Server is not leader", until one reached dg1 mid-start. The code is the same in
v1.2.0, v20.03, v20.11 and on main today (`n := groups().Node; if !n.AmLeader()`, no nil
check), though whether a start can still serve that window there is not verified.

That run's program had no pacing yet (a fault every 10 to 300 ms); its tapes replay it
(`--tape <tape dir>/branch-2.jsonl` with that build). Paced, it is more frequent still: the
first paced run (srv1, seed 1, timeline 1) panicked 15 times, every one this stack. The zeros'
own rebalancer (every 10 s) moves tablets too: no tablet mover is needed for it.

## Found: a replica replaying its log loses a predicate's index (blind, run 37)

Not in Jepsen's report, and no issue in Dgraph's tracker names it. The workload's schema is one
`/alter` (`key_0: int @index(int) @upsert . type_0: string @index(exact) . amount_0: int . ...`),
one Raft proposal of group 1 (`start_ts:3`). `applyMutations` (`worker/draft.go`) applies its
schema updates in order and returns at the first error. After a tablet in it has moved away
(`key_0` to group 2), an alpha that restarts and replays its log meets that proposal again:
`runSchemaMutation` refuses `key_0` (`Tablet isn't being served by this group. Tablet:
group_id:2 predicate:"key_0"`), so every update after it is skipped. That includes `type_0`'s
index, although group 1 still serves `type_0`.

Run 37 (srv3, seed 2, tree, CPU modulation), timeline 175: every alpha restarted at about
240 s, and dg1 and dg2 both logged that refusal at 240.8 s. From 247.8 s to the end, dg2
answered every `eq(type_0, ...)` query with `Attribute type_0 is not indexed`, through the
recovery check after faults stopped (`every alpha reads the accounts once faults stop` failed
at 372.3 s after 120 attempts). A replay of the timeline to 365 s, asking each alpha
(`runs exec 37 175 365 --node dg1 ...`):

- Zero's tablet map: `type_0` in group 1.
- `schema(pred: [type_0])`: dg1 and dg3 `string, index, [exact]`; dg2, dg4 and dg5 `string`,
  no index.
- `eq(type_0, "account")`: answered by dg1, dg3, dg4 and dg5 (the last two ask group 1); dg2,
  a replica of group 1 without the index, refuses it.

So the replicas of one group disagree on a predicate's schema, and the one without the index
answers queries with an error until something sets the schema again (dg1 kept its index from
its stored schema; later predicate moves set other predicates' schema again, but no move of
`type_0` succeeded). The loop is the same on main today: `runSchemaMutation` takes all the
updates and returns at the first predicate the group does not serve, before the rest.

## The system

- Five nodes, each a zero and an alpha (Jepsen's five), three replicas of each group: two groups
  of alphas, of three and of two. Zeros rebalance tablets every 10 s; the first node's zero is
  the peer the others join. `--lru_mb 1024` (1.1's minimum).
- `start.sh` starts each process again when it exits, as Jepsen's nemesis restarted the ones it
  killed.
- Readiness is the zero's HTTP port; the setup waits for every alpha to be in a group with a
  leader, then writes the schema and the first account.

## The workload

As Jepsen's bank: eight accounts holding 100, each account's key, type and amount on the
predicates of its stripe (its key modulo seven: `key_3`, `type_3`, `amount_3`), so that the
accounts' data spreads over many tablets.

- Transfers (three in four operations): read two accounts by key, write both back (an account
  at zero deleted, a new one created with its type), commit. 1 to 5 at a time.
- Reads: every account, through each type predicate, in one transaction.
- The tablet mover (one driver): every second to ten, every tablet of the bank's predicates to
  a group drawn among them all, through the zeros' leader (`/moveTablet`), as Jepsen's nemesis.

Through Dgraph's HTTP API: `/query`, `/mutate` and `/commit` with the transaction's start
timestamp, keys and predicates.

| Property | Breaks when |
|---|---|
| every account read has its amount | #4534, #4575 |
| every read sees the bank's total | read skew (#4543) |
| no account's amount is negative | |
| reads see only the bank's accounts, once each | |
| an account is one node | |
| every alpha reads the accounts once faults stop | |

Faults: the default ones, process kills (a zero or an alpha), restarts, graceful stops and
power losses, paced (the scenario's `pacing`): stretches of faults up to 10 s and quiet ones up
to 10 s, as Jepsen's nemesis acted every 10 s. Unpaced, a fault every 10 to 300 ms, no transfer
committed: an alpha out of its group takes seconds to serve again.
