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
keeper)
  # ClickHouse Keeper, server <id> of zk-1..3 (Raft between them on 9234, clients on 2181; its
  # log synced before a write is acknowledged, force_sync, its default).
  id=$2
  mkdir -p /etc/clickhouse-keeper /var/lib/clickhouse/coordination/log /var/lib/clickhouse/coordination/snapshots
  cat > /etc/clickhouse-keeper/keeper_config.xml <<CONF
<clickhouse>
  <logger><level>information</level><console>1</console></logger>
  <listen_host>0.0.0.0</listen_host>
  <keeper_server>
    <tcp_port>2181</tcp_port>
    <server_id>$id</server_id>
    <log_storage_path>/var/lib/clickhouse/coordination/log</log_storage_path>
    <snapshot_storage_path>/var/lib/clickhouse/coordination/snapshots</snapshot_storage_path>
    <four_letter_word_white_list>srvr,ruok,mntr</four_letter_word_white_list>
    <coordination_settings>
      <operation_timeout_ms>10000</operation_timeout_ms>
      <session_timeout_ms>30000</session_timeout_ms>
      <raft_logs_level>information</raft_logs_level>
    </coordination_settings>
    <raft_configuration>
      <server><id>1</id><hostname>zk-1</hostname><port>9234</port></server>
      <server><id>2</id><hostname>zk-2</hostname><port>9234</port></server>
      <server><id>3</id><hostname>zk-3</hostname><port>9234</port></server>
    </raft_configuration>
  </keeper_server>
</clickhouse>
CONF
  exec clickhouse-keeper --config-file=/etc/clickhouse-keeper/keeper_config.xml
  ;;
client)
  exec python3 /opt/zclient/zclient.py 7000
  ;;
esac
echo "usage: start.sh server <id> | keeper <id> | client" >&2
exit 2
