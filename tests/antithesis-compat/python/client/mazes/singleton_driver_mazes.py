#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Two mazes in one attempt (template "mazes"), for directed exploration: maze B's levels are as
# new to the tree as maze A's, and come after A's digits are drawn, so returning after B's
# progress never moves A on. A targeted run at A's solved line (tests/changed/mazes.diff) should
# head for A; one without direction spends its returns on both.
import determinismo as det

det.coverage_start(paths=["/opt/antithesis/"])


def digit():
    return det.random_below(10)


solved = False
if digit() == 7:
    det.reachable("mazes: A's first digit")
    if digit() == 3:
        det.reachable("mazes: A's second digit")
        if digit() == 9:
            det.reachable("mazes: A's third digit")
            if digit() == 1:
                solved = True
if digit() == 2:
    det.reachable("mazes: B's first digit")
    if digit() == 5:
        det.reachable("mazes: B's second digit")
        if digit() == 8:
            det.reachable("mazes: B's third digit")
            if digit() == 4:
                det.reachable("mazes: B solved")
det.always(not solved, "maze A is never solved")
