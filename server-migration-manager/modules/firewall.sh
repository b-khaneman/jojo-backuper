#!/usr/bin/env bash
#===============================================================================
# MODULE: Firewall Backup & Restore (iptables / nftables)
# SERVER MIGRATION MANAGER v1.0 | JOJO BACKUP
#===============================================================================

backup_firewall() {
    local out="${1:-}"
    [[ -z "$out" ]] && out="${METADATA_DIR:-/tmp}/firewall"
    mkdir -p "$out"

    msg_info "Backing up firewall rules..."

    # iptables
    if check_command iptables-save; then
        iptables-save > "$out/iptables.rules" 2>/dev/null || true
        ip6tables-save > "$out/ip6tables.rules" 2>/dev/null || true
        msg_dim "  iptables rules saved"
    fi

    # nftables
    if check_command nft; then
        nft list ruleset > "$out/nftables.ruleset" 2>/dev/null || true
        msg_dim "  nftables ruleset saved"
    fi

    # ufw
    if check_command ufw; then
        ufw status verbose > "$out/ufw.status" 2>/dev/null || true
        [[ -d /etc/ufw ]] && cp -a /etc/ufw "$out/" 2>/dev/null || true
        msg_dim "  ufw config saved"
    fi

    # firewalld
    if check_command firewall-cmd; then
        firewall-cmd --list-all > "$out/firewalld.list" 2>/dev/null || true
        [[ -d /etc/firewalld ]] && cp -a /etc/firewalld "$out/" 2>/dev/null || true
    fi

    # Persist helpers
    [[ -f /etc/iptables/rules.v4 ]] && mkdir -p "$out/etc-iptables" && cp -a /etc/iptables "$out/etc-iptables/" 2>/dev/null || true
    [[ -f /etc/nftables.conf ]] && cp -a /etc/nftables.conf "$out/" 2>/dev/null || true

    msg_ok "Firewall backed up"
    log_ok "Firewall backup → $out"
}

restore_firewall() {
    local src="${1:-}"
    [[ -z "$src" || ! -d "$src" ]] && { msg_warn "No firewall backup found"; return 0; }

    if [[ "${RESTORE_FIREWALL:-yes}" != "yes" ]]; then
        msg_dim "Firewall restore skipped (config)"
        return 0
    fi

    msg_step "Restoring firewall rules..."
    log_info "Restoring firewall from $src"

    # Ensure SSH is not locked out: open port temporarily if needed
    local ssh_port="${REMOTE_PORT:-22}"

    # Prefer nftables if ruleset exists and nft is available
    if [[ -f "$src/nftables.ruleset" ]] && check_command nft && [[ -s "$src/nftables.ruleset" ]]; then
        msg_info "Restoring nftables ruleset..."
        # Flush and reload
        nft flush ruleset 2>/dev/null || true
        if nft -f "$src/nftables.ruleset" 2>/dev/null; then
            msg_ok "nftables restored"
            [[ -f "$src/nftables.conf" ]] && cp -a "$src/nftables.conf" /etc/nftables.conf
        else
            msg_warn "nftables restore had errors — ruleset saved for manual review"
            cp -a "$src/nftables.ruleset" /root/smm-nftables.ruleset.restore
        fi
    fi

    # iptables
    if [[ -f "$src/iptables.rules" ]] && check_command iptables-restore && [[ -s "$src/iptables.rules" ]]; then
        msg_info "Restoring iptables rules..."
        if iptables-restore < "$src/iptables.rules" 2>/dev/null; then
            msg_ok "iptables restored"
        else
            msg_warn "iptables restore had errors — saved to /root/smm-iptables.rules.restore"
            cp -a "$src/iptables.rules" /root/smm-iptables.rules.restore
        fi
        # Persist
        mkdir -p /etc/iptables
        cp -a "$src/iptables.rules" /etc/iptables/rules.v4 2>/dev/null || true
        if check_command netfilter-persistent; then
            netfilter-persistent save 2>/dev/null || true
        fi
    fi

    if [[ -f "$src/ip6tables.rules" ]] && check_command ip6tables-restore; then
        ip6tables-restore < "$src/ip6tables.rules" 2>/dev/null || true
        cp -a "$src/ip6tables.rules" /etc/iptables/rules.v6 2>/dev/null || true
    fi

    # ufw
    if [[ -d "$src/ufw" ]]; then
        msg_info "Restoring UFW configuration..."
        cp -a "$src/ufw/." /etc/ufw/ 2>/dev/null || true
        if check_command ufw; then
            ufw --force reload 2>/dev/null || true
        fi
    fi

    # Safety: ensure SSH port remains reachable
    if check_command iptables; then
        iptables -C INPUT -p tcp --dport "$ssh_port" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport "$ssh_port" -j ACCEPT 2>/dev/null || true
    fi

    msg_ok "Firewall restore completed"
    log_ok "Firewall restore completed"
}
