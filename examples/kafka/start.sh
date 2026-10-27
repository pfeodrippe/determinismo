#!/bin/sh
# SPDX-License-Identifier: MIT
# start.sh broker <id> [format-unsynced]: one KRaft node (broker and controller), its log in
# /data, formatted the first time (a fixed cluster id: every node the same cluster). start.sh client: the client
# node on port 7000.
set -e
case "$1" in
broker)
  id=$2
  cat > /tmp/server.properties <<PROPERTIES
process.roles=broker,controller
node.id=$id
controller.quorum.voters=1@kafka-1:9093,2@kafka-2:9093,3@kafka-3:9093
listeners=PLAINTEXT://:9092,CONTROLLER://:9093
advertised.listeners=PLAINTEXT://kafka-$id:9092
controller.listener.names=CONTROLLER
inter.broker.listener.name=PLAINTEXT
listener.security.protocol.map=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
log.dirs=/data/kafka
num.partitions=4
default.replication.factor=3
min.insync.replicas=2
offsets.topic.replication.factor=3
transaction.state.log.replication.factor=3
transaction.state.log.min.isr=2
auto.create.topics.enable=false
group.initial.rebalance.delay.ms=0
PROPERTIES
  if [ ! -f /data/kafka/meta.properties ]; then
    /opt/kafka/bin/kafka-storage.sh format -t MkU3OEVBNTcwNTJENDM2Qk -c /tmp/server.properties \
      --ignore-formatted > /dev/null
    # Kafka writes bootstrap.checkpoint without forcing it to disk, and reads it at every start:
    # a power loss before writeback leaves it empty and the node never starts (README). Made
    # durable here, unless asked to format as Kafka does (the format-unsynced profile).
    [ "${3:-}" = "format-unsynced" ] || sync /data/kafka/bootstrap.checkpoint /data/kafka
  fi
  export KAFKA_HEAP_OPTS="-Xms512m -Xmx512m"
  exec /opt/kafka/bin/kafka-server-start.sh /tmp/server.properties
  ;;
client)
  exec java -Xms128m -Xmx256m -cp "/opt/kclient:/opt/kafka/libs/*" KClient 7000 \
    kafka-1:9092,kafka-2:9092,kafka-3:9092
  ;;
esac
echo "usage: start.sh broker <id> | client" >&2
exit 2
