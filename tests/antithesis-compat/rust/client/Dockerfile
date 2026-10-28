# SPDX-License-Identifier: MIT
# The maze built with the SDK's coverage feature: rustc's trace-pc-guard on the program's own
# code (--target: RUSTFLAGS reach it, not the build scripts), debug information kept, the binary
# in /symbols as Antithesis's instrumented builds have it.
FROM docker.io/library/rust:1.82-slim-bookworm AS build
COPY sdk/rust /src/sdk-rust
COPY tests/antithesis-compat/rust/client /src/client
WORKDIR /src/client
RUN rm -rf /src/sdk-rust/target && \
    RUSTFLAGS="-C passes=sancov-module -C llvm-args=-sanitizer-coverage-level=3 -C llvm-args=-sanitizer-coverage-trace-pc-guard -C link-arg=-Wl,--build-id" \
    cargo build --release --target x86_64-unknown-linux-gnu --quiet && \
    cp target/x86_64-unknown-linux-gnu/release/maze-rust /usr/local/bin/maze-rust

FROM docker.io/library/debian:bookworm-slim
COPY --from=build /usr/local/bin/maze-rust /usr/local/bin/maze-rust
COPY --from=build /usr/local/bin/maze-rust /symbols/maze-rust
COPY tests/antithesis-compat/rust/client/maze_rust/ /opt/antithesis/test/v1/maze_rust/
RUN chmod +x /opt/antithesis/test/v1/maze_rust/*
CMD ["sleep", "infinity"]
