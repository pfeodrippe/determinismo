# SPDX-License-Identifier: MIT
# An nREPL server (server/deps.edn pins the version), with the JVM SDK's coverage agent on its
# code (JDK 24+: a line first run is a new behavior for strategies and the tree). Its
# dependencies are fetched at build time: the guest has no network.
FROM docker.io/library/clojure:temurin-25-tools-deps-alpine
WORKDIR /app
COPY sdk/java/Determinismo.java sdk/java/DeterminismoCoverage.java /sdk/
RUN mkdir -p /sdk/classes && javac -d /sdk/classes /sdk/*.java && \
    printf 'Premain-Class: DeterminismoCoverage\n' > /sdk/manifest && \
    jar cfm /sdk/determinismo-coverage.jar /sdk/manifest -C /sdk/classes .
COPY examples/nrepl/server/deps.edn /app/
RUN clojure -P -M:server
ENTRYPOINT ["clojure", "-J-javaagent:/sdk/determinismo-coverage.jar=nrepl", "-M:server"]
