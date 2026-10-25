#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# The self-test's maze in Python (template "maze"): four digits from platform randomness, each
# checked before the next is drawn; 1 in 10000 attempts solves it by chance. With line coverage
# on, a coverage-guided strategy climbs it one digit at a time.
import determinismo as det

det.coverage_start(paths=["/opt/antithesis/"])


def digit():
    return det.random_below(10)


solved = False
if digit() == 7:
    det.reachable("maze: first digit")
    if digit() == 3:
        det.reachable("maze: second digit")
        if digit() == 9:
            det.reachable("maze: third digit")
            if digit() == 1:
                solved = True
det.always(not solved, "the maze is never solved")
