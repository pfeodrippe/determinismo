# SPDX-License-Identifier: MIT
# NATS Server v2.15.2 (2026-10-26), the release's static binary, checked against its SHA256SUMS,
# with two JetStream configurations: NATS's defaults (data flushed to disk every two minutes,
# acknowledged before) and sync.conf (flushed before every acknowledgement).
FROM docker.io/library/alpine:3.20
ARG NATS_VERSION=v2.15.2
ARG NATS_SHA256=67cb8e10bc6f0c4b47f75a728529a20953dbae2a4f9a4a52ae8517d65ae303ff
RUN wget -q -O /tmp/nats.tar.gz \
      "https://github.com/nats-io/nats-server/releases/download/${NATS_VERSION}/nats-server-${NATS_VERSION}-linux-amd64.tar.gz" \
 && echo "${NATS_SHA256}  /tmp/nats.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/nats.tar.gz -C /tmp \
 && mv "/tmp/nats-server-${NATS_VERSION}-linux-amd64/nats-server" /usr/local/bin/ \
 && rm -rf /tmp/nats* \
 && mkdir -p /etc/nats /data \
 && printf 'jetstream {\n  store_dir: /data\n}\n' > /etc/nats/default.conf \
 && printf 'jetstream {\n  store_dir: /data\n  sync_interval: always\n}\n' > /etc/nats/sync.conf
ENTRYPOINT ["/usr/local/bin/nats-server"]
