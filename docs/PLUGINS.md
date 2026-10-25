# Strategy plugins (protocol v1)

A strategy decides what the guest gets at each decision point. determinismo runs it as a separate
process and talks to it over its stdin/stdout: one JSON object per line, strictly alternating
request (from determinismo) and response (from the plugin). Anything a plugin writes to stderr is
passed through to the user. Plugins can be written in any language; the reference plugins are in
`plugins/` (Zig).

```
determinismo explore ... --strategy "plugins/mutate --corpus-max 64"
```

## Messages

Every request has a `method`. Every response is a JSON object; `{}` always means "the default".

| Request | When | Response |
|---|---|---|
| `{"method":"hello","protocol":1,"exploration_seed":"<hex>"}` | Once, at start. | `{"name":"<plugin name>"}` |
| `{"method":"branch","index":I,"seed":"<hex>"}` | Before each branch, with the branch's seed. | `{}` |
| `{"method":"random","pull":P,"size":N,"default":"<hex>","vtime_ns":T,"branches":C}` | The guest asked for `N` random bytes; pull `P` of this timeline (counted from boot). | `{}` to use `default`, or `{"hex":"<2N hex digits>"}` |
| `{"method":"event","vtime_ns":T,"branches":C,"event":<guest event>}` | The guest emitted an event (assertions, lifecycle, logs). | `{}` |
| `{"method":"branch_end","index":I,"outcome":"<outcome>","events":E,"failing":["<property>",...]}` | The branch ended. | `{}` to continue, `{"stop":true}` to end the exploration early |

Seeds are 64-bit and travel as 16 hex digits, since JSON numbers lose precision past 2^53.
`vtime_ns` and `branches` together are the moment (ARCHITECTURE.md §1). Decisions made before
the snapshot (boot and setup) are not sent: every branch shares them.

## Tapes

Every answer a plugin overrides is written to the branch's tape, so a branch replays without the
plugin, which may not be deterministic itself (ARCHITECTURE.md §7):

```
{"tape":2,"inputs":"<hex>","exploration_seed":"<hex>","branch":I,"branch_seed":"<hex>"}
{"pull":P,"hex":"..."}
```

`determinismo explore ... --tape <file>` replays one branch from its tape. `inputs` identifies what
the machine booted (kernel and initramfs bytes, command line, disks): a replay with different
inputs is refused, since it would be a different universe.

## Limits

Overridden values are at most 64 bytes (SDK pulls are 8). A plugin must answer every request; a
plugin that exits or writes a malformed line ends the exploration with an error.
