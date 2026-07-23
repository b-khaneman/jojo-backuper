#!/usr/bin/env bash
#===============================================================================
# MODULE: Restore Engine (local + remote orchestration)
# JOJO BACKUPER v1.1.1 | @B_KHANEMAN
#===============================================================================

#-------------------------------------------------------------------------------
# Connect to new server (interactive)
#-------------------------------------------------------------------------------
# Read a line from the controlling terminal (safe after curl|bash)
tty_read() {
    local prompt="$1"
    local __var="$2"
    local __val=""
    if [[ -r /dev/tty ]]; then
        read -r -p "$prompt" __val < /dev/tty || true
    else
        read -r -p "$prompt" __val || true
    fi
    __val="$(printf '%s' "$__val" | tr -d '\r')"
    printf -v "$__var" '%s' "$__val"
}

tty_read_silent() {
    local prompt="$1"
    local __var="$2"
    local __val=""
    if [[ -r /dev/tty ]]; then
        read -r -s -p "$prompt" __val < /dev/tty || true
        echo > /dev/tty
    else
        read -r -s -p "$prompt" __val || true
        echo
    fi
    __val="$(printf '%s' "$__val" | tr -d '\r')"
    printf -v "$__var" '%s' "$__val"
}

connect_new_server() {
    set_log_file "${PROJECT_LOG_DIR}/transfer.log"
    echo
    msg_info "Configure connection to the NEW server"
    echo

    local input_host="" input_port="" input_user="" auth_choice="" input_key="" input_rpath=""
    tty_read "New server IP / hostname: " input_host
    [[ -z "$input_host" ]] && { msg_error "Host is required"; return 1; }
    REMOTE_HOST="$input_host"

    tty_read "SSH Port [${REMOTE_PORT:-${SSH_PORT:-22}}]: " input_port
    REMOTE_PORT="${input_port:-${REMOTE_PORT:-${SSH_PORT:-22}}}"
    SSH_PORT="$REMOTE_PORT"

    tty_read "Username [${REMOTE_USER:-root}]: " input_user
    REMOTE_USER="${input_user:-${REMOTE_USER:-root}}"

    echo
    echo "Authentication method:"
    echo "  1) Private key"
    echo "  2) Password"
    tty_read "Choice [1]: " auth_choice
    auth_choice="${auth_choice:-1}"

    if [[ "$auth_choice" == "2" ]]; then
        AUTH_METHOD="password"
        tty_read_silent "Password: " SSH_PASSWORD
        SSH_KEY=""
        if ! check_command sshpass; then
            msg_info "Installing sshpass..."
            apt-get install -y sshpass 2>/dev/null || die "sshpass required for password auth"
        fi
    else
        AUTH_METHOD="key"
        SSH_PASSWORD=""
        local default_key="${HOME}/.ssh/id_rsa"
        [[ -f "${HOME}/.ssh/id_ed25519" ]] && default_key="${HOME}/.ssh/id_ed25519"
        tty_read "Private key path [${default_key}]: " input_key
        SSH_KEY="${input_key:-$default_key}"
        if [[ ! -f "$SSH_KEY" ]]; then
            msg_warn "Key file not found: $SSH_KEY"
            msg_dim "Will try default SSH agent / config"
        fi
    fi

    tty_read "Remote backup path [${REMOTE_PATH:-/backup}]: " input_rpath
    REMOTE_PATH="${input_rpath:-${REMOTE_PATH:-/backup}}"

    # Persist to a runtime state file (not overwriting secrets into config.conf by default)
    local state_file="${PROJECT_LOG_DIR}/.remote_state"
    {
        echo "REMOTE_HOST=\"$REMOTE_HOST\""
        echo "REMOTE_PORT=\"$REMOTE_PORT\""
        echo "REMOTE_USER=\"$REMOTE_USER\""
        echo "REMOTE_PATH=\"$REMOTE_PATH\""
        echo "AUTH_METHOD=\"$AUTH_METHOD\""
        echo "SSH_KEY=\"$SSH_KEY\""
        # Password stored only in-memory for session; optionally temp file with 600
    } > "$state_file"
    chmod 600 "$state_file"

    if [[ "$AUTH_METHOD" == "password" ]]; then
        umask 077
        # printf avoids echo flag issues with passwords
        printf '%s' "$SSH_PASSWORD" > "${PROJECT_LOG_DIR}/.ssh_password"
        chmod 600 "${PROJECT_LOG_DIR}/.ssh_password"
        if [[ -z "$SSH_PASSWORD" ]]; then
            msg_error "Password was empty — try again"
            return 1
        fi
    fi

    echo
    loading_anim "Testing connection" 1
    if test_ssh_connection; then
        # Probe remote OS
        local remote_info
        remote_info="$(ssh_cmd "grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\\\"'; || echo unknown")"
        msg_info "Remote OS: $remote_info"
        ssh_cmd "mkdir -p '$REMOTE_PATH'" 2>/dev/null || \
            remote_sudo "mkdir -p '$REMOTE_PATH'" 2>/dev/null || true
        # Save connection into config for convenience (without password)
        _persist_remote_config
        msg_ok "Connected and ready"
        return 0
    fi
    return 1
}

_persist_remote_config() {
    local conf="${SCRIPT_DIR}/config.conf"
    [[ -f "$conf" ]] || return 0
    # Update non-secret remote fields in config using sed
    sed -i.bak \
        -e "s|^REMOTE_HOST=.*|REMOTE_HOST=\"${REMOTE_HOST}\"|" \
        -e "s|^REMOTE_USER=.*|REMOTE_USER=\"${REMOTE_USER}\"|" \
        -e "s|^REMOTE_PORT=.*|REMOTE_PORT=\"${REMOTE_PORT}\"|" \
        -e "s|^REMOTE_PATH=.*|REMOTE_PATH=\"${REMOTE_PATH}\"|" \
        -e "s|^SSH_PORT=.*|SSH_PORT=\"${REMOTE_PORT}\"|" \
        -e "s|^AUTH_METHOD=.*|AUTH_METHOD=\"${AUTH_METHOD}\"|" \
        -e "s|^SSH_KEY=.*|SSH_KEY=\"${SSH_KEY}\"|" \
        "$conf" 2>/dev/null || true
    rm -f "${conf}.bak" 2>/dev/null || true
}

load_remote_state() {
    local state_file="${PROJECT_LOG_DIR}/.remote_state"
    if [[ -f "$state_file" ]]; then
        # shellcheck source=/dev/null
        source "$state_file"
    fi
    if [[ -f "${PROJECT_LOG_DIR}/.ssh_password" ]]; then
        SSH_PASSWORD="$(cat "${PROJECT_LOG_DIR}/.ssh_password")"
        AUTH_METHOD="password"
    fi
}

#-------------------------------------------------------------------------------
# Remote sudo helpers — always elevate so restore/install never fail on perms
#-------------------------------------------------------------------------------
remote_sudo() {
    local remote_cmd="$1"
    if [[ "${REMOTE_USER:-root}" == "root" ]]; then
        ssh_cmd "$remote_cmd"
        return $?
    fi
    if [[ "${AUTH_METHOD:-key}" == "password" && -n "${SSH_PASSWORD:-}" ]]; then
        # Password only for sudo -S; command itself must NOT share that pipe as stdin
        ssh_cmd "printf '%s\n' $(printf '%q' "$SSH_PASSWORD") | sudo -S -p '' -- bash -c $(printf '%q' "$remote_cmd")"
        return $?
    fi
    if ssh_cmd "sudo -n true" 2>/dev/null; then
        ssh_cmd "sudo -n -- bash -c $(printf '%q' "$remote_cmd")"
    else
        ssh_cmd "sudo -- bash -c $(printf '%q' "$remote_cmd")"
    fi
}

remote_sudo_script() {
    # Upload a temp script and run it as root — avoids stdin/password pipe conflicts
    local script="$1"
    local stamp="$$-$(date +%s)"
    local local_tmp="/tmp/smm-remote-${stamp}.sh"
    local remote_tmp="/tmp/smm-remote-${stamp}.sh"

    printf '%s\n' "$script" > "$local_tmp"
    chmod 700 "$local_tmp"

    ssh_cmd "mkdir -p /tmp" || { rm -f "$local_tmp"; return 1; }

    local scp_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -P "${REMOTE_PORT:-22}")
    if [[ "${AUTH_METHOD:-key}" == "key" && -n "${SSH_KEY:-}" ]]; then
        scp_opts+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
    fi

    if [[ "${AUTH_METHOD:-key}" == "password" && -n "${SSH_PASSWORD:-}" ]]; then
        if ! SSHPASS="$SSH_PASSWORD" sshpass -e scp "${scp_opts[@]}" "$local_tmp" \
            "${REMOTE_USER}@${REMOTE_HOST}:${remote_tmp}"; then
            rm -f "$local_tmp"
            msg_error "Failed to upload remote helper script"
            return 1
        fi
    else
        if ! scp "${scp_opts[@]}" "$local_tmp" \
            "${REMOTE_USER}@${REMOTE_HOST}:${remote_tmp}"; then
            rm -f "$local_tmp"
            msg_error "Failed to upload remote helper script"
            return 1
        fi
    fi
    rm -f "$local_tmp"

    if ! remote_sudo "chmod 700 '$remote_tmp' && bash '$remote_tmp'; ec=\$?; rm -f '$remote_tmp'; exit \$ec"; then
        ssh_cmd "rm -f '$remote_tmp'" 2>/dev/null || true
        return 1
    fi
    return 0
}

_build_ssh_rsh() {
    local opts
    mapfile -t opts < <(build_ssh_opts)
    if [[ "${AUTH_METHOD:-key}" == "password" && -n "${SSH_PASSWORD:-}" ]]; then
        export SSHPASS="$SSH_PASSWORD"
        # shellcheck disable=SC2089
        SSH_RSH="sshpass -e -P assword ssh ${opts[*]}"
    else
        SSH_RSH="ssh ${opts[*]}"
    fi
}

#-------------------------------------------------------------------------------
# QUICK: Ask new server details → upload ALL backups + install JOJO toolkit
#-------------------------------------------------------------------------------
deploy_to_new_server() {
    set_log_file "${PROJECT_LOG_DIR}/transfer.log"
    require_root

    echo
    echo -e "${C_CYAN}${C_BOLD}════════════════════════════════════════${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}  DEPLOY TO NEW SERVER (Quick Setup)   ${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}════════════════════════════════════════${C_RESET}"
    echo
    msg_info "This will:"
    msg_dim "  1) Ask for new server connection details"
    msg_dim "  2) Upload all local backups + JOJO BACKUPER scripts"
    msg_dim "  3) Install dependencies on the new server (sudo)"
    msg_dim "  4) NOT restore yet — use option 2 after this"
    echo

    local backups=()
    mapfile -t backups < <(ls -1t "${BACKUP_DIR}"/server-backup-*.tar.zst \
        "${BACKUP_DIR}"/server-backup-*.tar.zst.gpg \
        "${BACKUP_DIR}"/server-backup-*.tar.zst.enc 2>/dev/null | awk 'NF')
    # de-dup and prefer newest by mtime — ls -1t already across globs is unsorted between globs
    mapfile -t backups < <(ls -1t "${BACKUP_DIR}"/server-backup-* 2>/dev/null | grep -E '\.tar\.zst(\.gpg|\.enc)?$' || true)
    if (( ${#backups[@]} == 0 )); then
        msg_error "No backup found in ${BACKUP_DIR}"
        msg_info "Create a backup first (menu option 3)"
        return 1
    fi

    msg_ok "Found ${#backups[@]} backup(s). Latest: $(basename "${backups[0]}")"
    echo

    connect_new_server || return 1

    msg_step "Preparing remote directories..."
    remote_sudo "mkdir -p '${REMOTE_PATH}' /var/log/server-migration /opt/jojo-backup && chmod 755 '${REMOTE_PATH}'" \
        || die "Cannot create remote directories (need root/sudo on new server)"

    _build_ssh_rsh
    local ssh_rsh="$SSH_RSH"

    local rsync_extra=(--partial --progress --inplace --compress --human-readable --timeout=120)
    if [[ "${BANDWIDTH_LIMIT_KB:-0}" =~ ^[1-9][0-9]*$ ]]; then
        rsync_extra+=(--bwlimit="${BANDWIDTH_LIMIT_KB}")
        msg_info "Bandwidth limit: ${BANDWIDTH_LIMIT_KB} KB/s"
    fi
    msg_step "Uploading all backups to ${REMOTE_HOST}:${REMOTE_PATH}/ ..."
    local files_to_send=()
    local f
    for f in "${backups[@]}"; do
        files_to_send+=("$f")
        [[ -f "${f}.sha256" ]] && files_to_send+=("${f}.sha256")
        [[ -f "${f}.manifest" ]] && files_to_send+=("${f}.manifest")
        [[ -f "${f}.parts.list" ]] && files_to_send+=("${f}.parts.list")
        local part
        for part in "${f}.part."*; do
            [[ -f "$part" ]] && files_to_send+=("$part")
        done
    done

    if ! rsync -avz "${rsync_extra[@]}" -e "$ssh_rsh" \
        "${files_to_send[@]}" \
        "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/"; then
        msg_error "Backup upload failed — re-run option 1 to resume"
        log_error "deploy: backup rsync failed"
        return 1
    fi
    msg_ok "Backups uploaded"

    msg_step "Uploading JOJO BACKUPER scripts (full toolkit)..."
    local toolkit_tar="/tmp/jojo-backup-toolkit-$$.tar.zst"
    tar -C "$SCRIPT_DIR" -cf - \
        migrate.sh restore-agent.sh install.sh config.conf VERSION README.md \
        modules \
        2>/dev/null | zstd -T0 -3 -o "$toolkit_tar"

    if ! rsync -avz "${rsync_extra[@]}" -e "$ssh_rsh" \
        "$toolkit_tar" \
        "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/jojo-backup-toolkit.tar.zst"; then
        msg_error "Toolkit upload failed"
        rm -f "$toolkit_tar"
        return 1
    fi
    rm -f "$toolkit_tar"

    msg_step "Installing toolkit on new server (sudo)..."
    local install_script
    install_script=$(cat <<EOF
set -e
mkdir -p /opt/jojo-backup
zstd -dc '${REMOTE_PATH}/jojo-backup-toolkit.tar.zst' | tar -xf - -C /opt/jojo-backup
chmod +x /opt/jojo-backup/migrate.sh /opt/jojo-backup/restore-agent.sh /opt/jojo-backup/install.sh
cp -a /opt/jojo-backup/restore-agent.sh '${REMOTE_PATH}/restore-agent.sh'
cp -a /opt/jojo-backup/migrate.sh '${REMOTE_PATH}/migrate.sh' || true
ln -sfn /opt/jojo-backup '${REMOTE_PATH}/smm'
cd /opt/jojo-backup
bash ./install.sh
ls -1t '${REMOTE_PATH}'/server-backup-* 2>/dev/null | grep -E '\.tar\.zst(\.gpg|\.enc)?$' | head -1 > /opt/jojo-backup/.latest_backup
echo DEPLOY_OK
EOF
)

    if ! remote_sudo_script "$install_script"; then
        msg_warn "Install script returned non-zero — verifying files on remote..."
    fi
    if ! remote_sudo "test -x /opt/jojo-backup/restore-agent.sh && test -f /opt/jojo-backup/.latest_backup"; then
        msg_error "Remote install failed (toolkit not found)"
        return 1
    fi
    msg_ok "Toolkit installed on new server"

    {
        echo "deployed_at=$(date -Iseconds)"
        echo "remote=${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}"
        echo "path=${REMOTE_PATH}"
        echo "toolkit=/opt/jojo-backup"
        echo "latest=$(basename "${backups[0]}")"
    } > "${PROJECT_LOG_DIR}/.last_deploy"

    echo
    msg_ok "Deploy completed successfully"
    msg_info "Backups on new server : ${REMOTE_PATH}/"
    msg_info "Toolkit installed at  : /opt/jojo-backup"
    msg_info "Next step             : menu option 2 → Restore Backup (sudo)"
    log_ok "Deploy to ${REMOTE_HOST} completed"
    declare -f notify_transfer_done &>/dev/null && notify_transfer_done "$(basename "${backups[0]}")" || true
    return 0
}

#-------------------------------------------------------------------------------
# QUICK: Restore on new server using sudo (safe permissions)
#-------------------------------------------------------------------------------
sudo_restore_on_new_server() {
    set_log_file "${PROJECT_LOG_DIR}/restore.log"
    require_root
    load_remote_state

    echo
    echo -e "${C_YELLOW}${C_BOLD}════════════════════════════════════════${C_RESET}"
    echo -e "${C_YELLOW}${C_BOLD}  RESTORE ON NEW SERVER (sudo)          ${C_RESET}"
    echo -e "${C_YELLOW}${C_BOLD}════════════════════════════════════════${C_RESET}"
    echo

    if [[ -z "${REMOTE_HOST:-}" ]]; then
        msg_warn "New server not configured yet"
        msg_info "Enter details now (or run option 1 Deploy first)"
        connect_new_server || return 1
    fi

    local archive_path
    archive_path="$(ssh_cmd "cat /opt/jojo-backup/.latest_backup 2>/dev/null || ls -1t '${REMOTE_PATH}'/server-backup-* 2>/dev/null | grep -E '\\.tar\\.zst(\\.gpg|\\.enc)?\$' | head -1" | tr -d '\r' | tail -1)"
    [[ -n "$archive_path" ]] || die "No backup on new server. Run option 1 (Deploy) first."

    local agent="/opt/jojo-backup/restore-agent.sh"
    if ! ssh_cmd "test -f '$agent'" 2>/dev/null; then
        agent="${REMOTE_PATH}/restore-agent.sh"
    fi
    ssh_cmd "test -f '$agent'" 2>/dev/null || die "restore-agent.sh missing — run option 1 (Deploy) first"

    echo -e "${C_RED}${C_BOLD}"
    echo "WARNING: This will OVERWRITE the new server using sudo."
    echo "  Target : ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}"
    echo "  Archive: ${archive_path}"
    echo "  Agent  : ${agent}"
    echo -e "${C_RESET}"

    if ! confirm_action "Overwrite new server and restore backup with sudo?"; then
        return 1
    fi

    declare -f create_restore_point_remote &>/dev/null && create_restore_point_remote

    local reboot_flag="${REBOOT_AFTER_RESTORE:-yes}"
    local rb=""
    if declare -f tty_read &>/dev/null; then
        tty_read "Reboot new server after restore? [Y/n]: " rb
    else
        read -r -p "Reboot new server after restore? [Y/n]: " rb < /dev/tty || true
    fi
    case "${rb:-Y}" in
        n|N|no|NO) reboot_flag="no" ;;
        *) reboot_flag="yes" ;;
    esac

    msg_step "Starting restore with sudo on ${REMOTE_HOST}..."
    log_info "sudo restore start host=$REMOTE_HOST archive=$archive_path"

    local restore_script
    restore_script=$(cat <<EOF
set -e
chmod +x '$agent'
bash '$agent' --archive '$archive_path' --yes --reboot=${reboot_flag}
EOF
)

    if remote_sudo_script "$restore_script"; then
        msg_ok "Remote sudo restore finished"
        log_ok "sudo restore OK on $REMOTE_HOST"
        declare -f notify_restore_done &>/dev/null && notify_restore_done || true
    else
        # Reboot may kill SSH mid-flight — treat as possible success if reboot=yes
        if [[ "$reboot_flag" == "yes" ]]; then
            msg_warn "SSH session ended (often normal during reboot) — waiting for host..."
        else
            msg_error "Remote restore failed — check /var/log/server-migration/restore.log on new server"
            log_error "sudo restore failed"
            declare -f notify_restore_fail &>/dev/null && notify_restore_fail "sudo restore failed" || true
            return 1
        fi
    fi

    if [[ "$reboot_flag" == "yes" ]]; then
        msg_step "Waiting for new server to come back..."
        sleep 20
        local i
        for i in $(seq 1 36); do
            if ssh_cmd "echo SMM_ALIVE" 2>/dev/null | grep -q SMM_ALIVE; then
                msg_ok "New server is online after reboot"
                verify_migration_remote 2>/dev/null || true
                declare -f postcheck_remote &>/dev/null && postcheck_remote || true
                return 0
            fi
            show_progress $(( i * 100 / 36 ))
            sleep 5
        done
        msg_warn "Server not reachable yet — check manually (may still be booting)"
    else
        verify_migration_remote 2>/dev/null || true
    fi
    return 0
}

#-------------------------------------------------------------------------------
# Upload backup via rsync
#-------------------------------------------------------------------------------
upload_backup() {
    set_log_file "${PROJECT_LOG_DIR}/transfer.log"
    require_root
    load_remote_state

    if [[ -z "${REMOTE_HOST:-}" ]]; then
        msg_warn "Remote server not configured. Running Connect first..."
        connect_new_server || return 1
    fi

    local archive="${1:-}"
    archive="$(ls -1t "${BACKUP_DIR}"/server-backup-*.tar.zst \
        "${BACKUP_DIR}"/server-backup-*.tar.zst.gpg \
        "${BACKUP_DIR}"/server-backup-*.tar.zst.enc 2>/dev/null | head -1)"
    if [[ -z "$archive" ]]; then
        archive="$(ls -1t "${BACKUP_DIR}"/server-backup-* 2>/dev/null | grep -E '\.tar\.zst(\.gpg|\.enc)?$' | head -1)"
    fi
    if [[ -z "$archive" || ! -f "$archive" ]]; then
        die "No backup found to upload. Create a backup first."
    fi

    msg_info "Uploading: $(basename "$archive")"
    msg_info "Target: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/"
    log_info "Upload start: $archive → ${REMOTE_HOST}:${REMOTE_PATH}"

    # Ensure remote path exists
    ssh_cmd "mkdir -p '$REMOTE_PATH' && mkdir -p /var/log/server-migration" || die "Cannot create remote path"

    # Build rsync SSH command
    local ssh_rsh
    local opts
    mapfile -t opts < <(build_ssh_opts)
    if [[ "${AUTH_METHOD:-key}" == "password" && -n "${SSH_PASSWORD:-}" ]]; then
        export SSHPASS="$SSH_PASSWORD"
        ssh_rsh="sshpass -e ssh ${opts[*]}"
    else
        ssh_rsh="ssh ${opts[*]}"
    fi

    loading_anim "Starting transfer (rsync resume-capable)" 1

    local rsync_extra=(--partial --progress --inplace --compress --human-readable --timeout=120)
    if [[ "${BANDWIDTH_LIMIT_KB:-0}" =~ ^[1-9][0-9]*$ ]]; then
        rsync_extra+=(--bwlimit="${BANDWIDTH_LIMIT_KB}")
        msg_info "Bandwidth limit: ${BANDWIDTH_LIMIT_KB} KB/s"
    fi
    # Also transfer checksum + manifest + restore-agent + split parts
    local files_to_send=("$archive")
    [[ -f "${archive}.sha256" ]] && files_to_send+=("${archive}.sha256")
    [[ -f "${archive}.manifest" ]] && files_to_send+=("${archive}.manifest")
    [[ -f "${archive}.parts.list" ]] && files_to_send+=("${archive}.parts.list")
    local part
    for part in "${archive}.part."*; do
        [[ -f "$part" ]] && files_to_send+=("$part")
    done

    local agent="${SCRIPT_DIR}/restore-agent.sh"
    [[ -f "$agent" ]] && files_to_send+=("$agent")

    # Copy modules for remote restore
    local modules_tarball="/tmp/smm-modules-$$.tar.zst"
    tar -C "$SCRIPT_DIR" -cf - modules config.conf migrate.sh restore-agent.sh install.sh 2>/dev/null \
        | zstd -T0 -3 -o "$modules_tarball" 2>/dev/null || true

    if ! rsync -avz "${rsync_extra[@]}" -e "$ssh_rsh" \
        "${files_to_send[@]}" \
        "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/"; then
        msg_error "rsync transfer failed or interrupted"
        msg_info "You can re-run Upload Backup to resume"
        log_error "rsync failed for $archive"
        rm -f "$modules_tarball"
        declare -f notify_send &>/dev/null && notify_send "Upload FAILED" "$(basename "$archive")" || true
        return 1
    fi

    if [[ -f "$modules_tarball" ]]; then
        rsync -avz -e "$ssh_rsh" "$modules_tarball" \
            "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/smm-bundle.tar.zst" || true
        ssh_cmd "cd '$REMOTE_PATH' && mkdir -p smm && zstd -dc smm-bundle.tar.zst | tar -xf - -C smm" || true
        rm -f "$modules_tarball"
    fi

    # Make restore-agent executable on remote
    ssh_cmd "chmod +x '${REMOTE_PATH}/restore-agent.sh' '${REMOTE_PATH}/smm/restore-agent.sh' 2>/dev/null; true"

    msg_ok "Upload completed successfully"
    log_ok "Upload completed: $(basename "$archive")"
    declare -f notify_transfer_done &>/dev/null && notify_transfer_done "$(basename "$archive")" || true
    return 0
}

#-------------------------------------------------------------------------------
# Trigger remote restore
#-------------------------------------------------------------------------------
restore_server_remote() {
    set_log_file "${PROJECT_LOG_DIR}/restore.log"
    require_root
    load_remote_state

    if [[ -z "${REMOTE_HOST:-}" ]]; then
        msg_warn "Remote not configured"
        connect_new_server || return 1
    fi

    local archive_name
    archive_name="$(ls -1t "${BACKUP_DIR}"/server-backup-* 2>/dev/null | grep -E '\.tar\.zst(\.gpg|\.enc)?$' | head -1 | xargs -r basename)"
    if [[ -z "$archive_name" ]]; then
        archive_name="$(ssh_cmd "ls -1t '${REMOTE_PATH}'/server-backup-* 2>/dev/null | grep -E '\\.tar\\.zst(\\.gpg|\\.enc)?\$' | head -1 | xargs -r basename")"
    fi
    [[ -z "$archive_name" ]] && die "No backup archive found locally or on remote"

    echo
    echo -e "${C_RED}${C_BOLD}╔══════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_RED}${C_BOLD}║  WARNING: DESTRUCTIVE OPERATION          ║${C_RESET}"
    echo -e "${C_RED}${C_BOLD}╠══════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_YELLOW}║  This will OVERWRITE the new server.     ║${C_RESET}"
    echo -e "${C_YELLOW}║  Target: ${REMOTE_USER}@${REMOTE_HOST}              ║${C_RESET}"
    echo -e "${C_YELLOW}║  Archive: ${archive_name}  ║${C_RESET}"
    echo -e "${C_RED}${C_BOLD}╚══════════════════════════════════════════╝${C_RESET}"
    echo

    if ! confirm_action "This will overwrite the current server (${REMOTE_HOST}). Continue?"; then
        return 1
    fi

    declare -f create_restore_point_remote &>/dev/null && create_restore_point_remote

    msg_step "Deploying and launching restore-agent on remote..."
    log_info "Remote restore start on $REMOTE_HOST archive=$archive_name"

    # Ensure agent + modules exist remotely
    local agent_path="/opt/jojo-backup/restore-agent.sh"
    if ssh_cmd "test -f '$agent_path' || test -f '${REMOTE_PATH}/smm/restore-agent.sh' || test -f '${REMOTE_PATH}/restore-agent.sh'"; then
        :
    else
        msg_info "Restore agent missing on remote — uploading first..."
        upload_backup || return 1
    fi

    agent_path="/opt/jojo-backup/restore-agent.sh"
    if ! ssh_cmd "test -f '$agent_path'" 2>/dev/null; then
        agent_path="${REMOTE_PATH}/smm/restore-agent.sh"
    fi
    if ! ssh_cmd "test -f '$agent_path'" 2>/dev/null; then
        agent_path="${REMOTE_PATH}/restore-agent.sh"
    fi

    msg_info "Running restore-agent with sudo (this may take a long time)..."
    local restore_script
    restore_script=$(cat <<EOF
set -e
chmod +x '$agent_path'
bash '$agent_path' --archive '${REMOTE_PATH}/${archive_name}' --yes --reboot=${REBOOT_AFTER_RESTORE:-yes}
EOF
)
    if remote_sudo_script "$restore_script"; then
        msg_ok "Remote restore finished"
        log_ok "Remote restore completed on $REMOTE_HOST"
        declare -f notify_restore_done &>/dev/null && notify_restore_done || true
    else
        if [[ "${REBOOT_AFTER_RESTORE:-yes}" == "yes" ]]; then
            msg_warn "SSH ended during restore/reboot — waiting for host..."
        else
            msg_error "Remote restore reported failure — check /var/log/server-migration/restore.log on new server"
            log_error "Remote restore failed"
            declare -f notify_restore_fail &>/dev/null && notify_restore_fail "remote agent failed" || true
            return 1
        fi
    fi

    # Post-restore verification
    msg_step "Waiting for remote host after potential reboot..."
    if [[ "${REBOOT_AFTER_RESTORE:-yes}" == "yes" ]]; then
        sleep 15
        local i
        for i in $(seq 1 30); do
            if ssh_cmd "echo SMM_ALIVE" 2>/dev/null | grep -q SMM_ALIVE; then
                msg_ok "New server is reachable after restore"
                verify_migration_remote
                return 0
            fi
            show_progress $(( i * 100 / 30 ))
            sleep 10
        done
        msg_warn "Could not re-establish SSH after reboot — verify manually"
        return 0
    fi

    verify_migration_remote
}

verify_migration_remote() {
    msg_step "Verifying migration on remote..."
    local report
    report="$(ssh_cmd '
        echo "hostname=$(hostname)"
        echo "os=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d \"\\\"\")"
        echo "kernel=$(uname -r)"
        echo "disk=$(df -h / | awk "NR==2{print \$4\" free\"}")"
        systemctl is-system-running 2>/dev/null || true
        test -f /var/log/server-migration/restore.log && echo "restore_log=present" || echo "restore_log=missing"
        test -f /etc/smm-restore-complete && echo "marker=OK" || echo "marker=missing"
    ' 2>/dev/null)" || {
        msg_warn "Verification SSH call failed"
        return 1
    }
    echo "$report" | while read -r line; do msg_info "  $line"; done
    if echo "$report" | grep -q "marker=OK"; then
        msg_ok "Migration verification: SUCCESS marker found"
        log_ok "Migration verified on remote"
        return 0
    fi
    msg_warn "Restore complete marker not found — check remote logs"
    return 1
}

#-------------------------------------------------------------------------------
# Local restore (when restore-agent / migrate runs ON the new server)
#-------------------------------------------------------------------------------
restore_from_archive() {
    local archive="$1"
    local auto_yes="${2:-no}"
    local do_reboot="${3:-yes}"

    set_log_file "${LOG_DIR:-/var/log/server-migration}/restore.log"
    mkdir -p "${LOG_DIR:-/var/log/server-migration}"
    require_root

    [[ -f "$archive" ]] || die "Archive not found: $archive"

    if [[ "$auto_yes" != "yes" ]]; then
        if ! confirm_action "This will overwrite the current server filesystem from $(basename "$archive"). Continue?"; then
            return 1
        fi
    fi

    msg_info "Starting restore from $(basename "$archive")"
    log_info "=== RESTORE START archive=$archive ==="

    # Join split parts if needed
    if [[ -f "${archive}.parts.list" ]]; then
        local joined="/tmp/smm-joined-$$.tar.zst"
        join_backup_parts "${archive}.parts.list" "$joined"
        archive="$joined"
    fi

    # Verify checksum
    if [[ "${VERIFY_CHECKSUM:-yes}" == "yes" && -f "${archive}.sha256" ]]; then
        verify_checksum "$archive" || die "Checksum validation failed — aborting restore"
    fi

    # Decrypt if encrypted (sets DECRYPTED_BACKUP_FILE — never capture msg stdout)
    local work_archive="$archive"
    if declare -f is_encrypted_backup &>/dev/null && is_encrypted_backup "$archive"; then
        DECRYPTED_BACKUP_FILE=""
        decrypt_backup_file "$archive" "/tmp/smm-decrypted-$$.tar.zst" || die "Decrypt failed"
        [[ -n "${DECRYPTED_BACKUP_FILE:-}" && -f "$DECRYPTED_BACKUP_FILE" ]] || die "Decrypt produced no file"
        work_archive="$DECRYPTED_BACKUP_FILE"
    elif [[ -f "${archive}.manifest" ]] && grep -q 'encrypted=yes' "${archive}.manifest" 2>/dev/null; then
        DECRYPTED_BACKUP_FILE=""
        decrypt_backup_file "$archive" "/tmp/smm-decrypted-$$.tar.zst" || die "Decrypt failed"
        work_archive="${DECRYPTED_BACKUP_FILE:-}"
        [[ -f "$work_archive" ]] || die "Decrypt produced no file"
    fi

    check_dependencies
    check_disk_space "/" 5

    msg_step "Installing required packages on target..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y zstd tar rsync pv \
        iptables iptables-persistent curl 2>/dev/null || true

    msg_step "Stopping conflicting services..."
    local stop_list=(nginx apache2 mysql mariadb postgresql redis-server redis mongod docker postfix dovecot)
    local s
    for s in "${stop_list[@]}"; do
        systemctl stop "$s" 2>/dev/null || true
    done

    local work="/tmp/smm-restore-$$"
    mkdir -p "$work/rootfs" "$work/extract"

    msg_step "Extracting backup archive (this takes time)..."
    show_progress 5
    if check_command pv; then
        local sz
        sz="$(stat -c%s "$work_archive")"
        pv -s "$sz" "$work_archive" | zstd -d | tar -xpf - -C "$work/extract" 2>>"${LOG_DIR}/restore.log"
    else
        start_spinner "Extracting tar.zst..."
        zstd -dc "$work_archive" | tar -xpf - -C "$work/extract" 2>>"${LOG_DIR}/restore.log"
        stop_spinner
    fi
    show_progress 40

    local session_dir extras=""
    session_dir="$(find "$work/extract" -type d -name 'smm-session' 2>/dev/null | head -1)"
    if [[ -n "$session_dir" && -d "$session_dir/extras" ]]; then
        extras="$session_dir/extras"
        SMM_SESSION_DIR="$session_dir"
        msg_info "Found session extras: $extras"
    fi

    if [[ -n "$extras" && -d "$extras/packages" ]]; then
        declare -f restore_packages &>/dev/null && restore_packages "$extras/packages"
    fi

    msg_step "Restoring filesystem trees..."
    local tree
    for tree in etc home root opt usr var srv boot; do
        if [[ -d "$work/extract/$tree" ]]; then
            msg_info "  Syncing /$tree ..."
            if [[ "$tree" == "etc" ]]; then
                rsync -aAX --exclude='fstab' --exclude='netplan/**' --exclude='cloud/**' \
                    "$work/extract/$tree/" "/$tree/" 2>>"${LOG_DIR}/restore.log" || true
                [[ -f "$work/extract/etc/fstab" ]] && cp -a /etc/fstab /etc/fstab.smm-pre 2>/dev/null; \
                    cp -a "$work/extract/etc/fstab" /etc/fstab 2>/dev/null || true
                [[ -d "$work/extract/etc/netplan" ]] && mkdir -p /etc/netplan && \
                    cp -a "$work/extract/etc/netplan/." /etc/netplan/ 2>/dev/null || true
            else
                rsync -aAX --exclude='**/docker/overlay2/**' --exclude='**/containerd/**' \
                    "$work/extract/$tree/" "/$tree/" 2>>"${LOG_DIR}/restore.log" || \
                rsync -a "$work/extract/$tree/" "/$tree/" 2>>"${LOG_DIR}/restore.log" || true
            fi
        fi
        if [[ -d "$work/extract/./$tree" ]]; then
            rsync -a "$work/extract/./$tree/" "/$tree/" 2>/dev/null || true
        fi
    done
    show_progress 70

    if [[ -n "$extras" ]]; then
        [[ -d "$extras/network" ]] && restore_network "$extras/network"
        show_progress 73
        [[ -d "$extras/firewall" ]] && restore_firewall "$extras/firewall"
        show_progress 76
        [[ -d "$extras/ssl" ]] && restore_ssl "$extras/ssl"
        show_progress 79
        [[ -d "$extras/security" ]] && restore_security "$extras/security"
        show_progress 82
        [[ -d "$extras/web" ]] && restore_web "$extras/web"
        show_progress 85
        [[ -d "$extras/mail" ]] && restore_mail "$extras/mail"
        show_progress 87
        [[ -d "$extras/tunnels" ]] && restore_tunnels "$extras/tunnels"
        show_progress 89
        [[ -d "$extras/databases" ]] && restore_databases "$extras/databases"
        show_progress 92
        [[ -d "$extras/docker" ]] && restore_docker "$extras/docker"
        show_progress 94
        [[ -d "$extras/pasarguard" ]] && restore_pasarguard "$extras/pasarguard"
        show_progress 95
        [[ -d "$extras/services" ]] && restore_services "$extras/services"
    fi

    declare -f clean_cloud_init &>/dev/null && clean_cloud_init

    msg_step "Reloading systemd and enabling services..."
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    {
        echo "restored_at=$(date -Iseconds)"
        echo "archive=$(basename "$archive")"
        echo "hostname=$(hostname)"
        echo "tool=SERVER_MIGRATION_MANAGER_v${SMM_VERSION:-1.1.0}"
    } > /etc/smm-restore-complete

    declare -f postcheck_local &>/dev/null && postcheck_local || true

    show_progress 100
    msg_ok "Restore completed successfully"
    log_ok "Restore completed from $archive"
    declare -f notify_restore_done &>/dev/null && notify_restore_done || true

    rm -rf "$work"
    [[ "$work_archive" != "$archive" ]] && rm -f "$work_archive" 2>/dev/null || true

    if [[ "$do_reboot" == "yes" ]]; then
        msg_warn "Rebooting in 5 seconds..."
        sleep 5
        systemctl reboot || reboot
    fi
    return 0
}

#-------------------------------------------------------------------------------
# Full migration wizard (backup → connect → upload → restore)
#-------------------------------------------------------------------------------
run_full_migration_wizard() {
    msg_info "FULL MIGRATION WIZARD"
    msg_dim "This will: preflight → backup → connect → upload → restore"
    if ! confirm_action "Start the full automated migration wizard?"; then
        return 1
    fi
    preflight_check || {
        if ! confirm_action "Pre-flight reported issues. Continue anyway?"; then
            return 1
        fi
    }
    create_full_backup || return 1
    if [[ -z "${REMOTE_HOST:-}" ]]; then
        connect_new_server || return 1
    else
        test_ssh_connection || connect_new_server || return 1
    fi
    upload_backup || return 1
    restore_server_remote || return 1
    generate_migration_report 2>/dev/null || true
    msg_ok "Wizard finished"
}
