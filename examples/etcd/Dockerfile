# SPDX-License-Identifier: MIT
# etcd v3.7.3 (2026-10-22), the release's static binaries, checked against its SHA256SUMS.
FROM docker.io/library/alpine:3.20
ARG ETCD_VERSION=v3.7.3
ARG ETCD_SHA256=5dfa9cc3b3ce3b4b491fbcc2057d3daa166bcc6676f743fcd20f8e5760cb9775
RUN wget -q -O /tmp/etcd.tar.gz \
      "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz" \
 && echo "${ETCD_SHA256}  /tmp/etcd.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/etcd.tar.gz -C /tmp \
 && mv "/tmp/etcd-${ETCD_VERSION}-linux-amd64/etcd" "/tmp/etcd-${ETCD_VERSION}-linux-amd64/etcdctl" \
      /usr/local/bin/ \
 && rm -rf /tmp/etcd*
ENTRYPOINT ["/usr/local/bin/etcd"]
