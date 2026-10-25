# SPDX-License-Identifier: MIT
"""The bank, over a tiny RESP client (standard library only), with the lost-update bug."""
import socket

import determinismo as det

ACCOUNTS = 10
BALANCE = 100


class Redis:
    def __init__(self, host="redis", port=6379):
        self.socket = socket.create_connection((host, port), timeout=1)
        self.buffer = b""

    def call(self, *parts):
        command = b"*%d\r\n" % len(parts)
        for part in parts:
            data = str(part).encode()
            command += b"$%d\r\n%s\r\n" % (len(data), data)
        self.socket.sendall(command)
        return self._reply()

    def _line(self):
        while b"\r\n" not in self.buffer:
            chunk = self.socket.recv(65536)
            if not chunk:
                raise ConnectionError("closed")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\r\n", 1)
        return line

    def _reply(self):
        line = self._line()
        kind, rest = line[:1], line[1:]
        if kind in (b"+", b":"):
            return rest.decode()
        if kind == b"-":
            raise RuntimeError(rest.decode())
        if kind == b"$":
            size = int(rest)
            if size < 0:
                return None
            while len(self.buffer) < size + 2:
                self.buffer += self.socket.recv(65536)
            data, self.buffer = self.buffer[:size], self.buffer[size + 2:]
            return data.decode()
        if kind == b"*":
            return [self._reply() for _ in range(int(rest))]
        raise RuntimeError("bad reply")


def transfer(redis):
    source = det.random_below(ACCOUNTS)
    target = (source + 1 + det.random_below(ACCOUNTS - 1)) % ACCOUNTS
    amount = 1 + det.random_below(50)
    source_balance = int(redis.call("GET", "account:%d" % source))
    target_balance = int(redis.call("GET", "account:%d" % target))  # Not WATCHed: the bug.
    if source_balance < amount:
        det.sometimes(True, "transfer rejected for insufficient funds")
        return
    redis.call("MULTI")
    redis.call("SET", "account:%d" % source, source_balance - amount)
    redis.call("SET", "account:%d" % target, target_balance + amount)
    redis.call("EXEC")
    det.reachable("transfer committed")
