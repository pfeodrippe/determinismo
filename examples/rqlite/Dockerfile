# SPDX-License-Identifier: MIT
# rqlite 10.6.6 (Raft and SQLite 3.53.4, Go), three voting nodes; start.sh runs one.
FROM docker.io/rqlite/rqlite:10.6.6
COPY examples/rqlite/start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh
ENTRYPOINT ["/usr/local/bin/start.sh"]
