#!/bin/bash
# SPDX-License-Identifier: MIT
# hunt-queue.sh <run id> <request JSON, or a file of it>...: one hunt at a time. Waits for the run to
# end, then starts each request in turn through serve, waiting for each to end. A run also ends
# here once its discovery plateaus: after an hour, no new behavior over its last 100 timelines
# (or its last quarter, if more); its time budget stays the bound.
set -u
current=$1
shift
data=${DETERMINISMO_DATA:-$HOME/.determinismo}
# Running while its explorer holds the run's pid file locked (src/runs.zig): whether serve is up
# or not (the OOM killer once took serve, and the queue took that for the run's end).
running() { [ -e "$data/runs/$1/pid" ] && ! flock -n -s "$data/runs/$1/pid" true; }
plateaued() { # <run id>: exit 0 when its discovery is flat past the hour
  local started
  started=$(stat -c %Y "$data/runs/$1/request.json")
  [ $(( $(date +%s) - started )) -ge 3600 ] || return 1
  curl -s localhost:7878/runs/$1/discovery | python3 -c '
import sys, json
points = json.load(sys.stdin)["points"]
if not points: sys.exit(1)
timelines, behaviors = points[-1]
window = max(100, timelines // 4)
if timelines < window: sys.exit(1)
before = [b for t, b in points if t <= timelines - window]
sys.exit(0 if before and before[-1] == behaviors else 1)'
}
rare_said=
rare_check() { # <run id>: once it has 100 timelines, says (once) which sometimes properties
  # held in under 5% of them (report.zig's rarely_true): a workload that hardly ever got where
  # it should (Kafka's run 56 committed in 9 timelines of 508, and passed, for hours)
  [ "$rare_said" = "$1" ] && return
  local said
  said=$(curl -s --max-time 30 localhost:7878/runs/$1 | python3 -c '
import sys, json, urllib.request
run = json.load(sys.stdin)
timelines = (run.get("stats") or {}).get("timelines") or 0
if timelines < 100: sys.exit(1)
properties = json.load(urllib.request.urlopen("http://localhost:7878/runs/%d/properties" % run["id"], timeout=30))
rare = [p for p in properties if p.get("type") == "sometimes" and p.get("status") == "passing"
        and 0 < (p.get("timelines_true") or 0) and p["timelines_true"] * 20 < timelines]
print("; ".join("%s (%d of %d)" % (p["message"], p["timelines_true"], timelines) for p in rare))
' 2>/dev/null) || return
  rare_said=$1
  [ -n "$said" ] && echo "$(date +%H:%M) run $1: rarely true, the workload may hardly progress: $said"
}
budget_over() { # <run id>: exit 0 once its time budget has passed: it starts no timeline
  # more, and its last ones finish beside the next run (the CPU pool is shared): a Kafka hunt's
  # straggler ran 15 minutes past its budget on one core while the other 15 waited (run 67)
  python3 - "$data/runs/$1/request.json" <<'PY'
import json, os, sys, time, re
path = sys.argv[1]
budget = (json.load(open(path)).get("time_budget") or "")
match = re.fullmatch(r"(\d+)([smh])", budget)
if not match: sys.exit(1)
seconds = int(match[1]) * {"s": 1, "m": 60, "h": 3600}[match[2]]
sys.exit(0 if time.time() - os.stat(path).st_mtime > seconds + 60 else 1)
PY
}
wait_run() { # <run id>: until it has not run for 3 minutes running (a stop and a resume, or
  # serve restarting, take seconds: not an end), or its budget is over
  local idle=0
  while [ $idle -lt 3 ]; do
    if running "$1"; then
      idle=0
      if budget_over "$1"; then
        echo "$(date +%H:%M) run $1: its budget is over, the next starts beside its last timelines"
        return
      fi
      rare_check "$1"
      if plateaued "$1"; then
        echo "$(date +%H:%M) run $1: no new behavior lately, stopping it"
        curl -s -X POST localhost:7878/runs/$1/stop > /dev/null
      fi
    else
      idle=$((idle + 1))
    fi
    sleep 60
  done
}
start() { # <request JSON, or a file of it>: its run's id, once serve takes it (retried while
  # serve is away; what serve answered instead is logged, on stderr: run 37 waited 10 minutes
  # unexplained)
  local id="" answer body=$1
  [ -f "$body" ] && body=$(cat "$body") # A path given was sent as the request (2026-10-28).
  while [ -z "$id" ]; do
    answer=$(curl -s --max-time 120 -w "\nHTTP %{http_code}" -X POST localhost:7878/runs -d "$body")
    id=$(printf '%s' "$answer" | head -1 | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])' 2>/dev/null)
    if [ -z "$id" ]; then
      echo "$(date +%H:%M) serve did not start the run: $(printf '%s' "$answer" | tr '\n' ' ' | cut -c1-300)" >&2
      sleep 30
    fi
  done
  echo "$id"
}
summary() { # <run id>: one line of what the run found, once it is over
  curl -s --max-time 60 localhost:7878/runs/$1 | python3 -c '
import sys, json, urllib.request
run = json.load(sys.stdin)
stats = run.get("stats") or {}
properties = json.load(urllib.request.urlopen("http://localhost:7878/runs/%d/properties" % run["id"], timeout=60))
failing = ["%s (%d)" % (p["message"], p.get("timelines_failing") or 0) for p in properties if p.get("status") == "failing"]
summary = run.get("summary") or {}
busy = ", %.1f of %d workers busy" % (summary["at_once"], summary["workers"]) if summary.get("workers") else ""
# Its timelines replayed as it ran: a parted one is a determinism bug of the platform.
replays = ""
try:
    asked = json.dumps({"sql": "SELECT count(*) AS n, count(*) FILTER (WHERE same) AS same FROM replays"}).encode()
    row = json.load(urllib.request.urlopen(urllib.request.Request("http://localhost:7878/runs/%d/sql" % run["id"], data=asked), timeout=60))[0]
    replays = ", replays %d of %d the same" % (row["same"], row["n"])
except Exception:
    pass
# Good-Turing beside the plateau rule (behaviors one timeline alone reached): which would have
# stopped it, measured before either replaces the other.
timelines = stats.get("timelines") or 0
once = stats.get("behaviors_once")
behaviors = ", %d behaviors, %d by one timeline alone" % (stats.get("behaviors") or 0, once) if once is not None else ""
print("%d timelines%s%s%s, failing: %s" % (timelines, behaviors, busy, replays, "; ".join(failing) or "nothing"))
' 2>/dev/null
}
for request in "$@"; do
  wait_run "$current"
  # Any run waited for, the one given at the start too (run 196 got no line, 2026-10-29).
  [ "$current" != 0 ] && echo "$(date +%H:%M) run $current: $(summary "$current")"
  current=$(start "$request")
  echo "$(date +%H:%M) started run $current: $request"
done
wait_run "$current"
echo "$(date +%H:%M) run $current: $(summary "$current")"
