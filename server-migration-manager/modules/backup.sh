#!/usr/bin/env bash
#===============================================================================
# MODULE: Full Server Backup Engine
# SERVER MIGRATION MANAGER v1.0 | JOJO BACKUP
#===============================================================================

# Source guard handled by caller

#-------------------------------------------------------------------------------
# Collect server metadata before backup
#-------------------------------------------------------------------------------
collect_server_metadata() {
    local meta_dir="$1"
    mkdir -p "$meta_dir"

    msg_step "Collecting server metadata..."
    show_progress 5

    {
        echo "hostname=$(hostname -f 2>/dev/null || hostname)"
        echo "short_hostname=$(hostname)"
        echo "os_pretty=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"')"
        echo "os_version=$(grep VERSION_ID /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"')"
        echo "kernel=$(uname -r)"
        echo "arch=$(uname -m)"
        echo "uptime=$(uptime -p 2>/dev/null || uptime)"
        echo "backup_time=$(date -Iseconds)"
        echo "backup_tool=SERVER_MIGRATION_MANAGER_v${SMM_VERSION:-1.1.0}"
    } > "$meta_dir/system.info"

    show_progress 15
    hostname > "$meta_dir/hostname.txt"
    uname -a > "$meta_dir/uname.txt"
    cp -a /etc/os-release "$meta_dir/os-release" 2>/dev/null || true

    # Packages
    msg_info "Saving installed packages..."
    dpkg --get-selections > "$meta_dir/packages.dpkg" 2>/dev/null || true
    apt-mark showmanual > "$meta_dir/packages.manual" 2>/dev/null || true
    dpkg -l > "$meta_dir/packages.list" 2>/dev/null || true

    show_progress 30

    # Services
    msg_info "Saving systemd services..."
    systemctl list-units --type=service --all --no-pager > "$meta_dir/services.all" 2>/dev/null || true
    systemctl list-units --type=service --state=running --no-pager > "$meta_dir/services.running" 2>/dev/null || true
    systemctl list-unit-files --type=service --state=enabled --no-pager > "$meta_dir/services.enabled" 2>/dev/null || true

    show_progress 45

    # Users & groups
    msg_info "Saving users and groups..."
    cp -a /etc/passwd "$meta_dir/passwd" 2>/dev/null || true
    cp -a /etc/group "$meta_dir/group" 2>/dev/null || true
    cp -a /etc/shadow "$meta_dir/shadow" 2>/dev/null || true
    cp -a /etc/gshadow "$meta_dir/gshadow" 2>/dev/null || true
    getent passwd > "$meta_dir/getent.passwd" 2>/dev/null || true
    getent group > "$meta_dir/getent.group" 2>/dev/null || true

    show_progress 55

    # Cron jobs
    msg_info "Saving cron jobs..."
    mkdir -p "$meta_dir/cron"
    cp -a /etc/crontab "$meta_dir/cron/crontab" 2>/dev/null || true
    cp -a /etc/cron.d "$meta_dir/cron/cron.d" 2>/dev/null || true
    cp -a /etc/cron.daily "$meta_dir/cron/cron.daily" 2>/dev/null || true
    cp -a /etc/cron.weekly "$meta_dir/cron/cron.weekly" 2>/dev/null || true
    cp -a /etc/cron.monthly "$meta_dir/cron/cron.monthly" 2>/dev/null || true
    cp -a /etc/cron.hourly "$meta_dir/cron/cron.hourly" 2>/dev/null || true
    for u in $(cut -f1 -d: /etc/passwd); do
        crontab -u "$u" -l > "$meta_dir/cron/crontab.${u}" 2>/dev/null || true
    done

    show_progress 65

    # Environment
    msg_info "Saving environment variables..."
    env | sort > "$meta_dir/environment.txt" 2>/dev/null || true
    cp -a /etc/environment "$meta_dir/etc.environment" 2>/dev/null || true
    cp -a /etc/profile "$meta_dir/etc.profile" 2>/dev/null || true
    [[ -d /etc/profile.d ]] && cp -a /etc/profile.d "$meta_dir/profile.d" 2>/dev/null || true

    # Mounts & disks
    df -hT > "$meta_dir/df.txt" 2>/dev/null || true
    lsblk -f > "$meta_dir/lsblk.txt" 2>/dev/null || true
    mount > "$meta_dir/mount.txt" 2>/dev/null || true
    cat /etc/fstab > "$meta_dir/fstab" 2>/dev/null || true

    show_progress 80

    # Listening ports / processes snapshot
    ss -tulnp > "$meta_dir/ss.listening" 2>/dev/null || netstat -tulnp > "$meta_dir/netstat.listening" 2>/dev/null || true
    ps auxf > "$meta_dir/ps.auxf" 2>/dev/null || true

    show_progress 100
    msg_ok "Server metadata collected → $meta_dir"
    log_ok "Metadata collected in $meta_dir"
}

#-------------------------------------------------------------------------------
# Create full filesystem backup with tar + zstd
#-------------------------------------------------------------------------------
create_full_backup() {
    set_log_file "${PROJECT_LOG_DIR}/backup.log"
    require_root
    acquire_lock 2>/dev/null || true
    check_dependencies
    check_ubuntu_version 2>/dev/null || true
    check_disk_space "$BACKUP_DIR"

    if [[ "${DRY_RUN:-no}" == "yes" ]]; then
        msg_warn "DRY_RUN=yes — estimating only, no archive will be written"
        estimate_backup_size
        release_lock 2>/dev/null || true
        return 0
    fi

    local ts
    ts="$(timestamp)"
    local session_dir="${BACKUP_DIR}/session-${ts}"
    local meta_dir="${session_dir}/metadata"
    local extras_dir="${session_dir}/extras"
    local archive="${BACKUP_DIR}/server-backup-${ts}.tar.zst"

    mkdir -p "$session_dir" "$meta_dir" "$extras_dir" "$BACKUP_DIR"
    METADATA_DIR="$meta_dir"
    SMM_SESSION_DIR="$session_dir"

    msg_info "Starting full server backup..."
    log_info "=== BACKUP START ts=$ts ==="
    loading_anim "Preparing backup session" 2
    declare -f notify_send &>/dev/null && notify_send "Backup started" "ts=$ts" || true

    # 1. Metadata
    collect_server_metadata "$meta_dir"

    # 2. Module-specific extras
    msg_step "Running component backups..."
    show_progress 5

    declare -f backup_network &>/dev/null && backup_network "$extras_dir/network"
    show_progress 12
    declare -f backup_firewall &>/dev/null && backup_firewall "$extras_dir/firewall"
    show_progress 18
    declare -f backup_databases &>/dev/null && backup_databases "$extras_dir/databases"
    show_progress 28
    declare -f backup_docker &>/dev/null && backup_docker "$extras_dir/docker"
    show_progress 36
    declare -f backup_pasarguard &>/dev/null && backup_pasarguard "$extras_dir/pasarguard"
    show_progress 38
    declare -f backup_ssl &>/dev/null && backup_ssl "$extras_dir/ssl"
    show_progress 45
    declare -f backup_tunnels &>/dev/null && backup_tunnels "$extras_dir/tunnels"
    show_progress 50
    declare -f backup_services &>/dev/null && backup_services "$extras_dir/services"
    show_progress 55
    declare -f backup_security &>/dev/null && backup_security "$extras_dir/security"
    show_progress 60
    declare -f backup_web &>/dev/null && backup_web "$extras_dir/web"
    show_progress 65
    declare -f backup_mail &>/dev/null && backup_mail "$extras_dir/mail"
    show_progress 70
    declare -f backup_packages_extra &>/dev/null && backup_packages_extra "$extras_dir/packages"
    show_progress 75

    # 3. Build exclude args for tar
    local exclude_args=()
    for path in "${BACKUP_EXCLUDE[@]}"; do
        exclude_args+=(--exclude="$path")
    done
    # Also exclude our own backup dir to avoid recursion
    exclude_args+=(--exclude="${BACKUP_DIR}")
    exclude_args+=(--exclude="/var/log/server-migration")
    exclude_args+=(--exclude="*/.cache/*")

    # Include session extras/metadata in a staging tree under /tmp for packing
    local staging="/tmp/smm-staging-${ts}"
    mkdir -p "$staging"
    cp -a "$session_dir" "$staging/smm-session" 2>/dev/null || true

    msg_step "Creating compressed filesystem archive (tar + zstd)..."
    msg_dim "This may take a long time on large servers..."
    log_info "Creating archive: $archive"

    local zstd_threads="${ZSTD_THREADS:-0}"
    local zstd_level="${ZSTD_LEVEL:-3}"
    local tar_exit=0

    # Prefer pv for progress if available
    if check_command pv; then
        # Estimate approximate size for pv (rough)
        local est_bytes
        est_bytes="$(du -sb /etc /home /root /opt /usr /var /srv /boot 2>/dev/null | awk '{s+=$1} END{print s+0}')"
        (
            tar -cpf - \
                "${exclude_args[@]}" \
                --warning=no-file-changed \
                --warning=no-file-removed \
                /etc /home /root /opt /usr /var /srv /boot \
                "$staging/smm-session" \
                2>>"${PROJECT_LOG_DIR}/backup.log"
        ) | pv -s "${est_bytes:-0}" | zstd -T"${zstd_threads}" -"${zstd_level}" -o "$archive"
        tar_exit=${PIPESTATUS[0]}
    else
        start_spinner "Compressing filesystem with zstd..."
        tar -cpf - \
            "${exclude_args[@]}" \
            --warning=no-file-changed \
            --warning=no-file-removed \
            /etc /home /root /opt /usr /var /srv /boot \
            "$staging/smm-session" \
            2>>"${PROJECT_LOG_DIR}/backup.log" \
            | zstd -T"${zstd_threads}" -"${zstd_level}" -o "$archive"
        tar_exit=${PIPESTATUS[0]}
        stop_spinner
    fi

    # tar exit 1 = files changed during read (acceptable)
    if [[ $tar_exit -gt 1 ]]; then
        msg_error "Backup archive creation failed (tar exit=$tar_exit)"
        log_error "tar failed with exit $tar_exit"
        declare -f notify_backup_fail &>/dev/null && notify_backup_fail "tar exit $tar_exit" || true
        rm -rf "$staging"
        release_lock 2>/dev/null || true
        return 1
    fi

    show_progress 88

    if [[ ! -f "$archive" ]] || [[ ! -s "$archive" ]]; then
        declare -f notify_backup_fail &>/dev/null && notify_backup_fail "empty archive" || true
        die "Archive was not created or is empty: $archive"
    fi

    # 4. Checksum (plaintext)
    create_checksum "$archive"
    show_progress 92

    # 5. Optional encryption + split
    ENCRYPTED_BACKUP_FILE=""
    if declare -f encrypt_backup_file &>/dev/null; then
        if encrypt_backup_file "$archive"; then
            if [[ -n "${ENCRYPTED_BACKUP_FILE:-}" && -f "${ENCRYPTED_BACKUP_FILE}" ]]; then
                archive="$ENCRYPTED_BACKUP_FILE"
            fi
        else
            msg_error "Encryption failed — plaintext archive kept"
            log_error "Encryption failed for backup"
        fi
    fi
    declare -f split_backup_if_needed &>/dev/null && split_backup_if_needed "$archive"
    show_progress 96

    # 6. Manifest (for final artifact — encrypted or plain)
    local size bytes
    bytes="$(stat -c%s "$archive" 2>/dev/null || stat -f%z "$archive")"
    size="$(human_size "$bytes")"
    if [[ ! -f "${archive}.manifest" ]]; then
        {
            echo "archive=$(basename "$archive")"
            echo "path=$archive"
            echo "size_bytes=$bytes"
            echo "size_human=$size"
            echo "created=$(date -Iseconds)"
            echo "hostname=$(hostname)"
            echo "checksum=$(awk '{print $1}' "${archive}.sha256" 2>/dev/null)"
            echo "compression=zstd"
            echo "session=$session_dir"
            echo "smm_version=${SMM_VERSION:-1.1.1}"
            echo "encrypted=${ENCRYPT_BACKUP:-no}"
        } > "${archive}.manifest"
    else
        # Refresh size fields on existing encrypt manifest
        echo "size_bytes=$bytes" >> "${archive}.manifest"
        echo "size_human=$size" >> "${archive}.manifest"
    fi

    cp -a "${archive}.manifest" "$session_dir/" 2>/dev/null || true

    rm -rf "$staging"
    show_progress 100

    echo
    msg_ok "Backup completed successfully"
    msg_info "Archive : $archive"
    msg_info "Size    : $size"
    msg_info "SHA256  : $(awk '{print $1}' "${archive}.sha256" 2>/dev/null)"
    log_ok "Backup completed: $archive ($size)"
    declare -f notify_backup_done &>/dev/null && notify_backup_done "$archive" "$size" || true

    enforce_backup_retention
    LAST_BACKUP_FILE="$archive"
    release_lock 2>/dev/null || true
    return 0
}

#-------------------------------------------------------------------------------
# Retention policy
#-------------------------------------------------------------------------------
enforce_backup_retention() {
    local keep="${KEEP_BACKUPS:-3}"
    local files
    mapfile -t files < <(ls -1t "${BACKUP_DIR}"/server-backup-*.tar.zst \
        "${BACKUP_DIR}"/server-backup-*.tar.zst.gpg \
        "${BACKUP_DIR}"/server-backup-*.tar.zst.enc 2>/dev/null)
    local count=${#files[@]}
    if (( count > keep )); then
        msg_info "Retention: keeping $keep backups (found $count)"
        local i
        for (( i=keep; i<count; i++ )); do
            local f="${files[$i]}"
            msg_dim "Removing old backup: $(basename "$f")"
            rm -f "$f" "${f}.sha256" "${f}.manifest" "${f}.parts.list"
            rm -f "${f}.part."* 2>/dev/null || true
            log_info "Removed old backup: $f"
        done
    fi
}

#-------------------------------------------------------------------------------
# Verify backup integrity
#-------------------------------------------------------------------------------
verify_backup() {
    set_log_file "${PROJECT_LOG_DIR}/backup.log"
    local archive="${1:-}"

    if [[ -z "$archive" ]]; then
        archive="$(ls -1t "${BACKUP_DIR}"/server-backup-* 2>/dev/null | grep -E '\.tar\.zst(\.gpg|\.enc)?$' | head -1)"
    fi

    if [[ -z "$archive" || ! -f "$archive" ]]; then
        die "No backup archive found in $BACKUP_DIR"
    fi

    msg_info "Verifying backup: $(basename "$archive")"
    loading_anim "Checking integrity" 1

    # Checksum
    if [[ -f "${archive}.sha256" ]]; then
        verify_checksum "$archive" || return 1
    else
        msg_warn "No .sha256 file found — generating one now"
        create_checksum "$archive"
    fi

    # Encrypted archives are not valid zstd until decrypted
    if declare -f is_encrypted_backup &>/dev/null && is_encrypted_backup "$archive"; then
        msg_ok "Archive is encrypted — SHA256 verified; skip zstd content test"
        log_ok "Verified encrypted backup: $archive"
        return 0
    fi
    if [[ -f "${archive}.manifest" ]] && grep -q 'encrypted=yes' "${archive}.manifest" 2>/dev/null; then
        msg_ok "Archive is encrypted — SHA256 verified; skip zstd content test"
        log_ok "Verified encrypted backup: $archive"
        return 0
    fi

    # Test archive readability
    msg_step "Testing archive contents (zstd + tar)..."
    start_spinner "Reading archive header..."
    if zstd -t "$archive" 2>/dev/null; then
        stop_spinner
        msg_ok "zstd integrity OK"
    else
        stop_spinner
        msg_error "zstd integrity check FAILED"
        return 1
    fi

    start_spinner "Listing sample files from archive..."
    local sample
    sample="$(zstd -dc "$archive" 2>/dev/null | tar -tf - 2>/dev/null | head -20)"
    stop_spinner
    if [[ -z "$sample" ]]; then
        msg_error "Cannot list archive contents"
        return 1
    fi
    msg_ok "Archive is readable"
    echo
    msg_dim "Sample contents:"
    echo "$sample" | while read -r line; do msg_dim "  $line"; done
    log_ok "Verified backup: $archive"
    return 0
}

#-------------------------------------------------------------------------------
# Show backup information
#-------------------------------------------------------------------------------
show_backup_info() {
    echo
    msg_info "Backup directory: $BACKUP_DIR"
    echo
    local found=0
    local f
    for f in "${BACKUP_DIR}"/server-backup-*.tar.zst \
             "${BACKUP_DIR}"/server-backup-*.tar.zst.gpg \
             "${BACKUP_DIR}"/server-backup-*.tar.zst.enc; do
        [[ -f "$f" ]] || continue
        found=1
        local bytes size sha created
        bytes="$(stat -c%s "$f" 2>/dev/null || echo 0)"
        size="$(human_size "$bytes")"
        sha="(none)"
        [[ -f "${f}.sha256" ]] && sha="$(awk '{print $1}' "${f}.sha256")"
        created="$(stat -c%y "$f" 2>/dev/null | cut -d. -f1 || echo unknown)"
        echo -e "${C_CYAN}────────────────────────────────────────${C_RESET}"
        echo -e "  File    : ${C_WHITE}$(basename "$f")${C_RESET}"
        echo -e "  Size    : $size"
        echo -e "  Created : $created"
        echo -e "  SHA256  : ${C_DIM}${sha}${C_RESET}"
        if [[ -f "${f}.manifest" ]]; then
            echo -e "  Manifest:"
            sed 's/^/    /' "${f}.manifest"
        fi
    done
    if [[ $found -eq 0 ]]; then
        msg_warn "No backups found."
    fi
    echo
}

#-------------------------------------------------------------------------------
# Cleanup backup files
#-------------------------------------------------------------------------------
cleanup_backups() {
    set_log_file "${PROJECT_LOG_DIR}/backup.log"
    show_backup_info
    if ! confirm_action "This will DELETE all backup archives in ${BACKUP_DIR}. Continue?"; then
        return 1
    fi
    local count=0
    local f
    for f in "${BACKUP_DIR}"/server-backup-*.tar.zst \
             "${BACKUP_DIR}"/server-backup-*.sha256 \
             "${BACKUP_DIR}"/server-backup-*.manifest; do
        [[ -e "$f" ]] || continue
        rm -f "$f"
        ((count++)) || true
    done
    # Optional: session dirs
    rm -rf "${BACKUP_DIR}"/session-* 2>/dev/null || true
    msg_ok "Cleaned up $count backup-related files"
    log_ok "Cleanup completed ($count files)"
}
