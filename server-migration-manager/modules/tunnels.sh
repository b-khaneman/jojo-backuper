#!/usr/bin/env bash
#===============================================================================
# MODULE: Tunnel & VPN Backup (WireGuard, GRE, IPIP, VXLAN)
# SERVER MIGRATION MANAGER v1.0 | JOJO BACKUP
#===============================================================================

backup_tunnels() {
    local out="${1:-}"
    [[ -z "$out" ]] && out="${METADATA_DIR:-/tmp}/tunnels"
    mkdir -p "$out"

    msg_info "Backing up tunnels and VPN configuration..."

    # WireGuard
    if [[ -d /etc/wireguard ]]; then
        cp -a /etc/wireguard "$out/" 2>/dev/null || true
        chmod -R go-rwx "$out/wireguard" 2>/dev/null || true
        msg_dim "  /etc/wireguard copied"
    fi
    if check_command wg; then
        wg show all > "$out/wg_show.txt" 2>/dev/null || true
        wg show all dump > "$out/wg_dump.txt" 2>/dev/null || true
    fi
    systemctl list-units 'wg-quick*' --all --no-pager > "$out/wg-quick.units" 2>/dev/null || true

    # Tunnel interfaces (GRE / IPIP / VXLAN / sit / etc.)
    ip -d link show > "$out/ip_link_detail.txt" 2>/dev/null || true
    ip tunnel show > "$out/ip_tunnel.txt" 2>/dev/null || true
    ip -d link show type gre > "$out/gre.txt" 2>/dev/null || true
    ip -d link show type ipip > "$out/ipip.txt" 2>/dev/null || true
    ip -d link show type vxlan > "$out/vxlan.txt" 2>/dev/null || true
    ip -d link show type sit > "$out/sit.txt" 2>/dev/null || true
    ip -d link show type gretap > "$out/gretap.txt" 2>/dev/null || true

    # systemd-networkd tunnel .netdev / .network
    mkdir -p "$out/systemd-network"
    if [[ -d /etc/systemd/network ]]; then
        find /etc/systemd/network -type f \( -name '*.netdev' -o -name '*.network' \) \
            -exec cp -a {} "$out/systemd-network/" \; 2>/dev/null || true
    fi

    # Network scripts that may define tunnels
    mkdir -p "$out/network-scripts"
    for f in /etc/network/interfaces /etc/network/interfaces.d/*; do
        [[ -e "$f" ]] || continue
        if grep -qiE 'gre|ipip|vxlan|wireguard|tunnel' "$f" 2>/dev/null; then
            cp -a "$f" "$out/network-scripts/" 2>/dev/null || true
        fi
    done

    # Netplan tunnel-related
    mkdir -p "$out/netplan-tunnels"
    if [[ -d /etc/netplan ]]; then
        for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
            [[ -f "$f" ]] || continue
            if grep -qiE 'tunnels:|wireguard|vxlan|gre' "$f" 2>/dev/null; then
                cp -a "$f" "$out/netplan-tunnels/" 2>/dev/null || true
            fi
        done
    fi

    # OpenVPN / IPsec extras (bonus)
    [[ -d /etc/openvpn ]] && cp -a /etc/openvpn "$out/" 2>/dev/null || true
    [[ -d /etc/ipsec.d ]] && cp -a /etc/ipsec.d "$out/" 2>/dev/null || true
    [[ -f /etc/ipsec.conf ]] && cp -a /etc/ipsec.conf "$out/" 2>/dev/null || true
    [[ -f /etc/ipsec.secrets ]] && cp -a /etc/ipsec.secrets "$out/" 2>/dev/null || true

    # Custom systemd tunnel services
    mkdir -p "$out/systemd-units"
    find /etc/systemd/system /lib/systemd/system -maxdepth 1 -type f \
        \( -name '*tunnel*' -o -name '*gre*' -o -name '*vxlan*' -o -name '*wg-*' -o -name 'wg-quick*' \) \
        -exec cp -a {} "$out/systemd-units/" \; 2>/dev/null || true

    msg_ok "Tunnels/VPN backed up"
    log_ok "Tunnels backup → $out"
}

restore_tunnels() {
    local src="${1:-}"
    [[ -z "$src" || ! -d "$src" ]] && { msg_warn "No tunnel backup found"; return 0; }

    if [[ "${RESTORE_TUNNELS:-no}" != "yes" ]]; then
        msg_dim "Tunnel restore skipped (safe default — prevents routing/SSH break)"
        # Stage for manual review
        if [[ -d "$src" ]]; then
            mkdir -p /root/smm-tunnels-from-old
            cp -a "$src/." /root/smm-tunnels-from-old/ 2>/dev/null || true
        fi
        return 0
    fi

    msg_step "Restoring tunnels and VPN (files only — no auto-start)..."
    log_info "Restoring tunnels from $src"

    # WireGuard — copy only; do NOT enable/start (can blackhole traffic on new VPS)
    if [[ -d "$src/wireguard" ]]; then
        if ! check_command wg; then
            apt-get update -qq
            apt-get install -y wireguard wireguard-tools 2>/dev/null || true
        fi
        mkdir -p /etc/wireguard /root/smm-wireguard-from-old
        cp -a "$src/wireguard/." /root/smm-wireguard-from-old/
        cp -a "$src/wireguard/." /etc/wireguard/
        chmod 700 /etc/wireguard
        find /etc/wireguard -name '*.conf' -exec chmod 600 {} \; 2>/dev/null || true
        msg_warn "  WireGuard configs copied — NOT started (start manually after SSH check)"
        msg_dim "  Example: systemctl start wg-quick@wg0"
    fi

    # systemd-network tunnel defs — stage only (restarting networkd mid-restore is dangerous)
    if [[ -d "$src/systemd-network" ]] && [[ -n "$(ls -A "$src/systemd-network" 2>/dev/null)" ]]; then
        mkdir -p /root/smm-systemd-network-from-old
        cp -a "$src/systemd-network/." /root/smm-systemd-network-from-old/
        msg_dim "  systemd-network tunnel units staged (not applied live)"
    fi

    # Custom systemd units — copy, do not enable
    if [[ -d "$src/systemd-units" ]]; then
        mkdir -p /root/smm-tunnel-units-from-old
        cp -a "$src/systemd-units/." /root/smm-tunnel-units-from-old/
    fi

    # OpenVPN / IPsec — copy only
    [[ -d "$src/openvpn" ]] && cp -a "$src/openvpn" /root/smm-openvpn-from-old 2>/dev/null || true
    [[ -f "$src/ipsec.conf" ]] && cp -a "$src/ipsec.conf" /root/smm-ipsec.conf.from-old 2>/dev/null || true

    if [[ -f "$src/ip_tunnel.txt" ]] || [[ -f "$src/gre.txt" ]]; then
        mkdir -p /root/smm-tunnel-hints
        cp -a "$src"/gre.txt "$src"/ipip.txt "$src"/vxlan.txt "$src"/ip_tunnel.txt \
            /root/smm-tunnel-hints/ 2>/dev/null || true
    fi

    msg_ok "Tunnel/VPN files staged (no live network changes)"
    log_ok "Tunnel restore completed (safe mode)"
}
