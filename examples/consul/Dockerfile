# SPDX-License-Identifier: MIT
# Consul 2.1.0 (its current release, 2026-10-22), three servers; start.sh runs one.
FROM docker.io/hashicorp/consul:2.1.0
COPY --chmod=755 examples/consul/start.sh /usr/local/bin/start.sh
ENTRYPOINT ["/usr/local/bin/start.sh"]
