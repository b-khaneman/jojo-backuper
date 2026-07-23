#!/usr/bin/env bash
#===============================================================================
# install.sh — Install dependencies for JOJO BACKUPER
# by @B_KHANEMAN — Ubuntu 20.04 / 22.04 / 24.04
#
# Usage:
#   sudo bash install.sh          # install only
#   sudo bash install.sh --run    # install then launch menu
#===============================================================================

set -euo pipefail

RUN_AFTER="no"
for arg in "$@"; do
    case "$arg" in
        --run|-r) RUN_AFTER="yes" ;;
        --help|-h)
            echo "Usage: sudo bash install.sh [--run]"
            exit 0
            ;;
    esac
done

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root: sudo bash $0"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "[+] Updating apt..."
apt-get update -qq

PKGS=(
    tar rsync openssh-client ca-certificates git
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
# Prefer canonical path if this file is reached via odd wrappers
if command -v readlink >/dev/null 2>&1; then
    _canon="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
    if [[ -n "$_canon" ]]; then
        SCRIPT_DIR="$(cd "$(dirname "$_canon")" && pwd)"
    fi
    unset _canon
fi
chmod +x "${SCRIPT_DIR}/migrate.sh" "${SCRIPT_DIR}/restore-agent.sh" "${SCRIPT_DIR}/install.sh" 2>/dev/null || true
# Fix no-exec / missing +x (common Permission denied / os error 13)
chmod +x "${SCRIPT_DIR}/install.sh" || true
find "${SCRIPT_DIR}/modules" -type f -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true

# Strip CRLF if present (Windows checkout)
if command -v sed >/dev/null 2>&1; then
    sed -i 's/\r$//' "${SCRIPT_DIR}/migrate.sh" "${SCRIPT_DIR}/install.sh" "${SCRIPT_DIR}/restore-agent.sh" 2>/dev/null || true
    find "${SCRIPT_DIR}/modules" -type f -name '*.sh' -exec sed -i 's/\r$//' {} \; 2>/dev/null || true
fi

mkdir -p /var/log/server-migration
mkdir -p "${SCRIPT_DIR}/backups" "${SCRIPT_DIR}/logs"

# Always recreate clean symlinks (never copy migrate.sh into /usr/local/bin)
rm -f /usr/local/bin/smm /usr/local/bin/jojo /usr/local/bin/jojo-backuper
ln -sfn "${SCRIPT_DIR}/migrate.sh" /usr/local/bin/smm
ln -sfn "${SCRIPT_DIR}/migrate.sh" /usr/local/bin/jojo
ln -sfn "${SCRIPT_DIR}/migrate.sh" /usr/local/bin/jojo-backuper

# Verify symlink points to real migrate.sh
if [[ ! -L /usr/local/bin/jojo ]] || [[ ! -f "$(readlink -f /usr/local/bin/jojo)" ]]; then
    echo "[WARN] Symlink verification failed — use: sudo bash ${SCRIPT_DIR}/migrate.sh"
fi

echo "[OK] Symlinks: jojo / smm / jojo-backuper"
echo
echo "[OK] JOJO BACKUPER dependencies installed."
echo "     Author: @B_KHANEMAN"
echo "     Start:  sudo jojo"
echo "         or: sudo bash ${SCRIPT_DIR}/migrate.sh"

if [[ "$RUN_AFTER" == "yes" ]]; then
    echo
    echo "[+] Launching JOJO BACKUPER..."
    if [[ ! -t 0 ]] && [[ -r /dev/tty ]]; then
        exec </dev/tty
    fi
    exec bash "${SCRIPT_DIR}/migrate.sh"
fi
