# SPDX-License-Identifier: MIT
# Redis with the bank's configuration baked in: the `built` profile's `build` source.
FROM docker.io/library/redis:7.4-alpine
COPY redis.conf /usr/local/etc/redis/redis.conf
CMD ["redis-server", "/usr/local/etc/redis/redis.conf"]
