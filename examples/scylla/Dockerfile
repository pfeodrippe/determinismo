# SPDX-License-Identifier: MIT
# ScyllaDB 4.2.rc3, the build of Jepsen's analysis (2020), started by start.sh with Jepsen's
# configuration (no supervisord, no JMX).
FROM docker.io/scylladb/scylla:4.2.rc3
COPY examples/scylla/start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh
ENTRYPOINT ["/usr/local/bin/start.sh"]
