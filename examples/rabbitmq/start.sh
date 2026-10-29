#!/bin/sh
# SPDX-License-Identifier: MIT
# start.sh broker <id>: one RabbitMQ node, rabbit@rabbit-<id>, of the cluster rabbit-1..3 (classic
# config peer discovery: a node with no database yet joins the first peer it reaches). Nodes
# start one after another, so every node's one peer is rabbit-1, which forms the cluster: the
# others join it. Discovery dials every peer listed, and peers not started yet held a node in
# it past its readiness wait (60 s). Its data in /var/lib/rabbitmq (the node's disk).
# start.sh broker <id> flags-synced: the feature flags file kept as an atomic replace would keep
# it (the flags-synced profile: past the feature flags finding).
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
  # RabbitMQ rewrites its feature flags file in place (truncated, written, never synced) at
  # every boot, and a power loss before it reaches the disk leaves it empty: the node never
  # boots again (README: Findings). Hunt run 100 met it in 476 of ~700 timelines, which hid
  # the rest. The flags-synced profile works it around as an atomic replace would: each new
  # content is synced and a copy kept (written aside, synced, renamed in), and a node starting
  # with an empty file gets the last good one back. (Syncing alone, within a second, was not
  # enough: a broker losing power again within a second of a restart, its smoke's 2 of 4.)
  if [ "${3:-}" = "flags-synced" ]; then
    flags=/var/lib/rabbitmq/mnesia/rabbit@rabbit-$id-feature_flags
    good=/var/lib/rabbitmq/feature_flags.good
    if [ -f "$flags" ] && [ ! -s "$flags" ] && [ -s "$good" ]; then
      cp "$good" "$flags" && sync "$flags"
    fi
    (last=; while :; do
       if [ -s "$flags" ]; then
         now=$(cksum < "$flags")
         if [ "$now" != "$last" ] && sync "$flags" && cp "$flags" "$good.tmp" && sync "$good.tmp" \
           && mv "$good.tmp" "$good" && sync -f "$good"; then
           last=$now
         fi
       fi
       sleep 0.2
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
