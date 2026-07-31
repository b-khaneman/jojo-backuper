#!/usr/bin/env bash
#===============================================================================
# JOJO BACKUPER — One-command bootstrap
# by @B_KHANEMAN
#
#   curl -fsSL https://raw.githubusercontent.com/b-khaneman/jojo-backuper/main/bootstrap.sh | sudo bash
#===============================================================================

set -uo pipefail

REPO_URL="${JOJO_REPO_URL:-https://github.com/b-khaneman/jojo-backuper.git}"
INSTALL_DIR="${JOJO_INSTALL_DIR:-/opt/jojo-backuper}"
BRANCH="${JOJO_BRANCH:-main}"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "[ERROR] Run as root:"
    echo "  curl -fsSL https://raw.githubusercontent.com/b-khaneman/jojo-backuper/main/bootstrap.sh | sudo bash"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

echo "========================================="
echo "  JOJO BACKUPER — Quick Install"
echo "  by @B_KHANEMAN"
echo "========================================="
echo

echo "[+] Installing base packages..."
apt-get update -qq || true
apt-get install -y git curl ca-certificates >/dev/null 2>&1 || apt-get install -y git curl ca-certificates

preserve_runtime() {
    local app="${INSTALL_DIR}/server-migration-manager"
    mkdir -p /tmp/jojo-preserve.$$
    [[ -f "${app}/config.conf" ]] && cp -a "${app}/config.conf" /tmp/jojo-preserve.$$/config.conf
    [[ -d "${app}/logs" ]] && cp -a "${app}/logs" /tmp/jojo-preserve.$$/logs
}

restore_runtime() {
    local app="${INSTALL_DIR}/server-migration-manager"
    mkdir -p "${app}/logs" "${app}/backups"
    [[ -f /tmp/jojo-preserve.$$/config.conf ]] && cp -a /tmp/jojo-preserve.$$/config.conf "${app}/config.conf"
    [[ -d /tmp/jojo-preserve.$$/logs ]] && cp -a /tmp/jojo-preserve.$$/logs/. "${app}/logs/" 2>/dev/null || true
    rm -rf /tmp/jojo-preserve.$$
}

echo "[+] Syncing from GitHub..."
preserve_runtime
if [[ ! -d "${INSTALL_DIR}/.git" ]]; then
    rm -rf "$INSTALL_DIR"
    git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$INSTALL_DIR"
else
    git -C "$INSTALL_DIR" remote set-url origin "$REPO_URL" 2>/dev/null || true
    git -C "$INSTALL_DIR" fetch origin "$BRANCH" --prune 2>/dev/null || git -C "$INSTALL_DIR" fetch origin
    git -C "$INSTALL_DIR" checkout -f "$BRANCH" >/dev/null 2>&1 || true
    git -C "$INSTALL_DIR" reset --hard "origin/${BRANCH}" >/dev/null 2>&1 || true
    git -C "$INSTALL_DIR" clean -fd \
        -e 'server-migration-manager/backups' \
        -e 'server-migration-manager/logs' >/dev/null 2>&1 || true
fi
restore_runtime
echo "[OK] Code: $(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo ok)"

APP_DIR="${INSTALL_DIR}/server-migration-manager"
[[ -f "${APP_DIR}/migrate.sh" ]] || { echo "[ERROR] migrate.sh missing"; exit 1; }

chmod +x "$APP_DIR"/*.sh 2>/dev/null || true
find "$APP_DIR/modules" "$APP_DIR/scripts" -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true

echo "[+] Running installer..."
bash "${APP_DIR}/install.sh" || { echo "[ERROR] install failed"; exit 1; }

rm -f /usr/local/bin/smm /usr/local/bin/jojo /usr/local/bin/jojo-backuper /usr/local/bin/jojo-menu
ln -sfn "${APP_DIR}/migrate.sh" /usr/local/bin/smm
ln -sfn "${APP_DIR}/migrate.sh" /usr/local/bin/jojo
ln -sfn "${APP_DIR}/migrate.sh" /usr/local/bin/jojo-backuper

# Absolute launcher — always works
cat > /usr/local/bin/jojo-menu <<EOF
#!/usr/bin/env bash
exec bash "${APP_DIR}/migrate.sh" "\$@"
EOF
chmod +x /usr/local/bin/jojo-menu

echo
echo "========================================="
echo "  INSTALL COMPLETE"
echo "========================================="
echo
echo "  Start the menu with this command:"
echo
echo "      sudo jojo-menu"
echo
echo "  or:"
echo
echo "      sudo bash ${APP_DIR}/migrate.sh"
echo
echo "========================================="
echo

# NEVER auto-launch after curl|bash — it hangs waiting on /dev/tty/script.
# Only auto-launch when this script itself was started on a real TTY
# (e.g. sudo bash bootstrap.sh downloaded as a file).
if [[ -t 0 && -t 1 && -r /dev/tty ]]; then
    echo "[+] Interactive terminal detected — starting menu..."
    exec bash "${APP_DIR}/migrate.sh"
fi

echo "[*] Pipe install detected (curl|bash) — menu is ready."
echo "    Type the command above to open it."
exit 0
