# SPDX-License-Identifier: MIT
# Apache Kafka 3.8.0 (checked against Apache's published SHA-512), KRaft brokers, and the client
# node: KClient.java compiled against the distribution's own kafka-clients (the Java client
# Jepsen's Kafka tests used, at 3.8.0). One image; start.sh runs a broker or the client.
FROM docker.io/library/debian:bookworm-slim AS build
ARG KAFKA_SHA512=0a33b7be7b6fa53249ba80f9d02cda71ed81927c160aa6ee9be1e3d3c1c4b50466ffc905293143fd88ceac7f5e7d8f5bec28ef972addd3c459cc8b1291e738aa
RUN apt-get update -q \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
      openjdk-17-jdk-headless ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/kafka.tgz https://archive.apache.org/dist/kafka/3.8.0/kafka_2.13-3.8.0.tgz \
 && echo "${KAFKA_SHA512}  /tmp/kafka.tgz" | sha512sum -c - \
 && mkdir /opt/kafka && tar -xzf /tmp/kafka.tgz -C /opt/kafka --strip-components=1 \
 && rm /tmp/kafka.tgz
COPY examples/kafka/KClient.java /opt/kclient/KClient.java
RUN javac -cp "/opt/kafka/libs/*" -d /opt/kclient /opt/kclient/KClient.java

FROM docker.io/library/debian:bookworm-slim
# C1 only: short timelines and restarted JVMs never repay C2's compiling (examples/ignite/README.md).
ENV JAVA_TOOL_OPTIONS="-XX:TieredStopAtLevel=1"
RUN apt-get update -q \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends openjdk-17-jre-headless \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /opt/kafka /opt/kafka
COPY --from=build /opt/kclient /opt/kclient
COPY examples/kafka/start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh && mkdir -p /data
ENTRYPOINT ["/usr/local/bin/start.sh"]
