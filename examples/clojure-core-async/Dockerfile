# SPDX-License-Identifier: MIT
# core.async under test: 1.9.865 (commit f281893) with core-async.patch (the Clojure SDK's
# assertions at its rare paths, buggify points in its race windows, alts!'s port order a platform
# decision), as a local dependency of the service (app/); the catalog agent declares every
# assertion as it loads, and the coverage agent makes each core.async line first run a new
# behavior (JDK 24+). Everything is fetched at build time: the guest has no network.
FROM docker.io/library/clojure:temurin-25-tools-deps-alpine
# C1 only: short timelines and restarted JVMs never repay C2's compiling (examples/ignite/README.md).
ENV JAVA_TOOL_OPTIONS="-XX:TieredStopAtLevel=1"
RUN apk add --no-cache git
RUN git clone --quiet https://github.com/clojure/core.async /src/core.async && \
    git -C /src/core.async checkout --quiet f281893a53a4f25cad07dd6a09af4ae9c9233a89
COPY examples/clojure-core-async/core-async.patch /src/
RUN cd /src/core.async && git apply /src/core-async.patch
WORKDIR /app
COPY sdk/java/Determinismo.java sdk/java/DeterminismoCatalog.java sdk/java/DeterminismoCoverage.java /app/java/
COPY sdk/clojure/determinismo.clj /app/src/
COPY examples/clojure-core-async/app/deps.edn /app/
COPY examples/clojure-core-async/app/async_check.clj /app/src/
RUN mkdir -p /app/classes && javac -d /app/classes /app/java/*.java && \
    printf 'Premain-Class: DeterminismoCatalog\n' > /app/catalog.manifest && \
    jar cfm /app/determinismo-catalog.jar /app/catalog.manifest -C /app/classes . && \
    printf 'Premain-Class: DeterminismoCoverage\n' > /app/coverage.manifest && \
    jar cfm /app/determinismo-coverage.jar /app/coverage.manifest -C /app/classes . && \
    clojure -P -M -m async-check && \
    echo "$(clojure -Spath):/app/classes" > /app/classpath
ENV COVERED="clojure/core/async,async_check"
ENTRYPOINT ["sh", "-c", "exec java -javaagent:/app/determinismo-catalog.jar -javaagent:/app/determinismo-coverage.jar=$COVERED -cp \"$(cat /app/classpath)\" clojure.main -m async-check"]
