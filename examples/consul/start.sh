#!/bin/sh
# SPDX-License-Identifier: MIT
# start.sh <name>: Consul server <name> of c1..c3, HTTP on 8500, its data in /consul/data. The
# three bootstrap together (-bootstrap-expect 3, each joining the others), as Consul's docs
# deploy servers. Raft at production timing (raft_multiplier 1, Consul's recommendation for
# production; 5 by default, for small machines): elections within a timeline's faults.
set -eu
name=${1:?usage: start.sh <name>}
# IPv4 (/etc/hosts): the address peers dial.
address() { awk -v name="$1" '$2 == name && $1 ~ /^[0-9.]+$/ { print $1; exit }' /etc/hosts; }
self=$(address "$name")
mkdir -p /consul/data
exec consul agent -server -bootstrap-expect 3 -node "$name" -bind "$self" -client 0.0.0.0 \
  -retry-join "$(address c1)" -retry-join "$(address c2)" -retry-join "$(address c3)" \
  -data-dir /consul/data -log-level info \
  -hcl 'performance { raft_multiplier = 1 }' -hcl 'disable_update_check = true'
