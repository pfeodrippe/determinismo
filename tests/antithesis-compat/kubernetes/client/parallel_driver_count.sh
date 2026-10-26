#!/bin/sh
# SPDX-License-Identifier: MIT
# Counts a few increments, through the Service, and records how many succeeded.
for i in 1 2 3; do
  if redis-cli -h kv -t 2 INCR counter >/dev/null 2>&1; then
    redis-cli -h kv -t 2 INCR acknowledged >/dev/null 2>&1
  fi
done
exit 0
