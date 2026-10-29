# SPDX-License-Identifier: MIT
# MySQL 26.10.0 (the official image) as a Group Replication member, single-primary, as InnoDB
# Cluster runs them: gr.cnf, the recovery user (init.sql), and a start script that joins the
# group, or forms it again when none runs (start).
FROM docker.io/library/mysql:26.10.0
COPY examples/mysql-gr/gr.cnf /etc/mysql/conf.d/gr.cnf.in
COPY examples/mysql-gr/init.sql /docker-entrypoint-initdb.d/00-gr.sql
COPY examples/mysql-gr/start /usr/local/bin/gr-start
ENTRYPOINT ["/usr/local/bin/gr-start"]
