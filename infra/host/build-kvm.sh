#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Builds kvm.ko and kvm-intel.ko out-of-tree from the Debian source matching the running kernel,
# applying kernel/patches/*.patch (if any). Runs on the host as a sudo-capable user.
# Usage: build-kvm.sh [workdir]   Output: <workdir>/linux-<ver>/arch/x86/kvm/{kvm,kvm-intel}.ko
set -euo pipefail

krel=$(uname -r)                          # e.g. 6.12.113+deb13-amd64
ver=${krel%%+*}                           # e.g. 6.12.113
series=$(echo "$ver" | cut -d. -f1,2)     # e.g. 6.12
repo=$(cd "$(dirname "$0")/../.." && pwd)
work=${1:-$HOME/kvm-build}
tree=$work/linux-$ver
patched_paths="arch/x86/kvm arch/x86/include virt/kvm include"

pkgver=$(dpkg-query -W -f='${Version}' "linux-image-$krel")
if ! dpkg-query -W -f='${Version}' "linux-source-$series" 2>/dev/null | grep -qx "$pkgver"; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q "linux-source-$series=$pkgver"
fi

if [ ! -f "$tree/.prepared" ]; then
  rm -rf "$tree"; mkdir -p "$work"
  tar -C "$work" -xaf "/usr/src/linux-source-$series.tar.xz"
  mv "$work/linux-source-$series" "$tree"
  cp "/boot/config-$krel" "$tree/.config"
  cp "/usr/src/linux-headers-$krel/Module.symvers" "$tree/"
  # Debian's signing-key paths don't exist outside their build; modules_prepare doesn't need them.
  "$tree/scripts/config" --file "$tree/.config" --set-str SYSTEM_TRUSTED_KEYS "" \
    --set-str SYSTEM_REVOCATION_KEYS "" --set-str MODULE_SIG_KEY ""
  make -C "$tree" -s olddefconfig
  make -C "$tree" -s -j"$(nproc)" KERNELRELEASE="$krel" modules_prepare
  # Track only what our patches may touch (Debian's .gitignore ignores everything, hence -f).
  (cd "$tree" && git init -q && git add -f -- $patched_paths \
     && git -c user.email=b@local -c user.name=build commit -qm base)
  touch "$tree/.prepared"
fi

# Re-apply our patches on a clean base every time.
(cd "$tree" && git checkout -q -- $patched_paths && git clean -qfd -- arch/x86/kvm virt/kvm)
for p in "$repo"/kernel/patches/*.patch; do
  [ -e "$p" ] || continue
  echo "applying $(basename "$p")"
  (cd "$tree" && git apply --whitespace=nowarn "$p")
done

make -C "$tree" -s -j"$(nproc)" KERNELRELEASE="$krel" M=arch/x86/kvm modules
ls -la "$tree/arch/x86/kvm/"{kvm,kvm-intel}.ko
