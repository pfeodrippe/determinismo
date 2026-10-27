# SPDX-License-Identifier: MIT
# YugabyteDB 1.3.1.0-b16, the release of Jepsen's analysis (2019), its master and tablet server
# started by start.sh with Jepsen's flags.
FROM docker.io/yugabytedb/yugabyte:1.3.1.0-b16
COPY examples/yugabyte/start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh
ENTRYPOINT ["/usr/local/bin/start.sh"]
