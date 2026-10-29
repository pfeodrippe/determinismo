#!/bin/sh
# SPDX-License-Identifier: MIT
# start.sh <id>: OpenSearch node os-<id> of the cluster os-1..3, every node cluster-manager
# eligible and a data node; the cluster bootstraps from all three. No plugins (plain HTTP on
# 9200), no index created on a write. Its data in /usr/share/opensearch/data (the node's disk;
# the translog synced before a write is acknowledged, OpenSearch's default).
set -e
id=$1
cat > /usr/share/opensearch/config/opensearch.yml <<CONF
cluster.name: determinismo
node.name: os-$id
network.host: 0.0.0.0
http.port: 9200
transport.port: 9300
discovery.seed_hosts: ["os-1", "os-2", "os-3"]
cluster.initial_cluster_manager_nodes: ["os-1", "os-2", "os-3"]
action.auto_create_index: false
CONF
export OPENSEARCH_JAVA_OPTS="-Xms512m -Xmx512m" DISABLE_INSTALL_DEMO_CONFIG=true
exec /usr/share/opensearch/bin/opensearch
