#!/bin/sh
# Once faults stop, Redis answers again through its Service, and the counter keeps every
# acknowledged increment: its append-only file (fsync on every write) is on a persistent volume,
# so a killed pod's Redis comes back with it. Kubelet restarts a container that keeps dying
# later and later (up to 5 minutes apart): this waits 6.
acknowledged=$(cat /tmp/acknowledged 2> /dev/null || echo 0)
for attempt in $(seq 180); do
  if [ "$(redis-cli -h redis -t 2 ping 2> /dev/null)" = PONG ]; then
    value=$(redis-cli -h redis -t 2 get counter 2> /dev/null)
    case "$value" in '' | *[!0-9]*) value=0 ;; esac
    if [ "$value" -lt "$acknowledged" ]; then
      echo "the counter is $value, below an acknowledged $acknowledged"
      exit 1
    fi
    echo "counter $value (acknowledged up to $acknowledged at least)"
    exit 0
  fi
  sleep 2
done
echo "Redis never answered in the 6 minutes after faults stopped"
exit 1
