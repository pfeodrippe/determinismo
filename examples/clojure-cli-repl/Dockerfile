# SPDX-License-Identifier: MIT
# clojure-cli.repl's nREPL server (io.github.clojure/clojure-cli.repl-server 0.2.1) with a
# project config (app/.cljconf): port 7888 and a probe middleware. Every dependency, the config's
# classpath included, is fetched at build time: the guest has no network.
FROM docker.io/library/clojure:temurin-21-tools-deps-alpine
WORKDIR /app
COPY examples/clojure-cli-repl/app/ /app/
RUN clojure -P -M -m clojure-cli.repl.server && \
    cd .cljconf/org.clojure/clojure-cli.repl && clojure -Srepro -A:clojure-cli.repl/server -Spath
ENTRYPOINT ["clojure", "-M", "-m", "clojure-cli.repl.server"]
