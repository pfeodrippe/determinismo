# SPDX-License-Identifier: MIT
# The Clojure compiler and runtime under test: Clojure 1.12.6 (commit 31a3138) with clojure.patch
# (the Java SDK's assertions at their rare paths, buggify points in their race windows) and the
# SDK compiled into clojure.lang, built here with its own Maven build; the service (app/) runs
# on it, with the catalog agent declaring every assertion as its class loads. Everything is
# fetched at build time: the guest has no network.
FROM docker.io/library/clojure:temurin-25-tools-deps-alpine
# C1 only: short timelines and restarted JVMs never repay C2's compiling (examples/ignite/README.md).
ENV JAVA_TOOL_OPTIONS="-XX:TieredStopAtLevel=1"
RUN apk add --no-cache git maven
RUN git clone --quiet https://github.com/clojure/clojure /src/clojure && \
    git -C /src/clojure checkout --quiet 31a3138ab25343a619fc3734a503a48affe236d1
COPY sdk/java/Determinismo.java sdk/java/DeterminismoCatalog.java /app/sdk/
COPY sdk/clojure/determinismo.clj /app/src/
COPY examples/clojure-compiler/clojure.patch /src/
# The SDK in clojure.lang (a class in the default package cannot be called from a package).
RUN cd /src/clojure && git apply /src/clojure.patch && \
    (echo "package clojure.lang;"; cat /app/sdk/Determinismo.java) \
      > src/jvm/clojure/lang/Determinismo.java && \
    mvn --quiet -Plocal -Dmaven.test.skip=true package && cp clojure.jar /app/clojure.jar
# The catalog agent, with the SDK in its own (default) package: it finds both.
RUN javac -d /app/classes /app/sdk/Determinismo.java /app/sdk/DeterminismoCatalog.java && \
    printf 'Premain-Class: DeterminismoCatalog\n' > /app/manifest && \
    jar cfm /app/determinismo-catalog.jar /app/manifest -C /app/classes .
COPY examples/clojure-compiler/app/compiler_check.clj /app/src/
WORKDIR /app
ENTRYPOINT ["java", "-javaagent:/app/determinismo-catalog.jar", \
            "-cp", "/app/clojure.jar:/app/classes:/app/src", \
            "clojure.main", "-m", "compiler-check"]
