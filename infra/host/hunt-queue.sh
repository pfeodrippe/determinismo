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
wait_run() { # <run id>: until it has not run for 3 minutes running (a stop and a resume, or
  # serve restarting, take seconds: not an end)
  local idle=0
  while [ $idle -lt 3 ]; do
    if running "$1"; then
      idle=0
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
for request in "$@"; do
  wait_run "$current"
  current=$(start "$request")
  echo "$(date +%H:%M) started run $current: $request"
done
wait_run "$current"
