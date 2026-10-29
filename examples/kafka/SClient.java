// SPDX-License-Identifier: MIT
// The Kafka client node's share-group side (Kafka 4.2+, KIP-932, queues for Kafka): Kafka's Java
// client behind a line protocol for determinismo's drivers, beside KClient (port 7001). Each
// connection is one client process with its own idempotent producer and its own share consumer,
// made at their first use.
//
//   group <group>                   -> ok | error <reason>    (the share group reads from the
//                                                              beginning: share.auto.offset.reset)
//   produce <topic> <value>         -> ok | unknown <reason>
//   consume <group> <topic>         -> ok <record>...  | error <reason>
//
// `consume`: one poll (up to a second), every record acknowledged ACCEPT, then commitSync. A
// record is `<value>:<delivery count>:<c|x>`: `c` when its partition's acknowledgements committed
// (commitSync's answer for the partition carried no error), `x` when not known to.
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
import java.util.Optional;
import java.util.Properties;
import org.apache.kafka.clients.admin.AdminClient;
import org.apache.kafka.clients.admin.AlterConfigOp;
import org.apache.kafka.clients.admin.ConfigEntry;
import org.apache.kafka.clients.consumer.AcknowledgeType;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.apache.kafka.clients.consumer.KafkaShareConsumer;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.KafkaException;
import org.apache.kafka.common.TopicIdPartition;
import org.apache.kafka.common.config.ConfigResource;
import org.apache.kafka.common.serialization.ByteArrayDeserializer;
import org.apache.kafka.common.serialization.ByteArraySerializer;
import org.apache.kafka.common.serialization.LongDeserializer;
import org.apache.kafka.common.serialization.LongSerializer;

public final class SClient {
    private static String bootstrap;

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
                out.println(session.handle(line.trim().split(" ")));
            }
        } catch (Exception e) {
            // The driver went away: its clients with it.
        } finally {
            session.close();
        }
    }

    private static String reason(Throwable e) {
        Throwable cause = e.getCause() != null ? e.getCause() : e;
        String text = cause.getClass().getSimpleName() + ": " + cause.getMessage();
        return text.replace('\n', ' ').replace('\r', ' ');
    }

    private static final class Session {
        private KafkaProducer<byte[], Long> producer;
        private KafkaShareConsumer<byte[], Long> consumer;

        String handle(String[] words) {
            try {
                switch (words[0]) {
                    case "group":
                        return group(words[1]);
                    case "produce":
                        return produce(words[1], Long.parseLong(words[2]));
                    case "consume":
                        return consume(words[1], words[2]);
                    default:
                        return "error unknown command " + words[0];
                }
            } catch (NumberFormatException | ArrayIndexOutOfBoundsException e) {
                return "error bad command: " + reason(e);
            }
        }

        private String group(String group) {
            Properties properties = new Properties();
            properties.put("bootstrap.servers", bootstrap);
            properties.put("request.timeout.ms", "5000");
            properties.put("default.api.timeout.ms", "10000");
            try (AdminClient admin = AdminClient.create(properties)) {
                ConfigResource resource = new ConfigResource(ConfigResource.Type.GROUP, group);
                AlterConfigOp earliest = new AlterConfigOp(
                        new ConfigEntry("share.auto.offset.reset", "earliest"), AlterConfigOp.OpType.SET);
                admin.incrementalAlterConfigs(Map.of(resource, List.of(earliest))).all().get();
                return "ok";
            } catch (Exception e) {
                return "error " + reason(e);
            }
        }

        private String produce(String topic, long value) {
            if (producer == null) {
                Properties properties = new Properties();
                properties.put("bootstrap.servers", bootstrap);
                properties.put("acks", "all");
                properties.put("enable.idempotence", "true");
                properties.put("max.block.ms", "10000");
                properties.put("request.timeout.ms", "3000");
                properties.put("delivery.timeout.ms", "10000");
                properties.put("key.serializer", ByteArraySerializer.class.getName());
                properties.put("value.serializer", LongSerializer.class.getName());
                try {
                    producer = new KafkaProducer<>(properties);
                } catch (Exception e) {
                    return "unknown " + reason(e);
                }
            }
            try {
                producer.send(new ProducerRecord<>(topic, null, value)).get();
                return "ok";
            } catch (Exception e) {
                // It may have been written (a timeout after the broker took it).
                closeProducer();
                return "unknown " + reason(e);
            }
        }

        private String consume(String group, String topic) {
            if (consumer == null) {
                Properties properties = new Properties();
                properties.put("bootstrap.servers", bootstrap);
                properties.put("group.id", group);
                properties.put("share.acknowledgement.mode", "explicit");
                properties.put("request.timeout.ms", "5000");
                properties.put("default.api.timeout.ms", "10000");
                properties.put("key.deserializer", ByteArrayDeserializer.class.getName());
                properties.put("value.deserializer", LongDeserializer.class.getName());
                try {
                    consumer = new KafkaShareConsumer<>(properties);
                    consumer.subscribe(List.of(topic));
                } catch (Exception e) {
                    closeConsumer();
                    return "error " + reason(e);
                }
            }
            List<ConsumerRecord<byte[], Long>> polled = new ArrayList<>();
            try {
                ConsumerRecords<byte[], Long> records = consumer.poll(Duration.ofMillis(1000));
                for (ConsumerRecord<byte[], Long> record : records) {
                    polled.add(record);
                    consumer.acknowledge(record, AcknowledgeType.ACCEPT);
                }
            } catch (Exception e) {
                closeConsumer();
                return "error " + reason(e);
            }
            Map<TopicIdPartition, Optional<KafkaException>> committed = Map.of();
            boolean commitFailed = false;
            if (!polled.isEmpty()) {
                try {
                    committed = consumer.commitSync(Duration.ofSeconds(10));
                } catch (Exception e) {
                    commitFailed = true;
                }
            }
            StringBuilder reply = new StringBuilder("ok");
            for (ConsumerRecord<byte[], Long> record : polled) {
                boolean partitionCommitted = false;
                if (!commitFailed) {
                    for (Map.Entry<TopicIdPartition, Optional<KafkaException>> entry : committed.entrySet()) {
                        if (entry.getKey().topic().equals(record.topic())
                                && entry.getKey().partition() == record.partition()) {
                            partitionCommitted = entry.getValue().isEmpty();
                        }
                    }
                }
                short count = record.deliveryCount().orElse((short) 0);
                reply.append(' ').append(record.value()).append(':').append(count)
                        .append(':').append(partitionCommitted ? 'c' : 'x');
            }
            if (commitFailed) closeConsumer();
            return reply.toString();
        }

        private void closeProducer() {
            if (producer == null) return;
            try {
                producer.close(Duration.ZERO);
            } catch (Exception ignored) {
                // Closing what failed.
            }
            producer = null;
        }

        private void closeConsumer() {
            if (consumer == null) return;
            try {
                consumer.close(Duration.ZERO);
            } catch (Exception ignored) {
                // Closing what failed.
            }
            consumer = null;
        }

        void close() {
            closeProducer();
            closeConsumer();
        }
    }
}
