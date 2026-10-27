#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Builds the guest kernel from the Debian linux-source tarball (the host kernel's version) with
# guest/kernel/patches applied and x86_64_defconfig plus guest/kernel/determinismo.config, and
# det_guest.ko against it.
# Runs on the Linux host. Usage: guest/kernel/build.sh <out-dir>
set -euo pipefail
out=${1:?usage: $0 <out-dir>}
here=$(cd "$(dirname "$0")" && pwd)
version=6.12
tarball=/usr/src/linux-source-$version.tar.xz
[ -f "$tarball" ] || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q linux-source-$version
work=$HOME/guest-kernel
mkdir -p "$work" "$out"
if [ ! -d "$work/linux-source-$version" ]; then
  tar -xJf "$tarball" -C "$work"
fi
cd "$work/linux-source-$version"
# guest/kernel/patches/*.patch, each applied once (a tree that has it is left as it is).
for patch in "$here"/patches/*.patch; do
  [ -e "$patch" ] || continue
  if ! patch -p1 -R -s -f --dry-run < "$patch" > /dev/null 2>&1; then
    patch -p1 -s < "$patch"
  fi
done
make -s x86_64_defconfig
scripts/kconfig/merge_config.sh -m -O . .config "$here/determinismo.config" >/dev/null
make -s olddefconfig
# Every option of the fragment must have survived (dependencies can silently drop some).
missing=0
while read -r line; do
  case $line in CONFIG_*=*) grep -qx "$line" .config || { echo "missing: $line" >&2; missing=1; } ;; esac
done < "$here/determinismo.config"
[ $missing -eq 0 ] || exit 1
make -s -j"$(nproc)" bzImage modules # modules: also writes Module.symvers
cp arch/x86/boot/bzImage "$out/vmlinuz"
make -s -C "$here/../module" KDIR="$PWD" clean all
cp "$here/../module/det_guest.ko" "$out/det_guest.ko"
ls -la "$out"
