#!/usr/bin/env bash
#===============================================================================
#
#   JOJO BACKUPER v1.3.8
#   by @B_KHANEMAN
#   Server Migration Manager — Enterprise VPS Cloning & Migration
#
#===============================================================================

set -o pipefail

# Resolve real script directory even when launched via /usr/local/bin/jojo symlink
_SMM_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$_SMM_SOURCE" ]]; do
    _SMM_DIR="$(cd -P "$(dirname "$_SMM_SOURCE")" && pwd)"
    _SMM_SOURCE="$(readlink "$_SMM_SOURCE")"
    [[ "$_SMM_SOURCE" != /* ]] && _SMM_SOURCE="${_SMM_DIR}/${_SMM_SOURCE}"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_SMM_SOURCE")" && pwd)"
unset _SMM_SOURCE _SMM_DIR
cd "$SCRIPT_DIR"

if [[ ! -f "${SCRIPT_DIR}/config.conf" || ! -d "${SCRIPT_DIR}/modules" ]]; then
    echo "[ERROR] JOJO BACKUPER files not found next to migrate.sh"
    echo "        Expected: ${SCRIPT_DIR}/config.conf and ${SCRIPT_DIR}/modules/"
    echo "        Fix with:"
    echo "          curl -fsSL https://raw.githubusercontent.com/b-khaneman/jojo-backuper/main/bootstrap.sh | sudo bash"
    exit 1
fi

# shellcheck source=config.conf
source "${SCRIPT_DIR}/config.conf"
# Prefer VERSION file after GitHub updates (config.conf may be preserved locally)
if [[ -f "${SCRIPT_DIR}/VERSION" ]]; then
    SMM_VERSION="$(tr -d '[:space:]' < "${SCRIPT_DIR}/VERSION")"
fi

mkdir -p "$BACKUP_DIR" "$PROJECT_LOG_DIR" "${SCRIPT_DIR}/logs" "${SCRIPT_DIR}/backups"
mkdir -p /var/log/server-migration 2>/dev/null || true

source "${SCRIPT_DIR}/modules/common.sh"
source "${SCRIPT_DIR}/modules/preflight.sh"
source "${SCRIPT_DIR}/modules/network.sh"
source "${SCRIPT_DIR}/modules/firewall.sh"
source "${SCRIPT_DIR}/modules/database.sh"
source "${SCRIPT_DIR}/modules/docker.sh"
source "${SCRIPT_DIR}/modules/pasarguard.sh"
source "${SCRIPT_DIR}/modules/ssl.sh"
source "${SCRIPT_DIR}/modules/tunnels.sh"
source "${SCRIPT_DIR}/modules/services.sh"
source "${SCRIPT_DIR}/modules/security.sh"
source "${SCRIPT_DIR}/modules/web.sh"
source "${SCRIPT_DIR}/modules/mail.sh"
source "${SCRIPT_DIR}/modules/packages.sh"
source "${SCRIPT_DIR}/modules/notify.sh"
source "${SCRIPT_DIR}/modules/encrypt.sh"
source "${SCRIPT_DIR}/modules/postcheck.sh"
source "${SCRIPT_DIR}/modules/update.sh"
source "${SCRIPT_DIR}/modules/backup.sh"
source "${SCRIPT_DIR}/modules/restore.sh"

load_remote_state 2>/dev/null || true

usage() {
    cat <<EOF
Usage: sudo $0 [command]

Quick:
  deploy              Deploy to new server
  sudo-restore        Restore backup
  pasarguard|pg-panel Migrate PasarGuard panel
  backup              Create full backup
  update              Update from GitHub

Transfer:
  connect             Connect to new server
  upload              Upload backup

Backups:
  verify              Verify backup
  info                Show backups
  delete              Delete backup

Checks:
  preflight           Pre-flight check
  postcheck           Health check

Advanced:
  estimate            Estimate backup size
  wizard              Full migration wizard
  report              Migration report
  schedule            Schedule weekly backup
  notify-test         Test notifications
  cleanup             Delete backup (same as delete)

Install + run:
  curl -fsSL https://raw.githubusercontent.com/b-khaneman/jojo-backuper/main/bootstrap.sh | sudo bash

EOF
}

run_command() {
    case "${1:-}" in
        deploy|setup-new)   deploy_to_new_server ;;
        sudo-restore|restore-sudo) sudo_restore_on_new_server ;;
        pasarguard|pg-panel|migrate-pasarguard|pasar)
            migrate_pasarguard_panel ;;
        update|upgrade|self-update) update_from_github ;;
        backup)      create_full_backup ;;
        connect)     connect_new_server ;;
        upload)      upload_backup "${2:-}" ;;
        restore)     sudo_restore_on_new_server ;;
        verify)      verify_backup "${2:-}" ;;
        info)        show_backup_info ;;
        delete|delete-backup|rm-backup) delete_backups ;;
        cleanup)     cleanup_backups ;;
        preflight)   preflight_check ;;
        estimate)    estimate_backup_size ;;
        wizard)      run_full_migration_wizard ;;
        postcheck)
            if [[ -n "${REMOTE_HOST:-}" ]]; then postcheck_remote; else postcheck_local; fi
            ;;
        report)      generate_migration_report ;;
        schedule)    install_systemd_timer ;;
        notify-test) test_notifications ;;
        help|-h|--help) usage ;;
        "") return 1 ;;
        *) msg_error "Unknown command: $1"; usage; exit 1 ;;
    esac
}

# Ensure interactive TTY (fixes empty menu input after curl|bash install)
ensure_tty() {
    if [[ ! -t 0 ]] && [[ -r /dev/tty ]]; then
        exec </dev/tty
    fi
    if [[ ! -t 1 ]] && [[ -w /dev/tty ]]; then
        exec >/dev/tty
    fi
    if [[ ! -t 2 ]] && [[ -w /dev/tty ]]; then
        exec 2>/dev/tty
    fi
}

advanced_menu() {
    while true; do
        print_advanced_menu
        if [[ -r /dev/tty ]]; then
            read -r -p "Advanced [0-5]: " adv < /dev/tty || adv=""
        else
            read -r -p "Advanced [0-5]: " adv || adv=""
        fi
        adv="$(echo "$adv" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        echo
        case "$adv" in
            1) estimate_backup_size; pause_enter ;;
            2) run_full_migration_wizard; pause_enter ;;
            3) generate_migration_report; pause_enter ;;
            4)
                echo "  a) systemd timer (recommended)"
                echo "  b) cron"
                if [[ -r /dev/tty ]]; then
                    read -r -p "Choice [a]: " sch < /dev/tty
                else
                    read -r -p "Choice [a]: " sch
                fi
                if [[ "${sch:-a}" == "b" ]]; then schedule_backup_cron; else install_systemd_timer; fi
                pause_enter
                ;;
            5) test_notifications; pause_enter ;;
            0|"") return 0 ;;
            *)
                msg_warn "Invalid option: '$adv' — enter 0 to 5"
                sleep 1
                ;;
        esac
    done
}

main_menu() {
    require_root
    ensure_tty
    setup_signal_traps
    check_dependencies

    while true; do
        print_menu
        # Always read from the controlling terminal
        if [[ -r /dev/tty ]]; then
            read -r -p "Select option [1-14]: " choice < /dev/tty || choice=""
        else
            read -r -p "Select option [1-14]: " choice || choice=""
        fi
        # Trim whitespace / CR
        choice="$(echo "$choice" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        echo
        if [[ -z "$choice" ]]; then
            msg_warn "No input received — type a number (1-14) and press Enter"
            sleep 1
            continue
        fi
        case "$choice" in
            1)  deploy_to_new_server; pause_enter ;;
            2)  sudo_restore_on_new_server; pause_enter ;;
            3)  migrate_pasarguard_panel; pause_enter ;;
            4)  create_full_backup; pause_enter ;;
            5)  connect_new_server; pause_enter ;;
            6)  upload_backup; pause_enter ;;
            7)  verify_backup; pause_enter ;;
            8)  show_backup_info; pause_enter ;;
            9)  delete_backups; pause_enter ;;
            10) preflight_check; pause_enter ;;
            11)
                if [[ -n "${REMOTE_HOST:-}" ]]; then postcheck_remote; else postcheck_local; fi
                pause_enter
                ;;
            12) update_from_github ;;
            13)
                echo
                msg_ok "Goodbye."
                exit 0
                ;;
            14) advanced_menu ;;
            *)
                msg_warn "Invalid option: '$choice' — enter 1 to 14"
                sleep 1
                ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ $# -gt 0 ]]; then
        require_root
        setup_signal_traps
        run_command "$@"
        exit $?
    fi
    main_menu
fi
