# SPDX-License-Identifier: MIT
# The ZooKeeper client node: kazoo behind a line protocol for determinismo's drivers, one
# connection a client process (Jepsen's clients are one per process too):
#
#   txn <node> <mop>...  -> ok <read>... | fail <reason> | unknown <reason>
#   keys <node>          -> keys <key>... | unknown <reason>
#
# <node> is 1, 2 or 3: zk-<node>:2181 only (no failover to another server), connected on first
# use and again after an error. A mop is `a:<key>:<value>` (append) or `r:<key>` (read); a read
# answers `<key>:<v>,<v>,...` (empty: `<key>:`), in the mops' order, each seeing the
# transaction's own earlier appends. Each key is the znode /elle/<key>, its list comma-separated.
#
# A transaction reads every key it touches (sync, then get: the server catches up with the
# leader first), then commits one multi: a version check of each key it only read (a create and
# a delete of each it read as absent: the create fails if the znode appeared since), a versioned
# set (or a create) of each it appended to. ZooKeeper applies a multi whole or not at all, so
# the reads hold at the commit: strictly serializable. A conflict (BadVersion, NodeExists)
# retries from the reads, a few times, then fails (nothing applied). No answer: unknown.
import socket
import sys
import threading

from kazoo.client import KazooClient
from kazoo.exceptions import BadVersionError, NodeExistsError, NoNodeError

TIMEOUT_S = 5
CONFLICT_RETRIES = 5
ROOT = "/elle"


def reason(error):
    text = str(error).replace("\n", " ")
    return (type(error).__name__ + ": " + text)[:200]


class Conflict(Exception):
    """The multi was refused for a version or existence check: nothing applied, try again."""


class Refused(Exception):
    """The multi was refused otherwise: nothing applied."""


class ReadFailed(Exception):
    """A read before the commit failed: nothing was sent to commit."""


class Session:
    def __init__(self):
        self.clients = {}

    def client(self, node):
        known = self.clients.get(node)
        if known is not None and known.connected:
            return known
        self.drop(node)
        # Reconnecting in the background with short delays (kazoo's default backs off to a
        # minute): a server just back serves again soon.
        client = KazooClient(hosts="zk-%s:2181" % node, timeout=TIMEOUT_S,
                             connection_retry={"max_tries": -1, "delay": 0.1, "max_delay": 1})
        client.start(timeout=TIMEOUT_S)
        try:
            client.create_async(ROOT).get(timeout=TIMEOUT_S)
        except NodeExistsError:
            pass
        self.clients[node] = client
        return client

    def drop(self, node):
        known = self.clients.pop(node, None)
        if known is not None:
            try:
                known.stop()
                known.close()
            except Exception:
                pass

    def transaction(self, client, mops):
        keys = []
        for mop in mops:
            if mop[1] not in keys:
                keys.append(mop[1])
        # The reads: each key's list and version (-1: no znode yet).
        lists = {}
        versions = {}
        for key in keys:
            path = "%s/%s" % (ROOT, key)
            try:
                # Every call bounded: kazoo's blocking calls wait for the connection, which
                # (reconnecting forever) never comes back while the server is down: run 86's
                # timelines hung at their ceiling.
                client.sync_async(path).get(timeout=TIMEOUT_S)
                data, stat = client.get_async(path).get(timeout=TIMEOUT_S)
                lists[key] = [v for v in data.decode().split(",") if v]
                versions[key] = stat.version
            except NoNodeError:
                lists[key] = []
                versions[key] = -1
            except Exception as error:
                raise ReadFailed(reason(error))
        appended = set()
        reads = []
        for mop in mops:
            if mop[0] == "a":
                lists[mop[1]].append(mop[2])
                appended.add(mop[1])
            else:
                reads.append("%s:%s" % (mop[1], ",".join(lists[mop[1]])))
        # The commit: one multi.
        transaction = client.transaction()
        for key in keys:
            path = "%s/%s" % (ROOT, key)
            if key not in appended:
                if versions[key] >= 0:
                    transaction.check(path, versions[key])
                else:
                    # Still absent at the commit: a multi cannot check a missing znode, so it
                    # creates and deletes it (NodeExists if another transaction made it since,
                    # whose append this read would otherwise miss).
                    transaction.create(path, b"")
                    transaction.delete(path)
                continue
            data = ",".join(lists[key]).encode()
            if versions[key] < 0:
                transaction.create(path, data)
            else:
                transaction.set_data(path, data, version=versions[key])
        # Raises with no answer (unknown); answered, a refused multi's results are errors, the
        # failing operation's own and RolledBackError for the others.
        results = transaction.commit_async().get(timeout=TIMEOUT_S)
        errors = [result for result in results if isinstance(result, Exception)]
        if any(isinstance(e, (BadVersionError, NodeExistsError, NoNodeError)) for e in errors):
            raise Conflict(reason(errors[0]))
        if errors:
            raise Refused(reason(errors[0]))
        return reads

    def handle(self, words):
        command = words[0]
        if command == "txn" and len(words) >= 3:
            node = words[1]
            mops = []
            for text in words[2:]:
                parts = text.split(":")
                if parts[0] == "a" and len(parts) == 3:
                    mops.append(("a", parts[1], parts[2]))
                elif parts[0] == "r" and len(parts) == 2:
                    mops.append(("r", parts[1], None))
                else:
                    return "fail bad mop " + text
            try:
                client = self.client(node)
            except Exception as error:
                self.drop(node)
                return "fail " + reason(error)  # Not connected: nothing was sent.
            for _ in range(CONFLICT_RETRIES):
                try:
                    return " ".join(["ok"] + self.transaction(client, mops))
                except Conflict:
                    continue
                except (Refused, ReadFailed) as error:
                    if isinstance(error, ReadFailed):
                        self.drop(node)
                    return "fail " + str(error)
                except Exception as error:
                    self.drop(node)
                    return "unknown " + reason(error)
            return "fail conflicts"
        if command == "keys" and len(words) == 2:
            node = words[1]
            try:
                client = self.client(node)
                client.sync_async(ROOT).get(timeout=TIMEOUT_S)
                children = client.get_children_async(ROOT).get(timeout=TIMEOUT_S)
                return " ".join(["keys"] + sorted(children))
            except Exception as error:
                self.drop(node)
                return "unknown " + reason(error)
        return "fail unknown command"


def serve(connection):
    session = Session()
    reader = connection.makefile("r")
    try:
        for line in reader:
            words = line.split()
            if not words:
                continue
            answer = session.handle(words)
            connection.sendall((answer + "\n").encode())
    except OSError:
        pass
    finally:
        for node in list(session.clients):
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
