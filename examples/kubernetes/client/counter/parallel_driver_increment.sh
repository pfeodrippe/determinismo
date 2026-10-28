#!/bin/sh
# Increments the counter; under faults Redis may not answer (or its name not resolve), which is
# not a failure. An acknowledged increment is noted: the counter must keep it (eventually).
value=$(redis-cli -h redis -t 2 incr counter 2> /dev/null)
case "$value" in
  '' | *[!0-9]*) echo "not acknowledged: '$value'" ;;
  *) echo "$value" > /tmp/acknowledged; echo "counter $value" ;;
esac
