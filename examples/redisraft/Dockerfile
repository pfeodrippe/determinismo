# SPDX-License-Identifier: MIT
# Redis-Raft (github.com/RedisLabs/redisraft) at 2d1cf30 (2020-05-09), the build Jepsen's
# analysis found history rewritten by crashes alone in (#52), on Redis 6.0.3 (checked against its
# published SHA-256); its dependencies are its git submodules at that commit (cmocka, for its
# tests, from its current home). start.sh runs a node.
FROM docker.io/library/debian:bookworm-slim AS build
RUN apt-get update -q \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
      build-essential cmake autoconf automake libtool git ca-certificates wget pkg-config python3 \
      libbsd-dev \
 && rm -rf /var/lib/apt/lists/*
ARG REDIS_VERSION=6.0.3
ARG REDIS_SHA256=bca46dce81fe92f7b2de4cf8ae41fbc4b94fbd5674def7f12c87e7f9165cbb3a
RUN wget -q -O /tmp/redis.tar.gz "https://download.redis.io/releases/redis-${REDIS_VERSION}.tar.gz" \
 && echo "${REDIS_SHA256}  /tmp/redis.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/redis.tar.gz -C /tmp \
 && make -C "/tmp/redis-${REDIS_VERSION}" -j"$(nproc)" MALLOC=libc CFLAGS=-fcommon \
 && cp "/tmp/redis-${REDIS_VERSION}/src/redis-server" "/tmp/redis-${REDIS_VERSION}/src/redis-cli" /usr/local/bin/
ARG REDISRAFT_COMMIT=2d1cf3051eac05e41f87a1e5ba269d547c194c7a
RUN git clone -q https://github.com/RedisLabs/redisraft.git /redisraft \
 && cd /redisraft \
 && git checkout -q "${REDISRAFT_COMMIT}" \
 && git config --global url."https://gitlab.com/cmocka/cmocka.git".insteadOf "git://git.cryptomilk.org/projects/cmocka.git" \
 && git submodule update -q --init --recursive \
 && make CC="gcc -fcommon"

FROM docker.io/library/debian:bookworm-slim
RUN apt-get update -q \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends libbsd0 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/bin/redis-server /usr/local/bin/redis-cli /usr/local/bin/
COPY --from=build /redisraft/redisraft.so /usr/lib/redisraft.so
COPY examples/redisraft/start.sh /usr/local/bin/start.sh
RUN mkdir -p /data
ENTRYPOINT ["/bin/sh", "/usr/local/bin/start.sh"]
