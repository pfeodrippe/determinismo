#!/bin/sh
# SPDX-License-Identifier: MIT
# start.sh broker <id>: one RabbitMQ node, rabbit@rabbit-<id>, of the cluster rabbit-1..3 (classic
# config peer discovery: a node with no database yet joins the first peer it reaches). Nodes
# start one after another, so every node's one peer is rabbit-1, which forms the cluster: the
# others join it. Discovery dials every peer listed, and peers not started yet held a node in
# it past its readiness wait (60 s). Its data in /var/lib/rabbitmq (the node's disk).
# start.sh broker <id> flags-unsynced: RabbitMQ's feature_flags file as RabbitMQ leaves it.
# start.sh client: the client node on port 7000.
set -e
case "$1" in
broker)
  id=$2
  mkdir -p /etc/rabbitmq /var/lib/rabbitmq
  cat > /etc/rabbitmq/rabbitmq.conf <<CONF
cluster_formation.peer_discovery_backend = classic_config
cluster_formation.classic_config.nodes.1 = rabbit@rabbit-1
cluster_formation.discovery_retry_limit = 10
cluster_formation.discovery_retry_interval = 1000
loopback_users = none
listeners.tcp.default = 5672
CONF
  # The Erlang cookie every node shares (owner-only, or the node refuses it).
  printf 'determinismo-rabbitmq-cookie' > /var/lib/rabbitmq/.erlang.cookie
  chmod 600 /var/lib/rabbitmq/.erlang.cookie
  chown -R rabbitmq:rabbitmq /var/lib/rabbitmq 2>/dev/null || true
  export RABBITMQ_NODENAME=rabbit@rabbit-$id HOME=/var/lib/rabbitmq
  # RabbitMQ writes its feature_flags file without syncing it, and a power loss before the
  # kernel writes it back leaves it empty: the node never boots again (README: Findings). The
  # guest writes nothing back unasked, so in nearly every timeline the cluster bricked itself
  # and hid the rest. Unless asked to keep RabbitMQ's behavior (`flags-unsynced`), the file is
  # synced within a second of each change, as a host's writeback would within 30 s.
  if [ "${3:-flags-synced}" != "flags-unsynced" ]; then
    flags=/var/lib/rabbitmq/mnesia/rabbit@rabbit-$id-feature_flags
    (last=; while :; do
       now=$(stat -c %Y.%s "$flags" 2>/dev/null) || now=
       if [ -n "$now" ] && [ "$now" != "$last" ] && sync "$flags"; then last=$now; fi
       sleep 1
     done) &
  fi
  # As the image's own entrypoint runs it: the rabbitmq user.
  exec gosu rabbitmq rabbitmq-server
  ;;
client)
  exec python3 /opt/rclient/rclient.py 7000
  ;;
esac
echo "usage: start.sh broker <id> | client" >&2
exit 2
