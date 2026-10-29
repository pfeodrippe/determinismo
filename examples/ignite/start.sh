#!/bin/sh
# SPDX-License-Identifier: MIT
# start.sh server <n>: Ignite node n<n> of n1..n3 (cluster port 3344, clients 10800, REST 10300),
# through the image's own entrypoint; its data in /opt/ignite/work. IGNITE_RAFT_FSYNC: whether
# table partitions' Raft logs are synced before an entry is acknowledged (Ignite's default:
# false). A small heap: three JVMs (and the client's) share the machine.
# start.sh client: the client node on port 7000.
set -eu
case "$1" in
server)
  cat > /opt/ignite/etc/determinismo.conf <<CONF
ignite {
  network {
    port = 3344
    nodeFinder {
      type = STATIC
      netClusterNodes = ["n1:3344", "n2:3344", "n3:3344"]
    }
  }
  raft {
    fsync = ${IGNITE_RAFT_FSYNC:-false}
  }
}
CONF
  export JVM_MAX_MEM=768m JVM_MIN_MEM=768m
  exec docker-entrypoint.sh --config-path /opt/ignite/etc/determinismo.conf \
    --work-dir /opt/ignite/work --node-name "n$2"
  ;;
client)
  exec /opt/java/openjdk/bin/java -Xmx256m -cp "/opt/iclient:/opt/iclient/lib/*" IClient 7000 \
    n1:10800,n2:10800,n3:10800
  ;;
esac
echo "usage: start.sh server <n> | client" >&2
exit 2
