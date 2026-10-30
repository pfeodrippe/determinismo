# nREPL

nREPL is the protocol Clojure editors speak. `nrepl_test.zig` drives a server with concurrent
clients (bencode over TCP, `client.zig`) under faults. It tests two servers:

- **nrepl/nrepl 1.8.0** (`Dockerfile`, `server/deps.edn`): profile `default`, scenario
  `sessions`.
- **jank 0.1's own server** (`Dockerfile.jank`): profile `jank`, scenario `jank`. jank is Clojure
  on LLVM, installed from jank's own repository; the package was built 2026-10-28, binary version
  `cf627abb`. Its scenario is the same without `interrupt`, an op jank's server does not have.

The properties:

- `(+ a b)` answers a + b.
- `*1` right after it is a + b.
- Every answered request ends with `done`, and nothing answers it after.
- An evaluation that throws gets its error back, and its session evaluates on.
- A var defined in one session has its value in another, and completes and looks up there.
- After `(in-ns 'x)`, the session's next evaluation is in `x`.
- What an evaluation prints comes back to it, and nothing another evaluation printed.
- An interrupted evaluation ends interrupted or done.
- After faults, a new session evaluates again.

```
determinismo explore ... --program zig-out/bin/nrepl-test --profile jank --scenario jank
```

## The first smoke (srv3, run 217, 2026-10-30)

Profile `jank`, 2 timelines of 37 s and 19 s. Every property held except "a session keeps its
namespace" (below), with no crash. jank's server idles most of the time: 91% of virtual time
was skipped, at 10 virtual seconds per wall second. The first hunt (1 h) is queued.

## jank 0.1, met while writing the workload (2026-10-30)

Each one was checked against jank's tracker; none was reported upstream.

### Two evaluations kill the whole server

When one of these runs over nREPL, every connected editor loses the server.

- **Integer division by zero dies of SIGFPE.** `(/ 1 0)` and `(/ 0 0)` kill the process. So do
  `apply`, a function, `let` and runtime counts (`(/ 1 (count []))`). `(quot 1 0)`, `(rem 1 0)`,
  `(mod 5 0)` and `(/ 1N 0)` throw "Division by zero is not permitted." as they should.
  - The cause is the known regression of jank#629: `/` on two integers divides natively again,
    so `(/ 2 4)` is `0`, not `1/2`. That report names only the truncation.
- **A stack overflow dies of SIGSEGV, even inside `try`.** For example,
  `((fn deep [n] (if (zero? n) 0 (inc (deep (dec n))))) 100000)`. Clojure throws a
  StackOverflowError the program can catch. Not in the tracker.

The workload's jank timelines leave these two forms out. Otherwise every timeline would end at
them.

### Concurrent evaluations swap each other's output

The probe: three rounds of eight clients at once, each evaluation printing its own mark twice.

- **Most evaluations got the wrong output.** Only 4 of 24 got exactly their two marks. The rest
  got none (client 2 of round 1), one, or other evaluations' marks: client 1 of round 1 got
  marks 12 and 17 beside one of its own.
- **The server's stdout ends up in a deleted file.** After the rounds, its fd 1 pointed at
  `/tmp/jank-nrepl-WVmQWk (deleted)`, so whatever it prints from then on is lost.
- **The cause** is `capture.jank`. To capture an evaluation's output, it points the process's
  own stdout and stderr at a temp file of the evaluation's own (`dup` the fd, then `dup2` the
  temp file over it), and restores the saved fd when the evaluation ends. Two evaluations
  interleave those swaps. One saves the other's temp file as "the original" and restores it
  last.

Concurrent evaluations became possible when jank#1022 was fixed (2026-10-09). This race is not
in the tracker. The workload's `print` driver checks it ("output is its own").

### Wrong answers

- **Out-of-range casts answer `-9223372036854775808`.** This happens for `(long ##Inf)` and
  `(int 1e20)`: C++'s conversion is undefined. Clojure throws "Value out of range for long".
  Not in the tracker.

### Sessions don't hold state

A session is a bare id: `clone` answers `(random-uuid)`.

- **The namespace is not kept.** After `(in-ns 'x)`, whose reply's ns is `x`, the session's
  next evaluation is in `user`. Every request without an `ns` field evaluates in `user`.
  Clojure's server keeps the session in `x`. Not in the tracker.
- **`*1` belongs to the connection, not the session.** It is the thread's binding, and each
  connection has its own thread. On the same connection `*1` is right; a request of the same
  session on another connection reads `nil`.

### Protocol details

- **`completions` and `lookup` need `ns`.** Without it, `completions` answers
  `namespace-not-found` and `lookup` answers an error. nREPL's ops reference makes `ns` optional,
  defaulting to `*ns*`. Editors send it, and so does the workload.
- **Empty messages.** Each part of an evaluation's reply that is `nil` (no output, no error)
  goes out as a message with only an id and a session, before the value.
- **Unsorted keys.** Reply keys are not in sorted order (jank#1088, open).
