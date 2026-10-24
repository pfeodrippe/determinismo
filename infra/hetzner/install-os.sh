#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Installs Debian 13 on a Hetzner dedicated server that is booted into the rescue system.
# WIPES BOTH DISKS. Usage: infra/hetzner/install-os.sh <ip> [installimage.conf]
set -euo pipefail

ip=${1:?usage: $0 <ip> [installimage.conf]}
conf=${2:-$(dirname "$0")/installimage.conf}
ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

ssh "${ssh_opts[@]}" "root@$ip" 'test "$(hostname)" = rescue' \
  || { echo "error: $ip is not in the Hetzner rescue system" >&2; exit 1; }

scp "${ssh_opts[@]}" "$conf" "root@$ip:/tmp/installimage.conf"
# installimage copies root's authorized_keys from the rescue system into the new OS.
ssh "${ssh_opts[@]}" "root@$ip" \
  'TERM=xterm /root/.oldroot/nfs/install/installimage -a -c /tmp/installimage.conf && reboot'

# The rescue system and the installed OS have different SSH host keys.
ssh-keygen -R "$ip" >/dev/null 2>&1 || true
echo "Installed; rebooting $ip. Next: infra/host/bootstrap.sh $ip"
