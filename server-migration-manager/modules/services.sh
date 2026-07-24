#!/usr/bin/env bash
#===============================================================================
# MODULE: Systemd Services Backup & Restore
# SERVER MIGRATION MANAGER v1.0 | JOJO BACKUP
#===============================================================================

backup_services() {
    local out="${1:-}"
    [[ -z "$out" ]] && out="${METADATA_DIR:-/tmp}/services"
    mkdir -p "$out"

    msg_info "Backing up systemd service state..."

    systemctl list-units --type=service --all --no-pager > "$out/all-services.txt" 2>/dev/null || true
    systemctl list-units --type=service --state=running --no-pager > "$out/running.txt" 2>/dev/null || true
    systemctl list-unit-files --type=service --state=enabled --no-pager > "$out/enabled.txt" 2>/dev/null || true
    systemctl list-unit-files --type=service --state=disabled --no-pager > "$out/disabled.txt" 2>/dev/null || true
    systemctl list-timers --all --no-pager > "$out/timers.txt" 2>/dev/null || true
    systemctl list-sockets --all --no-pager > "$out/sockets.txt" 2>/dev/null || true

    # Custom unit files
    mkdir -p "$out/units/system" "$out/units/user"
    cp -a /etc/systemd/system/*.service "$out/units/system/" 2>/dev/null || true
    cp -a /etc/systemd/system/*.timer "$out/units/system/" 2>/dev/null || true
    cp -a /etc/systemd/system/*.socket "$out/units/system/" 2>/dev/null || true
    # Copy drop-in directories
    find /etc/systemd/system -mindepth 1 -maxdepth 1 -type d -name '*.d' -o -name '*.service.d' \
        2>/dev/null | while read -r d; do
        cp -a "$d" "$out/units/system/" 2>/dev/null || true
    done
    # Also copy entire custom tree selectively
    rsync -a --include='*/' --include='*.service' --include='*.timer' --include='*.socket' \
        --include='*.conf' --exclude='*' /etc/systemd/system/ "$out/units/system-full/" 2>/dev/null || true

    # Enabled unit list (machine-readable)
    systemctl list-unit-files --type=service --state=enabled --no-legend --no-pager \
        | awk '{print $1}' > "$out/enabled.list" 2>/dev/null || true

    msg_ok "Services state backed up"
    log_ok "Services backup → $out"
}

restore_services() {
    local src="${1:-}"
    [[ -z "$src" || ! -d "$src" ]] && { msg_warn "No services backup found"; return 0; }

    msg_step "Restoring systemd services..."
    log_info "Restoring services from $src"

    # Restore custom unit files
    if [[ -d "$src/units/system-full" ]]; then
        cp -a "$src/units/system-full/." /etc/systemd/system/ 2>/dev/null || true
    elif [[ -d "$src/units/system" ]]; then
        cp -a "$src/units/system/." /etc/systemd/system/ 2>/dev/null || true
    fi

    systemctl daemon-reload

    # Re-enable services from list
    if [[ -f "$src/enabled.list" ]]; then
        local unit
        while read -r unit; do
            [[ -z "$unit" ]] && continue
            # Skip missing units
            if systemctl cat "$unit" &>/dev/null; then
                systemctl enable "$unit" 2>/dev/null || true
            fi
        done < "$src/enabled.list"
    fi

    # Restart only SSH-safe basics — NOT docker/panel (CPU lock risk)
    local critical=(ssh sshd cron crond)
    local svc
    for svc in "${critical[@]}"; do
        if systemctl list-unit-files "${svc}.service" &>/dev/null; then
            systemctl restart "$svc" 2>/dev/null || true
        fi
    done
    msg_warn "Heavy services (docker/nginx/db) NOT auto-restarted — start manually after SSH check"

    msg_ok "Services restore completed"
    log_ok "Services restore completed"
}
