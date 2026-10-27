// SPDX-License-Identifier: MIT
// The Kafka client node: Apache Kafka's Java client (the one in the broker's distribution, as
// Jepsen used it), behind a line protocol for determinismo's drivers. Each connection is one
// client process with one long-lived transactional producer, set up as Jepsen's Kafka tests set
// theirs (acks=all, idempotence, 1,000 retries, short timeouts), and handling errors as the
// Java client's documentation says: on a KafkaException, abort the transaction, even after a
// commit timed out (which, with a commit still in flight, is KAFKA-17754's opening).
//
//   hello <transactional id>                     -> ok | error <reason>
//   txn commit|abort <topic> <partition>:<value>... -> ok | aborted | fail <reason> | unknown <reason>
//   create <topic> <partitions> <replicas>       -> ok | exists | error <reason>
//   read <topic> <partition>                     -> values <value>,... | error <reason>
//
// `fail`: the transaction certainly did not commit (it was aborted). `unknown`: it may have.
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.PrintWriter;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.concurrent.ExecutionException;
import org.apache.kafka.clients.admin.AdminClient;
import org.apache.kafka.clients.admin.NewTopic;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.KafkaException;
import org.apache.kafka.common.TopicPartition;
import org.apache.kafka.common.errors.AuthorizationException;
import org.apache.kafka.common.errors.OutOfOrderSequenceException;
import org.apache.kafka.common.errors.ProducerFencedException;
import org.apache.kafka.common.errors.TopicExistsException;
import org.apache.kafka.common.errors.UnsupportedVersionException;
import org.apache.kafka.common.serialization.ByteArraySerializer;
import org.apache.kafka.common.serialization.ByteArrayDeserializer;
import org.apache.kafka.common.serialization.LongDeserializer;
import org.apache.kafka.common.serialization.LongSerializer;

public final class KClient {
    private static String bootstrap;
    private static final long readTimeoutMs = 30_000;

    public static void main(String[] args) throws Exception {
        int port = Integer.parseInt(args[0]);
        bootstrap = args[1];
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
                String reply;
                try {
                    reply = session.handle(line.trim().split(" +"));
                } catch (Exception e) {
                    reply = "error " + reason(e);
                }
                out.println(reply);
            }
        } catch (Exception e) {
            // The driver went away: its producer goes with it.
        } finally {
            session.close();
        }
    }

    private static final class Session {
        private String transactionalId;
        private KafkaProducer<byte[], Long> producer;

        String handle(String[] words) throws Exception {
            switch (words[0]) {
                case "hello":
                    transactionalId = words[1];
                    producerOpen();
                    return "ok";
                case "txn":
                    return transaction(words);
                case "create":
                    return create(words[1], Integer.parseInt(words[2]), Short.parseShort(words[3]));
                case "read":
                    return read(new TopicPartition(words[1], Integer.parseInt(words[2])));
                default:
                    return "error unknown command";
            }
        }

        private void producerOpen() {
            Properties properties = new Properties();
            properties.put("bootstrap.servers", bootstrap);
            properties.put("transactional.id", transactionalId);
            properties.put("enable.idempotence", "true");
            properties.put("acks", "all");
            properties.put("retries", "1000");
            properties.put("request.timeout.ms", "3000");
            properties.put("delivery.timeout.ms", "10000");
            properties.put("max.block.ms", "10000");
            properties.put("transaction.timeout.ms", "10000");
            producer = new KafkaProducer<>(properties, new ByteArraySerializer(), new LongSerializer());
            producer.initTransactions();
        }

        private void producerDrop() {
            if (producer != null) producer.close(Duration.ZERO);
            producer = null;
        }

        private String transaction(String[] words) {
            boolean commit = words[1].equals("commit");
            String topic = words[2];
            boolean committing = false;
            try {
                if (producer == null) producerOpen();
                producer.beginTransaction();
                for (int i = 3; i < words.length; i++) {
                    String[] parts = words[i].split(":");
                    producer.send(new ProducerRecord<>(topic, Integer.parseInt(parts[0]), null,
                            Long.parseLong(parts[1])));
                }
                if (!commit) {
                    producer.abortTransaction();
                    return "aborted";
                }
                committing = true;
                producer.commitTransaction();
                return "ok";
            } catch (ProducerFencedException | OutOfOrderSequenceException | AuthorizationException
                    | UnsupportedVersionException e) {
                // Fatal for this producer: a new one for the next transaction.
                producerDrop();
                return "unknown " + reason(e);
            } catch (KafkaException e) {
                // The documented recovery: abort, then the next transaction may begin.
                try {
                    producer.abortTransaction();
                } catch (Exception abortFailed) {
                    producerDrop();
                    return "unknown " + reason(e) + " / abort: " + reason(abortFailed);
                }
                return committing ? "unknown " + reason(e) : "fail " + reason(e);
            } catch (Exception e) {
                producerDrop();
                return "unknown " + reason(e);
            }
        }

        private String create(String topic, int partitions, short replicas) throws Exception {
            Properties properties = new Properties();
            properties.put("bootstrap.servers", bootstrap);
            properties.put("request.timeout.ms", "5000");
            properties.put("default.api.timeout.ms", "10000");
            try (AdminClient admin = AdminClient.create(properties)) {
                NewTopic newTopic = new NewTopic(topic, partitions, replicas)
                        .configs(Map.of("min.insync.replicas", "2"));
                admin.createTopics(List.of(newTopic)).all().get();
                return "ok";
            } catch (ExecutionException e) {
                if (e.getCause() instanceof TopicExistsException) return "exists";
                return "error " + reason(e.getCause());
            }
        }

        /** Every committed value of a partition, from the beginning (read_committed). */
        private String read(TopicPartition partition) {
            Properties properties = new Properties();
            properties.put("bootstrap.servers", bootstrap);
            properties.put("isolation.level", "read_committed");
            properties.put("auto.offset.reset", "earliest");
            properties.put("enable.auto.commit", "false");
            properties.put("request.timeout.ms", "5000");
            properties.put("default.api.timeout.ms", "10000");
            List<TopicPartition> assigned = List.of(partition);
            try (KafkaConsumer<byte[], Long> consumer = new KafkaConsumer<>(properties,
                    new ByteArrayDeserializer(), new LongDeserializer())) {
                consumer.assign(assigned);
                consumer.seekToBeginning(assigned);
                Map<TopicPartition, Long> ends = consumer.endOffsets(assigned);
                List<Long> values = new ArrayList<>();
                long deadline = System.currentTimeMillis() + readTimeoutMs;
                while (!caughtUp(consumer, ends)) {
                    if (System.currentTimeMillis() > deadline) return "error read timed out";
                    for (ConsumerRecord<byte[], Long> record : consumer.poll(Duration.ofMillis(500))) {
                        values.add(record.value());
                    }
                }
                StringBuilder reply = new StringBuilder("values ");
                for (int i = 0; i < values.size(); i++) {
                    if (i > 0) reply.append(',');
                    reply.append(values.get(i));
                }
                return reply.toString();
            } catch (Exception e) {
                return "error " + reason(e);
            }
        }

        private static boolean caughtUp(KafkaConsumer<byte[], Long> consumer, Map<TopicPartition, Long> ends) {
            for (Map.Entry<TopicPartition, Long> end : ends.entrySet()) {
                if (consumer.position(end.getKey()) < end.getValue()) return false;
            }
            return true;
        }

        void close() {
            producerDrop();
        }
    }

    private static String reason(Throwable e) {
        String message = e.getClass().getSimpleName() + ": " + e.getMessage();
        return message.replace('\n', ' ').replace('\r', ' ');
    }
}
