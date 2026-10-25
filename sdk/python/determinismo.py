# SPDX-License-Identifier: MIT
"""determinismo SDK for Python: assertions, events and platform randomness.

Inside determinismo everything goes through /dev/determinismo: events are recorded with their
moment, and every random value is a decision the platform can steer and replay. Outside it
(local runs) randomness comes from the OS and events go to stderr, so the same code runs
everywhere. One file, standard library only: copy it next to your code.

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


def _emit(message):
    line = json.dumps(message, separators=(",", ":"), default=str)
    data = line.encode()
    if len(data) > MESSAGE_SIZE_MAX:  # The assertion must not be lost: drop the details.
        if "assert" in message:
            message["assert"]["details"] = "<details too large>"
        data = json.dumps(message, separators=(",", ":")).encode()[:MESSAGE_SIZE_MAX]
    fd = _device_fd()
    if fd is None:
        sys.stderr.write(line + "\n")
        return
    os.write(fd, data)  # One write, one event.


def _assert(kind, condition, message, details):
    assert message
    _emit({"assert": {"type": kind, "message": message, "condition": bool(condition),
                      "details": details or {}}})


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


def setup_complete(details=None):
    """The system is ready: the platform snapshots here and starts exploring."""
    _emit({"lifecycle": "setup_complete", "details": details or {}})


def event(name, details=None):
    """A structured event: {"event": name, "details": details}."""
    assert name
    _emit({"event": name, "details": details or {}})


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
_declared = set()
_scanned = set()


def declare(kind, message):
    """Announces an assertion before it runs: one never reached is judged too. Assertions with
    literal messages are announced already."""
    if (kind, message) in _declared:
        return
    _declared.add((kind, message))
    _emit({"assert": {"type": kind, "message": message, "hit": False}})


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
            direct.update((a.asname or a.name, a.name) for a in node.names if a.name in _KINDS)
    if not modules and not direct:
        return
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        function = node.func
        if (isinstance(function, ast.Attribute) and isinstance(function.value, ast.Name)
                and function.value.id in modules and function.attr in _KINDS):
            kind = function.attr
        elif isinstance(function, ast.Name) and function.id in direct:
            kind = direct[function.id]
        else:
            continue
        position = 0 if kind in ("reachable", "unreachable") else 1
        message = node.args[position] if len(node.args) > position else next(
            (keyword.value for keyword in node.keywords if keyword.arg == "message"), None)
        if isinstance(message, ast.Constant) and isinstance(message.value, str):
            declare(kind, message.value)


def _catalog_hook(name, arguments):
    # Every module's code goes through exec as it runs: imported, run as a script, or exec'd.
    if name == "exec" and arguments and hasattr(arguments[0], "co_filename"):
        _catalog_source(arguments[0].co_filename)


def _catalog_start():
    if _device_fd() is None:
        return  # Outside determinismo: no platform to announce to.
    for module in list(sys.modules.values()):  # Those that ran before this SDK was imported.
        filename = getattr(module, "__file__", None)
        if filename:
            _catalog_source(filename)
    sys.addaudithook(_catalog_hook)


_catalog_start()
