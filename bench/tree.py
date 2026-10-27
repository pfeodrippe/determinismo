#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""How deep the tree explorer gets, for comparing ways of choosing where to branch: the
self-test maze (four digits drawn one after the other, each right one time in ten), the same
seeds and budget for every variant, and per run how many timelines reached each digit. Run on
the host, from the repository, after `zig build -Drelease` (and det-initramfs):

    python3 bench/tree.py [--branches 400] [--seeds 1,...,8] [--strategy "python3 plugins/python/tree_rarity.py"]

Without --strategy, the explorer's own choice; with one, a plugin's `returns` (no rebuild needed to
try a rule). Means at the end: the second digit is where variants differ (2026-10-26, the
generation rarity rule: 16.6 timelines on average over seeds 1 to 8, against 14.6 before).
"""
import argparse
import os
import re
import subprocess
import tempfile

HOME = os.path.expanduser("~")
GUEST = os.environ.get("DETERMINISMO_GUEST", f"{HOME}/guest")
MACHINE = ["--kernel", f"{GUEST}/vmlinuz", "--initrd", f"{GUEST}/base.cpio",
           "--append", "quiet", "--cache", f"{HOME}/cache"]
DIGITS = ["first", "second", "third"]


def run(seed, branches, strategy, extra):
    command = ["zig-out/bin/determinismo", "explore", *MACHINE,
               "--program", "zig-out/bin/det-selftest", "--profile", "maze", "--scenario", "maze",
               "--seed", str(seed), "--branches", str(branches)]
    command += extra
    if strategy:
        tapes = tempfile.mkdtemp(prefix="tree-bench-")
        command += ["--branching", "tree", "--tape-dir", tapes, "--strategy", strategy]
    output = subprocess.run(command, capture_output=True).stderr.decode(errors="replace")
    reached = {}
    for digit in DIGITS:
        found = re.search(rf"hit in +(\d+)/\d+ branches.*maze: {digit} digit", output)
        reached[digit] = int(found.group(1)) if found else 0
    reached["solved"] = "FAIL always" in output and "never solved" in output
    return reached


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--branches", type=int, default=400)
    parser.add_argument("--seeds", default="1,2,3,4,5,6,7,8")
    parser.add_argument("--strategy")
    parser.add_argument("--explore", default="", help='more explore options: "--horizon 2s --pipeline 1"')
    arguments = parser.parse_args()
    seeds = [int(seed) for seed in arguments.seeds.split(",")]
    totals = dict.fromkeys(DIGITS, 0)
    for seed in seeds:
        reached = run(seed, arguments.branches, arguments.strategy, arguments.explore.split())
        for digit in DIGITS:
            totals[digit] += reached[digit]
        solved = "  solved" if reached["solved"] else ""
        print(f"seed {seed}: " + " ".join(f"{d}={reached[d]}" for d in DIGITS) + solved, flush=True)
    print("mean: " + " ".join(f"{d}={totals[d] / len(seeds):.1f}" for d in DIGITS))


if __name__ == "__main__":
    main()
