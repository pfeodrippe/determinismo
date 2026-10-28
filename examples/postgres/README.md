# PostgreSQL under determinismo

PostgreSQL 18.6 (the official image), one server whose data is on its own disk, following
Jepsen's PostgreSQL 12.3 analysis (2020: Serializable allowed G2-item, fixed in 12.4). Clients
run list-append transactions (`examples/sql/append.zig`, shared with CockroachDB and YugabyteDB:
anything that speaks PostgreSQL's protocol), and Elle checks every timeline's history on the
host (`sdk.elle`). The transactions are Jepsen's (jepsen-io/stolon, jepsen-io/sql): keys over
three tables, read and updated by primary or secondary key, appended by update-insert-update
(under a savepoint) or `ON CONFLICT`, one-operation transactions in autocommit, and up to 32
clients at once.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio \
  --program zig-out/bin/postgres-test --scenario serializable --seed 1 --branches 64
```

| Scenario | Transactions | Elle checks for |
|---|---|---|
| `serializable` | SERIALIZABLE | serializability (what PostgreSQL promises, and Jepsen checked) |
| `repeatable_read` | REPEATABLE READ | snapshot isolation (what PostgreSQL's Repeatable Read is) |

Faults: Antithesis's set, restarts, graceful stops and power losses (committed transactions are
synced first, so they must survive), and stalls and power losses at the server's syncs.

## Findings

None yet. Run 43 (srv3, 2026-10-28, `jepsen` profile, 12.3, seed 1, tree, checked then for
strict serializability) failed Elle in timeline 173 at 73.2 s with G2-item-realtime only: T17
appended to key 3 and read key 2 empty, T12 appended to key 2, and T14, the next transaction of
T12's session, read key 3 empty. The serial order T14, T17, T12 explains every read, so the
history is serializable; only real-time order breaks (T14 started after T12 committed).
PostgreSQL promises serializability, not real-time order (Jepsen observed histories that looked
strictly serializable, without a promise), so the scenario checks serializability now. Jepsen's
G2-item, a cycle of anti-dependencies alone, is what the `jepsen` profile hunts for.
