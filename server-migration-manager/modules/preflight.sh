#!/usr/bin/env bash
#===============================================================================
# MODULE: Pre-flight checks, locks, estimates, Ubuntu validation
# SERVER MIGRATION MANAGER v1.1 | JOJO BACKUP
#===============================================================================

acquire_lock() {
    local lock="${LOCK_FILE:-/var/run/smm-migration.lock}"
    mkdir -p "$(dirname "$lock")" 2>/dev/null || true
    if ! check_command flock; then
        msg_warn "flock not available - skipping exclusive lock"
        return 0
    fi
    exec 9>"$lock"
    if ! flock -n 9; then
        die "Another SMM process is running (lock: $lock)"
    fi
    echo $$ > "$lock"
    log_info "Lock acquired pid=$$"
}

release_lock() {
    if check_command flock; then
        flock -u 9 2>/dev/null || true
    fi
    rm -f "${LOCK_FILE:-/var/run/smm-migration.lock}" 2>/dev/null || true
}

setup_signal_traps() {
    trap 'stop_spinner 2>/dev/null; release_lock; msg_warn "Interrupted — cleaned up"; exit 130' INT TERM
    trap 'release_lock' EXIT
}

check_ubuntu_version() {
    local ver
    ver="$(grep VERSION_ID /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
    case "$ver" in
        20.04|22.04|24.04)
            msg_ok "Ubuntu $ver supported"
            return 0
            ;;
        *)
            msg_warn "Ubuntu $ver is not in the official support list (20.04/22.04/24.04)"
            msg_dim "Continuing anyway — results may vary"
            return 0
            ;;
    esac
}

check_architecture() {
    local arch
    arch="$(uname -m)"
    msg_info "Architecture: $arch"
    case "$arch" in
        x86_64|amd64|aarch64|arm64) return 0 ;;
        *) msg_warn "Unusual architecture: $arch" ;;
    esac
}

estimate_backup_size() {
    msg_step "Estimating backup size (this may take a minute)..."
    local total=0
    local path
    for path in "${BACKUP_INCLUDE[@]:-/etc /home /root /opt /usr /var /srv}"; do
        [[ -e "$path" ]] || continue
        local sz
        sz="$(du -sb --exclude=/proc --exclude=/sys --exclude=/dev "$path" 2>/dev/null | awk '{print $1}')"
        total=$(( total + ${sz:-0} ))
        msg_dim "  $path → $(human_size "${sz:-0}")"
    done
    # Rough compressed estimate (~40% of raw for mixed data with zstd-3)
    local est_comp=$(( total * 40 / 100 ))
    echo
    msg_info "Raw data (approx)        : $(human_size "$total")"
    msg_info "Compressed estimate (~40%): $(human_size "$est_comp")"
    local avail_kb avail_bytes
    avail_kb="$(df -Pk "${BACKUP_DIR}" | awk 'NR==2{print $4}')"
    avail_bytes=$(( avail_kb * 1024 ))
    msg_info "Free on backup volume    : $(human_size "$avail_bytes")"
    if (( avail_bytes < est_comp )); then
        msg_error "Likely insufficient space for compressed backup"
        return 1
    fi
    msg_ok "Disk space looks sufficient"
    ESTIMATED_RAW_BYTES="$total"
    ESTIMATED_COMP_BYTES="$est_comp"
    return 0
}

preflight_check() {
    set_log_file "${PROJECT_LOG_DIR}/preflight.log"
    print_banner
    msg_step "Running pre-flight checks..."
    echo

    local failed=0

    # Root
    if [[ "$(id -u)" -eq 0 ]]; then
        msg_ok "Running as root"
    else
        msg_error "Not root"; failed=1
    fi

    check_ubuntu_version
    check_architecture

    # Dependencies
    local req=(tar rsync ssh scp sha256sum zstd)
    local cmd
    for cmd in "${req[@]}"; do
        if check_command "$cmd"; then
            msg_ok "Command: $cmd"
        else
            msg_error "Missing: $cmd"; failed=1
        fi
    done
    for cmd in pv sshpass gpg openssl curl jq flock; do
        if check_command "$cmd"; then
            msg_ok "Optional: $cmd"
        else
            msg_dim "Optional missing: $cmd"
        fi
    done

    # Disk
    check_disk_space "${BACKUP_DIR}" "${MIN_FREE_SPACE_GB:-5}" || failed=1

    # SELinux/AppArmor awareness
    if check_command aa-status; then
        aa-status --enabled 2>/dev/null && msg_info "AppArmor: enabled" || msg_dim "AppArmor: inactive"
    fi

    # Open files / load
    msg_info "Load average: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo n/a)"
    msg_info "Uptime: $(uptime -p 2>/dev/null || uptime)"

    # Network outbound (DNS)
    if getent hosts google.com &>/dev/null || getent hosts cloudflare.com &>/dev/null; then
        msg_ok "DNS resolution works"
    else
        msg_warn "DNS resolution may be broken"
    fi

    # SSH client
    if check_command ssh; then
        msg_ok "SSH client available"
    fi

    # Remote configured?
    if [[ -n "${REMOTE_HOST:-}" ]]; then
        msg_info "Remote configured: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}"
        if test_ssh_connection 2>/dev/null; then
            msg_ok "Remote SSH reachable"
            # Compare arch
            local remote_arch
            remote_arch="$(ssh_cmd 'uname -m' 2>/dev/null)"
            local local_arch
            local_arch="$(uname -m)"
            if [[ -n "$remote_arch" && "$remote_arch" != "$local_arch" ]]; then
                msg_warn "Architecture mismatch: local=$local_arch remote=$remote_arch"
            else
                msg_ok "Remote architecture matches ($local_arch)"
            fi
            # Free space remote
            ssh_cmd "df -h '${REMOTE_PATH:-/backup}' 2>/dev/null || df -h /" || true
        else
            msg_warn "Remote SSH not reachable (configure via menu option Connect)"
        fi
    else
        msg_dim "Remote host not configured yet"
    fi

    # Encryption config sanity
    if [[ "${ENCRYPT_BACKUP:-no}" == "yes" ]]; then
        if [[ "${ENCRYPT_METHOD}" == "gpg" ]]; then
            check_command gpg || { msg_error "ENCRYPT_BACKUP=yes but gpg missing"; failed=1; }
        else
            check_command openssl || { msg_error "ENCRYPT_BACKUP=yes but openssl missing"; failed=1; }
        fi
        msg_info "Encryption enabled (${ENCRYPT_METHOD})"
    fi

    estimate_backup_size || true

    echo
    if [[ $failed -eq 0 ]]; then
        msg_ok "Pre-flight PASSED"
        log_ok "Pre-flight passed"
        return 0
    fi
    msg_error "Pre-flight found blocking issues"
    log_error "Pre-flight failed"
    return 1
}

create_restore_point_remote() {
    [[ "${CREATE_RESTORE_POINT:-yes}" == "yes" ]] || return 0
    [[ -n "${REMOTE_HOST:-}" ]] || return 0
    msg_step "Creating restore-point snapshot on NEW server..."
    ssh_cmd '
        RP="/root/smm-restore-point-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$RP"
        cp -a /etc/netplan "$RP/" 2>/dev/null || true
        cp -a /etc/ssh "$RP/" 2>/dev/null || true
        cp -a /etc/hostname /etc/hosts /etc/fstab "$RP/" 2>/dev/null || true
        iptables-save > "$RP/iptables.rules" 2>/dev/null || true
        dpkg --get-selections > "$RP/packages.dpkg" 2>/dev/null || true
        echo "$RP"
    ' && msg_ok "Remote restore-point created under /root/smm-restore-point-*"
}
