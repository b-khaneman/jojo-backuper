#!/usr/bin/env bash
#===============================================================================
# MODULE: Security — SSH, fail2ban, AppArmor, audit, authorized_keys
# SERVER MIGRATION MANAGER v1.1 | JOJO BACKUP
#===============================================================================

backup_security() {
    local out="${1:-}"
    [[ -z "$out" ]] && out="${METADATA_DIR:-/tmp}/security"
    mkdir -p "$out"

    msg_info "Backing up security configuration..."

    # SSH
    mkdir -p "$out/ssh"
    [[ -d /etc/ssh ]] && cp -a /etc/ssh "$out/" 2>/dev/null || true
    # Per-user authorized_keys / known_hosts
    mkdir -p "$out/user-ssh"
    local home
    for home in /root /home/*; do
        [[ -d "$home/.ssh" ]] || continue
        local user
        user="$(basename "$home")"
        [[ "$home" == /root ]] && user="root"
        mkdir -p "$out/user-ssh/$user"
        cp -a "$home/.ssh" "$out/user-ssh/$user/" 2>/dev/null || true
    done
    sshd -T > "$out/sshd_effective.conf" 2>/dev/null || true

    # fail2ban
    if [[ -d /etc/fail2ban ]]; then
        cp -a /etc/fail2ban "$out/" 2>/dev/null || true
        fail2ban-client status > "$out/fail2ban.status" 2>/dev/null || true
        msg_dim "  fail2ban saved"
    fi

    # AppArmor
    if [[ -d /etc/apparmor.d ]]; then
        mkdir -p "$out/apparmor"
        cp -a /etc/apparmor.d "$out/apparmor/" 2>/dev/null || true
        cp -a /etc/apparmor "$out/apparmor/etc-apparmor" 2>/dev/null || true
        aa-status > "$out/apparmor/aa-status.txt" 2>/dev/null || true
    fi

    # auditd
    [[ -d /etc/audit ]] && cp -a /etc/audit "$out/" 2>/dev/null || true
    [[ -f /etc/audit/auditd.conf ]] && cp -a /etc/audit/auditd.conf "$out/" 2>/dev/null || true

    # pam / login / sudo
    [[ -d /etc/pam.d ]] && cp -a /etc/pam.d "$out/" 2>/dev/null || true
    [[ -f /etc/sudoers ]] && cp -a /etc/sudoers "$out/" 2>/dev/null || true
    [[ -d /etc/sudoers.d ]] && cp -a /etc/sudoers.d "$out/" 2>/dev/null || true
    [[ -f /etc/security/access.conf ]] && mkdir -p "$out/security" && cp -a /etc/security "$out/" 2>/dev/null || true
    [[ -f /etc/login.defs ]] && cp -a /etc/login.defs "$out/" 2>/dev/null || true

    # ClamAV / RKHunter hints
    [[ -d /etc/clamav ]] && cp -a /etc/clamav "$out/" 2>/dev/null || true
    [[ -f /etc/rkhunter.conf ]] && cp -a /etc/rkhunter.conf "$out/" 2>/dev/null || true

    # sysctl security-ish snapshot already in network; keep issue/motd
    [[ -f /etc/issue ]] && cp -a /etc/issue "$out/" 2>/dev/null || true
    [[ -f /etc/motd ]] && cp -a /etc/motd "$out/" 2>/dev/null || true

    msg_ok "Security backup completed"
    log_ok "Security backup → $out"
}

restore_security() {
    local src="${1:-}"
    [[ -z "$src" || ! -d "$src" ]] && { msg_warn "No security backup found"; return 0; }
    [[ "${RESTORE_SECURITY:-yes}" == "yes" ]] || { msg_dim "Security restore skipped"; return 0; }

    msg_step "Restoring security configuration..."

    # SSH config (careful with host keys)
    if [[ -d "$src/ssh/ssh" ]] || [[ -d "$src/ssh" ]]; then
        local sshsrc="$src/ssh"
        [[ -d "$src/ssh/ssh" ]] && sshsrc="$src/ssh/ssh"
        # configs
        cp -a "$sshsrc"/sshd_config "$sshsrc"/ssh_config /etc/ssh/ 2>/dev/null || true
        cp -a "$sshsrc"/sshd_config.d /etc/ssh/ 2>/dev/null || true
        if [[ "${PRESERVE_NEW_SSH_HOST_KEYS:-yes}" != "yes" ]]; then
            cp -a "$sshsrc"/ssh_host_* /etc/ssh/ 2>/dev/null || true
            msg_info "  SSH host keys cloned from old server"
        else
            msg_dim "  Keeping NEW server SSH host keys (PRESERVE_NEW_SSH_HOST_KEYS=yes)"
        fi
    fi

    # User .ssh
    if [[ -d "$src/user-ssh" ]]; then
        local u
        for u in "$src/user-ssh"/*; do
            [[ -d "$u" ]] || continue
            local uname home
            uname="$(basename "$u")"
            if [[ "$uname" == "root" ]]; then home=/root; else home="/home/$uname"; fi
            mkdir -p "$home"
            cp -a "$u/.ssh" "$home/" 2>/dev/null || true
            chown -R "$uname:$uname" "$home/.ssh" 2>/dev/null || true
            chmod 700 "$home/.ssh" 2>/dev/null || true
            chmod 600 "$home/.ssh/"* 2>/dev/null || true
        done
        msg_ok "  User SSH keys restored"
    fi

    # fail2ban
    if [[ -d "$src/fail2ban" ]]; then
        apt-get install -y fail2ban 2>/dev/null || true
        cp -a "$src/fail2ban/." /etc/fail2ban/ 2>/dev/null || true
        systemctl enable fail2ban 2>/dev/null || true
        systemctl restart fail2ban 2>/dev/null || true
        msg_ok "  fail2ban restored"
    fi

    # sudoers
    [[ -f "$src/sudoers" ]] && cp -a "$src/sudoers" /etc/sudoers && chmod 440 /etc/sudoers
    [[ -d "$src/sudoers.d" ]] && cp -a "$src/sudoers.d/." /etc/sudoers.d/ 2>/dev/null || true
    [[ -d "$src/pam.d" ]] && cp -a "$src/pam.d/." /etc/pam.d/ 2>/dev/null || true

    # AppArmor profiles
    if [[ -d "$src/apparmor/apparmor.d" ]]; then
        cp -a "$src/apparmor/apparmor.d/." /etc/apparmor.d/ 2>/dev/null || true
        systemctl reload apparmor 2>/dev/null || true
    fi

    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    msg_ok "Security restore completed"
    log_ok "Security restore completed"
}
