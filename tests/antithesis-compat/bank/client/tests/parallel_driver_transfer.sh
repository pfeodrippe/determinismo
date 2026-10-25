#!/bin/sh
# SPDX-License-Identifier: MIT
# Transfers with a lost update: balances are read, then written, with nothing watched between.
for transfer in 1 2 3 4 5 6 7 8 9 10; do
  from=$((RANDOM % 10)); to=$(((from + 1 + RANDOM % 9) % 10)); amount=$((1 + RANDOM % 50))
  from_balance=$(redis-cli -h redis get "account:$from") || exit 0
  to_balance=$(redis-cli -h redis get "account:$to") || exit 0
  [ "$from_balance" -ge "$amount" ] 2>/dev/null || continue
  printf 'MULTI\nSET account:%s %s\nSET account:%s %s\nEXEC\n' \
    "$from" $((from_balance - amount)) "$to" $((to_balance + amount)) |
    redis-cli -h redis >/dev/null || exit 0
done
