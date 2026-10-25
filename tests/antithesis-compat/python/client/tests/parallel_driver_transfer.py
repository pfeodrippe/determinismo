#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
import bank
import determinismo as det

try:
    redis = bank.Redis()
    for _ in range(10):
        bank.transfer(redis)
except (OSError, ConnectionError) as error:  # Faults: Redis may be unreachable for a while.
    det.sometimes(True, "redis was unavailable to a test command", {"error": str(error)})
