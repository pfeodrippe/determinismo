# SPDX-License-Identifier: MIT
# The RabbitMQ client node: pika (the Python client RabbitMQ documents) behind a line protocol for
# determinismo's drivers, one connection a client process, as Jepsen's queue clients:
#
#   declare <node> <queue>        -> ok | error <reason>      (a quorum queue, three replicas)
#   enqueue <node> <queue> <value> -> ok | nack | unknown <reason>
#   dequeue <node> <queue>        -> value <v> | empty | unknown <reason>
#
# <node> is 1, 2 or 3: rabbit-<node>, connected on first use and again after an error. Enqueues
# are persistent publishes with publisher confirms (ok: confirmed; nack: refused, never stored;
# unknown: no answer, it may be). Dequeues take one message (basic.get) and acknowledge it:
# value once acknowledged; a message got but not acknowledged comes back, and is reported
# unknown (it will be dequeued again).
import socket
import sys
import threading

import pika
from pika.exceptions import AMQPError, NackError, UnroutableError

TIMEOUT_S = 5


def reason(error):
    text = str(error).replace("\n", " ")
    return (type(error).__name__ + ": " + text)[:200]


class Session:
    def __init__(self):
        self.connections = {}

    def channel(self, node):
        known = self.connections.get(node)
        if known is not None and known[0].is_open and known[1].is_open:
            return known[1]
        self.drop(node)
        parameters = pika.ConnectionParameters(
            host="rabbit-%s" % node, port=5672, heartbeat=5, socket_timeout=TIMEOUT_S,
            stack_timeout=TIMEOUT_S * 2, blocked_connection_timeout=TIMEOUT_S * 2,
            connection_attempts=1)
        connection = pika.BlockingConnection(parameters)
        channel = connection.channel()
        channel.confirm_delivery()
        self.connections[node] = (connection, channel)
        return channel

    def drop(self, node):
        known = self.connections.pop(node, None)
        if known is not None:
            try:
                known[0].close()
            except Exception:
                pass

    def handle(self, words):
        command = words[0]
        if command == "declare" and len(words) == 3:
            node, queue = words[1], words[2]
            try:
                self.channel(node).queue_declare(queue=queue, durable=True, arguments={
                    "x-queue-type": "quorum", "x-quorum-initial-group-size": 3})
                return "ok"
            except Exception as error:
                self.drop(node)
                return "error " + reason(error)
        if command == "enqueue" and len(words) == 4:
            node, queue, value = words[1], words[2], words[3]
            try:
                self.channel(node).basic_publish(
                    exchange="", routing_key=queue, body=value.encode(), mandatory=True,
                    properties=pika.BasicProperties(delivery_mode=2))
                return "ok"
            except NackError:
                return "nack"
            except UnroutableError:
                return "nack"
            except Exception as error:
                self.drop(node)
                return "unknown " + reason(error)
        if command == "dequeue" and len(words) == 3:
            node, queue = words[1], words[2]
            try:
                channel = self.channel(node)
                method, _, body = channel.basic_get(queue=queue, auto_ack=False)
            except Exception as error:
                self.drop(node)
                return "error " + reason(error)
            if method is None:
                return "empty"
            try:
                channel.basic_ack(method.delivery_tag)
                # The ack is asynchronous: a round trip makes sure the broker had it.
                channel.queue_declare(queue=queue, passive=True)
                return "value " + body.decode()
            except Exception as error:
                self.drop(node)
                return "unknown " + body.decode() + " " + reason(error)
        return "error unknown command"


def serve(connection):
    session = Session()
    reader = connection.makefile("r", encoding="utf-8", newline="\n")
    try:
        for line in reader:
            words = line.split()
            if not words:
                continue
            try:
                reply = session.handle(words)
            except Exception as error:
                reply = "error " + reason(error)
            connection.sendall((reply + "\n").encode())
    except (OSError, ValueError):
        pass
    finally:
        for node in list(session.connections):
            session.drop(node)
        connection.close()


def main():
    port = int(sys.argv[1])
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("0.0.0.0", port))
    listener.listen(64)
    while True:
        connection, _ = listener.accept()
        threading.Thread(target=serve, args=(connection,), daemon=True).start()


if __name__ == "__main__":
    main()
