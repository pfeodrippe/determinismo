#!/bin/sh
# SPDX-License-Identifier: MIT
# start.sh broker <id> [synced|format-unsynced] [flushed|unflushed] [coverage]: one KRaft node
# (broker and controller; node 4, the spare, a broker only, joining the quorum of the first
# three), its log in /data, formatted the first time (a fixed cluster id: every node the same
# cluster); `flushed` forces each write to disk before it is acknowledged
# (README: Profiles); `coverage` (Dockerfile.coverage's image) runs the broker with determinismo's
# coverage agent on its coordinators, replication and log.
# start.sh client: the client node on port 7000 (KClient), and on 7001 SClient, share groups'
# client, in the images of Kafka 4.2 and later.
set -e
case "$1" in
broker)
  id=$2
  roles=broker,controller
  listeners=PLAINTEXT://:9092,CONTROLLER://:9093
  quorum="controller.quorum.voters=1@kafka-1:9093,2@kafka-2:9093,3@kafka-3:9093"
  advertised=PLAINTEXT://kafka-$id:9092
  format_quorum=
  if [ "${KAFKA_QUORUM:-static}" = dynamic ]; then
    # A dynamic quorum (KIP-853): the three bootstrap it, with fixed directory IDs; node 4
    # (broker and controller) starts as an observer, and a driver adds it to the voters
    # (add-controller, run on it) and removes it (remove-controller).
    quorum="controller.quorum.bootstrap.servers=kafka-1:9093,kafka-2:9093,kafka-3:9093"
    advertised=PLAINTEXT://kafka-$id:9092,CONTROLLER://kafka-$id:9093
    format_quorum="--initial-controllers 1@kafka-1:9093:xbv_q-eAIgyUiVw1D1LL5g,2@kafka-2:9093:0MP0iOWxcjN47ISB--m3RA,3@kafka-3:9093:SnldpME5I_EeOBer2dBHTQ"
    [ "$id" -le 3 ] || format_quorum="--no-initial-controllers"
  else
    [ "$id" -le 3 ] || { roles=broker; listeners=PLAINTEXT://:9092; }
  fi
  cat > /tmp/server.properties <<PROPERTIES
process.roles=$roles
node.id=$id
$quorum
listeners=$listeners
advertised.listeners=$advertised
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
    # shellcheck disable=SC2086
    /opt/kafka/bin/kafka-storage.sh format -t MkU3OEVBNTcwNTJENDM2Qk -c /tmp/server.properties \
      --ignore-formatted $format_quorum > /dev/null
    # Kafka writes bootstrap.checkpoint without forcing it to disk, and reads it at every start:
    # a power loss before writeback leaves it empty and the node never starts (README). Made
    # durable here, unless asked to format as Kafka does (the format-unsynced profile).
    # The whole filesystem: 4.x's format writes its files elsewhere (no bootstrap.checkpoint
    # in /data/kafka), and a sync of a missing file failed every start.
    [ "${3:-}" = "format-unsynced" ] || sync -f /data/kafka
  fi
  export KAFKA_HEAP_OPTS="-Xms512m -Xmx512m"
  # Each source line of these classes reports itself the first time it runs (a "coverage"
  # event): the tree returns to timelines that ran new transaction code. Only the transaction
  # path: instrumenting the whole broker (kafka.server, kafka.log, ...) made it start 9 times
  # slower (15.6 s against 1.8 s of virtual time), and under faults it hardly ever served.
  # (UnifiedLog is Scala's kafka.log in 3.8.0, Java's storage module in 4.x: both named.)
  [ "${5:-}" != "coverage" ] || export KAFKA_OPTS="-javaagent:/opt/det/determinismo-coverage.jar=kafka.coordinator.transaction,org.apache.kafka.coordinator.transaction,kafka.server.ReplicaManager,kafka.cluster.Partition,kafka.log.UnifiedLog,org.apache.kafka.storage.internals.log.UnifiedLog"
  exec /opt/kafka/bin/kafka-server-start.sh /tmp/server.properties
  ;;
redpanda)
  # start.sh redpanda <id> (Dockerfile.redpanda's image): one Redpanda node of three, Kafka's
  # protocol on 9092, one shard and a gigabyte. The cluster forms from its seeds (all three: no
  # node is special, and none starts a cluster alone); its log in /var/lib/redpanda/data, synced
  # as Redpanda syncs it (by default, before acknowledging). Node 4, the spare, joins the cluster
  # later with a node ID the cluster assigns: one decommissioned is never reused, and the spare
  # joins again fresh as a new node.
  id=$2
  node_id="--node-id $id"
  [ "$id" -le 3 ] || node_id=""
  mkdir -p /etc/redpanda
  cat > /etc/redpanda/.bootstrap.yaml <<BOOTSTRAP
auto_create_topics_enabled: false
default_topic_replications: 3
default_topic_partitions: 4
transaction_coordinator_replication: 3
id_allocator_replication: 3
group_initial_rebalance_delay: 0
BOOTSTRAP
  # The image's redpanda.yaml is in developer mode, in which rpk starts Redpanda with
  # --unsafe-bypass-fsync=true: nothing synced, its durability untested (the first smoke ran so).
  # Production mode, as deployments run it.
  rpk redpanda mode production > /dev/null
  # Redpanda refuses to start after 5 crashes in a row (crash_loop_limit) until an operator
  # removes a file: faults kill brokers far more often (run 90: all three bricked so by 160 s).
  rpk redpanda config set redpanda.crash_loop_limit 1000000 > /dev/null
  # shellcheck disable=SC2086
  exec rpk redpanda start --overprovisioned --smp 1 --memory 1G --reserve-memory 0M --check=false \
    $node_id \
    --kafka-addr PLAINTEXT://0.0.0.0:9092 --advertise-kafka-addr "PLAINTEXT://kafka-$id:9092" \
    --rpc-addr 0.0.0.0:33145 --advertise-rpc-addr "kafka-$id:33145" \
    --seeds kafka-1:33145,kafka-2:33145,kafka-3:33145 \
    --set redpanda.empty_seed_starts_cluster=false
  ;;
client)
  # Share groups' client (Kafka 4.2+ images only) beside it, on 7001.
  if [ -f /opt/kclient/SClient.class ]; then
    java -Xms64m -Xmx192m -cp "/opt/kclient:/opt/kafka/libs/*" SClient 7001 \
      kafka-1:9092,kafka-2:9092,kafka-3:9092 &
  fi
  exec java -Xms128m -Xmx256m -cp "/opt/kclient:/opt/kafka/libs/*" KClient 7000 \
    kafka-1:9092,kafka-2:9092,kafka-3:9092
  ;;
esac
echo "usage: start.sh broker <id> | redpanda <id> | client" >&2
exit 2
