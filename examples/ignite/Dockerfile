# SPDX-License-Identifier: MIT
# Apache Ignite 3.1.0 (the official image), three server nodes, and the client node: IClient.java
# on Ignite's Java client 3.1.0 (from Maven Central, at build time). One image; start.sh runs a
# server or the client.
FROM docker.io/library/maven:3.9.16-eclipse-temurin-17 AS client
COPY examples/ignite/pom.xml /build/pom.xml
RUN cd /build && mvn -q dependency:copy-dependencies -DoutputDirectory=/opt/iclient/lib
COPY examples/ignite/IClient.java /build/IClient.java
RUN javac --release 11 -cp "/opt/iclient/lib/*" -d /opt/iclient /build/IClient.java

FROM docker.io/apacheignite/ignite:3.1.0
COPY --from=client /opt/iclient /opt/iclient
COPY examples/ignite/start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh
ENTRYPOINT ["/usr/local/bin/start.sh"]
