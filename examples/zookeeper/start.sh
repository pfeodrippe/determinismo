#!/bin/sh
# SPDX-License-Identifier: MIT
# start.sh server <id>: one ZooKeeper server, myid <id>, of the ensemble zk-1..3 (static: each
# server knows the others; a quorum of two elects a leader). Its snapshots and transaction log
# in /data and /datalog (the node's disk: power losses keep what it synced; ZooKeeper syncs its
# log before acknowledging, forceSync=yes).
# start.sh client: the client node on port 7000.
set -e
case "$1" in
server)
  id=$2
  mkdir -p /conf /data /datalog
  cat > /conf/zoo.cfg <<CONF
tickTime=2000
initLimit=10
syncLimit=5
dataDir=/data
dataLogDir=/datalog
clientPort=2181
standaloneEnabled=false
admin.enableServer=false
4lw.commands.whitelist=srvr,ruok,mntr
server.1=zk-1:2888:3888;2181
server.2=zk-2:2888:3888;2181
server.3=zk-3:2888:3888;2181
CONF
  echo "$id" > /data/myid
  chown -R zookeeper:zookeeper /data /datalog /conf 2>/dev/null || true
  export ZOOCFGDIR=/conf
  # As the image's own entrypoint runs it: the zookeeper user, in the foreground.
  exec gosu zookeeper zkServer.sh start-foreground
  ;;
client)
  exec python3 /opt/zclient/zclient.py 7000
  ;;
esac
echo "usage: start.sh server <id> | client" >&2
exit 2
