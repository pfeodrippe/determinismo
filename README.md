# determinismo

Deterministic simulation testing for whole systems, in the spirit of
[Antithesis](https://antithesis.com): run your services in one deterministic VM, explore many
timelines from a snapshot, inject faults, and replay any timeline exactly.

Design: [ARCHITECTURE.md](ARCHITECTURE.md). Style: [docs/STYLE.md](docs/STYLE.md).
Strategy plugins: [docs/PLUGINS.md](docs/PLUGINS.md).

## What works today

- A Zig VMM on a patched KVM where guest time is a function of retired branches: boots stock
  Linux, runs Redis and Postgres, and replays bit-identically.
- Tests written as plain programs, Antithesis-style: `first_`, `parallel_driver_`,
  `serial_driver_`, `singleton_driver_`, `anytime_`, `eventually_`, `finally_` commands, with a Zig
  SDK for handlers, assertions (`always`, `sometimes`, `reachable`, ...) and platform randomness.
- `determinismo explore`: boot once, snapshot at `setup_complete`, run many copy-on-write branches,
  report properties across the multiverse, replay any branch with `--branch N`.
- Strategy plugins in any language over a JSON-lines protocol, with tapes for exact replay.
- Fault injection (process pause and restart, clock skips) steered by the same decisions.
- Multiverse debugging: run any shell command (`redis-cli`, `psql`, an nREPL client) inside a
  branch at an exact virtual time.

## Quickstart (on the host)

```
infra/hetzner/install-os.sh <ip>          # Debian 13 on a fresh Hetzner box (rescue mode)
infra/host/bootstrap.sh <ip>              # packages, user `det`, SSH hardening, firewall
# On the host, in the repository:
sudo infra/host/m0-check.sh               # hardware qualification
infra/host/build-kvm.sh                   # KVM with kernel/patches/*.patch
sudo infra/host/load-kvm.sh               # swap in our KVM modules
make -C guest/module                      # /dev/determinismo for the guest
guest/build-rootfs.sh ~/guest-rootfs      # Debian guest with Redis and Postgres
guest/pack-initramfs.sh ~/guest-rootfs zig-out/bin guest/module/det_guest.ko /tmp/guest.cpio.zst
```

Build the VMM and guest binaries anywhere with Zig 0.17 (`zig build`), then:

```
determinismo explore --seed 1 --branches 40 \
  --kernel /boot/vmlinuz-$(uname -r) --initrd /tmp/guest.cpio.zst --memory-mib 2048 \
  --append det.scenario=bank \
  --strategy zig-out/bin/det-strategy-mutate --tape-dir /tmp/tapes
determinismo explore --tape /tmp/tapes/branch-16.jsonl --kernel ... --append det.scenario=bank
```

Multiverse debugging: stop a branch at a moment and run a command there (output streams back,
and is identical every time):

```
determinismo explore --seed 3 --branch 2 --at-vtime-ms 2824 \
  --exec "redis-cli mget account:0 account:1 ..." --kernel ... --append det.scenario=bank
```

`zig build test` runs the unit tests; `zig build tidy` checks style.
