#!/bin/bash
# SPDX-License-Identifier: MIT
# cassandra-start <node>: one Cassandra node of three (n1, n2, n3), through the image's own
# entrypoint (its CASSANDRA_* settings). Every node a seed. A small heap: three JVMs share the
# machine. CASSANDRA_COMMITLOG_SYNC: periodic (Cassandra's default, synced every 10 s) or batch
# (synced before a write is acknowledged).
set -euo pipefail
self=${1:?usage: cassandra-start <node>}
# IPv4: on a node, its own name also resolves to its link-local IPv6 address first.
address() { getent ahostsv4 "$1" | head -1 | cut -d' ' -f1; }
listen=$(address "$self")
export CASSANDRA_SEEDS="$(address n1),$(address n2),$(address n3)"
export CASSANDRA_LISTEN_ADDRESS=$listen CASSANDRA_BROADCAST_ADDRESS=$listen
export CASSANDRA_RPC_ADDRESS=$listen CASSANDRA_BROADCAST_RPC_ADDRESS=$listen
export CASSANDRA_CLUSTER_NAME=jepsen CASSANDRA_ENDPOINT_SNITCH=SimpleSnitch
export MAX_HEAP_SIZE=512M HEAP_NEWSIZE=128M
config=/etc/cassandra/cassandra.yaml
# From the shipped copy at every start: the image's entrypoint rewrites the configuration in
# place (cat over it), and a node killed during that rewrite was left with a truncated one,
# never to start again ("Missing required directive CommitLogSync", smoke run 199).
cp /etc/cassandra/cassandra.yaml.shipped "$config"
if [ "${CASSANDRA_COMMITLOG_SYNC:-periodic}" = batch ]; then
  sed -i -e 's/^commitlog_sync: periodic/commitlog_sync: batch/' -e 's/^commitlog_sync_period:/# commitlog_sync_period:/' "$config"
fi
# Accord (Cassandra 6): enabled where the configuration has it, else added.
if [ "${CASSANDRA_ACCORD:-0}" = 1 ]; then
  if grep -q '^accord:' "$config"; then
    sed -i '/^accord:/,/^[^ #]/ s/^\( *\)enabled: false/\1enabled: true/' "$config"
  else
    printf 'accord:\n  enabled: true\n' >> "$config"
  fi
fi
exec docker-entrypoint.sh cassandra -f
