# SPDX-License-Identifier: MIT
# PostgreSQL 18.6 run by Patroni, with etcd beside it as its store (DCS): a node of a three-node
# cluster as small deployments run them, each node an etcd member and a database. etcd v3.7.3's
# static binaries, checked against its SHA256SUMS; Patroni in a virtual environment of its own.
FROM docker.io/library/postgres:18.6
ARG ETCD_VERSION=v3.7.3
ARG ETCD_SHA256=5dfa9cc3b3ce3b4b491fbcc2057d3daa166bcc6676f743fcd20f8e5760cb9775
ARG PATRONI_VERSION=4.1.0
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3-venv curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && python3 -m venv /opt/patroni \
 && /opt/patroni/bin/pip install --no-cache-dir "patroni[etcd3]==${PATRONI_VERSION}" "psycopg[binary]" \
 && curl -fsSL -o /tmp/etcd.tar.gz \
      "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz" \
 && echo "${ETCD_SHA256}  /tmp/etcd.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/etcd.tar.gz -C /tmp \
 && mv "/tmp/etcd-${ETCD_VERSION}-linux-amd64/etcd" "/tmp/etcd-${ETCD_VERSION}-linux-amd64/etcdctl" /usr/local/bin/ \
 && rm -rf /tmp/etcd*
COPY examples/patroni/start /usr/local/bin/patroni-start
ENTRYPOINT ["/usr/local/bin/patroni-start"]
