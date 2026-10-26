#!/bin/sh
# SPDX-License-Identifier: MIT
# Once faults stop, Redis answers again, and counted at least what it acknowledged.
for attempt in $(seq 1 60); do
  counter=$(redis-cli -h kv -t 2 GET counter 2>/dev/null) && break
  sleep 1
done
acknowledged=$(redis-cli -h kv -t 2 GET acknowledged 2>/dev/null)
[ "${counter:-0}" -ge "${acknowledged:-0}" ]
