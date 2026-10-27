# SPDX-License-Identifier: MIT
# Dgraph v1.1.1, the release of Jepsen's analysis (2020): each node a zero and an alpha, started
# by start.sh with Jepsen's flags.
FROM docker.io/dgraph/dgraph:v1.1.1
COPY examples/dgraph/start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh
ENTRYPOINT ["/usr/local/bin/start.sh"]
