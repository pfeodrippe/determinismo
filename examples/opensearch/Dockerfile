# SPDX-License-Identifier: MIT
# OpenSearch (its current release), three nodes of one cluster, without its bundled plugins (k-NN,
# ML Commons, security...): the workload tests the core's replication, and on one vCPU the plugins
# slow every start and want more than a 512 MB heap. start.sh <id>, as the image's own user.
FROM docker.io/opensearchproject/opensearch:3.9.0
USER root
# A few passes: one a plugin depends on goes only after its dependents. None may be left.
RUN for pass in 1 2 3 4; do \
      for plugin in $(/usr/share/opensearch/bin/opensearch-plugin list); do \
        /usr/share/opensearch/bin/opensearch-plugin remove --purge "$plugin" || true; \
      done; \
    done; \
    test -z "$(/usr/share/opensearch/bin/opensearch-plugin list)"
COPY examples/opensearch/start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh
USER opensearch
ENTRYPOINT ["/usr/local/bin/start.sh"]
