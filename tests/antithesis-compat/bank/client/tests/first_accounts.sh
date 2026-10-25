#!/bin/sh
# SPDX-License-Identifier: MIT
# Ten accounts of 100 each.
for account in 0 1 2 3 4 5 6 7 8 9; do
  redis-cli -h redis set "account:$account" 100 >/dev/null
done
