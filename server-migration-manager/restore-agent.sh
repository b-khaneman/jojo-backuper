#!/usr/bin/env bash
#===============================================================================
#
#   RESTORE AGENT — SERVER MIGRATION MANAGER v1.1
#   JOJO BACKUP
#
#   Runs on the NEW server.
#   Usage:
#     sudo ./restore-agent.sh --archive /backup/server-backup-TIMESTAMP.tar.zst [--yes] [--reboot=yes|no]
#
#===============================================================================

set -o pipefail

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODULES_DIR=""
if [[ -d "${AGENT_DIR}/modules" ]]; then
    MODULES_DIR="${AGENT_DIR}/modules"
    CONFIG_FILE="${AGENT_DIR}/config.conf"
elif [[ -d "${AGENT_DIR}/../modules" ]]; then
    MODULES_DIR="$(cd "${AGENT_DIR}/../modules" && pwd)"
    CONFIG_FILE="$(cd "${AGENT_DIR}/.." && pwd)/config.conf"
elif [[ -d "${AGENT_DIR}/smm/modules" ]]; then
    MODULES_DIR="${AGENT_DIR}/smm/modules"
    CONFIG_FILE="${AGENT_DIR}/smm/config.conf"
fi

ARCHIVE=""
AUTO_YES="no"
DO_REBOOT="yes"
LOG_DIR="/var/log/server-migration"

mkdir -p "$LOG_DIR"
exec > >(tee -a "${LOG_DIR}/restore.log") 2>&1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive|-a) ARCHIVE="$2"; shift 2 ;;
        --archive=*) ARCHIVE="${1#*=}"; shift ;;
        --yes|-y) AUTO_YES="yes"; shift ;;
        --reboot=*) DO_REBOOT="${1#*=}"; shift ;;
        --reboot) DO_REBOOT="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 --archive FILE [--yes] [--reboot=yes|no]"
            exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

[[ -f "${CONFIG_FILE:-}" ]] && source "$CONFIG_FILE"

SCRIPT_DIR="$(dirname "$MODULES_DIR")"
PROJECT_LOG_DIR="${PROJECT_LOG_DIR:-$LOG_DIR}"
BACKUP_DIR="${BACKUP_DIR:-/backup}"

if [[ -z "$MODULES_DIR" || ! -d "$MODULES_DIR" ]]; then
    echo "[ERROR] Modules not found next to restore-agent.sh"
    exit 1
fi

source "${MODULES_DIR}/common.sh"
source "${MODULES_DIR}/preflight.sh"
source "${MODULES_DIR}/network.sh"
source "${MODULES_DIR}/firewall.sh"
source "${MODULES_DIR}/database.sh"
source "${MODULES_DIR}/docker.sh"
source "${MODULES_DIR}/pasarguard.sh"
source "${MODULES_DIR}/ssl.sh"
source "${MODULES_DIR}/tunnels.sh"
source "${MODULES_DIR}/services.sh"
source "${MODULES_DIR}/security.sh"
source "${MODULES_DIR}/web.sh"
source "${MODULES_DIR}/mail.sh"
source "${MODULES_DIR}/packages.sh"
source "${MODULES_DIR}/notify.sh"
source "${MODULES_DIR}/encrypt.sh"
source "${MODULES_DIR}/postcheck.sh"
source "${MODULES_DIR}/backup.sh"
source "${MODULES_DIR}/restore.sh"

if [[ -z "$ARCHIVE" ]]; then
    for candidate in /backup /root /var/backups "$AGENT_DIR" /opt/jojo-backup; do
        ARCHIVE="$(ls -1t "${candidate}"/server-backup-* 2>/dev/null | grep -E '\.tar\.zst(\.gpg|\.enc)?$' | head -1)"
        [[ -n "$ARCHIVE" ]] && break
    done
fi

[[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] || die "No backup archive. Use --archive /path/to/server-backup-*.tar.zst"

print_banner
msg_info "RESTORE AGENT starting on $(hostname)"
msg_info "Archive : $ARCHIVE"
msg_info "Reboot  : $DO_REBOOT"
echo

require_root
setup_signal_traps

if [[ "$AUTO_YES" != "yes" ]]; then
    echo -e "${C_RED}${C_BOLD}WARNING: This will overwrite the current server.${C_RESET}"
    confirm_action "This will overwrite the current server. Continue?" || exit 1
fi

if [[ -f "${ARCHIVE}.sha256" ]]; then
    verify_checksum "$ARCHIVE" || die "Checksum failed — refusing to restore"
else
    msg_warn "No .sha256 sidecar — generating one"
    create_checksum "$ARCHIVE"
fi

restore_from_archive "$ARCHIVE" "yes" "$DO_REBOOT"
exit $?
