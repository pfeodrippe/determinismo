#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Runs on the host as root, after the non-root user's SSH login is verified. Idempotent.
# Usage: harden.sh <user>
set -euo pipefail
user=${1:?usage: $0 <user>}

cat > /etc/ssh/sshd_config.d/10-determinismo.conf <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers $user
EOF
sshd -t
systemctl reload ssh

cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority filter; policy drop;
    iif lo accept
    ct state established,related accept
    ct state invalid drop
    meta l4proto { icmp, ipv6-icmp } accept
    tcp dport 22 accept
    # Tailscale (tailscale.sh): its direct connections, and serve's web UI to the tailnet only.
    udp dport 41641 accept
    iifname "tailscale0" tcp dport 7878 accept
  }
  chain forward { type filter hook forward priority filter; policy drop; }
  chain output  { type filter hook output priority filter; policy accept; }
}
EOF
nft -c -f /etc/nftables.conf
systemctl enable --now nftables >/dev/null
nft -f /etc/nftables.conf

# Security updates only, never the (pinned) kernel.
cat > /etc/apt/apt.conf.d/52determinismo-unattended <<'EOF'
Unattended-Upgrade::Package-Blacklist { "linux-"; };
Unattended-Upgrade::Automatic-Reboot "false";
EOF
echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true | debconf-set-selections
dpkg-reconfigure -f noninteractive unattended-upgrades
