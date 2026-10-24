#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Provisions and hardens a fresh determinismo host from your machine.
# Usage: infra/host/bootstrap.sh <ip> [user]   (default user: det)
set -euo pipefail

ip=${1:?usage: $0 <ip> [user]}
user=${2:-det}
here=$(cd "$(dirname "$0")" && pwd)
ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

until ssh "${ssh_opts[@]}" "root@$ip" true 2>/dev/null \
   || ssh "${ssh_opts[@]}" "$user@$ip" true 2>/dev/null; do
  echo "waiting for $ip to accept SSH..."; sleep 10
done

if ssh "${ssh_opts[@]}" "root@$ip" true 2>/dev/null; then
  ssh "${ssh_opts[@]}" "root@$ip" "bash -s -- $user" < "$here/provision.sh"
  # Never lock ourselves out: harden only once the new user can log in and sudo.
  ssh "${ssh_opts[@]}" "$user@$ip" 'sudo -n true'
  ssh "${ssh_opts[@]}" "root@$ip" "bash -s -- $user" < "$here/harden.sh"
else
  ssh "${ssh_opts[@]}" "$user@$ip" "sudo bash -s -- $user" < "$here/provision.sh"
  ssh "${ssh_opts[@]}" "$user@$ip" "sudo bash -s -- $user" < "$here/harden.sh"
fi

# A full-upgrade may have installed a newer kernel (Debian doesn't always flag it);
# boot into it so the running kernel matches the installed headers.
if ! ssh "${ssh_opts[@]}" "$user@$ip" 'test -d /lib/modules/$(uname -r)/build'; then
  ssh "${ssh_opts[@]}" "$user@$ip" 'sudo systemctl reboot' || true
  sleep 20
  until ssh "${ssh_opts[@]}" "$user@$ip" true 2>/dev/null; do echo "waiting for reboot..."; sleep 10; done
fi

ssh "${ssh_opts[@]}" "$user@$ip" \
  'test -d /lib/modules/$(uname -r)/build && echo "ok: $(whoami)@$(hostname), $(uname -r)"'
