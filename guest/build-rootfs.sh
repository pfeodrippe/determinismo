#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Builds the base guest root filesystem (Debian trixie minbase + services under test) into a
# directory. Slow; run once, then use pack-initramfs.sh. Runs on the host.
# Usage: guest/build-rootfs.sh <out-dir> [extra packages...]
set -euo pipefail
out=${1:?usage: $0 <out-dir> [extra packages...]}
shift
pkgs="busybox-static,procps,iproute2,redis-server,redis-tools,postgresql${*:+,$(IFS=,; echo "$*")}"

command -v mmdebstrap >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q mmdebstrap
sudo rm -rf "$out"
sudo mmdebstrap --variant=minbase --include="$pkgs" \
  --dpkgopt='path-exclude=/usr/share/{doc,man,info,locale}/*' \
  --dpkgopt='path-include=/usr/share/locale/locale.alias' \
  trixie "$out"
sudo du -sh "$out"
