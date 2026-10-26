# SPDX-License-Identifier: MIT
"""The plugin side of docs/PLUGINS.md for strategies written in Python (standard library only).

A strategy is an object with any of these methods; missing ones answer the default:

    hello(exploration_seed)                   once, at start (seeds are ints)
    returns(generation, candidates, count)    the tree's next moments: [(branch, vtime_ns,
                                              reason), ...]; with `wants = ["behaviors"]` each
                                              candidate has its behaviors (docs/PLUGINS.md)
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
        reply = {"name": name}
        # A strategy that only chooses where the tree returns: `decides = False` (no request per
        # decision or event); `wants = ["behaviors"]` gives `returns` each candidate's behaviors.
        if hasattr(strategy, "decides"):
            reply["decides"] = bool(strategy.decides)
        if hasattr(strategy, "wants"):
            reply["wants"] = list(strategy.wants)
        return reply
    if method == "branch":
        if hasattr(strategy, "branch"):
            arguments = [request["index"], int(request["seed"], 16)]
            # Where it starts, when the tree explorer branched it from another: {"branch", "vtime_ns"}.
            if "start" in inspect.signature(strategy.branch).parameters:
                arguments.append(request.get("from"))
            strategy.branch(*arguments)
        return {}
    if method == "returns":
        # The tree explorer's generation ended: which moments to return to (branch, vtime_ns,
        # reason), at most "count"; None leaves it to the explorer.
        if not hasattr(strategy, "returns"):
            return {}
        chosen = strategy.returns(request["generation"], request["candidates"], request["count"])
        if not chosen:
            return {}
        return {"returns": [{"branch": b, "vtime_ns": t, "reason": r} for b, t, r in chosen]}
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
        # An answer may come with why, (bytes, "reason"): shown with the decision, kept in tapes.
        reason = None
        if isinstance(answer, tuple):
            answer, reason = answer
        assert len(answer) == len(default), "an override has the default's size"
        return {"hex": answer.hex(), "reason": reason} if reason else {"hex": answer.hex()}
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
