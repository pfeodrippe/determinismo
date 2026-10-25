#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Assembles a bootable initramfs: base rootfs + our init + scenarios + guest binaries.
# Test templates: every guest binary that answers `--list` (the SDK's handler discovery) gets a
# template directory /opt/determinismo/test/<binary>/ with one entry per handler.
# Runs on the host. Usage: guest/pack-initramfs.sh <rootfs-dir> <bin-dir> <module.ko> <out.cpio.zst>
set -euo pipefail
rootfs=${1:?usage: $0 <rootfs-dir> <bin-dir> <module.ko> <out.cpio.zst>}
bins=${2:?}
module=${3:?}
out=${4:?}
here=$(cd "$(dirname "$0")" && pwd)

stage=$(mktemp -d)
trap 'sudo rm -rf "$stage"' EXIT
sudo cp -a "$rootfs/." "$stage/"
sudo install -m 755 "$here/rootfs/init" "$stage/init"
sudo mkdir -p "$stage/opt/determinismo/bin" "$stage/opt/determinismo/scenarios"
sudo cp -r "$here/scenarios/." "$stage/opt/determinismo/scenarios/"
sudo chmod -R a+rx "$stage/opt/determinismo/scenarios"
sudo mkdir -p "$stage/opt/determinismo/modules" "$stage/opt/determinismo/test"
sudo install -m 644 "$module" "$stage/opt/determinismo/modules/det_guest.ko"
for bin in "$bins"/*; do
  name=$(basename "$bin")
  case $name in determinismo|det-strategy-*) continue ;; esac  # Host-side programs.
  sudo install -m 755 "$bin" "$stage/opt/determinismo/bin/$name"
  handlers=$(timeout 5 "$bin" --list </dev/null 2>/dev/null) || continue
  sudo mkdir -p "$stage/opt/determinismo/test/${name%-test}"
  for handler in $handlers; do
    sudo ln -sf "/opt/determinismo/bin/$name" "$stage/opt/determinismo/test/${name%-test}/$handler"
  done
done
(cd "$stage" && sudo find . -print0 | sudo cpio -o -0 -H newc --quiet | zstd -q -T0 -9) > "$out"
ls -la "$out"
