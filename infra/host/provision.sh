#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Runs on the host as root. Idempotent. Usage: provision.sh <user>
set -euo pipefail
user=${1:?usage: $0 <user>}
export DEBIAN_FRONTEND=noninteractive

apt-get update -q
apt-get -y -q full-upgrade
apt-get -y -q install \
  build-essential bc bison flex libelf-dev libssl-dev dwarves zstd \
  linux-headers-amd64 linux-perf msr-tools cpuid numactl \
  git curl rsync tmux htop sudo nftables unattended-upgrades \
  podman uidmap erofs-utils busybox-static xz-utils cpio file default-jre-headless

# The host kernel is pinned: our KVM modules are built against it.
apt-mark hold linux-image-amd64 linux-headers-amd64 >/dev/null

if ! id "$user" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --groups sudo,kvm "$user"
fi
install -d -m 700 -o "$user" -g "$user" "/home/$user/.ssh"
install -m 600 -o "$user" -g "$user" /root/.ssh/authorized_keys "/home/$user/.ssh/authorized_keys"
echo "$user ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$user"
chmod 440 "/etc/sudoers.d/90-$user"
visudo -cq
