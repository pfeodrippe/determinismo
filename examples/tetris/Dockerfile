# SPDX-License-Identifier: MIT
# djblue/tetris's game as its jank frontend runs it, headless: tetris.core (the game, a .cljc
# its browser frontend shares) driven by harness.jank, AOT-compiled by jank (from jank's own
# Ubuntu repository), behind a line protocol on port 7000 (a game per connection). The node keeps
# the binary alone (its runtime is static: no LLVM), 1.9 GB of image less in the VM's memory.
FROM docker.io/library/ubuntu:24.04 AS build
RUN apt-get update -q \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
      ca-certificates curl gnupg git \
 && curl -fsS https://ppa.jank-lang.org/KEY.gpg | gpg --dearmor > /etc/apt/trusted.gpg.d/jank.gpg \
 && echo "deb [signed-by=/etc/apt/trusted.gpg.d/jank.gpg] https://ppa.jank-lang.org noble main" \
      > /etc/apt/sources.list.d/jank.list \
 && apt-get update -q \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -q jank \
 && rm -rf /var/lib/apt/lists/*
# The game at a known commit (2026-10-28).
RUN git clone -q https://github.com/djblue/tetris /opt/tetris \
 && git -C /opt/tetris checkout -q 798780285f039ef7402acfc00b5b367820f818af
COPY examples/tetris/harness.jank /opt/tetris/src/tetris/harness.jank
WORKDIR /opt/tetris
# jank's default optimization: with -O 2 its compiler segfaults on the game (jank 0.1, 2026-10).
RUN jank --module-path src compile --name tetris-harness tetris.harness \
 && cp target/tetris-harness /usr/local/bin/tetris-harness \
 && printf 'tick\nprobes\ndrop\nquit\n' | /usr/local/bin/tetris-harness

FROM docker.io/library/ubuntu:24.04
RUN apt-get update -q \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends socat \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/bin/tetris-harness /usr/local/bin/tetris-harness
RUN printf 'tick\nprobes\ndrop\nquit\n' | /usr/local/bin/tetris-harness
EXPOSE 7000
ENTRYPOINT ["socat", "TCP-LISTEN:7000,reuseaddr,fork", "EXEC:/usr/local/bin/tetris-harness"]
