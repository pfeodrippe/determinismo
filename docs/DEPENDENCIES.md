# External dependencies

A run is one deterministic machine with no way out: nothing in it reaches the internet, a cloud
API or a host service, because an answer from outside could differ between replays. Everything
the software talks to runs inside, as a node, the way Antithesis asks
([Handling external dependencies](https://antithesis.com/docs/reference/dependencies)).

Each dependency becomes one of two things:

- **The real thing in a container image.** Databases, queues, caches: the image you run in
  production, pinned to a version. It is pulled once on the host (podman), turned into an erofs
  disk and cached by image ID, so later runs boot it without a registry.
- **A mock or an emulator**, for what does not run in a container (a public cloud's managed
  services, a payment provider, a vendor API).

## Replacements

| Outside dependency | Inside the machine |
| --- | --- |
| AWS S3 | MinIO (`MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`; create buckets in a setup command) |
| Other AWS services (DynamoDB, SQS, Lambda, IAM, SSM, CloudWatch) | LocalStack (`SERVICES` limited to what you use, `DEBUG=0`, `LS_LOG=warn`), Moto |
| Azure storage, Functions, Cosmos DB | Azurite, Azure Functions Core Tools, the Cosmos DB emulator |
| Google Cloud | the Cloud SDK emulators, the Firebase Local Emulator Suite, fake-gcs-server |
| Stripe | stripe-mock |
| An LLM API | Ollama with a small model (slow inside the machine: keep calls few) |
| Any HTTP API | WireMock, MockServer, Microcks, JSON Server, or a small server of your own |

Open-source services run as they are: Postgres, MySQL, MariaDB, Redis, Memcached, Kafka,
RabbitMQ, NATS, Cassandra, ClickHouse, MongoDB, Elasticsearch, etcd, ZooKeeper, Consul, Vault,
nginx, Prometheus.

## Declaring them

With a Compose file (`--compose`), each service is a node:

```yaml
services:
  infra-postgres:
    image: docker.io/library/postgres:17.2-alpine   # pinned
    environment:
      POSTGRES_PASSWORD: test
    ports: ["5432"]          # the first port is the node's readiness check
  service-api:
    build: ./api
    depends_on: [infra-postgres]   # dependencies start first
```

Node names are lowercase letters, digits and dashes (Antithesis's `infra.` and `service.`
prefixes become `infra-` and `service-`). With a test program (`--program`), the same goes in
its profile through the SDK:
`.{ .name = "postgres", .source = .{ .image = "..." }, .ready = .{ .tcp = 5432 } }`, and
`.after = &.{"postgres"}` on the nodes that use it.

What differs from Docker:

- **Names.** Every node is reachable by its service name: the runtime writes all of them into each
  node's `/etc/hosts`, and there is no DNS server. A client that insists on DNS needs its
  resolver pointed at `/etc/hosts` (most do this already).
- **Readiness** is the first port of `ports` (or `expose`) accepting connections. `healthcheck` is
  reported and ignored; a dependency that needs more than an open port before use (migrations, a
  bucket, a topic) gets it from the scenario's first command, which can wait for it.
- **Storage.** Each node's root is its image, read-only, under a writable tmpfs overlay: a timeline
  starts from the same bytes every time and keeps what it writes until it ends. `volumes` are
  reported and ignored; nothing persists between timelines, which is what replay needs.
- **Memory.** All nodes share the machine's memory (`--memory-mib`); `mem_limit` sets a node's
  cgroup limit. Size the machine for every dependency together (a three-node K3s cluster runs in
  8 GiB).
- **Faults** apply to dependencies like any other node: partitions, clogs, pauses, degraded
  links, and kills where allowed. To spare one, set its node's `faults` fields to false (SDK).

## When a dependency phones home

Telemetry, license checks, update checks and the like fail inside the machine; that failure is
the same in every timeline, so it is harmless to determinism, but it can be slow (timeouts) or
noisy. Turn it off by configuration (for example `DO_NOT_TRACK=1`, or the product's own flag).
