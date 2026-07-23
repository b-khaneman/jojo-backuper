#!/usr/bin/env bash
#===============================================================================
# JOJO BACKUPER — One-command bootstrap
# by @B_KHANEMAN
#
# Install + launch in one shot:
#   curl -fsSL https://raw.githubusercontent.com/b-khaneman/jojo-backuper/main/bootstrap.sh | sudo bash
#
# Or:
#   wget -qO- https://raw.githubusercontent.com/b-khaneman/jojo-backuper/main/bootstrap.sh | sudo bash
#===============================================================================

set -euo pipefail

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

echo "========================================="
echo "  JOJO BACKUPER — Quick Install"
echo "  by @B_KHANEMAN"
echo "========================================="
echo

echo "[+] Installing base packages (git curl)..."
apt-get update -qq
apt-get install -y git curl ca-certificates >/dev/null

if [[ -d "${INSTALL_DIR}/.git" ]]; then
    echo "[+] Existing install found — updating ${INSTALL_DIR} ..."
    git -C "$INSTALL_DIR" fetch --all --prune
    git -C "$INSTALL_DIR" checkout "$BRANCH"
    git -C "$INSTALL_DIR" pull --ff-only origin "$BRANCH" || {
        echo "[!] Fast-forward failed — resetting to origin/${BRANCH}"
        git -C "$INSTALL_DIR" reset --hard "origin/${BRANCH}"
    }
else
    echo "[+] Cloning into ${INSTALL_DIR} ..."
    rm -rf "$INSTALL_DIR"
    git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$INSTALL_DIR"
fi

APP_DIR="${INSTALL_DIR}/server-migration-manager"
if [[ ! -d "$APP_DIR" ]]; then
    echo "[ERROR] server-migration-manager not found in repo"
    exit 1
fi

chmod +x "$APP_DIR"/install.sh "$APP_DIR"/migrate.sh "$APP_DIR"/restore-agent.sh 2>/dev/null || true
find "$APP_DIR/modules" -type f -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true

echo "[+] Running installer..."
bash "${APP_DIR}/install.sh"

# Convenience symlinks (remove any broken copies first)
rm -f /usr/local/bin/smm /usr/local/bin/jojo /usr/local/bin/jojo-backuper
ln -sfn "${APP_DIR}/migrate.sh" /usr/local/bin/smm
ln -sfn "${APP_DIR}/migrate.sh" /usr/local/bin/jojo
ln -sfn "${APP_DIR}/migrate.sh" /usr/local/bin/jojo-backuper

echo
echo "[OK] JOJO BACKUPER installed at ${INSTALL_DIR}"
echo "     Commands: sudo jojo   |   sudo smm   |   sudo jojo-backuper"
echo

if [[ "${SKIP_RUN}" == "yes" || "${JOJO_SKIP_RUN:-}" == "yes" ]]; then
    echo "[*] Skip run enabled — not launching menu."
    echo "    Start later with: sudo jojo"
    exit 0
fi

echo "[+] Launching JOJO BACKUPER..."
# Critical: when installed via `curl | sudo bash`, stdin is the pipe (EOF).
# Reattach to the real terminal so the menu can accept keyboard input.
if [[ ! -t 0 ]] && [[ -r /dev/tty ]]; then
    exec </dev/tty
fi
exec bash "${APP_DIR}/migrate.sh"
