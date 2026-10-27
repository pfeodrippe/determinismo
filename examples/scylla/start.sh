#!/bin/bash
# SPDX-License-Identifier: MIT
# start.sh <node>: one ScyllaDB node, configured as Jepsen's Scylla test (jepsen-io/scylla:
# resources/scylla.yaml, the settings it changes; SCYLLA_ARGS from resources/default/
# scylla-server).
# One shard (the machine's one CPU; Jepsen's nodes had two), overprovisioned (no busy polling:
# five nodes share the CPU), developer mode (no XFS, no I/O tuning), 768 MB each.
set -euo pipefail
self=${1:?usage: start.sh <node>}
nodes="n1 n2 n3 n4 n5"

# IPv4: on a node, its own name also resolves (nss myhostname) to its link-local IPv6 address,
# first, which Scylla 4.2 then looks up as an IPv4 name, forever (no nameserver to answer).
address() { getent ahostsv4 "$1" | head -1 | cut -d' ' -f1; }

# Every node a seed, itself too (Jepsen's bootstrap-seeds). Jepsen's join-seeds (every node but
# itself, after the first start) deadlock once faults take all five down together: a node not
# among its own seeds needs a live seed for its shadow round, and none ever starts again.
seeds=
for node in $nodes; do
  seeds=${seeds:+$seeds,}$(address "$node")
done
listen=$(address "$self")

cat > /etc/scylla/scylla.yaml <<YAML
cluster_name: 'jepsen'
num_tokens: 256
commitlog_sync_batch_window_in_ms: 1
commitlog_sync: batch
commitlog_segment_size_in_mb: 32
seed_provider:
    - class_name: org.apache.cassandra.locator.SimpleSeedProvider
      parameters:
          - seeds: '$seeds'
listen_address: $listen
native_transport_port: 9042
read_request_timeout_in_ms: 5000
write_request_timeout_in_ms: 2000
cas_contention_timeout_in_ms: 1000
phi_convict_threshold: 2
endpoint_snitch: SimpleSnitch
rpc_address: $listen
rpc_port: 9160
api_port: 10000
api_address: 127.0.0.1
batch_size_warn_threshold_in_kb: 5
batch_size_fail_threshold_in_kb: 50
hinted_handoff_enabled: true
partitioner: org.apache.cassandra.dht.Murmur3Partitioner
commitlog_total_space_in_mb: -1
developer_mode: true
murmur3_partitioner_ignore_msb_bits: 12
auto_bootstrap: true
ring_delay_ms: 3000
skip_wait_for_gossip_to_settle: 0
shadow_round_ms: 1000
YAML

# Supervised as the image's supervisord does (autorestart=unexpected): an exit other than 0
# starts it again. A node restarted while its seeds are down or cut off fails its shadow round
# ("Unable to gossip with any seeds") and exits 1; it starts again, as deployed. A stop goes to
# Scylla, and ends the loop.
child=0
trap 'kill -TERM $child 2>/dev/null; wait $child; exit 0' TERM INT
while true; do
  /usr/bin/scylla --options-file /etc/scylla/scylla.yaml \
    --log-to-syslog 0 --log-to-stdout 1 --default-log-level info --network-stack posix \
    --smp 1 --memory 768M --overprovisioned --developer-mode 1 &
  child=$!
  status=0
  wait $child || status=$?
  [ $status -eq 0 ] && exit 0
  echo "start.sh: scylla exited with status $status; starting it again"
  sleep 1
done
