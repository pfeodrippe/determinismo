#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Loads our KVM modules at every boot (a systemd unit running load-kvm.sh with the user's
# build), so a reboot does not leave the stock ones. Idempotent. Run as root.
# Usage: kvm-at-boot.sh <user>
set -euo pipefail
user=${1:?usage: $0 <user>}
home=$(getent passwd "$user" | cut -d: -f6)
repo=$(cd "$(dirname "$0")/../.." && pwd)
# The host kernel is pinned (provision.sh): the build is for this version.
build=$home/kvm-build/linux-$(uname -r | cut -d+ -f1)/arch/x86/kvm
[ -f "$build/kvm-intel.ko" ] || { echo "error: no KVM build in $build (build-kvm.sh)" >&2; exit 1; }
cat > /etc/systemd/system/determinismo-kvm.service <<EOF
[Unit]
Description=determinismo's KVM modules (kernel/patches)
After=systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$repo/infra/host/load-kvm.sh $build

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable determinismo-kvm.service >/dev/null
echo "determinismo-kvm.service enabled: $build"
