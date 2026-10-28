// SPDX-License-Identifier: MIT
// Quint (a specification language of the TLA family: github.com/quint-co/quint) under test. Its
// CLI (TypeScript) and its evaluator (Rust) run patched (../quint.patch): the SDKs' assertions
// mark an internal error anywhere and the simulator's own invariants. This service exercises
// them, one request per connection, all choices platform decisions:
//   "eval"       generated Quint expressions (integers near 2^31, 2^53 and 2^63, sets, lists,
//                maps, folds, lambdas), each evaluated by both backends' REPLs: the same value,
//                or the same error, unless the Rust one reports QNT600 or QNT601 (it computes
//                in 64 bits, as documented); integers printed as integers.
//   "simulate"   an example specification simulated twice with the same seed, on a backend:
//                the same outcome, the same output.
//   "test"       an example's tests (the examples dashboard's passing ones) on both backends:
//                they pass on both.
//   "typecheck"  an example specification mutated (a line dropped, doubled or two swapped, a
//                token changed): parsed and typechecked twice, the same answer, and never an
//                internal error.
// Replies: "ok" or "error <message>".
"use strict";

const det = require("determinismo"); // sdk/javascript
const net = require("net");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFile } = require("child_process");

const PORT = 7200;
const QUINT = process.env.QUINT_BIN || "/usr/local/bin/quint";
const EXAMPLES = process.env.QUINT_EXAMPLES || "/src/quint/examples";
// The examples whose dashboard says their tests pass, with their --main (made at build time).
const MANIFEST = JSON.parse(fs.readFileSync(process.env.QUINT_MANIFEST || "/app/manifest.json", "utf8"));
const TIMEOUT_MS = 120000;

/** Quint processes at once: each is a Node.js CLI (and a Rust evaluator under it), hundreds of
 * MB; parallel drivers asking at once filled a 4 GB machine, and the kernel's OOM killer took
 * this service (Quint's first run inside determinismo, srv3 run 21). The others wait. */
const QUINT_AT_ONCE = 2;
let quintRunning = 0;
const quintWaiting = [];

/** Runs quint with `args` (stdin from `input`): { code, stdout, stderr }, never throwing. */
async function quint(args, input) {
  if (quintRunning === QUINT_AT_ONCE) await new Promise((resolve) => quintWaiting.push(resolve));
  quintRunning += 1;
  try {
    return await new Promise((resolve) => {
      const child = execFile(QUINT, args, { timeout: TIMEOUT_MS, maxBuffer: 64 << 20 }, (error, stdout, stderr) => {
        const code = error ? (typeof error.code === "number" ? error.code : error.killed ? "timeout" : "error") : 0;
        resolve({ code, stdout, stderr });
      });
      if (input !== undefined) child.stdin.end(input);
    });
  } finally {
    quintRunning -= 1;
    const next = quintWaiting.shift();
    if (next) next();
  }
}

/** What no Quint command may print: an internal error's traces (a JavaScript exception, a Rust
 * panic), as opposed to the errors Quint reports about a specification. */
const INTERNAL = [
  // A JavaScript stack frame: in a .js or .ts file, or Node's own; not the trace of a
  // specification's runtime error (`at transfer(...) (/src/.../bank.qnt:193:7)`, run 25).
  /\bat [^\n]*\((?:[^()\n]*\.(?:[cm]?js|ts)|node:[\w/.:-]+):\d+:\d+\)/,
  /\b(TypeError|RangeError|ReferenceError|SyntaxError|InternalError): /,
  /Maximum call stack size exceeded/,
  /panicked at /,
  /thread '.*' panicked/,
  /RUST_BACKTRACE/,
];

function internalError(text) {
  const match = INTERNAL.find((pattern) => pattern.test(text));
  return match ? text.slice(Math.max(0, text.search(match) - 200), text.search(match) + 600) : null;
}

// --- Expressions -----------------------------------------------------------------------------

/** A platform decision among n, named for strategies. */
function pick(name, n) {
  return det.randomBelowNamed(name, n);
}

/** An integer literal, from buckets where the evaluators may part: small, around 2^31, 2^53
 * (JavaScript's exact integers), 2^63 (the Rust evaluator's 64 bits), and beyond. */
function intLiteral() {
  const bucket = pick("quint.int.bucket", 6);
  const offset = BigInt(pick("quint.int.offset", 7)) - 3n;
  const sign = pick("quint.int.sign", 2) === 0 ? 1n : -1n;
  let value;
  if (bucket === 0) value = BigInt(pick("quint.int.small", 21)) - 10n;
  else if (bucket === 1) value = sign * (2n ** 31n + offset);
  else if (bucket === 2) value = sign * (2n ** 53n + offset);
  else if (bucket === 3) value = sign * (2n ** 63n + offset);
  else if (bucket === 4) value = sign * (2n ** 64n + offset);
  else value = BigInt(pick("quint.int.medium", 2000001)) - 1000000n;
  return value < 0n ? `(${value})` : `${value}`;
}

/** An expression of `type` (int, bool, set, list, map), `depth` levels deep at most, over the
 * integer variables in `vars` (lambda parameters). */
function expression(type, depth, vars) {
  const leaf = depth <= 0;
  const intVar = () => (vars.length > 0 && pick("quint.var", 3) === 0 ? vars[pick("quint.var.which", vars.length)] : intLiteral());
  const sub = (t) => expression(t, depth - 1, vars);
  const lambda = (body) => {
    const name = `x${vars.length}`;
    return `${name} => ${expression(body, depth - 1, [...vars, name])}`;
  };
  switch (type) {
    case "int": {
      if (leaf) return intVar();
      const form = pick("quint.int.form", 12);
      if (form === 0) return intVar();
      if (form === 1) return `-(${sub("int")})`;
      if (form <= 5) return `(${sub("int")} ${["+", "-", "*", "/"][form - 2]} ${sub("int")})`;
      if (form === 6) return `(${sub("int")} % ${sub("int")})`;
      if (form === 7) return `(${sub("int")}^${pick("quint.int.exponent", 70)})`;
      if (form === 8) return `${sub("set")}.size()`;
      if (form === 9) return `${sub("list")}.length()`;
      if (form === 10) return `${sub("set")}.fold(0, (acc, y) => acc + y)`;
      return `(if (${sub("bool")}) ${sub("int")} else ${sub("int")})`;
    }
    case "bool": {
      if (leaf) return pick("quint.bool.literal", 2) === 0 ? "true" : "false";
      const form = pick("quint.bool.form", 8);
      if (form <= 3) return `(${sub("int")} ${["<", "<=", "==", "!="][form]} ${sub("int")})`;
      if (form === 4) return `(${sub("bool")} ${["and", "or", "implies", "iff"][pick("quint.bool.op", 4)]} ${sub("bool")})`;
      if (form === 5) return `${sub("set")}.contains(${sub("int")})`;
      if (form === 6) return `${sub("set")}.exists(${lambda("bool")})`;
      return `${sub("set")}.subseteq(${sub("set")})`;
    }
    case "set": {
      if (leaf) {
        const start = intVar();
        return `${start}.to(${start} + ${pick("quint.set.span", 4)})`;
      }
      const form = pick("quint.set.form", 7);
      if (form === 0) return `Set(${[sub("int"), sub("int"), sub("int")].slice(0, 1 + pick("quint.set.count", 3)).join(", ")})`;
      if (form <= 3) return `${sub("set")}.${["union", "intersect", "exclude"][form - 1]}(${sub("set")})`;
      if (form === 4) return `${sub("set")}.map(${lambda("int")})`;
      if (form === 5) return `${sub("set")}.filter(${lambda("bool")})`;
      return `${sub("map")}.keys()`;
    }
    case "list": {
      if (leaf) {
        const start = intVar();
        // range(i, j) with i > j is undefined (builtin.qnt): j is i plus a span.
        return `range(${start}, ${start} + ${pick("quint.list.span", 4)})`;
      }
      const form = pick("quint.list.form", 6);
      if (form === 0) return `[${[sub("int"), sub("int")].slice(0, 1 + pick("quint.list.count", 2)).join(", ")}]`;
      if (form === 1) return `${sub("list")}.concat(${sub("list")})`;
      if (form === 2) return `${sub("list")}.append(${sub("int")})`;
      if (form === 3) return `${sub("list")}.select(${lambda("bool")})`;
      if (form === 4) return `${sub("list")}.foldl([], (acc, y) => acc.append(y))`;
      return `range(0, 3).foldl(${sub("list")}, (acc, i) => acc.append(i))`;
    }
    case "map": {
      if (leaf) return `Map(${intVar()} -> ${intVar()})`;
      const form = pick("quint.map.form", 3);
      if (form === 0) return `${sub("set")}.mapBy(${lambda("int")})`;
      if (form === 1) return `${sub("map")}.put(${sub("int")}, ${sub("int")})`;
      return `Map(${sub("int")} -> ${sub("int")}, ${sub("int")} -> ${sub("int")})`;
    }
    default:
      throw new Error(`no expressions of type ${type}`);
  }
}

/** bignumber.js's object text ({ s: 1, e: 15, c: [90, 7199254740993] }) as the integer it is. */
function bignumberDigits(text) {
  return text.replace(/\{\s*s:\s*(-?1),\s*e:\s*(\d+),\s*c:\s*\[([\d,\s]+)\]\s*\}/g, (_all, s, _e, chunks) => {
    const parts = chunks.split(",").map((part) => part.trim());
    const digits = parts[0] + parts.slice(1).map((part) => part.padStart(14, "0")).join("");
    return (s === "-1" ? "-" : "") + digits.replace(/^0+(?=\d)/, "");
  });
}

/** Each expression's answer in a REPL's output (expressions separated by sentinel strings):
 * a value's text (whitespace collapsed), or "error <code>". */
function answers(stdout, count) {
  const parts = stdout.split(/"<<det-sentinel-\d+>>"\n?/);
  const result = [];
  for (let index = 0; index < count; index++) {
    const text = (parts[index] || "").trim();
    const error = text.match(/Error \[(QNT\d+)\]/);
    result.push(error ? `error ${error[1]}` : text.replace(/\s+/g, " "));
  }
  return result;
}

async function checkEval() {
  const count = 8;
  const types = ["int", "bool", "set", "list", "map"];
  const expressions = [];
  for (let index = 0; index < count; index++) {
    expressions.push(expression(types[pick("quint.eval.type", types.length)], 1 + pick("quint.eval.depth", 3), []));
  }
  const input = expressions.map((text, index) => `${text}\n"<<det-sentinel-${index}>>"\n`).join("");
  const [typescript, rust] = await Promise.all([
    quint(["repl", "-q", "--backend", "typescript"], input),
    quint(["repl", "-q", "--backend", "rust"], input),
  ]);
  for (const [backend, run] of [["typescript", typescript], ["rust", rust]]) {
    const internal = internalError(run.stdout + run.stderr);
    det.always(internal === null, "the REPL never fails with an internal error", { backend, internal, expressions });
  }
  det.always(!/\{\s*s:\s*-?1,\s*e:\s*\d+,\s*c:\s*\[/.test(rust.stdout), "the REPL prints integers as integers", {
    backend: "rust",
    output: rust.stdout.slice(0, 2000),
  });
  const fromTypescript = answers(typescript.stdout, count);
  const fromRust = answers(bignumberDigits(rust.stdout), count);
  for (let index = 0; index < count; index++) {
    const a = fromTypescript[index];
    const b = fromRust[index];
    // QNT600 (a literal) and QNT601 (a result) outside 64 bits: the Rust evaluator's
    // documented limit (docs/lessons/integers.md).
    const overflow = b === "error QNT601" || b === "error QNT600";
    det.sometimes(overflow, "the Rust evaluator reports a 64-bit overflow", {});
    det.sometimes(a === b && !a.startsWith("error"), "both evaluators compute a value", {});
    det.always(overflow || a === b, "the TypeScript and Rust evaluators agree", {
      expression: expressions[index],
      typescript: a,
      rust: b,
    });
  }
}

// --- Specifications --------------------------------------------------------------------------

function specification() {
  const index = pick("quint.spec", MANIFEST.length);
  return MANIFEST[index];
}

/** A simulation's output without what varies by itself (timings). */
function stable(text) {
  return text.replace(/\(\d+ms(?: at \d+ traces\/second)?\)/g, "(ms)").replace(/\d+ms\b/g, "ms");
}

async function checkSimulate() {
  const runnable = MANIFEST.filter((entry) => entry.runs);
  const spec = runnable[pick("quint.simulate.spec", runnable.length)];
  const backend = pick("quint.simulate.backend", 2) === 0 ? "typescript" : "rust";
  const seed = det.randomU64().toString();
  const args = ["run", ...spec.main, "--backend", backend, `--seed=${seed}`, `--max-samples=${10 + pick("quint.simulate.samples", 90)}`,
    `--max-steps=${1 + pick("quint.simulate.steps", 20)}`, path.join(EXAMPLES, spec.file)];
  const first = await quint(args);
  const second = await quint(args);
  for (const run of [first, second]) {
    const internal = internalError(run.stdout + run.stderr);
    det.always(internal === null, "a simulation never fails with an internal error", { spec: spec.file, backend, internal });
  }
  const [a, b] = [stable(first.stdout), stable(second.stdout)];
  let at = 0; // Where the two outputs part: each shown around it.
  while (at < a.length && at < b.length && a[at] === b[at]) at++;
  const around = (text) => text.slice(Math.max(0, at - 300), at + 700);
  det.always(first.code === second.code && a === b, "a simulation is the same for the same seed", {
    spec: spec.file, backend, seed, command: ["quint", ...args].join(" "), differ_at: at,
    first: { code: first.code, length: a.length, around: around(a), stderr: first.stderr.slice(-500) },
    second: { code: second.code, length: b.length, around: around(b), stderr: second.stderr.slice(-500) },
  });
  det.sometimes(first.code === 0, "a simulation finds no violation", { backend });
  det.sometimes(first.code === 1, "a simulation reports something", { backend });
}

async function checkTest() {
  const spec = specification();
  const seed = det.randomU64().toString();
  const run = (backend) => quint(["test", ...spec.main, "--backend", backend, `--seed=${seed}`,
    `--max-samples=${5 + pick("quint.test.samples", 45)}`, path.join(EXAMPLES, spec.file)]);
  const [typescript, rust] = await Promise.all([run("typescript"), run("rust")]);
  for (const [backend, result] of [["typescript", typescript], ["rust", rust]]) {
    const internal = internalError(result.stdout + result.stderr);
    det.always(internal === null, "quint test never fails with an internal error", { spec: spec.file, backend, internal });
    det.always(result.code === 0, "an example's tests pass on each backend", {
      spec: spec.file, backend, seed, code: result.code, output: (result.stdout + result.stderr).slice(-2000),
    });
  }
}

/** The specification's text, mutated: a line dropped, doubled or two swapped, or a token of one
 * line changed (a platform decision each). */
function mutate(source) {
  const lines = source.split("\n");
  const at = pick("quint.mutate.line", lines.length);
  const kind = pick("quint.mutate.kind", 4);
  if (kind === 0) lines.splice(at, 1);
  else if (kind === 1) lines.splice(at, 0, lines[at]);
  else if (kind === 2) {
    const other = pick("quint.mutate.other", lines.length);
    [lines[at], lines[other]] = [lines[other], lines[at]];
  } else {
    const tokens = lines[at].split(/(\s+)/);
    const replacements = ["true", "0", "x", "Set()", "+", "and", "{", "}", "(", ")", "=>", "val", "def", "Int", "\"s\""];
    const token = pick("quint.mutate.token", Math.max(1, tokens.length));
    tokens[token] = replacements[pick("quint.mutate.with", replacements.length)];
    lines[at] = tokens.join("");
  }
  return lines.join("\n");
}

async function checkTypecheck() {
  const spec = specification();
  const original = fs.readFileSync(path.join(EXAMPLES, spec.file), "utf8");
  const mutated = mutate(original);
  // Beside the original: its imports resolve as they did.
  const file = path.join(path.dirname(path.join(EXAMPLES, spec.file)), `.det-mutant-${process.pid}-${pick("quint.mutant", 1 << 30)}.qnt`);
  fs.writeFileSync(file, mutated);
  try {
    const first = await quint(["typecheck", file]);
    const second = await quint(["typecheck", file]);
    for (const run of [first, second]) {
      const internal = internalError(run.stdout + run.stderr);
      det.always(internal === null, "typechecking never fails with an internal error", { spec: spec.file, internal });
      det.always(run.code === 0 || run.code === 1, "typechecking answers yes or no", { spec: spec.file, code: run.code });
    }
    det.always(first.code === second.code && first.stdout === second.stdout && first.stderr.replace(file, "") === second.stderr.replace(file, ""),
      "typechecking gives the same answer twice", { spec: spec.file });
    det.sometimes(first.code === 0, "a mutant typechecks", {});
    det.sometimes(first.code === 1, "a mutant is rejected", {});
  } finally {
    fs.rmSync(file, { force: true });
  }
}

const CHECKS = { eval: checkEval, simulate: checkSimulate, test: checkTest, typecheck: checkTypecheck };

const server = net.createServer((socket) => {
  let request = "";
  socket.on("data", async (data) => {
    request += data.toString();
    if (!request.includes("\n")) return;
    const command = request.trim();
    const check = CHECKS[command];
    try {
      if (!check) throw new Error(`no check named ${command}`);
      await check();
      socket.end("ok\n");
    } catch (error) {
      socket.end(`error ${String(error && error.message).replace(/\s+/g, " ").slice(0, 300)}\n`);
    }
  });
  socket.on("error", () => {});
});

server.listen(PORT, "0.0.0.0", () => {
  det.event("quint_check_ready", { examples: MANIFEST.length, cpus: os.cpus().length });
});
