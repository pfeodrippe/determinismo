# SPDX-License-Identifier: MIT
# rqlite 10.6.6 (Raft and SQLite 3.53.4, Go), three voting nodes; start.sh runs one.
FROM docker.io/rqlite/rqlite:10.6.6
# Executable as copied: the image runs as its own user, who may not chmod a root-owned file
# (the first smoke's build failed there).
COPY --chmod=755 examples/rqlite/start.sh /usr/local/bin/start.sh
ENTRYPOINT ["/usr/local/bin/start.sh"]
