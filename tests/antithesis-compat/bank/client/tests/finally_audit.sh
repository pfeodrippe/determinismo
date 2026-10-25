#!/bin/sh
# SPDX-License-Identifier: MIT
# The total must still be 1000. Reports in the Antithesis SDK's format, which determinismo reads.
total=0
for account in 0 1 2 3 4 5 6 7 8 9; do
  balance=$(redis-cli -h redis get "account:$account")
  total=$((total + balance))
done
[ "$total" -eq 1000 ] && conserved=true || conserved=false
printf '{"antithesis_assert":{"hit":true,"must_hit":true,"assert_type":"always","display_type":"Always","message":"total balance is conserved","condition":%s,"details":{"total":%s}}}\n' \
  "$conserved" "$total" > "${ANTITHESIS_SDK_LOCAL_OUTPUT:-/dev/stderr}"
