#!/usr/bin/env bash
#===============================================================================
# install.sh — Install dependencies for JOJO BACKUPER
# by @B_KHANEMAN — Ubuntu 20.04 / 22.04 / 24.04
#
# Usage:
#   sudo bash install.sh          # install only
#   sudo bash install.sh --run    # install then launch menu
#===============================================================================

set -uo pipefail

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
export NEEDRESTART_MODE=a

# Avoid interactive prompts from iptables-persistent
echo 'iptables-persistent iptables-persistent/autosave_v4 boolean true' | debconf-set-selections 2>/dev/null || true
echo 'iptables-persistent iptables-persistent/autosave_v6 boolean true' | debconf-set-selections 2>/dev/null || true

echo "[+] Updating apt..."
apt-get update -qq || apt-get update

PKGS=(
    tar rsync openssh-client ca-certificates git
    zstd pv gzip xz-utils
    coreutils util-linux
    iptables
    curl wget
    gnupg openssl
    sshpass
    jq
    bsdutils
)

echo "[+] Installing: ${PKGS[*]}"
apt-get install -y "${PKGS[@]}" || apt-get install -y --fix-missing "${PKGS[@]}"

# Optional packages (do not fail install)
apt-get install -y iptables-persistent 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v readlink >/dev/null 2>&1; then
    _canon="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
    if [[ -n "$_canon" ]]; then
        SCRIPT_DIR="$(cd "$(dirname "$_canon")" && pwd)"
    fi
    unset _canon
fi

chmod +x "${SCRIPT_DIR}/migrate.sh" "${SCRIPT_DIR}/restore-agent.sh" "${SCRIPT_DIR}/install.sh" 2>/dev/null || true
find "${SCRIPT_DIR}/modules" "${SCRIPT_DIR}/scripts" -type f -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true

if command -v sed >/dev/null 2>&1; then
    sed -i 's/\r$//' "${SCRIPT_DIR}/migrate.sh" "${SCRIPT_DIR}/install.sh" "${SCRIPT_DIR}/restore-agent.sh" 2>/dev/null || true
    find "${SCRIPT_DIR}/modules" "${SCRIPT_DIR}/scripts" -type f -name '*.sh' -exec sed -i 's/\r$//' {} \; 2>/dev/null || true
fi

mkdir -p /var/log/server-migration
mkdir -p "${SCRIPT_DIR}/backups" "${SCRIPT_DIR}/logs"

rm -f /usr/local/bin/smm /usr/local/bin/jojo /usr/local/bin/jojo-backuper /usr/local/bin/jojo-menu
ln -sfn "${SCRIPT_DIR}/migrate.sh" /usr/local/bin/smm
ln -sfn "${SCRIPT_DIR}/migrate.sh" /usr/local/bin/jojo
ln -sfn "${SCRIPT_DIR}/migrate.sh" /usr/local/bin/jojo-backuper

# Absolute-path launcher (immune to symlink SCRIPT_DIR bugs)
cat > /usr/local/bin/jojo-menu <<EOF
#!/usr/bin/env bash
exec bash "${SCRIPT_DIR}/migrate.sh" "\$@"
EOF
chmod +x /usr/local/bin/jojo-menu

echo "[OK] Launchers: jojo-menu / jojo / smm"
echo
echo "[OK] JOJO BACKUPER dependencies installed."
echo "     Author: @B_KHANEMAN"
echo "     Start:  sudo jojo-menu"
echo "         or: sudo bash ${SCRIPT_DIR}/migrate.sh"

# --run only when caller has a real TTY (never hang on curl|bash)
if [[ "$RUN_AFTER" == "yes" ]]; then
    if [[ -t 0 && -t 1 ]]; then
        echo
        echo "[+] Launching JOJO BACKUPER..."
        exec bash "${SCRIPT_DIR}/migrate.sh"
    fi
    echo
    echo "[*] Installed. Open menu with: sudo jojo-menu"
fi
