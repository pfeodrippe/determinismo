# SPDX-License-Identifier: MIT
# Apache Cassandra 5.0.9 (the official image), a node of three: start.sh configures it.
FROM docker.io/library/cassandra:5.0.9
COPY examples/cassandra/start.sh /usr/local/bin/cassandra-start
ENTRYPOINT ["/usr/local/bin/cassandra-start"]
