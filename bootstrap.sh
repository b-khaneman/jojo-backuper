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
SKIP_RUN="${JOJO_SKIP_RUN:-no}"

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

echo "[+] Installing base packages (git curl)..."
apt-get update -qq || true
apt-get install -y git curl ca-certificates >/dev/null 2>&1 || apt-get install -y git curl ca-certificates

# Preserve local runtime data across updates
preserve_runtime() {
    local app="${INSTALL_DIR}/server-migration-manager"
    mkdir -p /tmp/jojo-preserve.$$
    [[ -f "${app}/config.conf" ]] && cp -a "${app}/config.conf" /tmp/jojo-preserve.$$/config.conf
    [[ -d "${app}/logs" ]] && cp -a "${app}/logs" /tmp/jojo-preserve.$$/logs
    # backups stay on disk (not removed by git reset if untracked) — still copy marker
    true
}

restore_runtime() {
    local app="${INSTALL_DIR}/server-migration-manager"
    mkdir -p "${app}/logs" "${app}/backups"
    if [[ -f /tmp/jojo-preserve.$$/config.conf ]]; then
        cp -a /tmp/jojo-preserve.$$/config.conf "${app}/config.conf"
        echo "[+] Restored local config.conf"
    fi
    if [[ -d /tmp/jojo-preserve.$$/logs ]]; then
        cp -a /tmp/jojo-preserve.$$/logs/. "${app}/logs/" 2>/dev/null || true
    fi
    rm -rf /tmp/jojo-preserve.$$
}

sync_from_github() {
    echo "[+] Syncing from GitHub (${BRANCH})..."
    preserve_runtime

    if [[ ! -d "${INSTALL_DIR}/.git" ]]; then
        echo "[+] Cloning into ${INSTALL_DIR} ..."
        rm -rf "$INSTALL_DIR"
        git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$INSTALL_DIR"
        restore_runtime
        return 0
    fi

    git -C "$INSTALL_DIR" remote set-url origin "$REPO_URL" 2>/dev/null || \
        git -C "$INSTALL_DIR" remote add origin "$REPO_URL" 2>/dev/null || true

    # Discard local tracked edits quietly (backups/logs are usually untracked)
    git -C "$INSTALL_DIR" fetch --all --prune 2>/dev/null || git -C "$INSTALL_DIR" fetch origin
    git -C "$INSTALL_DIR" checkout -f "$BRANCH" >/dev/null 2>&1 || true
    git -C "$INSTALL_DIR" reset --hard "origin/${BRANCH}" >/dev/null 2>&1 || \
        git -C "$INSTALL_DIR" reset --hard "origin/${BRANCH}"
    # Remove leftover untracked tracked-path junk but keep backups/logs
    git -C "$INSTALL_DIR" clean -fd \
        -e 'server-migration-manager/backups' \
        -e 'server-migration-manager/logs' \
        >/dev/null 2>&1 || true

    local rev
    rev="$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "[OK] Code updated → ${rev}"
    restore_runtime
}

sync_from_github

APP_DIR="${INSTALL_DIR}/server-migration-manager"
if [[ ! -f "${APP_DIR}/migrate.sh" ]]; then
    echo "[ERROR] migrate.sh not found at ${APP_DIR}"
    exit 1
fi

chmod +x "$APP_DIR"/install.sh "$APP_DIR"/migrate.sh "$APP_DIR"/restore-agent.sh 2>/dev/null || true
find "$APP_DIR/modules" -type f -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true

echo "[+] Running installer..."
bash "${APP_DIR}/install.sh" || {
    echo "[ERROR] install.sh failed"
    exit 1
}

rm -f /usr/local/bin/smm /usr/local/bin/jojo /usr/local/bin/jojo-backuper /usr/local/bin/jojo-menu
ln -sfn "${APP_DIR}/migrate.sh" /usr/local/bin/smm
ln -sfn "${APP_DIR}/migrate.sh" /usr/local/bin/jojo
ln -sfn "${APP_DIR}/migrate.sh" /usr/local/bin/jojo-backuper

cat > /usr/local/bin/jojo-menu <<EOF
#!/usr/bin/env bash
exec bash "${APP_DIR}/migrate.sh" "\$@"
EOF
chmod +x /usr/local/bin/jojo-menu

echo
echo "[OK] JOJO BACKUPER ready at ${INSTALL_DIR}"
echo "     Start:  sudo jojo-menu"
echo "         or: sudo bash ${APP_DIR}/migrate.sh"
echo

if [[ "${SKIP_RUN}" == "yes" || "${JOJO_SKIP_RUN:-}" == "yes" ]]; then
    exit 0
fi

echo "[+] Launching menu..."
echo "-----------------------------------------"

if [[ -r /dev/tty && -w /dev/tty ]]; then
    if command -v script >/dev/null 2>&1; then
        exec script -q -c "bash '${APP_DIR}/migrate.sh'" /dev/null < /dev/tty > /dev/tty 2>&1
    fi
    exec bash -c "exec </dev/tty >/dev/tty 2>/dev/tty; exec bash '${APP_DIR}/migrate.sh'"
fi

echo "[!] Auto-launch unavailable. Run:"
echo "      sudo jojo-menu"
exit 0
