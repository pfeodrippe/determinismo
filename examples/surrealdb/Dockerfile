# SPDX-License-Identifier: MIT
# SurrealDB 3.3.5 on TiKV v8.5.8: PD, TiKV and SurrealDB in one image (the release images'
# binaries, TiKV's image for its libraries), each node running the three, with Jepsen's PD and
# TiKV configurations (examples/tidb: regions of at most 5 keys, splitting and merging).
FROM docker.io/pingcap/tikv:v8.5.8
COPY --from=docker.io/pingcap/pd:v8.5.8 /pd-server /pd-server
COPY --from=docker.io/surrealdb/surrealdb:v3.3.5 /surreal /surreal
COPY examples/tidb/pd.toml /etc/tidb/pd.toml
COPY examples/tidb/tikv.toml /etc/tidb/tikv.toml
COPY examples/surrealdb/start /usr/local/bin/surreal-start
ENTRYPOINT ["/usr/local/bin/surreal-start"]
