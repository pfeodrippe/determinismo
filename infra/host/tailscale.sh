#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Puts the host on your tailnet (Tailscale, from its Debian repository): the web UI is then
# reachable from your devices only, at http://<the host's Tailscale address>:7878 (serve.sh listens
# there too; harden.sh lets port 7878 in from the Tailscale interface alone). Faster than an SSH
# tunnel: direct connections, many at once. Idempotent. Run as root, before serve.sh.
# Usage: tailscale.sh <hostname>
#   The first time, `tailscale up` prints a login URL: open it and sign in with your Tailscale
#   account (this script waits for it), then install Tailscale on your devices with the same one.
set -euo pipefail
name=${1:?usage: $0 <hostname>}
. /etc/os-release
if ! command -v tailscale >/dev/null; then
  base="https://pkgs.tailscale.com/stable/debian/$VERSION_CODENAME"
  curl -fsSL "$base.noarmor.gpg" -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsSL "$base.tailscale-keyring.list" -o /etc/apt/sources.list.d/tailscale.list
  apt-get update -q
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q tailscale
fi
systemctl enable --now tailscaled >/dev/null
tailscale up --hostname "$name"
echo "tailscale: $name is $(tailscale ip -4)"
