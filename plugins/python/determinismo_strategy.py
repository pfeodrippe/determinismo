# SPDX-License-Identifier: MIT
"""The plugin side of docs/PLUGINS.md for strategies written in Python (standard library only).

A strategy is an object with any of these methods; missing ones answer the default:

    hello(exploration_seed)                   once, at start (seeds are ints)
    branch(index, seed)                       before each branch
    random(pull, default, source, moment[, decision])
                                              a decision: return bytes to override, or None;
                                              `decision` is its label when the guest named it
                                              ({"name", "options"} or {"name", "range"})
    event(event, source, moment)              a guest event (a dict)
    branch_end(index, outcome, events, failing)   return True to stop the exploration

`default` is the bytes the branch would get; `source` is the asking process's name; `moment`
is (vtime_ns, branches). Run it with `serve(strategy)`; anything printed to stderr reaches the
user, stdout is the protocol.
"""
import inspect
import json
import sys


def serve(strategy, name):
    out = sys.stdout
    for line in sys.stdin:
        request = json.loads(line)
        reply = _dispatch(strategy, name, request)
        out.write(json.dumps(reply, separators=(",", ":")) + "\n")
        out.flush()


def _dispatch(strategy, name, request):
    method = request["method"]
    moment = (request.get("vtime_ns", 0), request.get("branches", 0))
    if method == "hello":
        if hasattr(strategy, "hello"):
            strategy.hello(int(request["exploration_seed"], 16))
        return {"name": name}
    if method == "branch":
        if hasattr(strategy, "branch"):
            strategy.branch(request["index"], int(request["seed"], 16))
        return {}
    if method == "random":
        if not hasattr(strategy, "random"):
            return {}
        default = bytes.fromhex(request["default"])
        arguments = [request["pull"], default, request.get("source", ""), moment]
        if "decision" in inspect.signature(strategy.random).parameters:
            arguments.append(request.get("decision"))
        answer = strategy.random(*arguments)
        if answer is None:
            return {}
        assert len(answer) == len(default), "an override has the default's size"
        return {"hex": answer.hex()}
    if method == "event":
        if hasattr(strategy, "event"):
            strategy.event(request["event"], request.get("source", ""), moment)
        return {}
    if method == "branch_end":
        stop = False
        if hasattr(strategy, "branch_end"):
            stop = bool(strategy.branch_end(request["index"], request["outcome"],
                                            request["events"], request["failing"]))
        return {"stop": True} if stop else {}
    raise ValueError(f"unknown method {method}")
