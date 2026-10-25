#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Builds the guest's base initramfs: det-init as /init, the guest runtime, busybox (for shells in
# debugging and the exec agent) and det_guest.ko (built with the guest kernel, which has all
# else built in: guest/kernel/). Nothing about the system under test is here: that comes on
# disks (see src/prepare.zig).
# Runs on the Linux host. Usage: guest/build-initramfs.sh <bin-dir> <det_guest.ko> <out.cpio.zst>
set -euo pipefail
bins=${1:?usage: $0 <bin-dir> <det_guest.ko> <out.cpio.zst>}
module=${2:?}
out=${3:?}
busybox=$(command -v busybox) || { echo "install busybox-static" >&2; exit 1; }
file -L "$busybox" | grep -q "statically linked" || { echo "busybox must be static" >&2; exit 1; }

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage"/{bin,sbin,etc,proc,sys,dev,run,tmp,det,root} \
  "$stage/opt/determinismo/bin" "$stage/opt/determinismo/modules"
install -m 755 "$busybox" "$stage/bin/busybox"
for applet in $("$busybox" --list); do
  [ -e "$stage/bin/$applet" ] || ln -s busybox "$stage/bin/$applet"
done
for program in det-init det-nodes det-composer det-faults det-agent; do
  install -m 755 "$bins/$program" "$stage/opt/determinismo/bin/$program"
done
ln -s opt/determinismo/bin/det-init "$stage/init"
install -m 644 "$module" "$stage/opt/determinismo/modules/det_guest.ko"
echo "root:x:0:0:root:/root:/bin/sh" > "$stage/etc/passwd"
echo "root:x:0:" > "$stage/etc/group"
# Reproducible: fixed order, owners and timestamps, so the same inputs give the same bytes. This
# matters for replay: the guest decompresses and unpacks this archive, so its exact bytes are
# part of every timeline.
find "$stage" -exec touch -h -d @0 {} +
(cd "$stage" && find . -print0 | LC_ALL=C sort -z | \
  cpio -o -0 -H newc --quiet --reproducible --owner=0:0 | zstd -q -T0 -19) > "$out"
ls -la "$out"
