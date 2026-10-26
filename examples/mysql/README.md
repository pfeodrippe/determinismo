# MySQL under determinismo

MySQL 26.10.0 (the official image), one server whose data is on its own disk, following
Jepsen's MySQL 8.0.34 analysis (2023: Repeatable Read allowed G2-item, G-single, lost update and
non-repeatable reads). Clients run Jepsen's list-append transactions (`examples/sql/append.zig`
over MySQL's protocol, `examples/sql/mysql.zig`), and Elle checks every timeline's history on
the host (`sdk.elle`).

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio \
  --program zig-out/bin/mysql-test --scenario repeatable_read --seed 1 --branches 64
```

| Scenario | Transactions | Elle checks for |
|---|---|---|
| `serializable` | SERIALIZABLE | strict serializability |
| `repeatable_read` | REPEATABLE READ (MySQL's default) | Repeatable Read |

Profiles: `default` (26.10.0) and `jepsen` (8.0.34, the version Jepsen analyzed, for the
blind-rediscovery benchmark in docs/JEPSEN.md).

Faults: Antithesis's set, restarts, graceful stops and power losses (InnoDB syncs its log at each
commit, so committed transactions must survive), and stalls and power losses at the server's
syncs.

## Findings

Jepsen's 2023 finding holds in 26.10.0, rediscovered blind: at Repeatable Read, Elle finds
G2-item and G-single-item (MySQL's Repeatable Read reads a snapshot but writes the latest
versions), in 2 of the first 4 timelines (`--scenario repeatable_read --seed 7`). Serializable:
4 of 4 timelines clean.
