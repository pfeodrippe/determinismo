# SPDX-License-Identifier: MIT
# RabbitMQ 4.1 (the official image), three nodes of one cluster, and the client node: rclient.py
# (pika, the Python client RabbitMQ documents) behind a line protocol. One image; start.sh runs
# a broker or the client.
FROM docker.io/library/rabbitmq:4.1.4
RUN apt-get update -q \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends python3 python3-pika \
 && rm -rf /var/lib/apt/lists/*
COPY examples/rabbitmq/rclient.py /opt/rclient/rclient.py
COPY examples/rabbitmq/start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh
ENTRYPOINT ["/usr/local/bin/start.sh"]
