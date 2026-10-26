#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Installs Debian 13 on a Hetzner dedicated server that is booted into the rescue system: its
# disks (one, or the first two in RAID1), the newest Debian 13 image there.
# WIPES THE DISKS. Usage: infra/hetzner/install-os.sh <ip> [hostname] [installimage.conf]
set -euo pipefail

ip=${1:?usage: $0 <ip> [hostname] [installimage.conf]}
hostname=${2:-determinismo}
conf=${3:-$(dirname "$0")/installimage.conf}
ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

ssh "${ssh_opts[@]}" "root@$ip" 'test "$(hostname)" = rescue' \
  || { echo "error: $ip is not in the Hetzner rescue system" >&2; exit 1; }

scp "${ssh_opts[@]}" "$conf" "root@$ip:/tmp/installimage.conf"
# installimage copies root's authorized_keys from the rescue system into the new OS.
ssh "${ssh_opts[@]}" "root@$ip" "bash -s -- $hostname" <<'EOF'
set -euo pipefail
disks=$(lsblk -dn -o NAME,TYPE,SIZE -b | awk '$2 == "disk" && $3 > 0 {print "/dev/" $1}' | sort | head -2)
count=$(echo "$disks" | wc -l)
image=$(ls /root/.oldroot/nfs/images/Debian-13*-amd64-base.tar.zst | sort -V | tail -1)
{
  n=1
  for disk in $disks; do echo "DRIVE$n $disk"; n=$((n + 1)); done
  if [ "$count" -eq 2 ]; then printf 'SWRAID 1\nSWRAIDLEVEL 1\n'; else echo 'SWRAID 0'; fi
  echo "HOSTNAME $1"
  echo "IMAGE $image"
  cat /tmp/installimage.conf
} > /tmp/autosetup.conf
echo "installing $image on" $disks
TERM=xterm /root/.oldroot/nfs/install/installimage -a -c /tmp/autosetup.conf
nohup sh -c 'sleep 2; reboot' >/dev/null 2>&1 & # Once this session closed cleanly.
EOF

# The rescue system and the installed OS have different SSH host keys.
ssh-keygen -R "$ip" >/dev/null 2>&1 || true
echo "Installed; rebooting $ip. Next: infra/host/bootstrap.sh $ip"
