#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Runs `determinismo serve` as a systemd unit for the user's build: started at boot after our
# KVM, restarted if it fails. A restart (a new build) leaves its runs running: the new serve adopts
# them (their pid files). `stop` takes the runs too (they live in its cgroup): before KVM is
# reloaded. Idempotent. Run as root.
# Usage: serve.sh <user> start|stop
#   Then, as the user on the host: determinismo explore --serve 127.0.0.1:7878 ...
set -euo pipefail
user=${1:?usage: $0 <user> start|stop}
action=${2:?usage: $0 <user> start|stop}
home=$(getent passwd "$user" | cut -d: -f6)
uid=$(id -u "$user")
unit=determinismo-serve.service
case $action in
  stop)
    systemctl kill "$unit" 2>/dev/null || true # Every process of the unit: its runs too.
    systemctl stop "$unit" 2>/dev/null || true
    exit 0
    ;;
  start) ;;
  *) echo "error: unknown action $action" >&2; exit 2 ;;
esac
# Runs prepare images with rootless podman, which wants the user's runtime directory: the user's
# manager runs without a login (lingering), and the unit starts after it.
loginctl enable-linger "$user"
cat > "/etc/systemd/system/$unit" <<EOF
[Unit]
Description=determinismo serve (runs, results and the web UI on 127.0.0.1:7878)
# At boot, after our KVM is loaded (ordering only: setup.sh loads it itself).
After=network.target determinismo-kvm.service user@$uid.service
Wants=user@$uid.service

[Service]
User=$user
Environment=XDG_RUNTIME_DIR=/run/user/$uid
WorkingDirectory=$home/determinismo
ExecStart=$home/determinismo/zig-out/bin/determinismo serve --listen 127.0.0.1:7878 \\
  --data $home/det-runs --bb $home/opt/bb/bb --kernel $home/guest/vmlinuz \\
  --initrd $home/guest/base.cpio --append quiet --cache $home/cache --memory-mib 4096
# Restarts stop serve alone: its runs go on, adopted by the next.
KillMode=process
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$unit" >/dev/null
systemctl restart "$unit"
echo "$unit running: $home/determinismo, data in $home/det-runs"
