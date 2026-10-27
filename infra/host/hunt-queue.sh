#!/bin/bash
# SPDX-License-Identifier: MIT# hunt-queue.sh <run id> <request JSON>...: srv2 runs one hunt at a time. Waits for the run to
# end, then starts each request in turn through serve, waiting for each to end. A run also ends
# here once its discovery plateaus: after an hour, no new behavior over its last 100 timelines
# (or its last quarter, if more); its time budget stays the bound.
set -u
current=$1
shift
running() { curl -s localhost:7878/runs/$1 | grep -q '"state":"running"'; }
plateaued() { # <run id>: exit 0 when its discovery is flat past the hour
  local started
  started=$(stat -c %Y ${DETERMINISMO_DATA:-$HOME/.determinismo}/runs/$1/request.json)
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
wait_run() { # <run id>
  while running "$1"; do
    if plateaued "$1"; then
      echo "$(date +%H:%M) run $1: no new behavior lately, stopping it"
      curl -s -X POST localhost:7878/runs/$1/stop > /dev/null
    fi
    sleep 60
  done
}
for request in "$@"; do
  wait_run "$current"
  current=$(curl -s -X POST localhost:7878/runs -d "$request" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
  echo "$(date +%H:%M) started run $current: $request"
done
wait_run "$current"
