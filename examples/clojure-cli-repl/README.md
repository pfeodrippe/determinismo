# clojure-cli.repl under determinismo

[clojure-cli.repl](https://github.com/clojure/clojure-cli.repl) is the Clojure CLI's REPL: a
terminal client (JLine, its own JVM) and a server, which is nREPL with clojure-cli.repl's
middleware. Editor evaluations (requests that carry `file`) are echoed to every terminal that
asked to `watch`, with their output; terminals browse results with an inspector; configured
middleware adds server data to every evaluation's final response.

This example runs its server (0.2.1, `app/`) beside plain nREPL 1.7.0 (`plain/`, the version
its server runs on, as the reference for what its middleware should leave unchanged), and a
test program (`cli_repl_test.zig`) whose clients are editors and terminals:

| Scenario | Property | What it means |
|---|---|---|
| editors | an editor evaluation answers as plain nREPL's does | the watch middleware is transparent to the editor |
| editors | a watching terminal sees each editor evaluation, through to its end | its watch feature, under concurrent editors and faults |
| editors | middleware data is on every evaluation's final response | its documented `:middleware` contract |
| paused-terminal | an editor evaluation finishes while a terminal does not read | one suspended terminal must not stop editors (checked in a quiet period: no fault explains a timeout) |
| inspector | a terminal's inspector navigation stays its own | two terminals attached; showing another session's `*1` is by design, moving another terminal's view is not |
| sessions | closed sessions are released | each kept session keeps its `*1`, `*2`, `*3` reachable |

The server binds loopback only; a config `:init` hook (`app/.cljconf`) makes nREPL's
`start-server` bind every interface, so the test program can reach it from another node.

```
determinismo explore --kernel ... --initrd ... --memory-mib 4096 \
  --program zig-out/bin/clojure-cli-repl-test --scenario paused-terminal --seed 1 \
  --branches 16 --branching tree
```

## Findings (clojure-cli.repl 0.2.1)

Not reported upstream yet.

1. **A terminal that does not read stops editor evaluations.** The watch middleware sends each
   editor evaluation's output to every watching terminal from inside the evaluation
   (`watch/reply-to-watchers`, synchronously, in the transport's `send`). When a terminal stops
   reading (suspended with Ctrl-Z, a stalled network) and its socket buffers fill, the
   evaluation blocks, and the editor waits forever. Explored with determinismo (seed 1, 16
   timelines, a quiet period, so no fault is involved): every evaluation printing 1012 lines
   of 100 characters or more (about 100 KB, what the socket buffers hold) never finished; those
   printing 737 lines or fewer did. When the terminal finally goes away, the blocked thread dies
   with an uncaught `java.net.SocketException: Socket closed` in its `nREPL-session-...` thread.
   Plain nREPL has no such path: an evaluation writes only to its own client.
2. **Closed sessions are kept.** `watch/sessions` adds every session that evaluates and never
   removes one: after 50 sessions evaluated and closed, the server still held 54 (with their
   `*1`, `*2`, `*3`).
3. **One inspector for all terminals.** The inspector's state (`inspect/view`) is one atom for
   the server: when two terminals inspect, one moves the other's view. determinismo (scenario
   `inspector`, seed 1): a terminal that stepped once into its result (`*1 / 0`) found its view
   at `*1 / 0 / :mine`, another terminal's step applied to it.

Findings 2 and 3 were seen first by a direct probe; the `sessions` and `inspector` scenarios
check them under concurrency and faults.

Observations (not counted as bugs):

- The `watch` operation never answers (no `done`), so a terminal cannot tell when it starts
  receiving: an editor evaluation running as a terminal attaches can reach it in part (its
  output and end without its code). The test program judges evaluations only once its terminal
  saw one through.
- nREPL itself (plain 1.7.0 too) prints an uncaught `java.net.SocketException: Socket closed`
  from a session's thread when a client disconnects while its evaluation still writes to it;
  under network faults this trips the built-in "no uncaught exceptions (Java)" property on both
  servers.
