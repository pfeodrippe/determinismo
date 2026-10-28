#!/bin/sh
# SPDX-License-Identifier: MIT
# start.sh broker <id> [synced|format-unsynced] [flushed|unflushed] [coverage]: one KRaft node
# (broker and controller), its log in /data, formatted the first time (a fixed cluster id: every
# node the same cluster); `flushed` forces each write to disk before it is acknowledged
# (README: Profiles); `coverage` (Dockerfile.coverage's image) runs the broker with determinismo's
# coverage agent on its coordinators, replication and log.
# start.sh client: the client node on port 7000.
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
  # Kafka leaves its log to the kernel's writeback (30 s) and counts on replicas: a power loss of
  # every replica within that window loses what they acknowledged, by design. Flushed, each write
  # is on disk before it counts.
  [ "${4:-flushed}" = "unflushed" ] || echo "log.flush.interval.messages=1" >> /tmp/server.properties
  if [ ! -f /data/kafka/meta.properties ]; then
    /opt/kafka/bin/kafka-storage.sh format -t MkU3OEVBNTcwNTJENDM2Qk -c /tmp/server.properties \
      --ignore-formatted > /dev/null
    # Kafka writes bootstrap.checkpoint without forcing it to disk, and reads it at every start:
    # a power loss before writeback leaves it empty and the node never starts (README). Made
    # durable here, unless asked to format as Kafka does (the format-unsynced profile).
    [ "${3:-}" = "format-unsynced" ] || sync /data/kafka/bootstrap.checkpoint /data/kafka
  fi
  export KAFKA_HEAP_OPTS="-Xms512m -Xmx512m"
  # Each source line of these classes reports itself the first time it runs (a "coverage"
  # event): the tree returns to timelines that ran new transaction code. Only the transaction
  # path: instrumenting the whole broker (kafka.server, kafka.log, ...) made it start 9 times
  # slower (15.6 s against 1.8 s of virtual time), and under faults it hardly ever served.
  [ "${5:-}" != "coverage" ] || export KAFKA_OPTS="-javaagent:/opt/det/determinismo-coverage.jar=kafka.coordinator.transaction,org.apache.kafka.coordinator.transaction,kafka.server.ReplicaManager,kafka.cluster.Partition,kafka.log.UnifiedLog"
  exec /opt/kafka/bin/kafka-server-start.sh /tmp/server.properties
  ;;
client)
  exec java -Xms128m -Xmx256m -cp "/opt/kclient:/opt/kafka/libs/*" KClient 7000 \
    kafka-1:9092,kafka-2:9092,kafka-3:9092
  ;;
esac
echo "usage: start.sh broker <id> | client" >&2
exit 2
