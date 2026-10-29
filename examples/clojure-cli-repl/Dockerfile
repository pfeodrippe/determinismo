# SPDX-License-Identifier: MIT
# clojure-cli.repl's nREPL server (io.github.clojure/clojure-cli.repl-server 0.2.1) with a
# project config (app/.cljconf): port 7888 and a probe middleware; the JVM SDK's coverage agent
# on its code and nREPL's (JDK 24+: a line first run is a new behavior for the tree). Every
# dependency, the config's classpath included, is fetched at build time: the guest has no
# network.
FROM docker.io/library/clojure:temurin-25-tools-deps-alpine
# C1 only: short timelines and restarted JVMs never repay C2's compiling (examples/ignite/README.md).
ENV JAVA_TOOL_OPTIONS="-XX:TieredStopAtLevel=1"
WORKDIR /app
COPY sdk/java/Determinismo.java sdk/java/DeterminismoCoverage.java /sdk/
RUN mkdir -p /sdk/classes && javac -d /sdk/classes /sdk/*.java && \
    printf 'Premain-Class: DeterminismoCoverage\n' > /sdk/manifest && \
    jar cfm /sdk/determinismo-coverage.jar /sdk/manifest -C /sdk/classes .
COPY examples/clojure-cli-repl/app/ /app/
RUN clojure -P -M -m clojure-cli.repl.server && \
    cd .cljconf/org.clojure/clojure-cli.repl && clojure -Srepro -A:clojure-cli.repl/server -Spath
ENTRYPOINT ["clojure", "-J-javaagent:/sdk/determinismo-coverage.jar=clojure_cli,nrepl", "-M", "-m", "clojure-cli.repl.server"]
