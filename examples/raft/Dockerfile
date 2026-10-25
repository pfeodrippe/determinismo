# SPDX-License-Identifier: MIT
# A HashiCorp Raft node (service/main.go), built from source.
FROM docker.io/library/golang:1.24-alpine AS build
WORKDIR /src
COPY examples/raft/service/ ./
RUN CGO_ENABLED=0 go build -o /raft-node .

FROM docker.io/library/alpine:3.20
COPY --from=build /raft-node /usr/local/bin/raft-node
ENTRYPOINT ["/usr/local/bin/raft-node"]
