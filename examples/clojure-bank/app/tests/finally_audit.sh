#!/bin/bash
# SPDX-License-Identifier: MIT
# The total must still be 1000 (reported in the Antithesis SDK's format).
exec 3<>/dev/tcp/127.0.0.1/7000
echo total >&3
read -r -t 5 total <&3
[ "$total" = 1000 ] && conserved=true || conserved=false
printf '{"antithesis_assert":{"hit":true,"display_type":"Always","message":"total balance is conserved","condition":%s,"details":{"total":"%s"}}}\n' \
  "$conserved" "$total" > "${ANTITHESIS_SDK_LOCAL_OUTPUT:-/dev/stderr}"
