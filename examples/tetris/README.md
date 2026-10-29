# djblue/tetris (jank)

[djblue/tetris](https://github.com/djblue/tetris) is a Tetris with two frontends sharing one game:
`src/tetris/core.cljc`, run by ClojureScript in the browser and by [jank](https://jank-lang.org)
(Clojure on LLVM) with raylib. This tests the jank build of the game, as Antithesis's
[Tetris quest](https://antithesis.com/blog/2026/tetris-quest) tested NES Tetris: a player's
moves chosen by the platform, steered toward deeper games, every timeline replayable.

- **The game node** (`Dockerfile`): Ubuntu 24.04 with jank from jank's own repository, the game at
  commit `79878028` (2026-10-28), and `harness.jank`, AOT-compiled by jank: tetris.core driven
  headless, the raylib frontend's actions (`core/update-player` with the same action maps, its
  timer's gravity as a `tick`) from lines on stdin, the game's state after each on stdout. A game
  per TCP connection (socat, port 7000).
- **The player** (`tetris_test.zig`): a tactic like Antithesis's, a piece at a time: maybe a hold
  (1 in 16), a placement among the three best the game's own projection allows
  (`tetris.placement`), some gravity ticks, maybe a nudge under an overhang (soft drops then a
  step aside), a hard drop. Every choice is a named
  decision: strategies steer them, replays repeat them. How far a game gets is guidance (`sometimes`
  over 40 lines, levels 5 and 10). No faults: what varies is the player.
- **The rules, checked after every move**: lines rise by four at most; the stack changes by whole
  pieces; a move places one piece at most and a hard drop places its piece; the stack and the
  falling piece stay on the 10x24 board; the falling piece never overlaps the stack in play; the
  score never goes down; the level is the one the lines give; no move throws.

```
determinismo explore --program zig-out/bin/tetris-test --scenario play --seed 1 --branches 16
```

## Found: one hard drop places two pieces

Every run of more than a few dozen timelines fails "a move places one piece at most" (srv3,
2026-10-29: 138 of run 112's 728 timelines; 5 drops in 96 timelines with seed 2). The failing
drops' details all read the same: the piece at the spawn row (`y_before 1`, moved left of the
centre, `x_before` 1 to 3), and after the drop a new piece at the spawn row too (`y_after 1`),
two pieces placed. `player-drop` (core.cljc) shifts the piece down until the player's `y` goes
*down*, which it takes for a new piece spawned at `y = 1`. A piece that cannot leave its spawn
row is locked at `y = 1`; the next one spawns at `y = 1` as well (away from the stack the
player built at the side, so the game goes on), the loop sees no decrease and drops it too: a
piece the player never placed, straight to the bottom. Both frontends share core.cljc: the
browser game and the jank one. A fix: loop until the piece locks (the shift down returned a
new piece), not on `y`.

The game's tracker has the symptom: djblue/tetris#7 (open since 2025-01-07), "using the space
bar to hard drop blocks, sometimes you will drop 2", put down to keyboards. This is a path in
the code that does it with one key press; #7 does not say whether its stacks were near the top,
so it may not be the only cause.

## Found: the level lags its lines

"The level is the one the lines give" fails once games clear lines (3 of 4 timelines with the
scoring player): at 5 lines the level is still 0, at 15 still 1, through the next piece's
moves. `update-score` sets the level from the lines *before* the move's clear, so it catches
up at the next shift down; in the browser game, a gravity step later. Minor, and real.

## Read in the source, not explored

- `main.jank`'s gravity, `(nth frames 0 (:level world))`, is always `frames`'s first: `nth`'s third
  argument is the default, not the index, and pieces fall as fast at every level. The harness
  leaves the frontend's timing out, so this one is not explored.

## Exploration

Random placement stacks up fast: 20 to 35 pieces a game, a line now and then. Antithesis's
quest kept, per depth bucket, the state with the best objective and went on from there. Here:

- One guidance target far away (an objective toward 1,000,000) gave nothing: guidance behaviors
  count by powers of two of the distance, and every game sat in the same one (run 102: no trend
  over 52 generations).
- Fixed rungs, "10 pieces in, 8 holes at most", were never reached (run 110).
- A guidance assertion per depth, "no holes after N pieces" (its distance the holes): each power
  of two closer at any depth is a new behavior the tree returns to. Run 112: games from 25 to
  about 30 pieces on average and lines from 0.06 to about 0.6 per game, the best 42 pieces; a
  plateau after some 16 generations.
- The player since: the harness reports where the piece would land for each rotation and
  column (`probes`: tetris.core's own projection), the player scores each landing as classic
  Tetris players are scored (Dellacherie's features, El-Tetris's weights: height, lines,
  holes, bumpiness) and a named decision picks among the best three. Its first four games:
  10 to 20 lines, level 2, about 80 pieces, where random placement cleared a line now and
  then.

## jank 0.1 (2026-10) met on the way

- No `read-line`, no `flush`: both throw ("TODO: port read-line", "TODO: port flesh"), and
  uncaught in `-main` the program segfaults instead of printing the error. The harness reads
  and flushes through `cpp/raw` C++.
- Joining what `sort` returns for an empty collection (`(clojure.string/join ";" (sort ...))`
  inside a function) segfaults; an empty board is "" in the harness.
- `jank compile -O 2` segfaulted compiling the game; the default optimization works.
