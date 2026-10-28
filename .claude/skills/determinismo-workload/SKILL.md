---
name: determinismo-workload
description: Write a determinismo test program (the Zig workload) for a system - its nodes, profiles, scenarios, drivers and recovery checks - and wire the SDK's assertions into the service. Use when asked to test a service, docker-compose project or cluster under determinismo.
---

# A determinismo workload

A test program is one Zig file, run inside the guest, that describes the system and drives it.
Read one example first: `examples/bank/bank_test.zig` (Redis, small), `examples/raft/raft_test.zig`
(three nodes), `examples/nrepl/nrepl_test.zig` (a protocol client), or
`examples/clojure-libs/libs_test.zig` (one scenario per library, as a function).

## Shape

```zig
const Nodes = struct { db: sdk.Node, app: sdk.Node };
const System = sdk.System(Nodes);

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{ .transfers = transfers } });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.db, .{ .build = .{ .context = ".", .dockerfile = "path/Dockerfile" },
        .ready = .{ .tcp = 5432 } });
}

fn transfers(s: *System.Scenario) void {
    s.parallel_driver("transfer", transfer);   // run concurrently, many times, under faults
    s.singleton_driver("audit", audit);         // one at a time
    s.eventually("recovers", recovers);         // after faults stop: the system works again
}
```

- Nodes are containers built from Dockerfiles (fetch every dependency at build time: the guest
  has no network), or binaries. An Antithesis-style compose project runs as is
  (`explore --compose compose.yaml`, see `tests/antithesis-compat`).
- Draw every choice from the SDK (`sdk.random_below`, `sdk.decide("name", options)`), never from
  the clock or `std.crypto.random`: strategies steer these, and replays repeat them.
- Clients: `sdk.tcp` (`Connection`, `request_line`, `http`), `node.exec_output` to run a command
  in a node. Protocol clients stay in the example (see `examples/bank/resp.zig`).
- A driver that loses its server to a fault is not a failure: `sdk.tcp.unavailable(err)` tells
  those errors apart; note them with a `sometimes` and return.
- `eventually` retries (`sdk.retry`) and ends in `assert_unreachable(...)` if the system never
  recovers.
- Note each operation before sending it (Jepsen's invocations), then its outcome: the composer
  may end the driver phase and kill drivers mid-call, and an operation that applied but was
  noted only after its answer is neither acknowledged nor unknown (an etcd counter came out one
  over in 83 timelines). Invoked without an outcome counts as unknown.

## Assertions in the service

Use the SDK of the service's language (`sdk/c`, `sdk/python`, `sdk/java` with the catalog agent,
`sdk/clojure`): assertions are cataloged as the code loads, so one that never runs is reported
too. Messages are literals: they are the property's identity.

## Build and run

Add the program to `build.zig`'s `programs`, then on the host with KVM:

```
zig build -Drelease
determinismo explore --kernel ... --initrd ... --program zig-out/bin/<name> \
  --scenario <scenario> --seed 1 --branches 32
```

Exit 0: all passed; 3: some failed (then use the `determinismo-debug` skill).
