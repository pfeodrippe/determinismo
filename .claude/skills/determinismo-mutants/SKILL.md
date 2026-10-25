---
name: determinismo-mutants
description: Write subtle mutants of a system's code and run a determinismo mutation campaign, to find what its properties miss. Use when asked whether a system's tests or properties are strong enough, or to run mutation testing under determinismo.
---

# A mutation campaign

A mutant is a small, plausible change to the system's code: the kind of bug a person would
write. `determinismo mutate` explores the system and each mutant with the same seed and tells,
for each, whether a property caught it, whether its code never ran, or whether it ran unnoticed
(a gap in the properties: the finding).

## Write mutants that matter

Read the code the properties are about, then change one thing per mutant:

- Concurrency: drop a lock or take it later, widen a race window, reorder two writes.
- Distributed protocols: skip a term or epoch check, accept a stale message, persist after
  replying instead of before, forget to fsync, apply before commit.
- Bounds and edges: an off-by-one in a range or an index, `<` for `<=`, a retry count of zero.
- Error paths: swallow an error, retry without backoff, treat a timeout as success.

Avoid mutants that only crash or fail to compile (syntax, removed functions): every test
catches those, and they say nothing about the properties.

## Run it

Each mutant is a patch (`git diff` output) relative to the node's build context:

```
git diff > mutants/skip-fsync.diff      # then undo the change
echo '{"name": "skip fsync before the reply", "node": "db", "patch": "mutants/skip-fsync.diff"}' >> mutants.jsonl
determinismo explore ...                # the options you use to explore the system
determinismo mutate <the same options> --mutants mutants.jsonl --out mutation-results
```

## Read the results

`mutation-results/results.jsonl` has one line per mutant:

- `caught`: the properties that failed only with it. Good.
- `never_ran`: no timeline ran its lines. The workload does not reach that code: add a
  driver, or a `sometimes` that says the path is taken.
- `unnoticed`: it ran (or the language reports no line coverage) and nothing failed. Write the
  property that would catch it (use the determinismo-properties skill), then run the campaign
  again.
