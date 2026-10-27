#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""How fast each way of exploring finds known bugs: one variant at a time (the whole host's CPUs),
the same seeds and wall-time budget for each, and per run when each target property first failed
(wall seconds, and how many timelines had finished), with how the exploration branched (timelines
from a moment, their depth). Run on the host, from the repository, after `zig build -Drelease`:

    python3 bench/explore.py --workload raft --budget 20m --seeds 1,2 \\
        --variant tree= --variant archive="--archive --pipeline 1" \\
        --variant clj-rarity="--pipeline 1 @rarity"

A variant is explore options; `@<name>` runs the Clojure strategy of that name (plugins/clojure/
strategies.clj, started here if its control port does not answer). Results are appended as JSON
lines to bench/explore-results.jsonl.
"""
import argparse
import json
import os
import re
import socket
import subprocess
import tempfile
import time

HOME = os.path.expanduser("~")
GUEST = os.environ.get("DETERMINISMO_GUEST", f"{HOME}/guest")
MACHINE = ["--kernel", f"{GUEST}/vmlinuz", "--initrd", f"{GUEST}/base.cpio", "--append", "quiet",
           "--cache", f"{HOME}/cache", "--memory-mib", "4096"]
RAFT = f"{HOME}/raft-poc/antithesis/config/docker-compose.yaml"

# (system arguments, target properties: the known bugs, by a prefix of their message)
WORKLOADS = {
    # As serve's runs of it (run 93): CPU modulation with the faults, as Antithesis does.
    "raft": (["--compose", RAFT, "--scenario", "raft", "--faults", "+restart,+stop,+crash",
              "--no-faults", "raft-client,raft-monitor", "--retroactive", "Applied block",
              "--cpu-modulation"],
             ["[workload-commit-progress]", "[log-matching]", "[fsm-convergence] cluster failed",
              "[election-safety]", "[leader-completeness]"]),
    "maze": (["--program", "zig-out/bin/det-selftest", "--profile", "maze", "--scenario", "maze"],
             ["the maze is never solved"]),
    "nats": (["--program", "zig-out/bin/nats-test", "--profile", "jepsen", "--scenario", "queue"],
             ["every acknowledged publish is read back", "no two acknowledged messages"]),
}
STRATEGY_PORT, CONTROL_PORT = 9100, 9101
BRANCH = re.compile(r"^\[branch +(\d+)\] .*failing=(\d+)(.*)$")


def control(command):
    with socket.create_connection(("127.0.0.1", CONTROL_PORT), timeout=5) as connection:
        connection.sendall((command + "\n").encode())
        return connection.makefile().readline().strip()


def strategies_ready(bb):
    try:
        control("reset")
        return None
    except OSError:
        host = subprocess.Popen([bb, "plugins/clojure/strategies.clj", "--port", str(STRATEGY_PORT),
                                 "--control", str(CONTROL_PORT)], stdout=subprocess.DEVNULL)
        for _ in range(100):
            time.sleep(0.2)
            try:
                control("reset")
                return host
            except OSError:
                continue
        raise SystemExit("the Clojure strategies did not start")


def run(workload, seed, budget, options, bb):
    system, targets = WORKLOADS[workload]
    record = tempfile.mktemp(suffix=".jsonl", prefix="explore-bench-")
    command = ["zig-out/bin/determinismo", "explore", *MACHINE, *system, "--seed", str(seed),
               "--time-budget", budget, "--record", record]  # As many as fit in the budget.
    strategy = [option[1:] for option in options if option.startswith("@")]
    command += [option for option in options if not option.startswith("@")]
    if strategy:
        strategies_ready(bb)
        assert control(f"use {strategy[0]}") == "ok", strategy[0]
        command += ["--strategy", f"tcp://127.0.0.1:{STRATEGY_PORT}",
                    "--tape-dir", tempfile.mkdtemp(prefix="explore-bench-tapes-")]
    start = time.monotonic()
    found = {}
    timelines = 0
    process = subprocess.Popen(command, stderr=subprocess.PIPE, text=True, errors="replace")
    for line in process.stderr:
        match = BRANCH.match(line)
        if not match:
            continue
        timelines += 1
        for target in targets:
            if target not in found and f'FAIL "{target}' in match.group(3):
                found[target] = {"wall_s": round(time.monotonic() - start, 1), "timelines": timelines,
                                 "branch": int(match.group(1))}
    process.wait()
    if process.returncode not in (0, 3):  # 3: properties failed, as expected.
        print(f"explore exited with {process.returncode}: {' '.join(command)}", flush=True)
    rows = []
    if os.path.exists(record):
        with open(record) as lines:
            rows = [json.loads(line)["branch"] for line in lines if '"branch"' in line]
    depths = [len(row.get("path") or []) for row in rows]
    return {
        "workload": workload, "seed": seed, "budget": budget, "options": " ".join(options),
        "timelines": len(rows), "from_moment": sum(1 for depth in depths if depth > 0),
        "depth_max": max(depths, default=0),
        "vtime_mean_s": round(sum(row["vtime_ns"] for row in rows) / max(1, len(rows)) / 1e9, 1),
        "found": found,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--workload", default="raft", choices=sorted(WORKLOADS))
    parser.add_argument("--budget", default="20m")
    parser.add_argument("--seeds", default="1,2")
    parser.add_argument("--variant", action="append", default=[],
                        help='name=explore options, e.g. archive="--archive --pipeline 1"')
    parser.add_argument("--bb", default=f"{HOME}/opt/bb/bb")
    arguments = parser.parse_args()
    variants = [variant.split("=", 1) for variant in arguments.variant] or [["tree", ""]]
    for name, options in variants:
        for seed in [int(seed) for seed in arguments.seeds.split(",")]:
            result = run(arguments.workload, seed, arguments.budget, options.split(), arguments.bb)
            result["variant"] = name
            with open("bench/explore-results.jsonl", "a") as out:
                out.write(json.dumps(result) + "\n")
            found = ", ".join(f"{target} at {hit['wall_s']}s (#{hit['timelines']})"
                              for target, hit in result["found"].items()) or "nothing"
            print(f"{name} seed {seed}: {result['timelines']} timelines, {result['from_moment']} from "
                  f"moments, depth {result['depth_max']}, {result['vtime_mean_s']}s mean; found {found}",
                  flush=True)


if __name__ == "__main__":
    main()
