#!/usr/bin/env bash
# Standalone heal for a broken post-migration VPS.
# Usage on NEW server:
#   curl -fsSL https://raw.githubusercontent.com/b-khaneman/jojo-backuper/main/server-migration-manager/scripts/heal-new-server.sh | sudo bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export TERM="${TERM:-xterm-256color}"

echo "=== JOJO BACKUPER auto-heal (standalone) ==="

# APT hooks
rm -f /etc/apt/apt.conf.d/*virt* /etc/apt/apt.conf.d/*hook* 2>/dev/null || true
sed -i '/apt_hook_ubuntu_virt/d' /etc/apt/apt.conf.d/* 2>/dev/null || true
rm -f /etc/apt/sources.list.d/docker*.list 2>/dev/null || true

# Dangling profile scripts
rm -f /etc/profile.d/70-systemd-shell-extra.sh /etc/profile.d/80-systemd-osc-context.sh 2>/dev/null || true
find /etc/profile.d -maxdepth 1 -type l ! -exec test -e {} \; -delete 2>/dev/null || true

apt-get update -qq || apt-get update || true

systemctl stop docker.socket docker.service containerd 2>/dev/null || true
apt-get remove -y docker.io docker-ce docker-ce-cli docker-compose-v2 docker-compose-plugin \
  containerd containerd.io docker-compose 2>/dev/null || true
apt-get purge -y docker-compose-plugin containerd.io docker-ce docker-ce-cli 2>/dev/null || true
dpkg --remove --force-remove-reinstreq docker-compose-plugin 2>/dev/null || true
apt-get -f install -y || true
apt-get install -y docker.io docker-compose-v2 || apt-get install -y docker.io || true

# Wipe stale container IDs (keep volumes/images)
systemctl stop docker containerd 2>/dev/null || true
rm -rf /var/lib/docker/containers /var/lib/docker/network
mkdir -p /var/lib/docker/containers /var/lib/docker/network
systemctl enable docker 2>/dev/null || true
systemctl start containerd 2>/dev/null || true
systemctl start docker
sleep 3
docker --version || { echo "Docker install failed"; exit 1; }

if [[ -d /opt/pasarguard ]]; then
  cd /opt/pasarguard
  if [[ -f .env ]] && grep -qE '^COMPOSE_PROJECT_NAME=[0-9a-f]{12}' .env 2>/dev/null; then
    sed -i '/^COMPOSE_PROJECT_NAME=/d' .env
  fi
  docker compose -p pasarguard down --remove-orphans 2>/dev/null || true
  docker rm -f $(docker ps -aq) 2>/dev/null || true
  docker compose -p pasarguard pull 2>/dev/null || true
  docker compose -p pasarguard up -d --force-recreate --remove-orphans || \
    docker-compose -p pasarguard up -d --force-recreate --remove-orphans || true
  sleep 5
  docker ps -a
  echo "=== PasarGuard heal attempted ==="
fi

# Official CLI (panel dir can exist without /usr/local/bin/pasarguard)
if ! command -v pasarguard >/dev/null 2>&1; then
  echo "=== Installing PasarGuard CLI ==="
  if [[ -f /opt/pasarguard/pasarguard.sh ]]; then
    cp -a /opt/pasarguard/pasarguard.sh /usr/local/bin/pasarguard
    chmod +x /usr/local/bin/pasarguard
  elif curl -fsSL "https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh" -o /usr/local/bin/pasarguard; then
    chmod +x /usr/local/bin/pasarguard
  else
    cat > /usr/local/bin/pasarguard <<'EOF'
#!/bin/bash
exec bash -c "$(curl -fsSL https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh)" -- "$@"
EOF
    chmod +x /usr/local/bin/pasarguard
  fi
fi
command -v pasarguard && echo "pasarguard CLI: $(command -v pasarguard)" || echo "pasarguard CLI still missing"

echo "=== DONE ==="
