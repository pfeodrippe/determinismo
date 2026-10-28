#!/bin/bash
# SPDX-License-Identifier: MIT
# start.sh <node>: a YugabyteDB node as Jepsen's YSQL tests ran it (jepsen-io/jepsen yugabyte,
# auto.clj): a master (one of three, replication factor 3, the initial system catalog snapshot)
# and a tablet server with YSQL's PostgreSQL proxy on 5433. Each is started again when it exits
# (as Jepsen's nemesis restarted killed ones; a kill of every master is how it found #2125). A
# stop ends both. A tablet server gets 1 GB, a master 512 MB (Jepsen's 2 GB each: three nodes
# share the machine; with 1 GB masters too, long timelines ended in the kernel's OOM kills of
# postgres backends, 22 of run 18's 215 on srv3).
set -uo pipefail
self=${1:?usage: start.sh <node>}
nodes="yb1 yb2 yb3"
bin=/home/yugabyte/bin

# IPv4: on a node, its own name also resolves (nss myhostname) to its link-local IPv6 address.
address() { getent ahostsv4 "$1" | head -1 | cut -d' ' -f1; }
ip=$(address "$self")
masters=
for node in $nodes; do masters=${masters:+$masters,}$(address "$node"):7100; done
mkdir -p /data/master /data/tserver
common=(--yb_num_shards_per_tserver 4 --logtostderr --minloglevel 1)

# A stop, seen by the supervising subshells too.
stopping=/tmp/start.stopping
rm -f "$stopping"
supervise() { # <name> <command...>
  local name=$1
  shift
  while [ ! -e "$stopping" ]; do
    "$@"
    status=$?
    [ ! -e "$stopping" ] || break
    echo "start.sh: $name exited with status $status; starting it again"
    sleep 1 || true # A process kill may take the sleep too.
  done
}
trap 'touch "$stopping"; pkill -TERM -x yb-master; pkill -TERM -x yb-tserver; wait; exit 0' TERM INT

supervise master "$bin/yb-master" --master_addresses "$masters" --rpc_bind_addresses "$ip:7100" \
  --fs_data_dirs /data/master --replication_factor 3 --use_initial_sys_catalog_snapshot \
  --load_balancer_max_concurrent_adds 10 --memory_limit_hard_bytes 536870912 "${common[@]}" &
supervise tserver "$bin/yb-tserver" --tserver_master_addrs "$masters" --rpc_bind_addresses "$ip:9100" \
  --fs_data_dirs /data/tserver --start_pgsql_proxy --pgsql_proxy_bind_address "$ip:5433" \
  --rpc_slow_query_threshold_ms 1000 --memory_limit_hard_bytes 1073741824 "${common[@]}" &
wait
