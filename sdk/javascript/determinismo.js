// SPDX-License-Identifier: MIT
/**
 * determinismo SDK for JavaScript (Node.js 18+): assertions, events and platform randomness.
 *
 * Inside determinismo everything goes through /dev/determinismo: events are recorded with their
 * moment, and every random value is a decision the platform can steer and replay. Outside it
 * (local runs) randomness comes from the OS and events go to stderr, so the same code runs
 * everywhere. One file, no dependencies: copy it next to your code, or depend on this directory.
 *
 *     const det = require("determinismo");
 *     const account = det.randomBelow(10);
 *     det.always(total === 1000, "total balance is conserved", { total });
 *
 * The assertion catalog: every assertion with a literal message is announced when its module's
 * code loads (CommonJS, TypeScript's compiled output included), before the assertion itself
 * runs (Antithesis's catalog), so one no timeline reaches is judged too. Modules this SDK cannot
 * see load (ES modules, bundles) announce theirs with `catalog(file)`; a message computed at run
 * time is known once it runs.
 *
 * The same API as the other SDKs (sdk/python, sdk/c, sdk/zig, sdk/java, sdk/clojure, sdk/rust; see
 * docs/SDKS.md), in JavaScript's names: randomBytes, randomU64 (a BigInt), randomBelow,
 * randomChoice, random, rng, prng; decide, randomBelowNamed; buggify, buggifyPause; always,
 * alwaysOrUnreachable, sometimes, reachable, unreachable, the guidance comparisons, alwaysSome,
 * sometimesAll, setAssertionEvents; declare, catalog, catalogAssertions, catalogWrite;
 * setupComplete, event, output; stopFaults, fault; coverageStart. Antithesis's TypeScript SDK's
 * names work too (alwaysGreaterThanOrEqualTo, sendEvent, ...): its code runs unchanged.
 *
 * Outside determinismo, events go to the file DETERMINISMO_SDK_LOCAL_OUTPUT names (or
 * Antithesis's ANTITHESIS_SDK_LOCAL_OUTPUT), one JSON object a line, else to stderr.
 */
"use strict";

const fs = require("fs");
const crypto = require("crypto");
const path = require("path");

const DEVICE_PATH = "/dev/determinismo";
const MESSAGE_SIZE_MAX = 4096 - 16; // One event or one randomness pull per device call.
const FAULTS_CONTROL = "/opt/determinismo/faults-control"; // faults.zig's control_path

let device = null;
let deviceOpened = false;

function deviceFd() {
  if (!deviceOpened) {
    deviceOpened = true;
    try {
      device = fs.openSync(DEVICE_PATH, "r+");
    } catch {
      device = null; // Not inside determinismo.
    }
  }
  return device;
}

/** Whether this process runs inside determinismo. */
function inside() {
  return deviceFd() !== null;
}

// Randomness -------------------------------------------------------------------------------

/** `count` random bytes (a Buffer): a platform decision inside determinismo. */
function randomBytes(count) {
  if (!(count > 0 && count <= MESSAGE_SIZE_MAX)) throw new RangeError(`randomBytes: ${count} bytes`);
  const fd = deviceFd();
  if (fd === null) return crypto.randomBytes(count);
  const data = Buffer.alloc(count);
  const read = fs.readSync(fd, data, 0, count, null);
  if (read !== count) throw new Error(`randomBytes: the platform gave ${read} of ${count} bytes`);
  return data;
}

/** A random 64-bit unsigned integer, as a BigInt. */
function randomU64() {
  return randomBytes(8).readBigUInt64LE(0);
}

/** A uniformly random integer in [0, count): a Number (count a Number) or a BigInt. */
function randomBelow(count) {
  if (typeof count === "bigint") {
    if (count <= 0n) throw new RangeError("randomBelow: count must be positive");
    return randomU64() % count;
  }
  if (!(Number.isSafeInteger(count) && count > 0)) throw new RangeError(`randomBelow: ${count}`);
  return Number(randomU64() % BigInt(count));
}

function randomChoice(items) {
  if (items.length === 0) throw new RangeError("randomChoice: no items");
  return items[randomBelow(items.length)];
}

/** A float in [0, 1) from 53 random bits. */
function unitFloat(u64) {
  return Number(u64 >> 11n) / 2 ** 53;
}

/** A float in [0, 1), as Math.random: a platform decision. */
function random() {
  return unitFloat(randomU64());
}

/** Draws for code that takes a generator: each a platform decision (steerable, replayed from
 * tapes); one request to the platform per draw. For hot loops, prng(). */
function rng() {
  return generator(() => randomU64());
}

/** A generator the platform seeds once (SplitMix64): draws cost nothing, and replay with the
 * seed. */
function prng() {
  let state = randomU64();
  return generator(() => {
    state = (state + 0x9e3779b97f4a7c15n) & 0xffffffffffffffffn;
    let z = state;
    z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & 0xffffffffffffffffn;
    z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & 0xffffffffffffffffn;
    return z ^ (z >> 31n);
  });
}

function generator(nextU64) {
  return {
    nextU64,
    /** A float in [0, 1), as Math.random. */
    random: () => unitFloat(nextU64()),
    below(count) {
      if (typeof count === "bigint") return nextU64() % count;
      return Number(nextU64() % BigInt(count));
    },
    choice(items) {
      return items[this.below(items.length)];
    },
    /** Shuffles `items` in place (Fisher-Yates) and returns it. */
    shuffle(items) {
      for (let index = items.length - 1; index > 0; index--) {
        const other = this.below(index + 1);
        [items[index], items[other]] = [items[other], items[index]];
      }
      return items;
    },
  };
}

// Events -----------------------------------------------------------------------------------

/** JSON text of `value`, BigInts as JSON integers (their digits, not a rounded Number), else as
 * JSON.stringify does (escaping, toJSON, undefined left out). */
function toJson(value) {
  if (typeof value === "bigint") return value.toString();
  if (typeof value !== "object" || value === null) return JSON.stringify(value);
  if (value instanceof Error) return toJson({ name: value.name, message: value.message });
  if (typeof value.toJSON === "function") return toJson(value.toJSON());
  if (Array.isArray(value)) return `[${value.map((item) => toJson(item) ?? "null").join(",")}]`;
  const members = [];
  for (const [key, item] of Object.entries(value)) {
    const encoded = toJson(item);
    if (encoded !== undefined) members.push(`${JSON.stringify(key)}:${encoded}`);
  }
  return `{${members.join(",")}}`;
}

let localOutput; // Outside determinismo: the local output file's descriptor, null for stderr.

function localOutputFd() {
  if (localOutput === undefined) {
    localOutput = null;
    const file = process.env.DETERMINISMO_SDK_LOCAL_OUTPUT || process.env.ANTITHESIS_SDK_LOCAL_OUTPUT;
    if (file) {
      try {
        localOutput = fs.openSync(file, "a");
      } catch {
        localOutput = null;
      }
    }
  }
  return localOutput;
}

function emit(message) {
  const line = toJson(message);
  let data = Buffer.from(line);
  if (data.length > MESSAGE_SIZE_MAX) {
    // The assertion must not be lost: drop the details.
    if (message.assert) message.assert.details = "<details too large>";
    data = Buffer.from(toJson(message)).subarray(0, MESSAGE_SIZE_MAX);
  }
  const fd = deviceFd();
  if (fd === null) {
    const local = localOutputFd();
    if (local === null) process.stderr.write(line + "\n");
    else fs.writeSync(local, line + "\n");
    return;
  }
  fs.writeSync(fd, data); // One write, one event.
}

/** Any JSON object as an event of its own (the protocol's raw form: docs/SDKS.md). */
function output(object) {
  emit(object);
}

/** The system is ready: the platform snapshots here and starts exploring. */
function setupComplete(details) {
  emit({ lifecycle: "setup_complete", details: details || {} });
}

/** A structured event: {"event": name, "details": details}. */
function event(name, details) {
  if (!name) throw new RangeError("event: a name");
  emit({ event: name, details: details || {} });
}

// Assertions -------------------------------------------------------------------------------

// Which evaluations become events: "every" one (the default: queries see each), or, as
// Antithesis's SDKs do, each assertion's "first" pass and first failure in this process (for hot
// paths: the same verdict, far fewer events). Set it once, at the start.
let assertionEvents = "every";
const seen = new Set(); // `${condition}\u0000${message}` already sent, in "first" mode.
const located = new Set(); // Assertions whose location this process already sent.
const best = new Map(); // Guidance: the smallest distance sent per message.

function setAssertionEvents(mode) {
  if (mode !== "every" && mode !== "first") throw new RangeError(`assertion events: ${mode}`);
  assertionEvents = mode;
}

/** Where the SDK was called from: the first stack frame outside this file. */
function location() {
  const stack = new Error().stack.split("\n").slice(1);
  for (const frame of stack) {
    const match = frame.match(/at (?:(.*?) \()?(.*?):(\d+):\d+\)?$/);
    if (!match || match[2] === __filename) continue;
    return { file: match[2], line: Number(match[3]), function: match[1] || "" };
  }
  return null;
}

function assertion(kind, condition, message, details) {
  if (!message) throw new RangeError("an assertion needs a message");
  const holds = Boolean(condition);
  if (assertionEvents === "first") {
    const key = `${holds}\u0000${message}`;
    if (seen.has(key)) return;
    seen.add(key);
  }
  const body = { type: kind, message, condition: holds, details: details || {} };
  if (!located.has(message)) {
    // Its location once per process: the platform keeps it.
    located.add(message);
    const at = location();
    if (at) body.location = at;
  }
  emit({ assert: body });
}

function always(condition, message, details) {
  assertion("always", condition, message, details);
}

function alwaysOrUnreachable(condition, message, details) {
  assertion("always_or_unreachable", condition, message, details);
}

function sometimes(condition, message, details) {
  assertion("sometimes", condition, message, details);
}

function reachable(message, details) {
  assertion("reachable", true, message, details);
}

function unreachable(message, details) {
  assertion("unreachable", true, message, details);
}

// Guidance assertions: the compared values in the details, and a guidance event telling
// strategies how far the timeline is from the interesting outcome (an `always` violated, a
// `sometimes` true): `distance`, lower is closer, 0 or less is there.

function guidance(message, distance) {
  const known = best.get(message);
  if (known !== undefined && distance >= known) return; // Only improvements.
  best.set(message, distance);
  emit({ guidance: { message, distance } });
}

function difference(a, b) {
  return typeof a === "bigint" || typeof b === "bigint" ? Number(BigInt(a) - BigInt(b)) : a - b;
}

function compare(kind, holds, margin, left, right, message, details) {
  assertion(kind, holds, message, { left, right, details: details || {} });
  guidance(message, kind === "always" ? margin : -margin);
}

function alwaysGreaterThan(left, right, message, details) {
  compare("always", left > right, difference(left, right), left, right, message, details);
}

function alwaysGreaterThanOrEqual(left, right, message, details) {
  compare("always", left >= right, difference(left, right), left, right, message, details);
}

function alwaysLessThan(left, right, message, details) {
  compare("always", left < right, difference(right, left), left, right, message, details);
}

function alwaysLessThanOrEqual(left, right, message, details) {
  compare("always", left <= right, difference(right, left), left, right, message, details);
}

function sometimesGreaterThan(left, right, message, details) {
  compare("sometimes", left > right, difference(left, right), left, right, message, details);
}

function sometimesGreaterThanOrEqual(left, right, message, details) {
  compare("sometimes", left >= right, difference(left, right), left, right, message, details);
}

function sometimesLessThan(left, right, message, details) {
  compare("sometimes", left < right, difference(right, left), left, right, message, details);
}

function sometimesLessThanOrEqual(left, right, message, details) {
  compare("sometimes", left <= right, difference(right, left), left, right, message, details);
}

/** At least one of the named conditions (an object of booleans, all evaluated) holds, every
 * time. */
function alwaysSome(conditions, message, details) {
  const held = Object.values(conditions).filter(Boolean).length;
  assertion("always", held > 0, message, { conditions, details: details || {} });
  guidance(message, held);
}

/** All the named conditions hold together, at least once. */
function sometimesAll(conditions, message, details) {
  const values = Object.values(conditions);
  const held = values.filter(Boolean).length;
  assertion("sometimes", held === values.length, message, { conditions, details: details || {} });
  guidance(message, values.length - held);
}

// Labeled decisions: the platform's strategies see the name and the options.

/** A named decision among options (which fault, which account, which node): returns the index
 * chosen, a platform decision announced with the options' names. */
function decide(name, options) {
  if (options.length === 0) throw new RangeError("decide: no options");
  if (inside()) emit({ decision: { name, options: options.map(String) } });
  return randomBelow(options.length);
}

/** randomBelow, named for strategies ("retry.jitter_ms"). */
function randomBelowNamed(name, count) {
  if (inside()) emit({ decision: { name, range: typeof count === "bigint" ? count.toString() : count } });
  return randomBelow(count);
}

const buggified = new Map(); // name -> { generator (null when inactive), until (ns) }
const BUGGIFY_PERIOD_NS = 2000000000n;

/** A buggify point (FoundationDB's BUGGIFY): inside determinismo, a point is active one stretch
 * of two seconds (virtual time) in four, a named decision ("buggify <name>") at the stretch's
 * first evaluation; while active, it is true one evaluation in four, drawn from its own generator
 * seeded by the platform for the stretch (a hot point costs a decision a stretch). Outside
 * determinismo, always false. Where it is true, take a rare path the real system can take too (a
 * pause, a retry), never one it cannot. */
function buggify(name) {
  const generator = buggifyGenerator(name);
  return generator !== null && generator.below(4) === 0;
}

/** At a buggify point, a pause of up to 9 ms one evaluation in 32 while the point is active
 * (rarer than buggify: pause points sit on hot paths, and a few pauses a stretch are enough for
 * the others to run in the window). Synchronous (it blocks the event loop, as a slow call does);
 * buggifyPauseAsync awaits instead. */
function buggifyPause(name) {
  const ms = buggifyPauseMs(name);
  if (ms > 0) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

/** buggifyPause for async code: resolves at once, or after the pause. */
function buggifyPauseAsync(name) {
  const ms = buggifyPauseMs(name);
  return new Promise((resolve) => (ms > 0 ? setTimeout(resolve, ms) : resolve()));
}

function buggifyPauseMs(name) {
  const generator = buggifyGenerator(name);
  if (generator === null || generator.below(32) !== 0) return 0;
  return generator.below(10);
}

function buggifyGenerator(name) {
  if (!inside()) return null;
  const now = process.hrtime.bigint(); // Virtual time inside determinismo.
  let point = buggified.get(name);
  if (!point || now >= point.until) {
    const active = randomBelowNamed("buggify " + name, 4) === 0;
    point = { generator: active ? prng() : null, until: now + BUGGIFY_PERIOD_NS };
    buggified.set(name, point);
  }
  return point.generator;
}

// The fault injector ------------------------------------------------------------------------

function faultsControl(message) {
  let fd;
  try {
    fd = fs.openSync(FAULTS_CONTROL, fs.constants.O_WRONLY | fs.constants.O_NONBLOCK);
  } catch {
    return; // No injector running.
  }
  try {
    fs.writeSync(fd, message); // Atomic: under PIPE_BUF.
  } finally {
    fs.closeSync(fd);
  }
}

/** A quiet period (Antithesis's ANTITHESIS_STOP_FAULTS): faults stop for `seconds`, except
 * clock skips; 0 ends it. Only while the fault injector runs. */
function stopFaults(seconds) {
  const header = Buffer.alloc(8);
  header.writeBigUInt64LE(BigInt(Math.round(Math.max(seconds, 0) * 1e9)));
  faultsControl(header);
}

/** A fault now, from the scenario: fault({ kind: "pause", node: "db", duration_ms: 2000 }),
 * fault({ kind: "partition_groups", groups: [["runner", "a"], ["b"]], disruption: "stopped" }).
 * Applied, logged and undone like a drawn one (guest/runtime/faults.zig lists the kinds). Only
 * while the fault injector runs (the drivers). */
function fault(request) {
  const body = Buffer.from(JSON.stringify(request));
  if (body.length + 8 > 4096) throw new RangeError("a fault request is at most 4088 bytes");
  const header = Buffer.alloc(8);
  header.writeBigUInt64LE((1n << 63n) | BigInt(body.length));
  faultsControl(Buffer.concat([header, body]));
}

// Code coverage ----------------------------------------------------------------------------

/** Code coverage for strategies: from now on, each block of code (V8's precise coverage) in
 * files under `paths` (prefixes; all but this SDK's when omitted) emits a "coverage" event the
 * first time this process runs it, as the C and Zig SDKs do for edges, collected every
 * `intervalMs` of (virtual) time and when the process exits. Strategies such as
 * det-strategy-mutate keep the timelines that reach new code. Inside determinismo only. */
function coverageStart(options = {}) {
  if (!inside()) return;
  const inspector = require("inspector");
  const prefixes = options.paths || null;
  const intervalMs = options.intervalMs || 1000;
  const session = new inspector.Session();
  session.connect();
  const reported = new Set();
  const collect = () => {
    session.post("Profiler.takePreciseCoverage", (error, result) => {
      if (error || !result) return;
      for (const script of result.result) {
        const file = script.url.startsWith("file://") ? script.url.slice(7) : script.url;
        if (!file || file === __filename) continue;
        if (prefixes && !prefixes.some((prefix) => file.startsWith(prefix))) continue;
        for (const fn of script.functions) {
          for (const range of fn.ranges) {
            if (range.count === 0) continue;
            const name = `block ${file}:${range.startOffset}`;
            if (reported.has(name)) continue;
            reported.add(name);
            event("coverage", { name });
          }
        }
      }
    });
  };
  session.post("Profiler.enable", () => {
    session.post("Profiler.startPreciseCoverage", { callCount: false, detailed: true }, () => {
      setInterval(collect, intervalMs).unref();
      process.on("exit", collect);
    });
  });
}

// The assertion catalog ---------------------------------------------------------------------

const KINDS = {
  always: ["always", 1],
  alwaysOrUnreachable: ["always_or_unreachable", 1],
  sometimes: ["sometimes", 1],
  reachable: ["reachable", 0],
  unreachable: ["unreachable", 0],
  alwaysSome: ["always", 1],
  sometimesAll: ["sometimes", 1],
};
for (const relation of ["GreaterThan", "GreaterThanOrEqual", "LessThan", "LessThanOrEqual", "GreaterThanOrEqualTo", "LessThanOrEqualTo"]) {
  KINDS["always" + relation] = ["always", 2];
  KINDS["sometimes" + relation] = ["sometimes", 2];
}
const declared = new Map(); // `${kind}\u0000${message}` -> { kind, message, file }
const scanned = new Set();
let announcing = false; // Inside determinismo, declared assertions are announced as they are.

/** Announces an assertion before it runs: one never reached is judged too. Assertions with
 * literal messages in CommonJS modules are announced already. */
function declare(kind, message, file = null) {
  const key = `${kind}\u0000${message}`;
  if (declared.has(key)) return;
  declared.set(key, { kind, message, file });
  if (announcing) emit({ assert: { type: kind, message, hit: false } });
}

/** The assertions the program declares so far (its loaded modules' and declare()'s): an
 * array of { kind, message, file }. */
function catalogAssertions() {
  return [...declared.values()];
}

/** Writes the catalog, one JSON object a line (`{"kind","message","file"}`), to `stream`
 * (process.stdout by default): what a program checks, for review or CI. */
function catalogWrite(stream = process.stdout) {
  for (const entry of catalogAssertions()) stream.write(toJson(entry) + "\n");
}

/** The arguments of the call whose "(" is at `open`: each argument's source text, split at the
 * top level (strings, template literals, brackets skipped). */
function callArguments(source, open) {
  const parts = [];
  let depth = 0;
  let start = open + 1;
  for (let at = open; at < source.length; at++) {
    const char = source[at];
    if (char === '"' || char === "'" || char === "`") {
      for (at++; at < source.length && source[at] !== char; at++) if (source[at] === "\\") at++;
      continue;
    }
    if (char === "(" || char === "[" || char === "{") depth++;
    else if (char === ")" || char === "]" || char === "}") {
      depth--;
      if (depth === 0) {
        parts.push(source.slice(start, at));
        return parts;
      }
    } else if (char === "," && depth === 1) {
      parts.push(source.slice(start, at));
      start = at + 1;
    }
  }
  return parts;
}

/** A plain string literal's value ('...', "..." or `...` without substitutions), else null. */
function literal(text) {
  const trimmed = text.trim();
  if (trimmed.length < 2) return null;
  const quote = trimmed[0];
  if (!(quote === '"' || quote === "'" || quote === "`") || trimmed[trimmed.length - 1] !== quote) return null;
  if (quote === "`" && trimmed.includes("${")) return null;
  try {
    return quote === '"' ? JSON.parse(trimmed) : JSON.parse('"' + trimmed.slice(1, -1).replace(/\\'/g, "'").replace(/"/g, '\\"') + '"');
  } catch {
    return null;
  }
}

/** Declares the assertions of a module's source: calls to this SDK's assertions, through the
 * names the module binds to it (require, import, TypeScript's compiled forms), whose message is a
 * literal. */
function catalogSource(source, file = null) {
  const bindings = new Set();
  const direct = new Map(); // Local name -> the SDK's.
  const requireOf = /(?:const|let|var)\s+(\w+)\s*=\s*(?:__importStar\(|__importDefault\()?\s*require\(\s*["'`][^"'`]*determinismo[^"'`]*["'`]\s*\)/g;
  for (const match of source.matchAll(requireOf)) bindings.add(match[1]);
  const importAll = /import\s+\*\s+as\s+(\w+)\s+from\s+["'][^"']*determinismo[^"']*["']/g;
  for (const match of source.matchAll(importAll)) bindings.add(match[1]);
  const destructured = /(?:(?:const|let|var)\s*\{([^}]*)\}\s*=\s*require\(\s*["'][^"']*determinismo[^"']*["']\s*\))|(?:import\s*\{([^}]*)\}\s*from\s*["'][^"']*determinismo[^"']*["'])/g;
  for (const match of source.matchAll(destructured)) {
    for (const entry of (match[1] || match[2]).split(",")) {
      const [name, alias] = entry.split(/\s*(?::|\bas\b)\s*/).map((part) => part.trim());
      if (KINDS[name]) direct.set(alias || name, name);
    }
  }
  if (bindings.size === 0 && direct.size === 0) return;
  const call = /(\w+)\.(\w+)\s*\)?\s*\(|\b(\w+)\s*\(/g;
  for (const match of source.matchAll(call)) {
    let called = null;
    if (match[1] && bindings.has(match[1]) && KINDS[match[2]]) called = match[2];
    else if (match[3] && direct.has(match[3])) called = direct.get(match[3]);
    if (!called) continue;
    const open = match.index + match[0].lastIndexOf("(");
    const [kind, position] = KINDS[called];
    const argument = callArguments(source, open)[position];
    const message = argument === undefined ? null : literal(argument);
    if (message) declare(kind, message, file);
  }
}

/** Announces the assertions of `file` (a module this SDK did not see load: an ES module, a
 * bundle). */
function catalog(file) {
  const resolved = path.resolve(file);
  if (scanned.has(resolved) || resolved === __filename) return;
  scanned.add(resolved);
  let source;
  try {
    source = fs.readFileSync(resolved, "utf8");
  } catch {
    return;
  }
  catalogSource(source, resolved);
}

function catalogStart() {
  // Outside determinismo too: catalogAssertions() lists them, but nothing is announced.
  announcing = inside();
  const Module = require("module");
  // The modules that loaded before this SDK, then every one that loads after.
  for (const loaded of Object.values(require.cache)) if (loaded && loaded.filename) catalog(loaded.filename);
  const compile = Module.prototype._compile;
  Module.prototype._compile = function (content, filename) {
    if (filename && !scanned.has(filename) && filename !== __filename) {
      scanned.add(filename);
      catalogSource(content, filename);
    }
    return compile.call(this, content, filename);
  };
  if (process.argv[1]) catalog(process.argv[1]);
}

catalogStart();

module.exports = {
  inside,
  randomBytes,
  randomU64,
  randomBelow,
  randomChoice,
  random,
  rng,
  prng,
  decide,
  randomBelowNamed,
  buggify,
  buggifyPause,
  buggifyPauseAsync,
  setAssertionEvents,
  always,
  alwaysOrUnreachable,
  sometimes,
  reachable,
  unreachable,
  alwaysGreaterThan,
  alwaysGreaterThanOrEqual,
  alwaysLessThan,
  alwaysLessThanOrEqual,
  sometimesGreaterThan,
  sometimesGreaterThanOrEqual,
  sometimesLessThan,
  sometimesLessThanOrEqual,
  alwaysSome,
  sometimesAll,
  declare,
  catalog,
  catalogAssertions,
  catalogWrite,
  setupComplete,
  event,
  output,
  stopFaults,
  fault,
  coverageStart,
  // Antithesis's TypeScript SDK's names.
  alwaysGreaterThanOrEqualTo: alwaysGreaterThanOrEqual,
  alwaysLessThanOrEqualTo: alwaysLessThanOrEqual,
  sometimesGreaterThanOrEqualTo: sometimesGreaterThanOrEqual,
  sometimesLessThanOrEqualTo: sometimesLessThanOrEqual,
  sendEvent: event,
};
