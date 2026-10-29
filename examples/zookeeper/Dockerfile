# SPDX-License-Identifier: MIT
# ZooKeeper 3.9 (the official image, its current release), three servers of one ensemble, and
# the client node: zclient.py (kazoo, ZooKeeper's Python client) behind a line protocol. One
# image; start.sh runs a server or the client.
FROM docker.io/library/zookeeper:3.9.6
RUN apt-get update -q \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends python3 python3-kazoo \
 && rm -rf /var/lib/apt/lists/*
COPY examples/zookeeper/zclient.py /opt/zclient/zclient.py
COPY examples/zookeeper/start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh
ENTRYPOINT ["/usr/local/bin/start.sh"]
