#!/usr/bin/env bash
#===============================================================================
# MODULE: Network Backup & Restore
# SERVER MIGRATION MANAGER v1.0 | JOJO BACKUP
#===============================================================================

backup_network() {
    local out="${1:-}"
    [[ -z "$out" ]] && out="${METADATA_DIR:-/tmp}/network"
    mkdir -p "$out"

    msg_info "Backing up network configuration..."

    # Config directories
    [[ -d /etc/netplan ]] && cp -a /etc/netplan "$out/" 2>/dev/null || true
    [[ -d /etc/network ]] && cp -a /etc/network "$out/" 2>/dev/null || true
    [[ -d /etc/systemd/network ]] && mkdir -p "$out/systemd" && cp -a /etc/systemd/network "$out/systemd/" 2>/dev/null || true
    [[ -f /etc/resolv.conf ]] && cp -a /etc/resolv.conf "$out/" 2>/dev/null || true
    [[ -f /etc/hosts ]] && cp -a /etc/hosts "$out/" 2>/dev/null || true
    [[ -f /etc/hostname ]] && cp -a /etc/hostname "$out/" 2>/dev/null || true

    # Runtime state
    ip addr > "$out/ip_addr.txt" 2>/dev/null || true
    ip -d link > "$out/ip_link.txt" 2>/dev/null || true
    ip route show table all > "$out/ip_route.txt" 2>/dev/null || true
    ip rule list > "$out/ip_rule.txt" 2>/dev/null || true
    ip -br addr > "$out/ip_br_addr.txt" 2>/dev/null || true

    # sysctl
    sysctl -a > "$out/sysctl_all.txt" 2>/dev/null || true
    [[ -d /etc/sysctl.d ]] && cp -a /etc/sysctl.d "$out/" 2>/dev/null || true
    [[ -f /etc/sysctl.conf ]] && cp -a /etc/sysctl.conf "$out/" 2>/dev/null || true

    # DNS / systemd-resolved
    [[ -d /etc/systemd/resolved.conf.d ]] && cp -a /etc/systemd/resolved.conf.d "$out/" 2>/dev/null || true
    [[ -f /etc/systemd/resolved.conf ]] && cp -a /etc/systemd/resolved.conf "$out/" 2>/dev/null || true
    resolvectl status > "$out/resolvectl.txt" 2>/dev/null || true

    # NetworkManager (if present)
    [[ -d /etc/NetworkManager ]] && cp -a /etc/NetworkManager "$out/" 2>/dev/null || true

    msg_ok "Network configuration backed up"
    log_ok "Network backup → $out"
}

restore_network() {
    local src="${1:-}"
    [[ -z "$src" || ! -d "$src" ]] && { msg_warn "No network backup found to restore"; return 0; }

    if [[ "${KEEP_TARGET_NETWORK:-yes}" == "yes" ]]; then
        msg_warn "Keeping NEW server network (KEEP_TARGET_NETWORK=yes) — old netplan NOT applied"
        msg_dim "  Old network configs saved for reference under extras only"
        return 0
    fi

    if [[ "${RESTORE_NETWORK:-no}" != "yes" ]]; then
        msg_dim "Network restore skipped (config)"
        return 0
    fi

    msg_step "Restoring network configuration..."
    log_info "Restoring network from $src"

    # Prefer netplan on Ubuntu
    if [[ -d "$src/netplan" ]]; then
        mkdir -p /etc/netplan
        # Backup existing
        mkdir -p /etc/netplan.smm-bak
        cp -a /etc/netplan/* /etc/netplan.smm-bak/ 2>/dev/null || true
        cp -a "$src/netplan/." /etc/netplan/ 2>/dev/null || true
        msg_info "Restored /etc/netplan"
    fi

    if [[ -d "$src/network" ]]; then
        cp -a "$src/network/." /etc/network/ 2>/dev/null || true
        msg_info "Restored /etc/network"
    fi

    if [[ -d "$src/systemd/network" ]]; then
        mkdir -p /etc/systemd/network
        cp -a "$src/systemd/network/." /etc/systemd/network/ 2>/dev/null || true
        msg_info "Restored /etc/systemd/network"
    fi

    [[ -f "$src/hosts" ]] && cp -a "$src/hosts" /etc/hosts
    [[ -f "$src/hostname" ]] && cp -a "$src/hostname" /etc/hostname
    [[ -f "$src/sysctl.conf" ]] && cp -a "$src/sysctl.conf" /etc/sysctl.conf
    [[ -d "$src/sysctl.d" ]] && cp -a "$src/sysctl.d/." /etc/sysctl.d/ 2>/dev/null || true

    if [[ -d "$src/resolved.conf.d" ]]; then
        mkdir -p /etc/systemd/resolved.conf.d
        cp -a "$src/resolved.conf.d/." /etc/systemd/resolved.conf.d/ 2>/dev/null || true
    fi

    # Apply sysctl
    sysctl --system >/dev/null 2>&1 || true

    # Try netplan apply (may fail if interfaces differ — non-fatal)
    if check_command netplan; then
        msg_info "Applying netplan (non-fatal if interfaces differ)..."
        netplan generate 2>/dev/null || true
        # Do NOT auto-apply netplan on restore of remote VPS with different NICs —
        # leave configs in place for admin review, attempt apply carefully
        netplan try --timeout 5 2>/dev/null || netplan apply 2>/dev/null || \
            msg_warn "netplan apply deferred — review /etc/netplan after reboot"
    fi

    msg_ok "Network configuration restored"
    log_ok "Network restore completed"
}
