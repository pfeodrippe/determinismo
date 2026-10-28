#!/bin/sh
# Once faults stop, Redis answers again and the counter reads as a number.
for attempt in $(seq 60); do
  value=$(redis-cli -h redis -t 2 get counter 2> /dev/null)
  case "$value" in
    '' | *[!0-9]*) sleep 1 ;;
    *) echo "counter $value"; exit 0 ;;
  esac
done
echo "the counter never read back"
exit 1
