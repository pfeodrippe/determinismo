#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Builds a minimal busybox initramfs that prints a line and reboots. Runs on the host.
# Usage: guest/build-hello.sh <out.cpio.gz>
set -euo pipefail
out=${1:?usage: $0 <out.cpio.gz>}
here=$(cd "$(dirname "$0")" && pwd)
[ -x /bin/busybox ] && file -L /bin/busybox | grep -q 'statically linked' \
  || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q busybox-static
root=$(mktemp -d)
mkdir -p "$root"/{bin,proc,sys,dev,tmp}
cp /bin/busybox "$root/bin/busybox"
install -m 755 "$here/hello/init" "$root/init"
(cd "$root" && find . | cpio -o -H newc --quiet | gzip -9) > "$out"
rm -rf "$root"
ls -la "$out"
