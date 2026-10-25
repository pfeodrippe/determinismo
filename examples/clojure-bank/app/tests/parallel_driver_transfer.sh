#!/bin/bash
# SPDX-License-Identifier: MIT
# Random transfers, one connection each.
for transfer in $(seq 1 15); do
  from=$((RANDOM % 10)); to=$(((from + 1 + RANDOM % 9) % 10)); amount=$((1 + RANDOM % 40))
  exec 3<>/dev/tcp/127.0.0.1/7000 || exit 0
  echo "transfer $from $to $amount" >&3
  read -r -t 2 answer <&3
  exec 3>&-
done
