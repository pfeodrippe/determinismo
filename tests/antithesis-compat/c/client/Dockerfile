# SPDX-License-Identifier: MIT
FROM docker.io/library/alpine:3.20
RUN apk add --no-cache clang lld musl-dev
COPY tests/antithesis-compat/c/client/ /src/client/
COPY sdk/c/determinismo.h /src/client/
WORKDIR /src/client
# Antithesis's way: trace-pc-guard, linked against libvoidstar, the unstripped binary in /symbols.
RUN clang -shared -fPIC -o /usr/lib/libvoidstar.so voidstar_stub.c && \
    clang -g -O1 -fsanitize-coverage=trace-pc-guard -c maze.c -o maze.o && \
    clang -fuse-ld=lld -Wl,--build-id -o /usr/local/bin/maze maze.o -L/usr/lib -lvoidstar && \
    clang -g -O1 -fsanitize-coverage=trace-pc-guard -c maze_sdk.c -o maze_sdk.o && \
    clang -fuse-ld=lld -Wl,--build-id -o /usr/local/bin/maze-sdk maze_sdk.o && \
    mkdir -p /symbols /opt/antithesis/test/v1/maze /opt/antithesis/test/v1/maze_sdk && \
    cp /usr/local/bin/maze /symbols/maze && cp /usr/local/bin/maze-sdk /symbols/maze-sdk && \
    cp maze/singleton_driver_maze.sh /opt/antithesis/test/v1/maze/ && \
    cp maze_sdk/singleton_driver_maze_sdk.sh /opt/antithesis/test/v1/maze_sdk/ && \
    chmod +x /opt/antithesis/test/v1/maze/* /opt/antithesis/test/v1/maze_sdk/*
CMD ["sleep", "infinity"]
