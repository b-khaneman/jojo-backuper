#!/usr/bin/env bash
#===============================================================================
# MODULE: Post-migration verification & cloud-init cleanup
# SERVER MIGRATION MANAGER v1.1 | JOJO BACKUP
#===============================================================================

clean_cloud_init() {
    [[ "${CLEAN_CLOUD_INIT:-yes}" == "yes" ]] || return 0
    msg_step "Cleaning cloud-init state (prevent hostname/network reset)..."
    if check_command cloud-init; then
        cloud-init clean --logs 2>/dev/null || true
        rm -f /etc/cloud/cloud.cfg.d/99-installer.cfg 2>/dev/null || true
        # Disable future network rewrite if desired
        if [[ -d /etc/cloud/cloud.cfg.d ]]; then
            cat > /etc/cloud/cloud.cfg.d/99-smm-disable-network.cfg <<'EOF'
network: {config: disabled}
EOF
        fi
        msg_ok "cloud-init cleaned"
    else
        msg_dim "cloud-init not present"
    fi
}

postcheck_local() {
    set_log_file "${PROJECT_LOG_DIR:-$LOG_DIR}/postcheck.log"
    msg_step "Running post-migration health checks..."
    local ok=0 fail=0

    # Marker
    if [[ -f /etc/smm-restore-complete ]]; then
        msg_ok "Restore marker present"
        ((ok++)) || true
        cat /etc/smm-restore-complete | sed 's/^/  /'
    else
        msg_warn "Restore marker missing"
        ((fail++)) || true
    fi

    # systemd
    local state
    state="$(systemctl is-system-running 2>/dev/null || echo unknown)"
    msg_info "System state: $state"
    [[ "$state" == "running" || "$state" == "degraded" ]] && ((ok++)) || ((fail++)) || true

    # SSH
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        msg_ok "SSH service active"
        ((ok++)) || true
    else
        msg_error "SSH not active"; ((fail++)) || true
    fi

    # Disk
    df -hT / | tail -1 | awk '{print "  rootfs: "$4" used, "$5" avail ("$6")"}'

    # TCP ports
    local port
    for port in ${POSTCHECK_TCP_PORTS:-22 80 443}; do
        if ss -tln | grep -q ":${port} "; then
            msg_ok "Listening on :$port"
            ((ok++)) || true
        else
            msg_dim "Not listening on :$port"
        fi
    done

    # HTTP URLs
    local url
    for url in ${POSTCHECK_HTTP_URLS:-}; do
        if curl -fsS -o /dev/null -m 10 "$url"; then
            msg_ok "HTTP OK: $url"
            ((ok++)) || true
        else
            msg_warn "HTTP FAIL: $url"
            ((fail++)) || true
        fi
    done

    # Critical services quick probe
    local svc
    for svc in nginx apache2 mysql mariadb postgresql docker redis-server; do
        if systemctl list-unit-files "${svc}.service" &>/dev/null; then
            if systemctl is-active --quiet "$svc"; then
                msg_ok "Service active: $svc"
            else
                msg_dim "Service installed but not active: $svc"
            fi
        fi
    done

    # DNS
    getent hosts localhost >/dev/null && msg_ok "localhost resolves" || msg_warn "localhost resolve failed"

    echo
    msg_info "Post-check summary: ok=$ok warn/fail=$fail"
    {
        echo "postcheck_at=$(date -Iseconds)"
        echo "ok=$ok"
        echo "fail=$fail"
        echo "system_state=$state"
    } > /etc/smm-postcheck-report

    log_ok "Post-check ok=$ok fail=$fail"
    return 0
}

postcheck_remote() {
    load_remote_state 2>/dev/null || true
    [[ -n "${REMOTE_HOST:-}" ]] || { msg_error "Remote not configured"; return 1; }
    msg_step "Running post-check on remote ${REMOTE_HOST}..."
    ssh_cmd 'bash -s' <<'EOS'
set -e
echo "hostname=$(hostname)"
echo "marker=$(test -f /etc/smm-restore-complete && echo OK || echo MISSING)"
echo "system=$(systemctl is-system-running 2>/dev/null || true)"
echo "ssh=$(systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || echo down)"
df -h / | awk "NR==2{print \"disk=\"\$4\" free\"}"
ss -tln | head -20
EOS
    msg_ok "Remote post-check finished"
}

generate_migration_report() {
    local report="${PROJECT_LOG_DIR}/migration-report-$(timestamp).txt"
    {
        echo "=============================================="
        echo " JOJO BACKUP — Migration Report"
        echo " SMM v${SMM_VERSION:-1.1}"
        echo "=============================================="
        echo "Generated: $(date -Iseconds)"
        echo "Old host : $(hostname)"
        echo "Remote   : ${REMOTE_USER:-}@${REMOTE_HOST:-}:${REMOTE_PORT:-}"
        echo
        echo "--- Latest backup ---"
        local latest
        latest="$(ls -1t "${BACKUP_DIR}"/server-backup-*.tar.zst 2>/dev/null | head -1)"
        if [[ -n "$latest" ]]; then
            echo "File: $latest"
            [[ -f "${latest}.manifest" ]] && cat "${latest}.manifest"
            [[ -f "${latest}.sha256" ]] && echo "SHA256: $(cat "${latest}.sha256")"
        else
            echo "(none)"
        fi
        echo
        echo "--- Disk ---"
        df -hT
        echo
        echo "--- Listening ---"
        ss -tuln 2>/dev/null | head -40 || true
    } > "$report"
    msg_ok "Report written: $report"
    echo "$report"
}

schedule_backup_cron() {
    msg_info "Install weekly full backup cron?"
    read -r -p "Day of week (0=Sun..6=Sat) [0]: " dow
    dow="${dow:-0}"
    read -r -p "Hour (0-23) [3]: " hour
    hour="${hour:-3}"
    local line="${hour} * * * ${dow} root ${SCRIPT_DIR}/migrate.sh backup >> ${LOG_DIR}/cron-backup.log 2>&1"
    # Actually cron format: min hour dom mon dow
    line="0 ${hour} * * ${dow} root ${SCRIPT_DIR}/migrate.sh backup >> ${LOG_DIR}/cron-backup.log 2>&1"
    echo "$line" > /etc/cron.d/smm-jojo-backup
    chmod 644 /etc/cron.d/smm-jojo-backup
    msg_ok "Cron installed: /etc/cron.d/smm-jojo-backup"
    msg_dim "$line"
}

install_systemd_timer() {
    cat > /etc/systemd/system/smm-backup.service <<EOF
[Unit]
Description=JOJO BACKUP — SMM full server backup
After=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/migrate.sh backup
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF

    cat > /etc/systemd/system/smm-backup.timer <<EOF
[Unit]
Description=Weekly JOJO BACKUP timer

[Timer]
OnCalendar=Sun *-*-* 03:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now smm-backup.timer
    msg_ok "systemd timer enabled (Sundays 03:00)"
    systemctl list-timers smm-backup.timer --no-pager || true
}
