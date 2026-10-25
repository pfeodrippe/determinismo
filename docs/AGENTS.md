# Using determinismo from an agent

determinismo is built to be driven by programs as much as by people: every timeline replays
exactly, results are JSON, and a Model Context Protocol server exposes the main operations.

## Connect

```
determinismo mcp --kernel <vmlinuz> --initrd <base.cpio> --memory-mib 2048 --cache <dir>
```

Tools: `describe`, `explore`, `replay`, `fork`, `query` (schemas in `src/mcp_tools.json`).
Without MCP, use `explore --record results.jsonl --events-dir events/` and `determinismo query`,
or the HTTP API (`determinismo serve`).

## A debugging loop that works

1. **Describe** the program: its profiles (nodes, faults allowed) and scenarios (test commands).
2. **Explore** a scenario with enough branches (32 to 128) and a fixed seed. Read the summary:
   which properties failed, in how many branches, and an example branch for each.
3. **Query** the multiverse: every branch's events (assertions, faults, commands, and what each
   node printed) are in the exploration's `events_dir`. Ask what the failures have in common:
   `query {condition: "assert.condition=false", preceded_by: "event=fault", within: 1,
   output: "branches"}` lists the timelines where a failure came within a second of a fault;
   `not_preceded_by` the ones where it did not. Each match carries its moment.
4. **Replay** a failing branch: same seed, `branch` = the example. It is the same timeline,
   every time, so its events (with virtual times) are evidence, not noise.
5. **Look at a moment**: replay with `at_vtime_ms` just before the first failure and an `exec`
   command, e.g. `det-nodes exec postgres psql -U postgres -c 'select ...'` or
   `det-nodes exec redis redis-cli get key`. The output is identical on every replay.
6. **Narrow down**: `causality` measures, at moments of the failing branch, how likely the
   failure was (futures forked there that fail): the bug was decided where the probability
   jumps; query the branch's events just before. `replay` with `until` stops at the first event
   matching a condition (its first violation, say) to look there. `fork` from any moment
   explores its futures.
   **Try a change**: `replay` with `exec` and `continue` makes a change at a moment (data, a
   setting, a function redefined through a REPL) and lets the branch play out; `fork` with
   `exec` explores many futures of the changed system.
7. **Fix and verify**: change the code, explore again with the same seed and more branches; the
   property should pass in all of them. A replay of an old failing branch is not proof (the
   inputs changed, so it is a different timeline); exploration is.

## Facts worth knowing

- A branch is identified by (inputs, seed, branch index[, fork point]). Inputs are the kernel,
  initramfs, command line (scenario included), timer slack and disks; `explore` prints their hash.
- Tapes (`--tape-dir`) record strategy overrides; `--tape` replays a branch without its strategy
  and refuses to run on different inputs.
- Virtual time is not wall time: idle time is skipped, so timeouts and sleeps cost nothing.
- Faults happen only during the driver phase; `finally` and `eventually` commands see a system
  without faults, which is where recovery is checked.
- Exit status of explore: 0 every property passed, 3 some failed, anything else an error.
- Built-in properties come with every system: nodes do not exit unexpectedly, the guest
  finishes its scenario, the kernel kills no process for lack of memory, and the kernel reports
  no warnings, BUGs or hung tasks. A kernel property's failure carries the log line and the
  kernel's timestamp (`kernel_us`, virtual time) in its details.
