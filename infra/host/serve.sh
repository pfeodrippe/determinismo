#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Runs `determinismo serve` as a systemd unit for the user's build: started at boot after our
# KVM, restarted if it fails. A restart (a new build) leaves its runs running: the new serve adopts
# them (their pid files). `stop` takes the runs too (they live in its cgroup): before KVM is
# reloaded. Idempotent. Run as root.
# Usage: serve.sh <user> start|stop [--reserved-cores N]
#   Every exploration on the host is one of its runs (~/.determinismo, src/runs.zig): serve
#   shows them however they were started.
#   --reserved-cores N: N physical cores (with their hyperthreads) for the user's own sessions
#   (ssh: builds, checks, benchmarks), the rest for serve and every run it starts (hunts), each
#   confined to its share by the kernel (cgroup cpusets: systemd's AllowedCPUs). Kept in
#   /etc/determinismo/reserved-cores for the next start. Default 0: runs may take every core.
set -euo pipefail
user=${1:?usage: $0 <user> start|stop [--reserved-cores N]}
action=${2:?usage: $0 <user> start|stop [--reserved-cores N]}
shift 2
reserved_given=
while [ $# -gt 0 ]; do
  case $1 in
    --reserved-cores) reserved_given=${2:?--reserved-cores needs a number}; shift 2 ;;
    *) echo "error: unknown option $1" >&2; exit 2 ;;
  esac
done
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
# The host's cores: N of them (the first, with their hyperthreads) for the user's sessions, the
# rest for serve and its runs.
config=/etc/determinismo/reserved-cores
if [ -n "$reserved_given" ]; then
  mkdir -p "$(dirname "$config")"
  echo "$reserved_given" > "$config"
fi
reserved=$(cat "$config" 2>/dev/null || echo 0)
read -r own_cpus run_cpus < <(python3 - "$reserved" <<'PY'
import sys

def cpus(text):
    out = []
    for part in text.strip().split(","):
        if part:
            first, _, last = part.partition("-")
            out += range(int(first), int(last or first) + 1)
    return out

def listed(cpus):
    ranges, start, previous = [], None, None
    for cpu in sorted(cpus) + [None]:
        if start is not None and cpu != previous + 1:
            ranges.append(f"{start}" if start == previous else f"{start}-{previous}")
            start = None
        if start is None:
            start = cpu
        previous = cpu
    return ",".join(ranges)

reserved = int(sys.argv[1])
online = cpus(open("/sys/devices/system/cpu/online").read())
cores = {}
for cpu in online:
    path = f"/sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list"
    siblings = [c for c in cpus(open(path).read()) if c in online]
    cores.setdefault(min(siblings), set()).update(siblings)
if reserved <= 0:
    print("- -")
elif reserved >= len(cores):
    sys.exit(f"error: {reserved} reserved cores leave none of {len(cores)} to runs")
else:
    own = set().union(*(cores[first] for first in sorted(cores)[:reserved]))
    print(listed(own), listed(set(online) - own))
PY
)
[ "$own_cpus" = - ] && own_cpus= && run_cpus=
# The user's sessions on their cores (or every core again, without a reservation).
systemctl set-property "user-$uid.slice" "AllowedCPUs=$own_cpus"
# On the tailnet too (tailscale.sh): the web UI from your devices, without a tunnel.
listen=127.0.0.1:7878
if command -v tailscale >/dev/null && address=$(tailscale ip -4 2>/dev/null); then
  listen="$listen,$address:7878"
fi
# Runs prepare images with rootless podman, which wants the user's runtime directory: the user's
# manager runs without a login (lingering), and the unit starts after it.
loginctl enable-linger "$user"
cat > "/etc/systemd/system/$unit" <<EOF
[Unit]
Description=determinismo serve (runs, results and the web UI on $listen)
# At boot, after our KVM is loaded (ordering only: setup.sh loads it itself), and Tailscale.
After=network.target determinismo-kvm.service user@$uid.service tailscaled.service
Wants=user@$uid.service

[Service]
User=$user
Environment=XDG_RUNTIME_DIR=/run/user/$uid
WorkingDirectory=$home/determinismo
ExecStart=$home/determinismo/zig-out/bin/determinismo serve --listen $listen \\
  --bb $home/opt/bb/bb --kernel $home/guest/vmlinuz \\
  --initrd $home/guest/base.cpio --append quiet --cache $home/cache --memory-mib 4096
# Restarts stop serve alone: its runs go on, adopted by the next.
KillMode=process
# A process the kernel's OOM killer takes (a holder, a worker) is not a reason to stop the unit
# and every run in it: systemd's default (stop) did, 2026-10-27.
OOMPolicy=continue
# The cores runs may take (all without a reservation: --reserved-cores).
AllowedCPUs=$run_cpus
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$unit" >/dev/null
systemctl restart "$unit"
echo "$unit running: $home/determinismo, runs in $home/.determinismo"
[ -z "$own_cpus" ] || echo "cores: CPUs $own_cpus for $user's sessions, $run_cpus for runs"
