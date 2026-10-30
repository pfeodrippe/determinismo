#!/bin/bash
# SPDX-License-Identifier: MIT
# Brings a parked host back (infra/host/park.sh's archive) on a fresh server, from your machine:
# the server set up as any new host (setup.sh: Debian, our KVM, the toolchain, the guest, the
# build, a check and serve), then the archive unpacked into the user's home, serve restarted on
# it (every parked run listed again, its events queryable), and the hunt queue left ready.
# Usage: infra/host/unpark.sh <ip> <archive> [--user <user>] [--reserved-cores N] [--skip-setup]
#   --skip-setup: the server is set up already (a second try at the unpacking).
set -euo pipefail

ip=${1:?usage: unpark.sh <ip> <archive> [--user <user>] [--reserved-cores N] [--skip-setup]}
archive=${2:?usage: unpark.sh <ip> <archive> [--user <user>] [--reserved-cores N] [--skip-setup]}
shift 2
user=det
reserved=2
setup=1
while [ $# -gt 0 ]; do
  case "$1" in
    --user) user=$2; shift 2 ;;
    --reserved-cores) reserved=$2; shift 2 ;;
    --skip-setup) setup=0; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
host="$user@$ip"
here=$(cd "$(dirname "$0")" && pwd)
zstd -t -q "$archive"
echo "== The archive is intact: $archive ($(du -h "$archive" | cut -f1))"

if [ $setup = 1 ]; then
  echo "== Setting the server up (setup.sh, about an hour: the guest kernel is built there)"
  "$here/setup.sh" "$ip" --user "$user" --reserved-cores "$reserved"
fi

echo "== Unpacking into $host's home, serve stopped meanwhile"
ssh "$host" 'sudo -n systemctl stop determinismo-serve'
zstd -dc "$archive" | ssh "$host" 'tar -C ~ -xf -'
ssh "$host" 'sudo -n systemctl start determinismo-serve; sleep 5; curl -s --max-time 60 localhost:7878/runs | python3 -c "
import json, sys
runs = json.load(sys.stdin)
print(\"serve lists %d runs\" % len(runs))"; head -3 ~/park-manifest.txt'
echo "== Back. The hunts left to run are in ~/hunts/next-list*.txt, in order (the queue's log:"
echo "~/hunts/queue-run.log says which ran). To run a list: ssh $host 'cd ~/determinismo && \\"
echo "  sudo -n systemd-run --uid=$user --unit hunts -p AllowedCPUs=<your reserved cores> \\"
echo "  infra/host/hunt-queue.sh 0 \$(grep -v \"^#\" ~/hunts/<list>)'"
echo "Runs parked from the old host keep their records and events; their tapes replay only on the"
echo "build that made them, and every new hunt starts on this one."
