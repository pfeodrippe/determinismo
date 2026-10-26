# SPDX-License-Identifier: MIT
# TiDB v8.5.8: PD, TiKV and TiDB in one image (the release images' binaries, TiKV's for its
# libraries), each node running the three as Jepsen's TiDB test does (jepsen-io/tidb), with its
# configurations.
FROM docker.io/pingcap/tikv:v8.5.8
COPY --from=docker.io/pingcap/pd:v8.5.8 /pd-server /pd-server
COPY --from=docker.io/pingcap/tidb:v8.5.8 /tidb-server /tidb-server
COPY examples/tidb/pd.toml examples/tidb/tidb.toml /etc/tidb/
COPY examples/tidb/tikv.toml /etc/tidb/tikv.toml
COPY examples/tidb/start /usr/local/bin/tidb-start
ENTRYPOINT ["/usr/local/bin/tidb-start"]
