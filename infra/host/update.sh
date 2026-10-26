#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Updates a set-up host's build in place, from your machine: the repository synced, the pinned
# tools installed (tools.sh), determinismo and the guest's initramfs rebuilt, and serve restarted
# on the new build with its runs left running (a run keeps the binary it started with; new runs,
# replays and serve itself use the new one). A change to the KVM patch needs setup.sh, which stops
# serve and its runs.
# Usage: infra/host/update.sh <ip> [--user <user>]
set -euo pipefail

ip=${1:?usage: $0 <ip> [--user <user>]}
shift
user=det
while [ $# -gt 0 ]; do
  case $1 in
    --user) user=$2 ;;
    *) echo "error: unknown option $1" >&2; exit 2 ;;
  esac
  shift 2
done
repo=$(cd "$(dirname "$0")/../.." && pwd)
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15)

echo "== the repository"
rsync -az -e "ssh ${ssh_opts[*]}" \
  --exclude .git --exclude .zig-cache --exclude zig-out --exclude .determinismo-cache \
  --exclude todo.md --exclude 'guest/module/*.ko' --exclude 'guest/module/*.o' \
  --exclude 'guest/module/.*' --exclude 'guest/module/*.mod*' \
  --exclude guest/module/Module.symvers --exclude guest/module/modules.order \
  "$repo/" "$user@$ip:determinismo/"

ssh "${ssh_opts[@]}" "$user@$ip" bash -s <<'EOF'
set -euo pipefail
cd ~/determinismo
# KVM as built (build-kvm.sh: the patch over a committed base) is the patch in the repository:
# else setup.sh, which rebuilds and reloads it.
kvm_tree=~/kvm-build/linux-$(uname -r | cut -d+ -f1)
if ! diff -q <(cd "$kvm_tree" && git diff -- arch/x86/kvm arch/x86/include virt/kvm include) \
             <(sed '1,4d' kernel/patches/0001-kvm-determinismo.patch) >/dev/null 2>&1; then
  echo "error: kernel/patches is not the KVM built here: run setup.sh" >&2
  exit 1
fi
echo "== the tools"
infra/host/tools.sh
echo "== the build"
~/opt/zig/zig build -Drelease
zig-out/bin/det-initramfs --bin zig-out/bin --module ~/guest/det_guest.ko \
  --busybox /usr/bin/busybox --out ~/guest/base.cpio
if systemctl is-active --quiet determinismo-serve.service; then
  # The unit as serve.sh writes it now (its runs outlive a restart), then the new build.
  sudo infra/host/serve.sh "$USER" start
fi
echo "== serve: $(systemctl is-active determinismo-serve.service || true)"
EOF
echo "== $ip updated"
