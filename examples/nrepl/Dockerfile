# SPDX-License-Identifier: MIT
# An nREPL server (server/deps.edn pins the version), its dependencies fetched at build time:
# the guest has no network.
FROM docker.io/library/clojure:temurin-21-tools-deps-alpine
WORKDIR /app
COPY examples/nrepl/server/deps.edn /app/
RUN clojure -P -M:server
ENTRYPOINT ["clojure", "-M:server"]
