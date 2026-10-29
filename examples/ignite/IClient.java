// SPDX-License-Identifier: MIT
// The Ignite client node: Apache Ignite 3's Java client behind a line protocol for determinismo's
// drivers. Each connection is one client process with its own IgniteClient (to every server,
// no retries: an operation's outcome is the one it reports), made at its first command.
//
//   setup                        -> ok | error <reason>
//   txn r:<k> a:<k>:<v> ...      -> ok <read>... | fail <reason> | unknown <reason>
//   read <k>                     -> ok <read> | fail <reason>
//
// A read is `[v1,v2,...]` (`[]` for no row), an append `-`, in the transaction's order. A
// transaction with an append is a read-write one (Ignite: serializable), each append a get and a
// put of the key's list with a `,v`; one without, a read-only one (read at its start time).
// `fail`: it certainly did not commit (an error before its commit, after which it is rolled back;
// or its commit's TransactionException, which Ignite documents as the transaction rolled back).
// `unknown`: it may have (the connection lost during its commit, or any other error there).
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.PrintWriter;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import org.apache.ignite.client.IgniteClient;
import org.apache.ignite.client.IgniteClientConnectionException;
import org.apache.ignite.sql.ResultSet;
import org.apache.ignite.sql.SqlRow;
import org.apache.ignite.table.KeyValueView;
import org.apache.ignite.table.Table;
import org.apache.ignite.tx.Transaction;
import org.apache.ignite.tx.TransactionException;
import org.apache.ignite.tx.TransactionOptions;

public final class IClient {
    private static String[] addresses;
    private static final long timeoutMs = 30_000;

    public static void main(String[] args) throws Exception {
        int port = Integer.parseInt(args[0]);
        addresses = args[1].split(",");
        try (ServerSocket server = new ServerSocket(port)) {
            while (true) {
                Socket socket = server.accept();
                Thread thread = new Thread(() -> serve(socket));
                thread.setDaemon(true);
                thread.start();
            }
        }
    }

    private static void serve(Socket socket) {
        Session session = new Session();
        try (socket;
                BufferedReader in = new BufferedReader(
                        new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8));
                PrintWriter out = new PrintWriter(
                        new OutputStreamWriter(socket.getOutputStream(), StandardCharsets.UTF_8), true)) {
            String line;
            while ((line = in.readLine()) != null) {
                out.println(session.handle(line.trim()));
            }
        } catch (Exception e) {
            // The driver went away: its client with it.
        } finally {
            session.close();
        }
    }

    private static String reason(Throwable e) {
        String text = e.getClass().getSimpleName() + ": " + e.getMessage();
        return text.replace('\n', ' ').replace('\r', ' ');
    }

    private static final class Session {
        private IgniteClient client;
        private KeyValueView<Long, String> lists;

        String handle(String line) {
            String[] words = line.split(" ");
            try {
                switch (words[0]) {
                    case "setup":
                        return setup();
                    case "txn":
                        return txn(words);
                    case "read":
                        return read(Long.parseLong(words[1]));
                    default:
                        return "error unknown command " + words[0];
                }
            } catch (NumberFormatException | ArrayIndexOutOfBoundsException e) {
                return "error bad command: " + reason(e);
            }
        }

        // Nothing sent until the client connects: a failure here is a definite one.
        private boolean connect() {
            if (client != null) return true;
            try {
                client = IgniteClient.builder()
                        .addresses(addresses)
                        .connectTimeout(5_000)
                        .operationTimeout(timeoutMs)
                        .retryPolicy(null)
                        .build();
                return true;
            } catch (Exception e) {
                client = null;
                return false;
            }
        }

        private KeyValueView<Long, String> lists() {
            if (lists == null) {
                Table table = client.tables().table("LISTS");
                if (table == null) throw new IllegalStateException("no table LISTS");
                lists = table.keyValueView(Long.class, String.class);
            }
            return lists;
        }

        private String setup() {
            if (!connect()) return "error not connected";
            try {
                sql("CREATE ZONE IF NOT EXISTS JEPSEN (REPLICAS 3, PARTITIONS 8) STORAGE PROFILES ['default']");
                sql("CREATE TABLE IF NOT EXISTS LISTS (ID BIGINT PRIMARY KEY, VAL VARCHAR) ZONE JEPSEN");
                lists();
                return "ok";
            } catch (Exception e) {
                drop();
                return "error " + reason(e);
            }
        }

        private void sql(String statement) {
            try (ResultSet<SqlRow> ignored = client.sql().execute(null, statement)) {
                // DDL: nothing to read.
            }
        }

        private String txn(String[] words) {
            if (!connect()) return "fail not connected";
            boolean writes = false;
            for (int i = 1; i < words.length; i++) writes |= words[i].startsWith("a:");
            Transaction tx;
            try {
                tx = client.transactions().begin(new TransactionOptions().readOnly(!writes).timeoutMillis(timeoutMs));
            } catch (Exception e) {
                drop();
                return "fail begin: " + reason(e);
            }
            List<String> results = new ArrayList<>();
            try {
                KeyValueView<Long, String> view = lists();
                for (int i = 1; i < words.length; i++) {
                    String[] parts = words[i].split(":");
                    long key = Long.parseLong(parts[1]);
                    String list = view.get(tx, key);
                    if (parts[0].equals("r")) {
                        results.add("[" + (list == null ? "" : list) + "]");
                    } else {
                        view.put(tx, key, list == null ? parts[2] : list + "," + parts[2]);
                        results.add("-");
                    }
                }
            } catch (Exception e) {
                // Before the commit: it rolls back, nothing applied.
                try {
                    tx.rollback();
                } catch (Exception ignored) {
                    // Ignite rolls back what it does not see committed.
                }
                if (e instanceof IgniteClientConnectionException) drop();
                return "fail " + reason(e);
            }
            try {
                tx.commit();
            } catch (TransactionException e) {
                // Ignite's word: rolled back.
                return "fail commit: " + reason(e);
            } catch (Exception e) {
                drop();
                return "unknown commit: " + reason(e);
            }
            return "ok " + String.join(" ", results);
        }

        // Once faults stop: a key's list, in a read-write transaction of its own.
        private String read(long key) {
            if (!connect()) return "fail not connected";
            try {
                Transaction tx = client.transactions().begin(new TransactionOptions().timeoutMillis(timeoutMs));
                String list;
                try {
                    list = lists().get(tx, key);
                } finally {
                    tx.rollback();
                }
                return "ok [" + (list == null ? "" : list) + "]";
            } catch (Exception e) {
                drop();
                return "fail " + reason(e);
            }
        }

        // A client that lost its servers is made anew at the next command.
        private void drop() {
            close();
        }

        void close() {
            lists = null;
            if (client != null) {
                try {
                    client.close();
                } catch (Exception ignored) {
                    // Closing what failed.
                }
                client = null;
            }
        }
    }
}
