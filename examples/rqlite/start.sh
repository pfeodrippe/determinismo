#!/bin/sh
# SPDX-License-Identifier: MIT
# start.sh <id>: rqlite node <id> of rq-1..3, HTTP on 4001, Raft on 4002, its data in
# /rqlite/file/data (the image's). The three bootstrap together (-bootstrap-expect 3, each
# joining through the others), as rqlite's docs cluster nodes; a node with state rejoins its
# cluster from it. RQLITE_FLAGS: more flags (the `snapshots` profile's).
set -eu
id=${1:?usage: start.sh <id>}
# IPv4 (/etc/hosts): advertised addresses peers dial.
address() { awk -v name="$1" '$2 == name && $1 ~ /^[0-9.]+$/ { print $1; exit }' /etc/hosts; }
self=$(address "rq-$id")
join="$(address rq-1):4002,$(address rq-2):4002,$(address rq-3):4002"
mkdir -p /rqlite/file/data
# shellcheck disable=SC2086
exec rqlited -node-id "$id" \
  -http-addr 0.0.0.0:4001 -http-adv-addr "$self:4001" \
  -raft-addr 0.0.0.0:4002 -raft-adv-addr "$self:4002" \
  -bootstrap-expect 3 -join "$join" -join-attempts 1000 -join-interval 1s \
  ${RQLITE_FLAGS:-} /rqlite/file/data
