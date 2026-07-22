#!/usr/bin/env bash
#===============================================================================
# install.sh — Install dependencies for JOJO BACKUPER v1.1.1
# by @B_KHANEMAN — Ubuntu 20.04 / 22.04 / 24.04
#===============================================================================

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "[+] Updating apt..."
apt-get update -qq

PKGS=(
    tar rsync openssh-client ca-certificates
    zstd pv gzip xz-utils
    coreutils util-linux
    iptables iptables-persistent
    curl wget
    gnupg openssl
    sshpass
    jq
)

echo "[+] Installing: ${PKGS[*]}"
apt-get install -y "${PKGS[@]}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "${SCRIPT_DIR}/migrate.sh" "${SCRIPT_DIR}/restore-agent.sh" "${SCRIPT_DIR}/install.sh"
find "${SCRIPT_DIR}/modules" -type f -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true

mkdir -p /var/log/server-migration
mkdir -p "${SCRIPT_DIR}/backups" "${SCRIPT_DIR}/logs"

ln -sfn "${SCRIPT_DIR}/migrate.sh" /usr/local/bin/smm
echo "[OK] Symlink: smm → ${SCRIPT_DIR}/migrate.sh"
echo
echo "[OK] JOJO BACKUPER dependencies installed."
echo "     Author: @B_KHANEMAN"
echo "     Start with: sudo ./migrate.sh"
echo "            or: sudo smm"
