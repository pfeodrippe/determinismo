# SPDX-License-Identifier: MIT
FROM docker.io/library/redis:7.4-alpine
COPY tests/ /opt/antithesis/test/v1/bank/
RUN chmod +x /opt/antithesis/test/v1/bank/*
CMD ["sleep", "infinity"]
