# Style

determinismo follows [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).
Our design goals are the same, in the same order: safety, performance, developer experience. This
page records how we apply it here and the few places where we knowingly differ.

`zig build tidy` checks the mechanical rules (SPDX header, no tabs or trailing whitespace, at most
100 columns, functions of at most 70 lines). `zig fmt` formats. Both must pass before a commit.

## What we apply everywhere (Zig)

- **Assertions**: assert arguments, return values, pre/postconditions and invariants; aim for at
  least two per function; assert compile-time relationships (`comptime { assert(...) }`), e.g. the
  KVM struct layouts in `src/kvm.zig` and the guest memory layout in `src/boot.zig`. Assertions
  are for programmer errors; operating errors (a bad guest request, a failed syscall) are handled.
- **Static allocation**: everything is reserved at init. The VMM's event table and JSON parse
  buffer (`src/events.zig`), the composer's command tables, and the RESP client's buffers are fixed
  size. Nothing allocates in the run loop.
- **Limits on everything**: queues, tables, loops and message sizes have explicit maxima
  (`property_count_max`, `commands_max`, `message_size_max`, ...). The VM's run loop is an event
  loop and says so (`comptime unreachable` after it).
- **Explicitly sized types** (`u32`, `u64`) for domain values; `usize` only where Zig requires it.
- **Naming**: `snake_case` for functions, variables and files; acronyms capitalized (`VM`, `PIT`,
  `RTC`); units and qualifiers last (`deadline_tsc`, `margin_branches`, `latency_ns_max`); helpers
  prefixed by their caller (`init_memory`, `timer_arm`).
- **Files are structs** where a file is one thing (`serial.zig` is `Serial`, `pit.zig` is `PIT`).
- **Options structs** when arguments could be confused; large structs initialized in place
  (`vm.init(gpa, &options)`).
- **Comments say why**, as sentences.
- **Zero dependencies** beyond the Zig toolchain.

## Where we differ, and why

| Area | What we do | Why |
|---|---|---|
| KVM patch, `det_guest.ko` | Linux kernel style (C, tabs, `WARN_ON_ONCE` for invariants) | It is kernel code; reviewers and tools expect kernel style. |
| Guest `/init` and scenario scripts | POSIX `sh` | They run inside the guest before anything else exists. |
| Host tooling | Zig where it is ours (`tools/`: tidy, e2e, det-initramfs) | Shell remains only where it drives other build systems or runs before Zig exists on a machine: `guest/kernel/build.sh` (make), `infra/` (installimage, provisioning, KVM module build and load). |
| Standard library calls | `std.os.linux` syscalls directly in hot or early paths | Fewer layers, explicit error handling, no hidden allocation. |
