#!/bin/bash
set -euo pipefail
exec > /var/log/skybroe-init.log 2>&1

# Bootstrap only. The deploy job in .github/workflows/cd.yml copies
# infra/docker-compose.prod.yml + infra/Caddyfile to /opt/skybroe and
# writes .env, so the instance never carries a stale copy of the stack.

# ── Swap — headroom for a small (1–2 GB) instance during image pulls ─
if [ ! -f /swapfile ]; then
  dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap defaults 0 0' >> /etc/fstab
fi

# ── Docker + Compose plugin ─────────────────────────────────────────
dnf install -y docker
# Cap local container logs (Caddy uses the default json-file driver) so a
# small root volume can't fill up.
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'JSON'
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
JSON
systemctl enable --now docker
usermod -aG docker ec2-user

dnf install -y docker-compose-plugin || {
  # Not packaged on AL2023 — fetch the release binary for this CPU arch
  # (uname -m → x86_64 | aarch64, matching Compose's asset names).
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -fsSL "https://github.com/docker/compose/releases/download/v2.27.1/docker-compose-linux-$(uname -m)" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
}

# ── App directory ─────────────────────────────────────────────────
mkdir -p /opt/skybroe
chown ec2-user:ec2-user /opt/skybroe

# ── Systemd service — starts containers on reboot once .env exists ─
cat > /etc/systemd/system/skybroe.service <<'SERVICE'
[Unit]
Description=SkyBroe containers
After=docker.service network-online.target
Requires=docker.service
ConditionPathExists=/opt/skybroe/.env

[Service]
Type=oneshot
RemainAfterExit=yes
User=ec2-user
WorkingDirectory=/opt/skybroe
ExecStart=/usr/bin/docker compose -f /opt/skybroe/docker-compose.prod.yml up -d
ExecStop=/usr/bin/docker compose -f /opt/skybroe/docker-compose.prod.yml down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable skybroe

echo "skybroe-init complete — Docker ready, awaiting first deploy"
