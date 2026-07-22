#!/usr/bin/env bash
#===============================================================================
#
#   JOJO BACKUPER v1.1
#   by @B_KHANEMAN
#   Server Migration Manager — Enterprise VPS Cloning & Migration
#
#===============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# shellcheck source=config.conf
source "${SCRIPT_DIR}/config.conf"

mkdir -p "$BACKUP_DIR" "$PROJECT_LOG_DIR" "${SCRIPT_DIR}/logs" "${SCRIPT_DIR}/backups"
mkdir -p /var/log/server-migration 2>/dev/null || true

source "${SCRIPT_DIR}/modules/common.sh"
source "${SCRIPT_DIR}/modules/preflight.sh"
source "${SCRIPT_DIR}/modules/network.sh"
source "${SCRIPT_DIR}/modules/firewall.sh"
source "${SCRIPT_DIR}/modules/database.sh"
source "${SCRIPT_DIR}/modules/docker.sh"
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
source "${SCRIPT_DIR}/modules/backup.sh"
source "${SCRIPT_DIR}/modules/restore.sh"

load_remote_state 2>/dev/null || true

usage() {
    cat <<EOF
Usage: sudo $0 [command]

Quick migration:
  deploy              Ask new server details + upload ALL backups + install toolkit
  sudo-restore        Restore on new server using sudo

Other:
  backup | connect | upload | restore | verify | info | cleanup
  preflight | estimate | wizard | postcheck | report | schedule | notify-test

EOF
}

run_command() {
    case "${1:-}" in
        deploy|setup-new)   deploy_to_new_server ;;
        sudo-restore|restore-sudo) sudo_restore_on_new_server ;;
        backup)      create_full_backup ;;
        connect)     connect_new_server ;;
        upload)      upload_backup "${2:-}" ;;
        restore)     sudo_restore_on_new_server ;;
        verify)      verify_backup "${2:-}" ;;
        info)        show_backup_info ;;
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

main_menu() {
    require_root
    setup_signal_traps
    check_dependencies

    while true; do
        print_menu
        read -r -p "Select option [1-16]: " choice
        echo
        case "$choice" in
            1)  deploy_to_new_server; pause_enter ;;
            2)  sudo_restore_on_new_server; pause_enter ;;
            3)  create_full_backup; pause_enter ;;
            4)  connect_new_server; pause_enter ;;
            5)  upload_backup; pause_enter ;;
            6)  verify_backup; pause_enter ;;
            7)  show_backup_info; pause_enter ;;
            8)  cleanup_backups; pause_enter ;;
            9)  preflight_check; pause_enter ;;
            10) estimate_backup_size; pause_enter ;;
            11) run_full_migration_wizard; pause_enter ;;
            12)
                if [[ -n "${REMOTE_HOST:-}" ]]; then postcheck_remote; else postcheck_local; fi
                pause_enter
                ;;
            13) generate_migration_report; pause_enter ;;
            14)
                echo "  a) systemd timer (recommended)"
                echo "  b) cron"
                read -r -p "Choice [a]: " sch
                if [[ "${sch:-a}" == "b" ]]; then schedule_backup_cron; else install_systemd_timer; fi
                pause_enter
                ;;
            15) test_notifications; pause_enter ;;
            16)
                echo
                msg_ok "Goodbye."
                exit 0
                ;;
            *)
                msg_warn "Invalid option: $choice"
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
