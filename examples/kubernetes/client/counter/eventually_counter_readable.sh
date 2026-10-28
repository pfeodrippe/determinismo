#!/bin/sh
# Once faults stop, Redis answers again through its Service, and the counter reads as a number
# (or not at all: a killed pod's Redis starts empty, it keeps nothing).
for attempt in $(seq 60); do
  if [ "$(redis-cli -h redis -t 2 ping 2> /dev/null)" = PONG ]; then
    value=$(redis-cli -h redis -t 2 get counter 2> /dev/null)
    case "$value" in
      '' | *[!0-9]*) echo "counter: none" ;;
      *) echo "counter $value" ;;
    esac
    exit 0
  fi
  sleep 1
done
echo "Redis never answered once faults stopped"
exit 1
