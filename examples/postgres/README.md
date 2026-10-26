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
| `serializable` | SERIALIZABLE | strict serializability |
| `repeatable_read` | REPEATABLE READ | snapshot isolation (what PostgreSQL's Repeatable Read is) |

Faults: Antithesis's set, restarts, graceful stops and power losses (committed transactions are
synced first, so they must survive), and stalls and power losses at the server's syncs.

## Findings

None yet: 6 of 6 timelines of `serializable` pass.
