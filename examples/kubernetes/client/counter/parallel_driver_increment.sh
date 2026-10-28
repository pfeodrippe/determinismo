#!/bin/sh
# Increments the counter; under faults Redis may not answer, which is not a failure.
redis-cli -h redis -t 2 incr counter || true
