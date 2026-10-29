# Consul under determinismo

Consul 2.1.0 (HashiCorp's current release, 2026-10-22: the first months of its 2.x line), three
servers, its KV store under list-append transactions whose every timeline's history Elle checks
on the host for strict serializability: what Consul promises for its writes and its
`?consistent` reads. Jepsen's analysis (2014, Consul 0.4) found stale reads in the default
consistency mode, where the leader answers from its lease; Consul documents that mode's
staleness since, and this workload reads `?consistent` throughout.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio --memory-mib 3072 \
  --program zig-out/bin/consul-test --scenario append --seed 1 --branches 64
```

## The system

- The image (Dockerfile): HashiCorp's `consul:2.1.0`; `start.sh <name>` runs a server of c1..c3,
  bootstrapping together (`-bootstrap-expect 3`, each `-retry-join`ing the others), Raft at
  production timing (`raft_multiplier = 1`; 5 by default, for small machines).
- Faults: the default ones, restarts, power losses (Consul syncs its Raft log before it commits
  an entry), graceful stops and clock skews (the default mode's lease leans on clocks; the
  `?consistent` reads here must not), in bursts with quiet stretches.

## The workload and its properties

Every key a KV entry `lists/<key, 20 digits>` (fixed width: a key is a prefix of itself alone),
its list the text `v1,v2,...` (base64 on the wire). A transaction reads all its keys in one
read-only transaction (`PUT /v1/txn?consistent`, a `get-tree` of each: nothing for a key never
written). With appends it then commits one transaction guarding every key with the index it
read (`check-index`, or `check-not-exists`) and setting the appended lists, so its reads are still
the keys' values when it commits. Outcomes: `ok` (200); `fail` when nothing was applied (no
connection, a guard failed with 409, no leader known); `info` otherwise (no answer, another
error: the entry may still commit).

- Elle: strict serializability of every timeline's history.
- Final reads: once faults stop, every committed append is in its key's list.
- The faults aim at the leader a server names (`/v1/status/leader`).

## Status

New (2026-10-29): first smoke queued on srv3.
