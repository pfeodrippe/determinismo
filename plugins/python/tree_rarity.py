# SPDX-License-Identifier: MIT
"""The tree explorer's own choice of where to return, as a plugin: a starting point for trying
other rules without rebuilding determinismo.

    determinismo explore ... --branching tree --tape-dir <dir> \
        --strategy "python3 plugins/python/tree_rarity.py"

Every timeline of a generation is judged against what earlier generations knew. A behavior new
to the generation weighs 1 / (its timelines that reached it); a timeline scores the sum, and
the tree returns just after its rarest new behavior (latest among equals) that leaves room to go
on (its first four fifths). It makes no decisions inside timelines (`decides = False`).
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from determinismo_strategy import serve  # noqa: E402

MS = 1_000_000


class TreeRarity:
    decides = False
    wants = ["behaviors"]

    def returns(self, generation, candidates, count):
        scored = []
        for candidate in candidates:
            start, end = candidate["start_ns"], candidate["end_ns"]
            room_end = start + (end - start) // 5 * 4
            score, best, moment, label = 0.0, None, None, ""
            for behavior in candidate["behaviors"]:
                timelines = behavior["new_in_generation"]
                if timelines == 0:
                    continue  # Known before this generation.
                score += 1.0 / timelines
                if behavior["vtime_ns"] <= room_end and (best is None or timelines <= best):
                    best, moment, label = timelines, behavior["vtime_ns"], behavior["label"]
            if moment is not None and end - start >= 2 * MS:
                scored.append((-score, candidate["branch"], moment, label, best, start, end))
        scored.sort()
        chosen = []
        for _, branch, moment, label, best, start, end in scored[:count]:
            at = min(max(moment + 1000, start + MS), end - MS)
            chosen.append((branch, at, f"Just after {label}, which {best} timelines of "
                           f"generation {generation} reached first (tree_rarity.py)."))
        return chosen  # Empty: the explorer chooses.


if __name__ == "__main__":
    serve(TreeRarity(), "tree-rarity")
