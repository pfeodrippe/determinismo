# SPDX-License-Identifier: MIT
"""determinismo SDK for Python: assertions, events and platform randomness.

Inside determinismo everything goes through /dev/determinismo: events are recorded with their
moment, and every random value is a decision the platform can steer and replay. Outside it
(local runs) randomness comes from the OS and events go to stderr, so the same code runs
everywhere. One file, standard library only: copy it next to your code.

    import determinismo as det
    account = det.random_below(10)
    det.always(total == 1000, "total balance is conserved", {"total": total})
"""
import json
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
