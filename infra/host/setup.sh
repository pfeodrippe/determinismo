#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Sets up a determinismo host from your machine, in one go: from a Hetzner box in its rescue
# system (or one installed already) to a checked host. Debian, provisioning and hardening, the
# repository, the toolchain, hardware qualification, our KVM (loaded at every boot), the guest,
# the build, an end-to-end check, and serve (a unit). Idempotent: run it again after a failure,
# or to update (which stops serve and its runs first).
# Usage: infra/host/setup.sh <ip> [--user <user>] [--hostname <name>] [--guest-from <user@host>]
#                             [--reserved-cores N]
#   --guest-from: the guest kernel and module copied from that host instead of built here, so
#   every host runs the same guest (the same run inputs, for replays across hosts).
#   --reserved-cores: N cores for your own sessions, the rest for runs (serve.sh); kept for the
#   next setup or update. Default: as before, or 0 (runs take every core).
set -euo pipefail

ip=${1:?usage: $0 <ip> [--user <user>] [--hostname <name>] [--guest-from <user@host>] [--reserved-cores N]}
shift
user=det
hostname=determinismo
guest_from=
reserved=
while [ $# -gt 0 ]; do
  case $1 in
    --user) user=$2 ;;
    --hostname) hostname=$2 ;;
    --guest-from) guest_from=$2 ;;
    --reserved-cores) reserved=$2 ;;
    *) echo "error: unknown option $1" >&2; exit 2 ;;
  esac
  shift 2
done
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

echo "== waiting for $ip to accept SSH"
until ssh "${ssh_opts[@]}" "root@$ip" true 2>/dev/null \
   || ssh "${ssh_opts[@]}" "$user@$ip" true 2>/dev/null; do
  sleep 30
done

if ssh "${ssh_opts[@]}" "root@$ip" 'test -x /root/.oldroot/nfs/install/installimage' 2>/dev/null; then
  echo "== installing Debian (rescue system)"
  "$repo/infra/hetzner/install-os.sh" "$ip" "$hostname"
  sleep 60 # The reboot begins.
fi

echo "== provisioning and hardening"
"$here/bootstrap.sh" "$ip" "$user"

echo "== the repository"
rsync -az --delete -e "ssh ${ssh_opts[*]}" \
  --exclude .git --exclude .zig-cache --exclude zig-out --exclude .determinismo-cache \
  --exclude todo.md --exclude 'guest/module/*.ko' --exclude 'guest/module/*.o' \
  --exclude 'guest/module/.*' --exclude 'guest/module/*.mod*' \
  --exclude guest/module/Module.symvers --exclude guest/module/modules.order \
  "$repo/" "$user@$ip:determinismo/"

if [ -n "$guest_from" ]; then
  echo "== the guest, from $guest_from"
  ssh "${ssh_opts[@]}" "$guest_from" 'tar -C ~/guest -c vmlinuz det_guest.ko' \
    | ssh "${ssh_opts[@]}" "$user@$ip" 'mkdir -p ~/guest && tar -C ~/guest -x'
fi

ssh "${ssh_opts[@]}" "$user@$ip" bash -s -- "$reserved" <<'EOF'
set -euo pipefail
reserved=${1:-}
cd ~/determinismo
echo "== serve stopped (and its runs): the build and KVM change under them"
sudo infra/host/serve.sh "$USER" stop
echo "== toolchain"
infra/host/tools.sh
echo "== hardware qualification"
sudo infra/host/m0-check.sh
echo "== our KVM"
infra/host/build-kvm.sh
# Loaded unless this very build is (load-kvm.sh records its hashes): a patch changed, it is
# reloaded, which needs every VM stopped (load-kvm.sh says so otherwise).
kvm_build=~/kvm-build/linux-$(uname -r | cut -d+ -f1)/arch/x86/kvm
built=$(sha256sum "$kvm_build/kvm.ko" "$kvm_build/kvm-intel.ko" | cut -d' ' -f1)
[ "$built" = "$(cat /run/determinismo-kvm 2>/dev/null)" ] || sudo infra/host/load-kvm.sh
sudo infra/host/kvm-at-boot.sh "$USER"
echo "== the guest and the build"
[ -f ~/guest/vmlinuz ] && [ -f ~/guest/det_guest.ko ] || guest/kernel/build.sh ~/guest
~/opt/zig/zig build -Drelease
zig-out/bin/det-initramfs --bin zig-out/bin --module ~/guest/det_guest.ko \
  --busybox /usr/bin/busybox --out ~/guest/base.cpio
echo "== end-to-end check"
~/opt/zig/zig build e2e -Drelease -Donly=bank
echo "== serve"
sudo infra/host/serve.sh "$USER" start ${reserved:+--reserved-cores "$reserved"}
EOF
echo "== $ip is a determinismo host ($user@$ip)"
