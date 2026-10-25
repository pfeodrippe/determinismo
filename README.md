# determinismo

Deterministic simulation testing for whole systems, in the spirit of
[Antithesis](https://antithesis.com): run your services in one deterministic VM, explore many
timelines from a snapshot, inject faults, and replay any timeline exactly.

Design: [ARCHITECTURE.md](ARCHITECTURE.md). Style: [docs/STYLE.md](docs/STYLE.md).
Strategy plugins: [docs/PLUGINS.md](docs/PLUGINS.md). Agents: [docs/AGENTS.md](docs/AGENTS.md).

## What works today

- A Zig VMM on a patched KVM where guest time is a function of retired branches; idle time is
  skipped, and every timeline replays bit-identically.
- Systems described in code: a test program's `describe` returns typed profiles whose nodes come
  from OCI images (pulled and flattened by podman on the host), Dockerfiles, directories or
  binaries. In the guest, each node runs in its own namespaces on a read-only disk with a tmpfs
  overlay, linked to every other node and to the tests.
- Tests as scenarios: functions listing test commands (setup, `first`, parallel, serial and
  singleton drivers, `anytime`, `eventually`, `finally`), with assertions (`always`, `sometimes`,
  `reachable`, ...) and platform randomness from the Zig SDK. Any language can implement the
  two-command protocol (`--describe`, `run <scenario> <command>`).
- `determinismo explore`: boot once, snapshot at `setup_complete`, run many copy-on-write branches,
  report properties across the multiverse, replay any branch with `--branch N`.
- Faults as decisions: pause, isolate, partition and restart nodes, skip clocks.
- Strategy plugins in any language over a JSON-lines protocol, with tapes for exact replay
  (refused if the kernel, initramfs, command line or disks changed).
- Multiverse debugging: run a command in the guest, or inside a node with `det-nodes exec`, at an
  exact virtual time of a branch.

## A test program

```zig
const Nodes = struct { postgres: sdk.Node, redis: sdk.Node };
const System = sdk.System(Nodes);

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.postgres, .{
        .image = "docker.io/library/postgres:17-alpine",
        .env = &.{"POSTGRES_HOST_AUTH_METHOD=trust"},
        .ready = .{ .tcp = 5432 },
    });
    default.node(.redis, .{ .image = "docker.io/library/redis:7.4-alpine", .ready = .{ .tcp = 6379 } });
}

fn prices(s: *System.Scenario) void {
    s.setup("catalog", catalog); // fn catalog(context: *System.Context) !void
    s.parallel_driver("reprice", reprice);
    s.parallel_driver("browse", browse);
    s.finally("coherent", coherent); // sdk.always(cached == database, ...)
}

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{ .prices = prices } });
}
```

Full examples: [examples/bank](examples/bank) (Redis, a lost update) and
[examples/shop](examples/shop) (Postgres and Redis, a stale cache). Other languages: the Python
SDK ([sdk/python](sdk/python), one file) in [examples/compose-python](examples/compose-python),
or any Antithesis SDK (see below).

## Coming from Antithesis

Bring the same project: a Compose file, and test commands in an image under
`/opt/antithesis/test/v1/<template>/` (`first_*`, `parallel_driver_*`, `finally_*`, ...). Each
template becomes a scenario whose commands run inside that service; assertions in the Antithesis
SDK's format (written to `$ANTITHESIS_SDK_LOCAL_OUTPUT`, which points to determinismo) count as
properties. Example: [examples/compose-bank](examples/compose-bank).

```
determinismo explore ... --compose examples/compose-bank/compose.yaml --scenario bank --branches 40
```

## Quickstart (on the host)

```
infra/hetzner/install-os.sh <ip>          # Debian 13 on a fresh Hetzner box (rescue mode)
infra/host/bootstrap.sh <ip>              # packages, user `det`, SSH hardening, firewall
# On the host, in the repository:
sudo infra/host/m0-check.sh               # hardware qualification
infra/host/build-kvm.sh                   # KVM with kernel/patches/*.patch
sudo infra/host/load-kvm.sh               # swap in our KVM modules
guest/kernel/build.sh ~/guest             # the guest kernel and det_guest.ko
zig build -Drelease                       # the VMM, the guest runtime, the examples
zig-out/bin/det-initramfs --bin zig-out/bin --module ~/guest/det_guest.ko --busybox /usr/bin/busybox --out ~/guest/base.cpio
```

Then explore a system (images are pulled and cached under `--cache` on first use):

```
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio --memory-mib 2048 \
  --program zig-out/bin/bank-test --scenario all --seed 7 --branches 40
determinismo explore ... --program zig-out/bin/bank-test --scenario bank --seed 7 --branch 0
determinismo explore ... --strategy zig-out/bin/det-strategy-mutate --tape-dir /tmp/tapes
determinismo explore ... --tape /tmp/tapes/branch-16.jsonl
```

Branches run on every CPU (`--jobs`, same timelines as one worker). Explore from an interesting
moment of a branch: it is replayed to that moment, snapshotted there, and branched again:

```
determinismo explore ... --program zig-out/bin/bank-test --seed 7 --from-branch 2 \
  --from-vtime-ms 1200 --branches 32
```

Results as JSON lines (`--record results.jsonl`). An HTTP API keeps runs, results and tapes, and
replays branches; an MCP server gives agents the same powers:

```
determinismo serve --listen 127.0.0.1:7878 --data ~/runs --kernel ... --initrd ... --cache ~/cache
curl -X POST localhost:7878/runs -d '{"program":"zig-out/bin/bank-test","scenario":"bank","branches":40}'
curl localhost:7878/runs/1                       # state, branches, properties
curl -X POST localhost:7878/runs/1/replay -d '{"branch":3}'
determinismo mcp --kernel ... --initrd ... --cache ~/cache   # tools: describe, explore, replay, fork
```

Multiverse debugging: stop a branch at a moment and run a command there (output streams back,
and is identical every time):

```
determinismo explore ... --program zig-out/bin/shop-test --seed 3 --branch 37 --at-vtime-ms 3610 \
  --exec "det-nodes exec postgres psql -U postgres -c 'select * from price'"
```

"What if": `--exec "<cmd>" --continue` makes a change at a moment and lets the branch run on;
`--from-branch B --from-vtime-ms T --from-exec "<cmd>"` explores many futures of the changed system.

`zig build test` runs the unit tests (on Linux); `zig build tidy` checks style; `zig build e2e`
boots the examples and checks exploration, exact replays from fresh boots, and tapes (on the host,
about 40 s).
