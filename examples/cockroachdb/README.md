# CockroachDB under determinismo

CockroachDB v26.3.3 (the official image), three nodes, each store on its own disk, following
Jepsen's CockroachDB analysis (2016: serializability violations, fixed then). Clients run
list-append transactions (`examples/sql/append.zig`) through random nodes, and Elle checks every
timeline's history on the host for serializability, CockroachDB's claim (single keys are never
stale; across keys it allows causal reversal, so not strict serializability).

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio --memory-mib 6144 \
  --program zig-out/bin/cockroachdb-test --scenario append --seed 1 --branches 64
```

Faults: Antithesis's set, restarts, graceful stops and power losses, and stalls and power losses
at the nodes' syncs. A wipe is left out: a node that lost its store cannot rejoin as itself.

Ranges are test-sized: they split at 64 KiB (CockroachDB's smallest; 512 MiB by default, which a
test's data never reaches) and merge under 16 KiB, so splits, merges and the lease and replica
moves after them happen within a timeline, as Jepsen's split nemesis made them happen. Internal
time series are off (a write every 10 s per node that nothing here reads).

## Findings

None yet: 4 of 4 timelines pass Elle on srv1 (seed 1, 6 GB guests: `--memory-mib 6144`).
