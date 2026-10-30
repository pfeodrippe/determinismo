#!/bin/bash
# SPDX-License-Identifier: MIT
# Parks a determinismo host, from your machine: its hunts stopped, what cannot be rebuilt
# archived onto this machine, and (only when asked) the server cancelled through Hetzner's Robot
# web service, with your own web service user. infra/host/unpark.sh brings it all back on a
# fresh server.
#
# Kept: every run's record, events, tapes and output (~/.determinismo, its snapshots and holders
# left out: memory images that only this build can use), serve's artifacts, the hunt requests
# and queue (~/hunts), the guest kernel and module (~/guest), the Raft POC's project
# (~/raft-poc), and the small scripts in ~/scratch. Not kept: the repository trees and the
# images, rebuilt from git and the pinned Dockerfiles by setup.sh.
#
# Usage: infra/host/park.sh <ip> <archive dir> [--user <user>] [--dry-run]
#        infra/host/park.sh --cancel <server number> <archive file>
#   --dry-run: says what it would stop and archive (and how big), changing nothing.
#   --cancel: once the archive is verified, cancels the server on Hetzner Robot. Needs
#   HETZNER_ROBOT_USER and HETZNER_ROBOT_PASSWORD (Robot: Settings, Web service and app
#   settings); shows the earliest cancellation date and asks you to type the server number.
set -euo pipefail

if [ "${1:-}" = "--cancel" ]; then
  server=${2:?usage: park.sh --cancel <server number> <archive file>}
  archive=${3:?usage: park.sh --cancel <server number> <archive file>}
  : "${HETZNER_ROBOT_USER:?set HETZNER_ROBOT_USER (a Robot web service user)}"
  : "${HETZNER_ROBOT_PASSWORD:?set HETZNER_ROBOT_PASSWORD}"
  echo "Checking the archive first: $archive"
  zstd -t -q "$archive"
  echo "  intact ($(du -h "$archive" | cut -f1))"
  robot=https://robot-ws.your-server.de
  status=$(curl -fsS -u "$HETZNER_ROBOT_USER:$HETZNER_ROBOT_PASSWORD" "$robot/server/$server/cancellation")
  echo "$status" | python3 -c '
import json, sys
c = json.load(sys.stdin)["cancellation"]
print("Server %s: cancelled %s, earliest cancellation date %s, location reservation possible %s" % (
    c.get("server_number"), c.get("cancelled"), c.get("earliest_cancellation_date"), c.get("reservation_possible")))'
  earliest=$(echo "$status" | python3 -c 'import json, sys; print(json.load(sys.stdin)["cancellation"]["earliest_cancellation_date"])')
  read -r -p "Cancel on which date (yyyy-mm-dd, or now) [$earliest]: " when
  when=${when:-$earliest}
  read -r -p "Type the server number ($server) to cancel it on $when: " typed
  [ "$typed" = "$server" ] || { echo "Not confirmed: nothing cancelled."; exit 1; }
  curl -fsS -u "$HETZNER_ROBOT_USER:$HETZNER_ROBOT_PASSWORD" -X POST "$robot/server/$server/cancellation" \
    --data-urlencode "cancellation_date=$when" --data-urlencode "reserve_location=false" \
    --data-urlencode "cancellation_reason=Parked; data archived"
  echo
  echo "Cancelled on $when. To withdraw it before then: curl -u ... -X DELETE $robot/server/$server/cancellation"
  exit 0
fi

ip=${1:?usage: park.sh <ip> <archive dir> [--user <user>] [--dry-run]}
directory=${2:?usage: park.sh <ip> <archive dir> [--user <user>] [--dry-run]}
shift 2
user=det
dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --user) user=$2; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
host="$user@$ip"
mkdir -p "$directory"
archive="$directory/determinismo-$ip-$(date +%Y%m%d-%H%M).tar.zst"

# What is kept, relative to the user's home (snapshots and holders left out below).
kept='.determinismo hunts guest raft-poc park-manifest.txt'
excluded='--exclude=.determinismo/runs/*/snapshots --exclude=.determinismo/runs/*/holders'

echo "== On $host: what runs now"
ssh "$host" 'systemctl list-units --type=service --state=active --plain --no-legend "after-*" "hunt*" "pass*" "unit*" "members*" | cut -d" " -f1
curl -s --max-time 30 localhost:7878/runs | python3 -c "
import json, sys
print(\"running runs:\", [r[\"id\"] for r in json.load(sys.stdin) if r.get(\"state\") == \"running\"] or \"none\")"'
echo "== What would be archived (before compression)"
ssh "$host" "cd ~ && du -shc $excluded $(echo $kept | sed 's/park-manifest.txt//') 2>/dev/null | tail -8; find scratch -maxdepth 1 -type f -size -1M | wc -l | sed 's/$/ small files in scratch/'"
if [ $dry = 1 ]; then
  echo "Dry run: nothing stopped or archived. The archive would be $archive."
  exit 0
fi

echo "== Stopping the hunt queue, then every running run (through serve), then serve"
ssh "$host" 'set -e
for unit in $(systemctl list-units --type=service --state=active --plain --no-legend "after-*" "hunt*" "pass*" "unit*" "members*" | cut -d" " -f1); do
  sudo -n systemctl stop "$unit"; echo "stopped $unit"
done
for id in $(curl -s --max-time 30 localhost:7878/runs | python3 -c "
import json, sys
print(\" \".join(str(r[\"id\"]) for r in json.load(sys.stdin) if r.get(\"state\") == \"running\"))"); do
  curl -s -X POST localhost:7878/runs/$id/stop > /dev/null; echo "stopping run $id"
done
for attempt in $(seq 60); do
  left=$(curl -s --max-time 30 localhost:7878/runs | python3 -c "
import json, sys
print(sum(1 for r in json.load(sys.stdin) if r.get(\"state\") == \"running\"))")
  [ "$left" = 0 ] && break
  sleep 5
done
sudo -n systemctl stop determinismo-serve
echo "serve stopped"'

echo "== A manifest of the host (what setup.sh rebuilds, for the record)"
ssh "$host" '{
  echo "parked $(date -Is) from $(hostname)"
  echo "deployed: $(git -C ~/determinismo log --oneline -1 2>/dev/null || echo "(no git: synced tree)")"
  echo "reserved cores: $(cat /etc/determinismo/reserved-cores 2>/dev/null || echo 0)"
  echo "== images"; podman images --format "{{.Repository}}:{{.Tag}} {{.Digest}}" 2>/dev/null | sort -u
  echo "== the hunt queue"; tail -20 ~/hunts/queue-run.log 2>/dev/null
} > ~/park-manifest.txt'

echo "== Archiving into $archive"
ssh "$host" "cd ~ && { find scratch -maxdepth 1 -type f -size -1M; printf '%s\n' $kept; } > /tmp/park-list && tar $excluded -cf - -T /tmp/park-list | zstd -T0 -6 -q" > "$archive.partial"
mv "$archive.partial" "$archive"
zstd -t -q "$archive"
echo "== Done: $archive ($(du -h "$archive" | cut -f1)), intact."
echo "Keep it safe (a second copy elsewhere is cheap). Then, to cancel the server:"
echo "  HETZNER_ROBOT_USER=... HETZNER_ROBOT_PASSWORD=... infra/host/park.sh --cancel <server number> $archive"
echo "To come back on a fresh server: infra/host/unpark.sh <new ip> $archive"
