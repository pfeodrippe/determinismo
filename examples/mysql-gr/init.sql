-- At the data directory's initialization, on every member alike: out of the binary log, the user
-- distributed recovery connects as, and its credentials for the recovery channel; then no GTID of
-- this server's own, so that no member has transactions the group lacks.
SET SQL_LOG_BIN = 0;
CREATE USER 'rpl'@'%' IDENTIFIED BY 'rpl';
GRANT REPLICATION SLAVE, BACKUP_ADMIN, CLONE_ADMIN, CONNECTION_ADMIN, GROUP_REPLICATION_STREAM ON *.* TO 'rpl'@'%';
SET SQL_LOG_BIN = 1;
CHANGE REPLICATION SOURCE TO SOURCE_USER = 'rpl', SOURCE_PASSWORD = 'rpl' FOR CHANNEL 'group_replication_recovery';
RESET BINARY LOGS AND GTIDS;
