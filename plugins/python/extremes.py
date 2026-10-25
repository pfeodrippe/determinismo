#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""A learning strategy in Python: how often to push the system's own decisions to extremes.

Edge cases hide at the ends of ranges (the first account, the largest amount, a zero delay).
For each branch this strategy picks a rate (an arm) and answers that share of the test's and
services' decisions with a boundary value (0 or the maximum: `random_below(n)` then gives 0 or
n-1 ends of the range; determinismo's own processes are left alone). A UCB1 bandit learns which
rate finds the most: a branch's reward is 1 when a property fails, plus a little for event
names never seen before. It shows the shape of any learned strategy (an RL policy, a model
asked for advice): observe events, decide, get rewarded at the branch's end; its overrides are
in the tapes, so its branches replay without it.

    determinismo explore ... --strategy "python3 plugins/python/extremes.py"
"""
import math
import random
import sys

from determinismo_strategy import serve

RATES = [0.0, 0.05, 0.2, 0.5]
RUNTIME = {"det-init", "det-nodes", "det-composer", "det-faults", "det-agent"}


class Extremes:
    def __init__(self):
        self.pulls = [0] * len(RATES)
        self.rewards = [0.0] * len(RATES)
        self.seen = set()
        self.arm = 0
        self.reward = 0.0
        self.prng = random.Random(0)
        self.overrides = 0

    def branch(self, index, seed):
        self.prng = random.Random(seed)  # A branch's choices depend on its seed alone.
        self.reward = 0.0
        self.overrides = 0
        total = sum(self.pulls)
        untried = [arm for arm, count in enumerate(self.pulls) if count == 0]
        if untried:
            self.arm = untried[0]
        else:
            self.arm = max(range(len(RATES)), key=lambda arm: self.rewards[arm] / self.pulls[arm]
                           + math.sqrt(2 * math.log(total) / self.pulls[arm]))

    def random(self, pull, default, source, moment):
        if source in RUNTIME or self.prng.random() >= RATES[self.arm]:
            return None
        self.overrides += 1
        return bytes(len(default)) if self.prng.random() < 0.5 else b"\xff" * len(default)

    def event(self, event, source, moment):
        name = event.get("event") or (event.get("assert") or {}).get("message")
        if name and name not in self.seen:
            self.seen.add(name)
            self.reward += 0.1

    def branch_end(self, index, outcome, events, failing):
        reward = self.reward + (1.0 if failing else 0.0)
        self.pulls[self.arm] += 1
        self.rewards[self.arm] += reward
        print(f"[extremes] branch {index}: rate={RATES[self.arm]} overrides={self.overrides} "
              f"failing={len(failing)} reward={reward:.1f}", file=sys.stderr)
        return False


if __name__ == "__main__":
    serve(Extremes(), "extremes")
