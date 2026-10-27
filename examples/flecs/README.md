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

v4.1.6 passes everything. So does master (3988dee) since the harness uses master's API: 32
timelines, every property, every "sometimes" reached (worker-thread deletes, observers during
merges, frames on several threads); then a 45-minute tree exploration on srv1 (seed 2): 4,528
timelines, none failing.

### Found: master's old-idiom hazard (2c517a7, "Remove implicit defer mode from core")

Under determinismo, master first aborted in 30 of 32 timelines on Flecs's own check
`assert(!(world->flags & EcsWorldReadonly))` in `flecs_table_ensure`. `determinismo stacks` at the
moment (frame pointers on) showed where: `ecs_progress` > worker pipeline > the `Decay` system >
`ecs_delete(it->world, e)` > `flecs_on_delete` > `flecs_table_ensure`. Bisected natively (a
16-line repro, outside determinismo) to 2c517a7 (2026-09-08), which made it the rule: systems and
observers get `it->stage` to queue operations, and `it->world` is the world itself, whose
operations run at once. So the idiom every Flecs program used until then, `ecs_delete(it->world,
e)` in a system, now deletes at once, inside the table the system is iterating, and nothing says
so, `FLECS_SANITIZE` included:

- Single-threaded, other entities' writes are lost: six entities with health 1, 2, 3, 1, 2, 3, a
  system that decrements each and deletes at 0; after the first frame e4 and e5 still have their
  starting values (the delete moved the table's last row while the system wrote on), and e4 is
  alive a frame after it reached 0. v4.1.6: every value right.
- With worker threads, `double free or corruption (fasttop)`, or the readonly assert above when a
  delete needs a new table (an entity that is a parent or a relationship target).

Locking a table while a system iterates it, as Flecs did (the LOCKED_STORAGE errors), would turn
the silent corruption into an error; master's open PR #2338 locks tables for OnAdd/OnRemove
hooks and observers only. Not reported upstream (findings stay here); nothing in Flecs's tracker
mentions it as of 2026-10-27.
