---
name: determinismo-debug
description: Investigate a failing determinismo property - query the multiverse, replay the failing timeline, look at moments, find where the failure was decided, and verify a fix. Use when a determinismo exploration reports FAIL, or when asked why a property failed.
---

# Debugging a determinismo failure

Every timeline replays exactly, so a failure is evidence, not flakiness. Follow
`docs/AGENTS.md` ("A debugging loop that works"); in short:

1. **Read the summary**: each failing property names an example branch (`--branch N`) and,
   when the SDK sent it, the assertion's place in the code (file:line function).
2. **Query** what failures have in common: `determinismo query <events-dir>
   'assert.condition=false' --preceded-by 'event=fault'` (and `--not-preceded-by`), or an event
   set pipeline (`with_last`, `with_next`, `through`) with `determinismo events`.
3. **Replay** the example: same seed, `--branch N` (a timeline past the first 16 of a tree
   exploration started inside another: replay it with `--tape <tape dir>/branch-N.jsonl`). Add
   `--until '<condition>'` to stop at the first violation, `--rewind-ms` to stop before it.
4. **Look at the moment**: `--at-vtime-ms T --exec 'det-nodes exec <node> <command>'` (the
   output is the same on every replay); `determinismo stacks`, `determinismo profile`,
   `determinismo extract` for files and core dumps.
5. **Find where it was decided**: `determinismo causality` forks futures at moments of the
   branch; the failure probability jumps where the bug was decided. Query the events just
   before that moment, the code first run inside the jump (`event=coverage`), and every
   thread's stack at its end (`--at-vtime-ms T --exec '/opt/determinismo/bin/det-profile
   <node> --stacks'`, or `determinismo stacks`).
   A command at a moment runs while the guest goes on: keep it quick (a slow one, a client
   waiting on a down node, moves the moment it reports on by seconds).
6. **Turn the logs up inside the jump**: the system's own logs are often too quiet to show the
   mechanism. At a moment inside the jump, raise its logger (an admin API, a config the node
   rereads; one its restarts keep too) and `--continue`, the timeline's own randomness after
   it: a future that fails as the original shows the mechanism step by step. Before the jump
   the perturbation makes futures pass; past it the cause is already in the past (Redpanda,
   run 177: `tx` at trace from 116 s showed its coordinator crash between `begin_tx` and
   recording the partitions).
7. **Try a change at a moment**: `--exec ... --continue`, or `fork` with `--exec` to explore
   many futures of the changed system (a patch through a REPL, a setting, `inject` a binary).
8. **Verify a fix by exploring again** with the same seed and more branches. An old branch's
   replay is not proof: different inputs make a different timeline.

Report: the property, the timeline (seed, branch, moment), the sequence of events that led to
it (faults, decisions, node output), the root cause in the code, and the fix with its
exploration result.
