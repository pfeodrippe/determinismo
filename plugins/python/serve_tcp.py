#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Serves a strategy over TCP, for `determinismo explore --strategy tcp://<address>:<port>`: each
connection (one per exploration worker) runs the strategy command with the connection as its
standard input and output. Standard library only.

The strategy runs here (a laptop with a model logged in, a GPU box) and the exploration on the
server; an SSH tunnel joins them:

    python3 plugins/python/serve_tcp.py 9000 python3 plugins/python/llm.py
    ssh -N -R 9000:127.0.0.1:9000 det@<server>      # then, on the server:
    determinismo explore ... --strategy tcp://127.0.0.1:9000
"""
import socket
import subprocess
import sys
import threading


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: serve_tcp.py <port> <strategy command>...")
    port, command = int(sys.argv[1]), sys.argv[2:]
    listener = socket.create_server(("127.0.0.1", port))
    print(f"[serve_tcp] {' '.join(command)} on 127.0.0.1:{port}", file=sys.stderr)
    while True:
        connection, peer = listener.accept()
        threading.Thread(target=run, args=(connection, command), daemon=True).start()


def run(connection, command):
    with connection:
        process = subprocess.Popen(command, stdin=connection.fileno(),
                                   stdout=connection.fileno())
        process.wait()


if __name__ == "__main__":
    main()
