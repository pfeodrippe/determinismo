# SPDX-License-Identifier: MIT
FROM docker.io/library/eclipse-temurin:25-jdk-alpine
COPY sdk/java/Determinismo.java sdk/java/DeterminismoCoverage.java /app/sdk/
COPY tests/antithesis-compat/java/client/Maze.java tests/antithesis-compat/java/client/StateMaze.java /app/src/
COPY tests/antithesis-compat/java/client/maze/ /opt/antithesis/test/v1/maze/
COPY tests/antithesis-compat/java/client/state/ /opt/antithesis/test/v1/state/
COPY tests/antithesis-compat/java/client/state_int/ /opt/antithesis/test/v1/state_int/
# The SDK and its coverage agent in one jar; the maze next to it.
RUN javac -d /app/sdk-classes /app/sdk/*.java && \
    printf 'Premain-Class: DeterminismoCoverage\n' > /app/manifest && \
    jar cfm /app/determinismo-coverage.jar /app/manifest -C /app/sdk-classes . && \
    javac -cp /app/sdk-classes -d /app/classes /app/src/Maze.java /app/src/StateMaze.java && \
    chmod +x /opt/antithesis/test/v1/maze/* /opt/antithesis/test/v1/state/* /opt/antithesis/test/v1/state_int/*
CMD ["sleep", "infinity"]
