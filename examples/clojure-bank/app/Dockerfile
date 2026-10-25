# SPDX-License-Identifier: MIT
FROM docker.io/library/clojure:temurin-21-tools-deps-alpine
COPY bank.clj patch.sh /app/
COPY tests/ /opt/antithesis/test/v1/bank/
RUN chmod +x /app/patch.sh /opt/antithesis/test/v1/bank/* && \
    find /root/.m2/repository/org/clojure -name '*.jar' | sort | tr '\n' ':' > /app/classpath
# The service, with a socket REPL on port 5555 for debugging sessions.
ENTRYPOINT ["sh", "-c", "exec java -Dclojure.server.repl='{:port 5555 :accept clojure.core.server/repl}' -cp \"$(cat /app/classpath)\" clojure.main /app/bank.clj"]
