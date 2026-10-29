# SPDX-License-Identifier: MIT
# Clojure's most used libraries (app/deps.edn), behind one http-kit service (app/src/libs.clj),
# with the Clojure SDK over the JVM one, its catalog agent, and its coverage agent on the
# libraries' code (JDK 24+: a line first run is a new behavior for strategies and the tree).
# Dependencies are fetched at build time: the guest has no network.
FROM docker.io/library/clojure:temurin-25-tools-deps-alpine
# C1 only: short timelines and restarted JVMs never repay C2's compiling (examples/ignite/README.md).
ENV JAVA_TOOL_OPTIONS="-XX:TieredStopAtLevel=1"
WORKDIR /app
COPY sdk/java/Determinismo.java sdk/java/DeterminismoCatalog.java sdk/java/DeterminismoCoverage.java /app/java/
COPY sdk/clojure/determinismo.clj /app/sdk/
COPY examples/clojure-libs/app/deps.edn /app/
COPY examples/clojure-libs/app/src/ /app/src/
RUN mkdir -p /app/classes && javac -d /app/classes /app/java/*.java && \
    printf 'Premain-Class: DeterminismoCatalog\n' > /app/catalog.manifest && \
    jar cfm /app/determinismo-catalog.jar /app/catalog.manifest -C /app/classes . && \
    printf 'Premain-Class: DeterminismoCoverage\n' > /app/coverage.manifest && \
    jar cfm /app/determinismo-coverage.jar /app/coverage.manifest -C /app/classes . && \
    clojure -P -M -m libs && \
    echo "$(clojure -Spath):/app/classes" > /app/classpath
ENV COVERED="clojure/core/async,manifold,cheshire,jsonista,clojure/data/json,taoensso/nippy,clj_yaml,malli,org/httpkit,libs"
ENTRYPOINT ["sh", "-c", "exec java -javaagent:/app/determinismo-catalog.jar -javaagent:/app/determinismo-coverage.jar=$COVERED -cp \"$(cat /app/classpath)\" clojure.main -m libs"]
