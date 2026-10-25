# SPDX-License-Identifier: MIT
FROM docker.io/library/clojure:temurin-21-tools-deps-alpine
COPY sdk/java/Determinismo.java /app/sdk/
COPY examples/clojure-bank/app/bank.clj examples/clojure-bank/app/patch.sh /app/
COPY examples/clojure-bank/app/tests/ /opt/antithesis/test/v1/bank/
# The Java SDK, compiled next to the service (Clojure calls it through interop).
RUN javac -d /app/classes /app/sdk/Determinismo.java && \
    chmod +x /app/patch.sh /opt/antithesis/test/v1/bank/* && \
    (find /root/.m2/repository/org/clojure -name '*.jar' | sort; echo /app/classes) | \
    tr '\n' ':' > /app/classpath
# The service, with a socket REPL on port 5555 for debugging sessions.
ENTRYPOINT ["sh", "-c", "exec java -Dclojure.server.repl='{:port 5555 :accept clojure.core.server/repl}' -cp \"$(cat /app/classpath)\" clojure.main /app/bank.clj"]
