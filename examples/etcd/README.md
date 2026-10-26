# etcd under determinismo

etcd v3.7.3 (2026-10-22, the release's binaries, checksummed), three members, explored blind
through its v3 JSON gateway. The test program is `etcd_test.zig`; the Elle checker node is
`checkers/elle`.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio \
  --program zig-out/bin/etcd-test --scenario kv --seed 1 --branches 64 --timeline 15m
```

Faults: Antithesis's set (partitions, clogs, degraded links, pauses, thread and process pauses,
throttling, clock skips), restarts, graceful stops and power losses (each member's data on its
own ext4 disk: what was synced survives), and at the members' syncs, stalls and power losses
(`sync_stall`, `durable_crash`). A wipe is left out: a member that lost its data cannot rejoin as
itself, by design. Members snapshot every 100 entries, so followers catch up from snapshots and
restarts load them.

What is checked:

| Property | How |
|---|---|
| Acknowledged writes survive | drivers note every acknowledged put; after faults, every one is read back with its value |
| Reads see earlier writes | after each acknowledged put, a linearizable read on a random member must see it, at a revision at least the put's |
| Revisions grow | each acknowledged put of a driver has a higher revision than its earlier ones |
| The counter counts | compare-and-swap increments: the final value is at least the acknowledged ones, at most those and the unknown ones |
| Members agree | anytime: the members' `hashkv` at the lowest revision they all reached are equal |
| Recovery | after faults, a write commits and the members reach the same revision and hash |
| Strict serializability | list-append transactions (reads, then one txn guarded by every key's mod revision), the whole history checked by Elle at the end of each timeline |

## Findings

None yet.
