# SPDX-License-Identifier: MIT
# The client of the Kubernetes project: redis-cli, and the test template "kv".
FROM docker.io/library/redis:7.4-alpine
COPY parallel_driver_count.sh eventually_counted.sh /opt/antithesis/test/v1/kv/
RUN chmod +x /opt/antithesis/test/v1/kv/*
