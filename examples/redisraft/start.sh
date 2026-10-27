#!/bin/sh
# SPDX-License-Identifier: MIT
# One Redis-Raft node: start.sh <id>. Redis with the module, its Raft log synced to /data
# (raft-log-fsync, as Jepsen ran it); the test program forms the cluster (RAFT.CLUSTER INIT on
# node 1, JOIN on the others), which the log then remembers across restarts.
set -e
id=$1
exec redis-server --port 6379 --dir /data --save "" --appendonly no --protected-mode no \
  --loadmodule /usr/lib/redisraft.so id="$id" addr="redis-$id:6379" raft-log-filename=raftlog.db \
  raft-log-fsync=yes follower-proxy=no
