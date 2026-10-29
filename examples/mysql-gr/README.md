# MySQL Group Replication under determinismo

MySQL 26.10.0 Group Replication: three members in single-primary mode, as InnoDB Cluster runs
them, `group_replication_consistency = BEFORE_ON_PRIMARY_FAILOVER`. Jepsen analyzed MySQL (8.0.34,
one server) and Galera, never Group Replication.

```
zig build -Drelease
determinismo explore --kernel ~/guest/vmlinuz --initrd ~/guest/base.cpio --memory-mib 4096 \
  --program zig-out/bin/mysql-gr-test --scenario serializable --seed 1 --time-budget 1h
```

## What it promises

A transaction commits once a majority of the group certified it (XCom, a Paxos), so a failover
loses no acknowledged commit; with BEFORE_ON_PRIMARY_FAILOVER a new primary applies its backlog
before it serves, so its reads are not stale. Members expelled or not yet back in the group are
read only.

## The system

- The image (Dockerfile): the official `mysql:26.10.0`, `gr.cnf` (GTIDs, the plugin, the group's
  name, seeds and consistency, `super_read_only` until the group makes a member its primary),
  `init.sql` at the data directory's initialization (the recovery user and its credentials, then
  no GTID of the member's own, so that no member holds transactions the group lacks).
- `start <id>`: mysqld, and beside it what an operator does: join the group when one runs; when
  none runs anywhere (the first start, or after every member went down), form it again on the
  member whose GTIDs hold every other's, once all three answer (MySQL Shell's
  `rebootClusterFromCompleteOutage()`); ties to the lowest name. No member forms a group while
  another could hold a newer one.

## The workload and its properties

Jepsen's MySQL workload (examples/sql/append.zig, MySQL's protocol): list-append transactions over
three tables through the primary, whatever member it is now (`super_read_only` off), drivers
outlasting about a minute of refused connections in a row. Faults in bursts with quiet stretches.

| Property | Breaks when |
|---|---|
| Elle finds no anomaly in the history (strict serializable; Repeatable Read in `repeatable_read`) | a cycle, a stale read after a failover, a lost or reordered append among the ones read |
| every committed append is in the final read | a failover (or anything) loses an acknowledged commit |
| the final reads reach a node once faults stop | the group never serves again |

## Status

- 2026-10-29: written. Smokes: the plugin's options aborted the data directory's
  initialization (`loose-` since); `super_read_only` in the configuration refused the image's own
  initialization (set from the second start on since); the start script's helper reached the
  initialization's server on the socket and formed a group there (over TCP since); the group
  failed to form on XCom's port (the MySQL communication stack, the default, on 3306 since).
  Then (seed 1, 4 timelines): all passed, 618 to 1,236 operations each, the group formed again
  after complete outages up to 15 times a timeline. Timeline 3 first waited for ever for memory
  beside its generation's holders in a 24 GB unit: holders give way to a waiting VM since.
