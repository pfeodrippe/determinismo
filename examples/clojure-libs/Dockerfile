# SPDX-License-Identifier: MIT
# Clojure's most used libraries (app/deps.edn), behind one http-kit service (app/src/libs.clj),
# with the Clojure SDK over the JVM one and its catalog agent. Dependencies are fetched at build
# time: the guest has no network.
FROM docker.io/library/clojure:temurin-21-tools-deps-alpine
WORKDIR /app
COPY sdk/java/Determinismo.java sdk/java/DeterminismoCatalog.java /app/java/
COPY sdk/clojure/determinismo.clj /app/sdk/
COPY examples/clojure-libs/app/deps.edn /app/
COPY examples/clojure-libs/app/src/ /app/src/
RUN mkdir -p /app/classes && javac -d /app/classes /app/java/*.java && \
    printf 'Premain-Class: DeterminismoCatalog\n' > /app/manifest && \
    jar cfm /app/determinismo-catalog.jar /app/manifest -C /app/classes . && \
    clojure -P -M -m libs && \
    echo "$(clojure -Spath):/app/classes" > /app/classpath
ENTRYPOINT ["sh", "-c", "exec java -javaagent:/app/determinismo-catalog.jar -cp \"$(cat /app/classpath)\" clojure.main -m libs"]
