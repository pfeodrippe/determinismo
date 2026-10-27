#!/bin/sh
# SPDX-License-Identifier: MIT
# One TigerBeetle replica: start.sh <replica> <name,name,name>, the replicas in order. Its data
# file is formatted when there is none (a fresh node, or one whose disk was wiped), as an operator
# would bring back a replica that lost its disk; then it runs. TigerBeetle takes peers by IP: the
# names come from the hosts file.
set -e
replica=$1
addresses=""
for name in $(echo "$2" | tr , ' '); do
  ip=$(awk -v n="$name" '{ for (i = 2; i <= NF; i++) if ($i == n) { print $1; exit } }' /etc/hosts)
  addresses="${addresses:+$addresses,}$ip:3000"
done
file=/data/0_$replica.tigerbeetle
if [ ! -f "$file" ]; then
  # Formatted aside, then renamed: a power loss while formatting (1 GiB of writes) leaves no
  # data file rather than one without a superblock, which TigerBeetle cannot start from.
  rm -f "$file.formatting"
  tigerbeetle format --cluster=0 --replica="$replica" --replica-count=3 --development "$file.formatting"
  sync "$file.formatting"
  mv "$file.formatting" "$file"
  sync /data
fi
exec tigerbeetle start --addresses="$addresses" --development --cache-grid=64MiB "$file"
