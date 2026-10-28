# SPDX-License-Identifier: MIT
FROM docker.io/library/alpine:3.20
RUN apk add --no-cache clang lld musl-dev
COPY tests/antithesis-compat/c/client/ /src/client/
WORKDIR /src/client
# Antithesis's way: trace-pc-guard, linked against libvoidstar, the unstripped binary in /symbols.
RUN clang -shared -fPIC -o /usr/lib/libvoidstar.so voidstar_stub.c && \
    clang -g -O1 -fsanitize-coverage=trace-pc-guard -c maze.c -o maze.o && \
    clang -fuse-ld=lld -Wl,--build-id -o /usr/local/bin/maze maze.o -L/usr/lib -lvoidstar && \
    mkdir -p /symbols /opt/antithesis/test/v1/maze && cp /usr/local/bin/maze /symbols/maze && \
    cp maze/singleton_driver_maze.sh /opt/antithesis/test/v1/maze/ && \
    chmod +x /opt/antithesis/test/v1/maze/*
CMD ["sleep", "infinity"]
