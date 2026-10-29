# SPDX-License-Identifier: MIT
"""determinismo SDK for Python: assertions, events and platform randomness.

Inside determinismo everything goes through /dev/determinismo: events are recorded with their
moment, and every random value is a decision the platform can steer and replay. Outside it
(local runs) randomness comes from the OS and events go to the file DETERMINISMO_SDK_LOCAL_OUTPUT
(or Antithesis's ANTITHESIS_SDK_LOCAL_OUTPUT) names, one JSON object a line, else to stderr, so
the same code runs everywhere. One file, standard library only: copy it next to your code.

The same API as the other SDKs (docs/SDKS.md); Antithesis's Python SDK's names work too
(get_random, send_event, always_greater_than_or_equal_to, ...).

    import determinismo as det
    account = det.random_below(10)
    det.always(total == 1000, "total balance is conserved", {"total": total})

The assertion catalog: every assertion with a literal message is announced when its module's
code runs (imported or executed), before the assertion itself runs (Antithesis's catalog), so
one no timeline reaches is judged too. A message computed at run time is known once it runs.
"""
import ast
import json
import random
import os
import sys
import threading
import time

DEVICE_PATH = "/dev/determinismo"
MESSAGE_SIZE_MAX = 4096 - 16  # One event or one randomness pull per device call.

_device = None
_device_opened = False


def _device_fd():
    global _device, _device_opened
    if not _device_opened:
        _device_opened = True
        try:
            _device = os.open(DEVICE_PATH, os.O_RDWR | os.O_CLOEXEC)
        except OSError:
            _device = None  # Not inside determinismo.
    return _device


def random_bytes(count):
    """`count` random bytes: a platform decision inside determinismo."""
    assert 0 < count <= MESSAGE_SIZE_MAX
    fd = _device_fd()
    if fd is None:
        return os.urandom(count)
    data = os.read(fd, count)
    assert len(data) == count
    return data


def random_u64():
    return int.from_bytes(random_bytes(8), "little")


def random_below(count):
    """A uniformly random integer in [0, count)."""
    assert count > 0
    return random_u64() % count


def random_choice(items):
    assert len(items) > 0
    return items[random_below(len(items))]


def random_float():
    """A float in [0, 1) from 53 random bits: a platform decision."""
    return (random_u64() >> 11) * (1.0 / (1 << 53))


get_random = random_u64  # Antithesis's name.


class Random(random.Random):
    """A random.Random whose every draw is a platform decision, for code that takes an RNG
    (shuffle, choice, sample, uniform, ...): what it draws is steerable by strategies and replays
    from tapes. Each draw is one request to the platform; for hot loops, prng()."""

    def seed(self, *arguments, **options):
        pass  # The platform decides.

    def random(self):
        return (random_u64() >> 11) * (1.0 / (1 << 53))

    def getrandbits(self, k):
        if k <= 0:
            return 0
        return int.from_bytes(random_bytes((k + 7) // 8), "little") >> (-k % 8)

    def getstate(self):
        raise NotImplementedError("platform randomness has no state to save")

    def setstate(self, state):
        raise NotImplementedError("platform randomness has no state to restore")


def rng():
    """A random.Random backed by platform decisions (see Random)."""
    return Random()


def prng():
    """A fast random.Random seeded from one platform decision: deterministic and different in
    every branch, steered only through its seed."""
    return random.Random(random_u64())


_local_output = None
_local_output_opened = False


def _local_output_fd():
    global _local_output, _local_output_opened
    if not _local_output_opened:
        _local_output_opened = True
        path = os.environ.get("DETERMINISMO_SDK_LOCAL_OUTPUT") or os.environ.get(
            "ANTITHESIS_SDK_LOCAL_OUTPUT")
        if path:
            try:
                _local_output = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_CLOEXEC,
                                        0o644)
            except OSError:
                _local_output = None
    return _local_output


def _emit(message):
    line = json.dumps(message, separators=(",", ":"), default=str)
    data = line.encode()
    if len(data) > MESSAGE_SIZE_MAX:  # The assertion must not be lost: drop the details.
        if "assert" in message:
            message["assert"]["details"] = "<details too large>"
        data = json.dumps(message, separators=(",", ":")).encode()[:MESSAGE_SIZE_MAX]
    fd = _device_fd()
    if fd is None:
        local = _local_output_fd()
        if local is None:
            sys.stderr.write(line + "\n")
        else:
            os.write(local, (line + "\n").encode())
        return
    os.write(fd, data)  # One write, one event.


def output(message):
    """Any JSON object as an event of its own (the protocol's raw form: docs/SDKS.md)."""
    _emit(message)


_located = set()  # Assertions whose location this process already sent.

# Which evaluations become events: "every" one (the default: queries see each), or, as
# Antithesis's SDKs do, each assertion's "first" pass and first failure in this process (for hot
# paths: the same verdict, far fewer events). Set it once, at the start.
assertion_events = "every"
_seen = set()  # (message, condition) already sent, in "first" mode.
_best = {}  # Guidance: the smallest distance sent per message.


def _location():
    """Where the SDK was called from: the first frame outside this file."""
    frame = sys._getframe(1)
    while frame is not None and frame.f_code.co_filename == __file__:
        frame = frame.f_back
    if frame is None:
        return None
    return {"file": frame.f_code.co_filename, "line": frame.f_lineno,
            "function": frame.f_code.co_name}


def _assert(kind, condition, message, details):
    assert message
    if assertion_events == "first":
        if (message, bool(condition)) in _seen:
            return
        _seen.add((message, bool(condition)))
    assertion = {"type": kind, "message": message, "condition": bool(condition),
                 "details": details or {}}
    if message not in _located:  # Its location once per process: the platform keeps it.
        _located.add(message)
        location = _location()
        if location:
            assertion["location"] = location
    _emit({"assert": assertion})


def always(condition, message, details=None):
    _assert("always", condition, message, details)


def always_or_unreachable(condition, message, details=None):
    _assert("always_or_unreachable", condition, message, details)


def sometimes(condition, message, details=None):
    _assert("sometimes", condition, message, details)


def reachable(message, details=None):
    _assert("reachable", True, message, details)


def unreachable(message, details=None):
    _assert("unreachable", True, message, details)


# Guidance assertions: the compared values in the details, and a guidance event telling
# strategies how far the timeline is from the interesting outcome (an `always` violated, a
# `sometimes` true): `distance`, lower is closer, 0 or less is there.

def _guidance(message, distance):
    # Only improvements: all a strategy needs.
    if distance >= _best.get(message, float("inf")):
        return
    _best[message] = distance
    _emit({"guidance": {"message": message, "distance": distance}})


def _compare(kind, holds, margin, left, right, message, details):
    merged = {"left": left, "right": right, "details": details or {}}
    _assert(kind, holds, message, merged)
    _guidance(message, margin if kind == "always" else -margin)


def always_greater_than(left, right, message, details=None):
    _compare("always", left > right, left - right, left, right, message, details)


def always_greater_than_or_equal(left, right, message, details=None):
    _compare("always", left >= right, left - right, left, right, message, details)


def always_less_than(left, right, message, details=None):
    _compare("always", left < right, right - left, left, right, message, details)


def always_less_than_or_equal(left, right, message, details=None):
    _compare("always", left <= right, right - left, left, right, message, details)


def sometimes_greater_than(left, right, message, details=None):
    _compare("sometimes", left > right, left - right, left, right, message, details)


def sometimes_greater_than_or_equal(left, right, message, details=None):
    _compare("sometimes", left >= right, left - right, left, right, message, details)


def sometimes_less_than(left, right, message, details=None):
    _compare("sometimes", left < right, right - left, left, right, message, details)


def sometimes_less_than_or_equal(left, right, message, details=None):
    _compare("sometimes", left <= right, right - left, left, right, message, details)


# Antithesis's names.
always_greater_than_or_equal_to = always_greater_than_or_equal
always_less_than_or_equal_to = always_less_than_or_equal
sometimes_greater_than_or_equal_to = sometimes_greater_than_or_equal
sometimes_less_than_or_equal_to = sometimes_less_than_or_equal


def always_some(conditions, message, details=None):
    """At least one of the named conditions (a dict of bools, all evaluated) holds, every time."""
    held = sum(1 for value in conditions.values() if value)
    _assert("always", held > 0, message, {"conditions": conditions, "details": details or {}})
    _guidance(message, held)


def sometimes_all(conditions, message, details=None):
    """All the named conditions hold together, at least once."""
    held = sum(1 for value in conditions.values() if value)
    _assert("sometimes", held == len(conditions), message,
            {"conditions": conditions, "details": details or {}})
    _guidance(message, len(conditions) - held)


# Labeled decisions: the platform's strategies see the name and the options.

def decide(name, options):
    """A named decision among options (which fault, which account, which node): returns the
    index chosen, a platform decision announced with the options' names."""
    assert options
    if _device_fd() is not None:
        _emit({"decision": {"name": name, "options": [str(option) for option in options]}})
    return random_below(len(options))


def random_below_named(name, count):
    """`random_below`, named for strategies ("retry.jitter_ms")."""
    if _device_fd() is not None:
        _emit({"decision": {"name": name, "range": count}})
    return random_below(count)


_buggify_lock = threading.Lock()
_buggified = {}  # name -> (random.Random, or None when inactive; end of the stretch, ns)
_BUGGIFY_PERIOD_NS = 2_000_000_000


def buggify(name):
    """A buggify point (FoundationDB's BUGGIFY): inside determinismo, a point is active one
    stretch of two seconds (virtual time) in four, a named decision ("buggify <name>") at the
    stretch's first evaluation; while active, it is True one evaluation in four, drawn from its own
    generator seeded by the platform for the stretch (a hot point costs a decision a stretch).
    Outside determinismo, always False. Where it is True, take a rare path the real system can
    take too (a pause, a retry), never one it cannot."""
    with _buggify_lock:
        generator = _buggify_generator(name)
        return generator is not None and generator.randrange(4) == 0


def buggify_pause(name):
    """At a buggify point, a pause of up to 9 ms one evaluation in 32 while the point is active
    (rarer than buggify: pause points sit on hot paths, and a few pauses a stretch are enough for
    the other threads to run in the window)."""
    with _buggify_lock:
        generator = _buggify_generator(name)
        if generator is None or generator.randrange(32) != 0:
            return
        ms = generator.randrange(10)
    if ms:
        time.sleep(ms / 1000)


def _buggify_generator(name):
    if _device_fd() is None:
        return None
    now = time.monotonic_ns()  # Virtual time inside determinismo.
    generator, until = _buggified.get(name, (None, 0))
    if now >= until:
        active = random_below_named("buggify " + name, 4) == 0
        generator = random.Random(random_u64()) if active else None
        _buggified[name] = (generator, now + _BUGGIFY_PERIOD_NS)
    return generator


def setup_complete(details=None):
    """The system is ready: the platform snapshots here and starts exploring."""
    _emit({"lifecycle": "setup_complete", "details": details or {}})


def event(name, details=None):
    """A structured event: {"event": name, "details": details}."""
    assert name
    _emit({"event": name, "details": details or {}})


send_event = event  # Antithesis's name.


_FAULTS_CONTROL = "/opt/determinismo/faults-control"  # faults.zig's control_path


def _faults_control(message):
    try:
        fd = os.open(_FAULTS_CONTROL, os.O_WRONLY | os.O_NONBLOCK)
    except OSError:
        return  # No injector running.
    try:
        os.write(fd, message)  # Atomic: under PIPE_BUF.
    finally:
        os.close(fd)


def stop_faults(seconds):
    """A quiet period (Antithesis's ANTITHESIS_STOP_FAULTS): faults stop for `seconds`,
    except clock skips; 0 ends it. Only while the fault injector runs."""
    _faults_control(int(max(seconds, 0) * 1e9).to_bytes(8, "little"))


def fault(**request):
    """A fault now, from the scenario: fault(kind="pause", node="db", duration_ms=2000),
    fault(kind="partition_groups", groups=[["runner", "a"], ["b"]], disruption="stopped").
    Applied, logged and undone like a drawn one (guest/runtime/faults.zig lists the kinds).
    Only while the fault injector runs (the drivers)."""
    body = json.dumps(request).encode()
    if len(body) + 8 > 4096:
        raise ValueError("a fault request is at most 4088 bytes")
    _faults_control(((1 << 63) | len(body)).to_bytes(8, "little") + body)


def fault_aim(node):
    """Aims the fault injector at `node` from now on, until another call ("" for none): half its
    faults involve it, each a decision strategies see and replays repeat. For the node that
    matters most at the moment (a primary, a leader), as Jepsen's nemeses target one."""
    name = node.encode()[:32]
    _faults_control(((1 << 61) | len(name)).to_bytes(8, "little") + name)


def coverage_start(paths=None):
    """Code coverage for strategies (Python 3.12+): from now on, each line of code under `paths`
    (prefixes of file names; None for every file but this SDK's) emits a "coverage" event the
    first time this process runs it, as the C and Zig SDKs do for edges. Strategies such as
    det-strategy-mutate keep the timelines that reach new code. A line costs nothing once
    reported: sys.monitoring stops watching it."""
    monitoring = sys.monitoring
    tool = monitoring.COVERAGE_ID
    monitoring.use_tool_id(tool, "determinismo")
    prefixes = tuple(paths) if paths else None

    def line(code, number):
        file = code.co_filename
        if file != __file__ and (prefixes is None or file.startswith(prefixes)):
            event("coverage", {"name": f"line {file}:{number}"})
        return monitoring.DISABLE

    monitoring.register_callback(tool, monitoring.events.LINE, line)
    monitoring.set_events(tool, monitoring.events.LINE)


# The assertion catalog ---------------------------------------------------------------------

_KINDS = ("always", "always_or_unreachable", "sometimes", "reachable", "unreachable")
# Guidance assertions: their kind, and where their message is among the arguments.
_GUIDED = {name: ("always" if name.startswith("always") else "sometimes", position)
           for name, position in [(f"{kind}_{relation}", 2)
                                  for kind in ("always", "sometimes")
                                  for relation in ("greater_than_or_equal_to",
                                                   "less_than_or_equal_to",
                                                   "greater_than", "greater_than_or_equal",
                                                   "less_than", "less_than_or_equal")]
           + [("always_some", 1), ("sometimes_all", 1)]}
_declared = {}  # (kind, message) -> the file it is in (None: declare()'s)
_scanned = set()
_announcing = False  # Inside determinismo, declared assertions are announced as they are.


def declare(kind, message, file=None):
    """Announces an assertion before it runs: one never reached is judged too. Assertions with
    literal messages are announced already."""
    if (kind, message) in _declared:
        return
    _declared[(kind, message)] = file
    if _announcing:
        _emit({"assert": {"type": kind, "message": message, "hit": False}})


def catalog_assertions():
    """The assertions the program declares so far (its loaded modules' and declare()'s): a list
    of {"kind", "message", "file"}."""
    return [{"kind": kind, "message": message, "file": file}
            for (kind, message), file in _declared.items()]


def catalog_write(stream=None):
    """Writes the catalog, one JSON object a line, to `stream` (stdout by default): what a
    program checks, for review or CI."""
    stream = stream or sys.stdout
    for entry in catalog_assertions():
        stream.write(json.dumps(entry) + "\n")


def catalog(filename):
    """Announces the assertions of `filename` (a module this SDK did not see run)."""
    _catalog_source(os.path.abspath(filename))


def _catalog_source(filename):
    """Declares the assertions of a source file: calls to this SDK's assertions (through the
    names the file binds to it) whose message is a literal."""
    if filename in _scanned or filename == __file__ or not filename.endswith(".py"):
        return
    _scanned.add(filename)
    try:
        with open(filename, encoding="utf-8") as source:
            tree = ast.parse(source.read(), filename)
    except (OSError, SyntaxError, ValueError):
        return
    modules = set()  # Names of this module: `import determinismo as det`.
    direct = {}  # Names of its assertions: `from determinismo import sometimes as s`.
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            modules.update(a.asname or a.name for a in node.names if a.name == "determinismo")
        elif isinstance(node, ast.ImportFrom) and node.module == "determinismo":
            direct.update((a.asname or a.name, a.name) for a in node.names
                          if a.name in _KINDS or a.name in _GUIDED)
    if not modules and not direct:
        return
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        function = node.func
        if (isinstance(function, ast.Attribute) and isinstance(function.value, ast.Name)
                and function.value.id in modules):
            called = function.attr
        elif isinstance(function, ast.Name) and function.id in direct:
            called = direct[function.id]
        else:
            continue
        if called in _GUIDED:
            kind, position = _GUIDED[called]
        elif called in _KINDS:
            kind = called
            position = 0 if kind in ("reachable", "unreachable") else 1
        else:
            continue
        message = node.args[position] if len(node.args) > position else next(
            (keyword.value for keyword in node.keywords if keyword.arg == "message"), None)
        if isinstance(message, ast.Constant) and isinstance(message.value, str):
            declare(kind, message.value, filename)


def _catalog_hook(name, arguments):
    # Every module's code goes through exec as it runs: imported, run as a script, or exec'd.
    if name == "exec" and arguments and hasattr(arguments[0], "co_filename"):
        _catalog_source(arguments[0].co_filename)


def _catalog_start():
    global _announcing
    # Outside determinismo too: catalog_assertions() lists them, but nothing is announced.
    _announcing = _device_fd() is not None
    for module in list(sys.modules.values()):  # Those that ran before this SDK was imported.
        filename = getattr(module, "__file__", None)
        if filename:
            _catalog_source(filename)
    sys.addaudithook(_catalog_hook)


_catalog_start()
