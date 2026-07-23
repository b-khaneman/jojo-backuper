#!/usr/bin/env bash
#===============================================================================
# JOJO BACKUPER — One-command bootstrap
# by @B_KHANEMAN
#
#   curl -fsSL https://raw.githubusercontent.com/b-khaneman/jojo-backuper/main/bootstrap.sh | sudo bash
#===============================================================================

set -uo pipefail
# Note: do NOT use set -e around launch — we always want a clear fallback message

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
apt-get install -y git curl ca-certificates >/dev/null || apt-get install -y git curl ca-certificates

if [[ -d "${INSTALL_DIR}/.git" ]]; then
    echo "[+] Existing install found — updating ${INSTALL_DIR} ..."
    git -C "$INSTALL_DIR" remote set-url origin "$REPO_URL" 2>/dev/null || true
    git -C "$INSTALL_DIR" fetch --all --prune || true
    git -C "$INSTALL_DIR" checkout "$BRANCH" 2>/dev/null || true
    git -C "$INSTALL_DIR" pull --ff-only origin "$BRANCH" 2>/dev/null || \
        git -C "$INSTALL_DIR" reset --hard "origin/${BRANCH}" || true
else
    echo "[+] Cloning into ${INSTALL_DIR} ..."
    rm -rf "$INSTALL_DIR"
    git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$INSTALL_DIR"
fi

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

# Clean symlinks
rm -f /usr/local/bin/smm /usr/local/bin/jojo /usr/local/bin/jojo-backuper
ln -sfn "${APP_DIR}/migrate.sh" /usr/local/bin/smm
ln -sfn "${APP_DIR}/migrate.sh" /usr/local/bin/jojo
ln -sfn "${APP_DIR}/migrate.sh" /usr/local/bin/jojo-backuper

# Tiny launcher that always uses absolute path (never relies on symlink resolution alone)
cat > /usr/local/bin/jojo-menu <<EOF
#!/usr/bin/env bash
exec bash "${APP_DIR}/migrate.sh" "\$@"
EOF
chmod +x /usr/local/bin/jojo-menu

echo
echo "[OK] JOJO BACKUPER installed at ${INSTALL_DIR}"
echo "     Start anytime with:"
echo "       sudo jojo-menu"
echo "       sudo bash ${APP_DIR}/migrate.sh"
echo

if [[ "${SKIP_RUN}" == "yes" || "${JOJO_SKIP_RUN:-}" == "yes" ]]; then
    echo "[*] Skip run enabled."
    exit 0
fi

echo "[+] Launching JOJO BACKUPER menu now..."
echo "-----------------------------------------"

launch_menu() {
    local migrate="${APP_DIR}/migrate.sh"
    [[ -f "$migrate" ]] || { echo "[ERROR] missing $migrate"; return 1; }

    # Full attach to controlling terminal (required after curl|bash)
    if [[ -r /dev/tty && -w /dev/tty ]]; then
        # Preferred: script(1) allocates a real tty reliably
        if command -v script >/dev/null 2>&1; then
            exec script -q -c "bash '$migrate'" /dev/null < /dev/tty > /dev/tty 2>&1
        fi
        # Fallback: reopen stdio on /dev/tty then exec
        exec bash -c "exec </dev/tty >/dev/tty 2>/dev/tty; exec bash '$migrate'"
    fi

    # Last resort (no tty)
    echo "[!] No interactive TTY detected."
    echo "    Run manually:"
    echo "      sudo bash ${migrate}"
    return 1
}

if ! launch_menu; then
    echo
    echo "[!] Auto-launch did not start the menu."
    echo "    Run this now:"
    echo "      sudo bash ${APP_DIR}/migrate.sh"
    echo "    or:"
    echo "      sudo jojo-menu"
    exit 0
fi
