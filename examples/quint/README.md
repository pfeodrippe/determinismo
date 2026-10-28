# Quint under test

[Quint](https://github.com/quint-co/quint) v0.33.0, a specification language of the TLA family
(its simulator and model checking play the part TLC plays for TLA+), built from source with
[quint.patch](quint.patch): its CLI (TypeScript) asserts through determinismo's JavaScript SDK
(`sdk/javascript`), its Rust evaluator (v0.7.0) through the Rust SDK (`sdk/rust`). The service
([app/quint_check.js](app/quint_check.js)) checks properties that need no reference answer, one
scenario each:

- `eval`: generated Quint expressions (integers around 2^31, 2^53 and 2^63 and beyond, sets,
  lists, maps, folds, lambdas; every choice a platform decision), each evaluated by both
  backends' REPLs: the same value or the same error, unless the Rust evaluator reports QNT600 or
  QNT601 (it computes in 64 bits, as documented); integers printed as integers.
- `simulate`: an example specification simulated twice with the same seed: the same outcome and
  output.
- `test`: an example's tests (those the examples dashboard marks passing, and that pass on both
  backends as the image builds) pass on both backends.
- `typecheck`: an example mutated (a line dropped, doubled or swapped, a token changed): the
  same answer twice, yes or no, never an internal error.

Inside Quint: an exception out of a CLI command is an internal error (Quint reports a
specification's errors as values); a panic in the Rust evaluator is one too (the simulator catches
them to report their seed); a sample's trace has at most max-steps + 1 states; a violation names
an invariant it violates.

    determinismo explore ... --memory-mib 4096 --program zig-out/bin/quint-test --scenario all

## Found while building it (v0.33.0, evaluator v0.7.0)

Both appeared at once, by hand and then from the `eval` check's first requests. Quint's issue
tracker has neither (searched 2026-10-28).

- **The TypeScript evaluator's `range` is wrong above 2^53.** It converts its bounds with
  `Number()` (quint/src/runtime/impl/builtins.ts), and Quint's integers are unbounded:
  `range(9007199254740993, 9007199254740996)` is `[9007199254740992, 9007199254740992,
  9007199254740992, 9007199254740992]` (four elements, all the same, none in the range); the Rust
  evaluator gives the three it should. Found by `eval` as `((range((-9223372036854775805),
  (-9223372036854775805) + 1).length() - 459302.to(459302 + 1).size())^21)`: TypeScript
  `-2097152` (an empty range), Rust `-1`. `nth`, `slice`, `replaceAt` and the tuple accessors
  convert the same way (their indices are small in practice).
- **The REPL on the Rust backend prints integers above 2^53 as bignumber.js objects**:
  `(-2)^63` prints `{ s: -1, e: 18, c: [92233, 72036854775808] }`, and so does
  `9223372036854775807 + 0`; the evaluator computes them right, the CLI's wrapper prints its
  parsed number's internals.

Smaller: the Rust evaluator's `replaceAt` error says `Out of bounds, replaceAt(${index})` (a
template never filled in), and `slice(1, -1)`'s error shows the -1 as 18446744073709551615.
`range(i, j)` with `i > j` differs between the backends (`[3, 2]` and `[]`), but builtin.qnt says
it is undefined, so the generator never asks.
