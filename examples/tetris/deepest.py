# SPDX-License-Identifier: MIT
"""Where the Tetris tree returns: just after the deepest game that improved (Antithesis's
Tetris quest kept each depth bucket's best state and went on from the deepest ones).

    determinismo explore ... --program zig-out/bin/tetris-test --scenario play \
        --tape-dir <dir> --strategy "python3 examples/tetris/deepest.py"

tetris_test.zig reports, every 5 pieces, the guidance "no holes after N pieces": a timeline that
came closer to it than any before at depth N reached the behavior `closer to "no holes after N
pieces"`, and "a game clears K lines" when it cleared K. Each candidate is scored by the deepest
such improvement it made (N, then K), and the tree returns just after it, the deepest first.
Candidates that improved nothing this generation come after, by the deepest milestone they
reached at all, so that every moment the explorer asks for is a deep one: returning only to the
generation's improvements left most of each generation to fresh games (run 161, README). It
makes no decisions inside timelines.
"""
import re
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0] + "/../../plugins/python")
from determinismo_strategy import serve  # noqa: E402

MS = 1_000_000
DEPTH = re.compile(r'closer to "no holes after (\d+) pieces"')
LINES = re.compile(r'"a game clears (\d+) lines"')


def depth_of(label):
    """(pieces, lines) a behavior's label stands for; (0, 0) when neither."""
    depth = DEPTH.search(label)
    lines = LINES.search(label)
    return (int(depth.group(1)) if depth else 0, int(lines.group(1)) if lines else 0)


class Deepest:
    decides = False
    wants = ["behaviors"]

    def returns(self, generation, candidates, count):
        scored = []
        for candidate in candidates:
            start, end = candidate["start_ns"], candidate["end_ns"]
            if end - start < 2 * MS:
                continue
            new, known = None, None
            for behavior in candidate["behaviors"]:
                key = depth_of(behavior["label"])
                if key == (0, 0):
                    continue
                item = (key, behavior["vtime_ns"], behavior["label"])
                if behavior["new_in_generation"] > 0 and (new is None or key > new[0]):
                    new = item
                if known is None or key > known[0]:
                    known = item
            best = new or known
            if best is not None:
                scored.append((new is not None, best[0], candidate["branch"], best[1], best[2], start, end))
        scored.sort(reverse=True)
        chosen = []
        for improved, (depth, lines), branch, moment, label, start, end in scored[:count]:
            at = min(max(moment + 1000, start + MS), end - MS)
            why = "the deepest improvement" if improved else "the deepest reached"
            chosen.append((branch, at, f"Just after {label} (depth {depth}, lines {lines}): "
                           f"{why} of generation {generation} (deepest.py)."))
        return chosen  # Empty: the explorer chooses.


if __name__ == "__main__":
    serve(Deepest(), "tetris-deepest")
