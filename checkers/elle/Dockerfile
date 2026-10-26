# SPDX-License-Identifier: MIT
# Elle behind an HTTP service (src/elle_service.clj), compiled ahead of time so that it starts
# quickly. Dependencies are fetched at build time: the guest has no network. The JVM sizes its
# pools as for 4 processors: with the guest's one, a pool of one thread deadlocks Elle (its
# history folds wait on tasks queued to the same pool), even on an empty history.
FROM docker.io/library/clojure:temurin-25-tools-deps-alpine
WORKDIR /app
COPY checkers/elle/deps.edn /app/
COPY checkers/elle/src/ /app/src/
RUN mkdir -p /app/classes && clojure -P && \
    echo "$(clojure -Spath)" > /app/classpath && \
    java -cp "$(cat /app/classpath)" clojure.main -e "(compile 'elle-service)"
EXPOSE 7700
ENTRYPOINT ["sh", "-c", "cd /app && exec java -XX:ActiveProcessorCount=4 -Xmx1g -cp \"$(cat /app/classpath)\" elle_service"]
