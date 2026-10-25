#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""A strategy that asks a language model where to put faults: Claude Haiku 5.5, through the
`claude` command line (Claude Code), so it runs wherever Claude Code is logged in.

Every few branches it shows the model what the last ones did (the faults chosen, by name, the
assertions that failed or came close, the properties still never reached) and the decisions it
can steer (the labeled ones: `fault` among named faults, `fault.wait_ns`, `fault.duration_ns`,
and any the system names through the SDK's `decide`). The model answers a plan: which options
to favor, and whether waits and durations should be short or long. Until the next consultation
the strategy answers labeled decisions from the plan (with some randomness, so branches still
differ) and leaves the rest to their defaults. Its answers are in the branches' tapes, so a
branch replays without it, and without the model.

    determinismo explore ... --strategy "python3 plugins/python/llm.py"
    determinismo explore ... --strategy "python3 plugins/python/llm.py --every 4 --model claude-haiku-5-5"
"""
import argparse
import json
import random
import subprocess
import sys

from determinismo_strategy import serve


class Llm:
    def __init__(self, every, model):
        self.every = every
        self.model = model
        self.plan = {}  # Decision name -> {"favor": [option names]} or {"scale": "short"|"long"}
        self.options = {}  # Decision name -> its options (or its range), as last seen.
        self.history = []  # One summary per finished branch.
        self.branch_faults = []
        self.branch_failing = []
        self.near = {}  # Guidance: message -> smallest distance seen.
        self.prng = random.Random(0)

    def branch(self, index, seed):
        self.prng = random.Random(seed)
        self.branch_faults = []
        if index > 0 and index % self.every == 0 and self.options:
            self.consult()

    def random(self, pull, default, source, moment, decision=None):
        if not decision:
            return None
        name = decision.get("name", "")
        size = len(default)
        if "options" in decision:
            options = decision["options"]
            self.options[name] = options
            favored = [i for i, option in enumerate(options)
                       if option in self.plan.get(name, {}).get("favor", [])]
            if favored and self.prng.random() < 0.8:
                index = self.prng.choice(favored)
                if name == "fault":
                    self.branch_faults.append(options[index])
                return index.to_bytes(8, "little")[:size].ljust(size, b"\0")
            return None
        if "range" in decision:
            count = int(decision["range"])
            self.options[name] = {"range": count}
            scale = self.plan.get(name, {}).get("scale")
            if count <= 0 or scale not in ("short", "long"):
                return None
            low, high = (0, count // 4) if scale == "short" else (3 * count // 4, count)
            value = self.prng.randrange(low, max(high, low + 1))
            return value.to_bytes(8, "little")[:size].ljust(size, b"\0")
        return None

    def event(self, event, source, moment):
        guidance = event.get("guidance")
        if guidance:
            message, distance = guidance.get("message"), guidance.get("distance", 0)
            self.near[message] = min(self.near.get(message, distance), distance)

    def branch_end(self, index, outcome, events, failing):
        self.history.append({"branch": index, "faults": self.branch_faults[:20],
                             "failing": failing, "outcome": outcome})
        self.history = self.history[-32:]
        return False

    def consult(self):
        steerable = {name: (options if isinstance(options, dict) else options[:60])
                     for name, options in self.options.items()}
        prompt = (
            "You steer a deterministic simulation test of a distributed system. Each branch is a "
            "timeline; you choose which faults the injector favors and how long waits and "
            "durations are, to make the system's properties fail (find bugs).\n"
            f"Decisions you can steer (name -> options, or a numeric range):\n"
            f"{json.dumps(steerable)}\n"
            f"Recent branches (faults favored, properties that failed):\n"
            f"{json.dumps(self.history[-16:])}\n"
            f"Assertions' closest distance to failing (lower is closer):\n"
            f"{json.dumps(self.near)}\n"
            "Answer with JSON only, no prose: {\"<decision name>\": {\"favor\": [<option names>]} "
            "or {\"scale\": \"short\"|\"long\"}, ...}. Favor what you expect to break things, and "
            "try something different when recent branches found nothing.")
        try:
            result = subprocess.run(["claude", "-p", "--model", self.model, prompt],
                                    capture_output=True, text=True, timeout=120)
            text = result.stdout.strip()
            start, end = text.find("{"), text.rfind("}")
            plan = json.loads(text[start:end + 1])
            if isinstance(plan, dict):
                self.plan = plan
                print(f"[llm] plan: {json.dumps(plan)[:300]}", file=sys.stderr)
        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
            print(f"[llm] no plan this time: {error}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--every", type=int, default=8, help="branches between consultations")
    parser.add_argument("--model", default="claude-haiku-5-5")
    arguments = parser.parse_args()
    serve(Llm(arguments.every, arguments.model), "llm")


if __name__ == "__main__":
    main()
