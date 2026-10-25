# SPDX-License-Identifier: MIT
FROM docker.io/library/clojure:temurin-21-tools-deps-alpine
COPY sdk/java/Determinismo.java sdk/java/DeterminismoCatalog.java /app/sdk/
COPY sdk/clojure/determinismo.clj /app/src/
COPY examples/clojure-bank/app/bank.clj examples/clojure-bank/app/patch.sh /app/
# The Clojure SDK (/app/src) over the Java one, compiled next to the service, and the catalog
# agent, which declares the assertions of every class as it loads.
RUN javac -d /app/classes /app/sdk/Determinismo.java /app/sdk/DeterminismoCatalog.java && \
    printf 'Premain-Class: DeterminismoCatalog\n' > /app/manifest && \
    jar cfm /app/determinismo-catalog.jar /app/manifest -C /app/classes . && \
    chmod +x /app/patch.sh && \
    (find /root/.m2/repository/org/clojure -name '*.jar' | sort; echo /app/classes; echo /app/src) | \
    tr '\n' ':' > /app/classpath
# The service, with a socket REPL on port 5555 for debugging sessions.
ENTRYPOINT ["sh", "-c", "exec java -javaagent:/app/determinismo-catalog.jar -Dclojure.server.repl='{:port 5555 :accept clojure.core.server/repl}' -cp \"$(cat /app/classpath)\" clojure.main /app/bank.clj"]
