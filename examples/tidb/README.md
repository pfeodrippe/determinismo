# TiDB under determinismo

TiDB v8.5.8, three nodes each running PD, TiKV and TiDB, as Jepsen's TiDB test runs them
(jepsen-io/tidb): its configurations (`pd.toml`, `tikv.toml`, `tidb.toml`: 300 ms PD elections,
short Raft ticks and leases, regions of at most 5 keys so that they split and merge all the time,
a 10 ms commit timeout) and a restart loop for each daemon (`start`). Clients run Jepsen's TiDB
list-append transactions (`INSERT ... ON DUPLICATE KEY UPDATE` over seven tables, reads by primary
key; `examples/sql/append.zig` over MySQL's protocol) through random nodes at Repeatable Read, and
Elle checks every timeline's history for snapshot isolation.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio --memory-mib 10240 \
  --program zig-out/bin/tidb-test --scenario append --seed 1 --branches 64
```

Profiles: `default` (v8.5.8) and `jepsen` (v2.1.7, the version Jepsen analyzed in 2019: its
automatic retries of conflicting transactions, on by default, broke snapshot isolation with lost
updates and read skew). The three nodes share the machine: each is limited to 3 GiB (TiKV
8.5 holds about 2.2 GB from its start, whatever its settings) or, for 2.1.7, 1 GiB (its TiKV
holds about 0.5 GB), so the guest needs `--memory-mib 10240`, or 4096 with `--profile jepsen`;
the block caches are small (`tikv.toml`, `tikv-2.1.7.toml`).
TiKV's gRPC resolves the nodes' names with the system resolver (`GRPC_DNS_RESOLVER=native`):
its default, c-ares, asks DNS and skips /etc/hosts.

Faults: Antithesis's set, restarts, graceful stops and power losses (each node's data on its own
disk), and stalls and power losses at the nodes' syncs.

## Findings

Jepsen's 2019 finding on 2.1.7, rediscovered blind (`--profile jepsen --seed 3`, 4 timelines of 3
minutes): Elle finds G-single-item (read skew), lost-update and incompatible-order in 2 of them,
from TiDB's automatic retries of conflicting transactions.
