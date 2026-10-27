# SPDX-License-Identifier: MIT
# TigerBeetle 0.16.13 (2024-11), the version and release binary Jepsen's analysis (2025) started
# from, checked against its SHA-256; start.sh formats a replica's data file when there is none
# (a fresh node, or a wiped one: an operator replacing a disk), then runs the replica.
FROM docker.io/library/alpine:3.20
ARG TB_VERSION=0.16.13
ARG TB_SHA256=0fac5d72626f51d79a1b755c173fdc89c0b286df4d79c808a6b76c1616378683
RUN wget -q -O /tmp/tb.zip \
      "https://github.com/tigerbeetle/tigerbeetle/releases/download/${TB_VERSION}/tigerbeetle-x86_64-linux.zip" \
 && echo "${TB_SHA256}  /tmp/tb.zip" | sha256sum -c - \
 && unzip -q /tmp/tb.zip -d /usr/local/bin \
 && rm /tmp/tb.zip \
 && mkdir -p /data
COPY examples/tigerbeetle/start.sh /usr/local/bin/start.sh
ENTRYPOINT ["/bin/sh", "/usr/local/bin/start.sh"]
