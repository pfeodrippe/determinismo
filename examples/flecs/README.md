# Flecs under determinismo

[Flecs](https://www.flecs.dev/flecs/) (master, pinned in build.zig.zon), an in-memory entity
component system, under a stress harness (`stress.c`): rounds of random operations against a
world with 0 to 4 worker threads, checked against a model of what it must hold, through the C
SDK.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio \
  --program zig-out/bin/flecs-test --scenario stress --seed 1 --branches 64
```

Operations (each drawn through the SDK, named for strategies): entities created alone, as
children, as instances of prefabs; deleted (children with them, relationships to them removed);
components set and removed, tags, an exclusive relationship, reparenting; batches through a
stage in readonly mode (merged at its end); frames of two multi-threaded systems (Move, Decay,
which deletes from worker threads) with observers. After each, the entities it touched are
checked against the model (alive, components and values, tags, parent, relationship, prefab);
every 25 steps all of them, a cached and an uncached query, and a parent's children. Inside the
systems: each entity visited once a frame.

The SDK goes further in: Flecs's OS hooks (mutexes, condition variables, thread creation, atomic
counters) yield the CPU when the platform says so (buggify), so the explorer varies interleavings
exactly where Flecs synchronizes; Flecs's sanitize checks (`FLECS_SANITIZE`, leak checks
included) and the build's undefined-behavior traps report as properties; the whole of Flecs is
instrumented for edge coverage, which strategies and the tree see.

Faults: what varies a library's behavior is scheduling, not the network or restarts (its state is
its memory): pauses of the process or of one of its threads, CPU throttling, clock skips.

## Status

v4.1.6 passes everything (8 timelines). Master (3988dee) aborts in 30 of 32 timelines on Flecs's
own check `assert(!(world->flags & EcsWorldReadonly))` in `flecs_table_ensure` (a table created
while readonly), with two model disagreements (a component's value, a deleted entity alive):
under investigation (the harness's readonly batches are new with master, where defer_begin/end
are gone).
