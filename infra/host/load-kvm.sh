#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Replaces the loaded KVM modules with our build (or the stock ones with --stock). Run as root.
# Usage: load-kvm.sh [--stock | <dir containing kvm.ko and kvm-intel.ko>]
set -euo pipefail
home=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
dir=${1:-$home/kvm-build/linux-$(uname -r | cut -d+ -f1)/arch/x86/kvm}
loaded=/run/determinismo-kvm # The loaded build's hashes (setup.sh reloads a newer one).

modprobe -r kvm_intel kvm 2>/dev/null || { echo "error: KVM is in use (stop all VMs first)" >&2; exit 1; }
rm -f "$loaded"
if [ "$dir" = --stock ]; then
  modprobe kvm_intel
else
  modprobe irqbypass
  insmod "$dir/kvm.ko"
  insmod "$dir/kvm-intel.ko"
  sha256sum "$dir/kvm.ko" "$dir/kvm-intel.ko" | cut -d' ' -f1 > "$loaded"
fi
printf 'kvm taint=%s kvm_intel taint=%s (O = our out-of-tree build)\n' \
  "$(cat /sys/module/kvm/taint)" "$(cat /sys/module/kvm_intel/taint)"
