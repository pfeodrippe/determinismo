#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""How well each strategy finds known bugs: the same workloads, seeds and branch budget for
every strategy, and for each run whether the bug was found and in how many timelines. Run on
the host, from the repository, after `zig build -Drelease`:

    python3 bench/strategies.py [--branches 128] [--seeds 1,2,3] [--llm tcp://127.0.0.1:9000]

`--llm` adds the LLM strategy, reached over TCP (plugins/python/serve_tcp.py on a machine where
the `claude` command is logged in, joined by an SSH tunnel).
"""
import argparse
import os
import re
import subprocess
import tempfile

HOME = os.path.expanduser("~")
MACHINE = ["--kernel", f"{HOME}/guest/vmlinuz", "--initrd", f"{HOME}/guest/base.cpio",
           "--memory-mib", "2048", "--append", "quiet", "--cache", f"{HOME}/cache"]

# (name, system arguments, the property that the bug fails or the target makes pass, wanted)
WORKLOADS = [
    ("bank: lost update", ["--program", "zig-out/bin/bank-test", "--scenario", "bank"],
     "total balance is conserved", "FAIL"),
    ("shop: stale cache", ["--program", "zig-out/bin/shop-test", "--scenario", "prices"],
     "cached prices match the database", "FAIL"),
    ("maze: digits add up", ["--program", "zig-out/bin/det-selftest", "--profile", "maze-sum",
                             "--scenario", "maze"], "maze sum: the digits add up", "PASS"),
]


def strategies(llm):
    found = [("none", None),
             ("mutate", "zig-out/bin/det-strategy-mutate --sync-dir {sync}"),
             ("extremes", "python3 plugins/python/extremes.py")]
    if llm:
        found.append(("llm", llm))
    return found


def explore(system, seed, branches, strategy):
    with tempfile.TemporaryDirectory() as sync:
        command = ["zig-out/bin/determinismo", "explore", *MACHINE, *system, "--seed", str(seed),
                   "--branches", str(branches)]
        if strategy:
            command += ["--strategy", strategy.format(sync=sync)]
        result = subprocess.run(command, capture_output=True, text=True)
        return result.stderr


def verdict(report, prop, wanted):
    """(found, timelines): whether the bug showed (or the target was reached), and in how many."""
    for line in report.splitlines():
        if prop not in line or not re.match(r"\s+(PASS|FAIL) ", line):
            continue
        status = line.split()[0]
        counts = re.search(r"failing in\s+(\d+)", line)
        failing = int(counts.group(1)) if counts else 0
        # A bug: the timelines that showed it. A target: the summary does not count them.
        return status == wanted, failing if wanted == "FAIL" else 0
    return False, 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--branches", type=int, default=128)
    parser.add_argument("--seeds", default="1,2,3")
    parser.add_argument("--llm", help="tcp://address:port of an LLM strategy")
    arguments = parser.parse_args()
    seeds = [int(seed) for seed in arguments.seeds.split(",")]
    print(f"{'workload':<22} {'strategy':<10} " + " ".join(f"seed {s:<6}" for s in seeds))
    for name, system, prop, wanted in WORKLOADS:
        for label, strategy in strategies(arguments.llm):
            cells = []
            for seed in seeds:
                found, count = verdict(explore(system, seed, arguments.branches, strategy), prop,
                                       wanted)
                cells.append(f"{'yes' if found else 'no':>3} {count:<6}")
            print(f"{name:<22} {label:<10} " + " ".join(cells), flush=True)


if __name__ == "__main__":
    main()
