# SPDX-License-Identifier: MIT
# Quint v0.33.0 (a specification language of the TLA family) under test, from source with
# quint.patch: its CLI (TypeScript) asserting through determinismo's JavaScript SDK, its Rust
# evaluator (v0.7.0) through the Rust SDK, both built here; the service (app/) checks it.
# Everything is fetched at build time: the guest has no network.
FROM docker.io/library/node:22-bookworm
RUN apt-get update -q && \
    apt-get install -yq --no-install-recommends git ca-certificates curl build-essential && \
    rm -rf /var/lib/apt/lists/*
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --quiet --profile minimal --default-toolchain 1.92.0
ENV PATH=/root/.cargo/bin:$PATH
RUN git clone --quiet --depth 1 --branch v0.33.0 https://github.com/quint-co/quint /src/quint
COPY sdk/rust /src/sdk-rust
COPY sdk/javascript /src/sdk-javascript
COPY examples/quint/quint.patch /src/
RUN cd /src/quint && git apply /src/quint.patch
# The evaluator where the CLI looks for it (QUINT_HOME/rust-evaluator-<version>): it downloads
# none.
ENV QUINT_HOME=/opt/quint
RUN cd /src/quint/evaluator && cargo build --release --quiet && \
    mkdir -p /opt/quint/rust-evaluator-v0.7.0 && \
    cp target/release/quint_evaluator /opt/quint/rust-evaluator-v0.7.0/ && rm -rf target
# --ignore-scripts: npm ci's prepare would compile before the SDK is in node_modules.
RUN cd /src/quint/quint && npm ci --silent --no-fund --no-audit --ignore-scripts && \
    cp -r /src/sdk-javascript node_modules/determinismo && npm run compile --silent && \
    printf '#!/bin/sh\nexec node /src/quint/quint/dist/src/cli.js "$@"\n' > /usr/local/bin/quint && \
    chmod +x /usr/local/bin/quint
COPY examples/quint/app /app
RUN mkdir -p /app/node_modules && cp -r /src/sdk-javascript /app/node_modules/determinismo && \
    cd /src/quint/examples && node /app/manifest.js > /app/manifest.json
WORKDIR /app
ENTRYPOINT ["node", "/app/quint_check.js"]
