# SPDX-License-Identifier: MIT
# Apache Cassandra 5.0.9 (the official image), a node of three: start.sh configures it.
FROM docker.io/library/cassandra:5.0.9
COPY examples/cassandra/start.sh /usr/local/bin/cassandra-start
# The configuration as shipped, never written again: start.sh restores it at every start.
RUN cp /etc/cassandra/cassandra.yaml /etc/cassandra/cassandra.yaml.shipped
ENTRYPOINT ["/usr/local/bin/cassandra-start"]
