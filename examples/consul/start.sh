#!/bin/sh
# SPDX-License-Identifier: MIT
# start.sh <name>: Consul server <name> of c1..c4, HTTP on 8500, its data in /consul/data. The
# first three bootstrap together (-bootstrap-expect 3, each joining the others), as Consul's
# docs deploy servers; c4, the spare, joins the cluster they formed when a driver starts it. Raft at production timing (raft_multiplier 1, Consul's recommendation for
# production; 5 by default, for small machines): elections within a timeline's faults.
set -eu
name=${1:?usage: start.sh <name>}
# IPv4 (/etc/hosts): the address peers dial.
address() { awk -v name="$1" '$2 == name && $1 ~ /^[0-9.]+$/ { print $1; exit }' /etc/hosts; }
self=$(address "$name")
mkdir -p /consul/data
# Its node ID given, never written: Consul writes /consul/data/node-id unsynced at its first
# boot, so a power loss soon after leaves it empty and the server refusing every boot after
# (hashicorp/consul#3489, open since 2017; every smoke timeline here met it).
node_id=$(printf '00000000-0000-4000-8000-%012d' "${name#c}")
bootstrap="-bootstrap-expect 3"
[ "${name#c}" -le 3 ] || bootstrap=""
# shellcheck disable=SC2086
exec consul agent -server $bootstrap -node "$name" -node-id "$node_id" -bind "$self" -client 0.0.0.0 \
  -retry-join "$(address c1)" -retry-join "$(address c2)" -retry-join "$(address c3)" \
  -data-dir /consul/data -log-level info \
  -hcl 'performance { raft_multiplier = 1 }' -hcl 'disable_update_check = true'
