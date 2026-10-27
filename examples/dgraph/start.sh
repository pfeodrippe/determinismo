#!/bin/bash
# SPDX-License-Identifier: MIT
# start.sh <index>: Dgraph node dg<index> as Jepsen's tests ran it (jepsen-io/dgraph,
# support.clj): a zero (three replicas of each group, tablets rebalanced every 10 s, the first
# node's zero the peer the others join) and an alpha joining its own node's zero. Each is started
# again when it exits (Jepsen's nemesis restarted the ones it killed); a stop ends both.
set -uo pipefail
index=${1:?usage: start.sh <index>}
self=dg$index
mkdir -p /data/zero /data/alpha

# A stop, seen by the supervising subshells too.
stopping=/tmp/start.stopping
rm -f "$stopping"
supervise() { # <name> <directory> <command...>
  local name=$1 directory=$2
  shift 2
  while [ ! -e "$stopping" ]; do
    (cd "$directory" && exec "$@")
    status=$?
    [ ! -e "$stopping" ] || break
    echo "start.sh: $name exited with status $status; starting it again"
    sleep 1 || true # A process kill may take the sleep too.
  done
}
trap 'touch "$stopping"; pkill -TERM -x dgraph; wait; exit 0' TERM INT

peer=()
[ "$index" = 1 ] || peer=(--peer dg1:5080)
supervise zero /data/zero dgraph zero --idx "$index" --my "$self:5080" --replicas 3 \
  --rebalance_interval 10s "${peer[@]}" &
supervise alpha /data/alpha dgraph alpha --lru_mb 1024 --idx "$index" --my "$self:7080" \
  --zero "$self:5080" &
wait
