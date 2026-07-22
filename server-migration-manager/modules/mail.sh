#!/usr/bin/env bash
#===============================================================================
# MODULE: Mail — Postfix / Exim / Dovecot / OpenDKIM
# SERVER MIGRATION MANAGER v1.1 | JOJO BACKUP
#===============================================================================

backup_mail() {
    local out="${1:-}"
    [[ -z "$out" ]] && out="${METADATA_DIR:-/tmp}/mail"
    mkdir -p "$out"

    msg_info "Backing up mail server configuration..."

    local any=0
    for d in /etc/postfix /etc/exim4 /etc/dovecot /etc/opendkim /etc/opendmarc \
             /etc/mailman /etc/postfixadmin; do
        if [[ -d "$d" ]]; then
            cp -a "$d" "$out/" 2>/dev/null || true
            any=1
            msg_dim "  $d"
        fi
    done

    [[ -f /etc/aliases ]] && cp -a /etc/aliases "$out/" && any=1
    [[ -f /etc/mailname ]] && cp -a /etc/mailname "$out/" && any=1

    if check_command postconf; then
        postconf -n > "$out/postconf.txt" 2>/dev/null || true
        postqueue -p > "$out/postqueue.txt" 2>/dev/null || true
        any=1
    fi
    if check_command doveconf; then
        doveconf -n > "$out/doveconf.txt" 2>/dev/null || true
        any=1
    fi

    for d in /var/mail /var/spool/mail /var/vmail /home/vmail; do
        [[ -d "$d" ]] || continue
        du -sh "$d" > "$out/$(echo "$d" | tr '/' '_').size" 2>/dev/null || true
    done

    if [[ $any -eq 0 ]]; then
        msg_dim "  No mail stack detected"
        echo "none" > "$out/STATUS.txt"
    else
        echo "ok" > "$out/STATUS.txt"
        msg_ok "Mail config backup completed"
    fi
    log_ok "Mail backup → $out"
}

restore_mail() {
    local src="${1:-}"
    [[ -z "$src" || ! -d "$src" ]] && return 0
    [[ "${RESTORE_MAIL:-yes}" == "yes" ]] || { msg_dim "Mail restore skipped"; return 0; }
    [[ -f "$src/STATUS.txt" && "$(cat "$src/STATUS.txt")" == "none" ]] && return 0

    msg_step "Restoring mail configuration..."

    if [[ -d "$src/postfix" ]]; then
        apt-get install -y postfix 2>/dev/null || true
        cp -a "$src/postfix/." /etc/postfix/ 2>/dev/null || true
        [[ -f "$src/aliases" ]] && cp -a "$src/aliases" /etc/aliases && newaliases 2>/dev/null || true
        [[ -f "$src/mailname" ]] && cp -a "$src/mailname" /etc/mailname
        systemctl enable postfix 2>/dev/null || true
        systemctl restart postfix 2>/dev/null || msg_warn "  postfix restart failed — check hostname/DNS"
        msg_ok "  postfix restored"
    fi

    if [[ -d "$src/dovecot" ]]; then
        apt-get install -y dovecot-core dovecot-imapd 2>/dev/null || true
        cp -a "$src/dovecot/." /etc/dovecot/ 2>/dev/null || true
        systemctl enable dovecot 2>/dev/null || true
        systemctl restart dovecot 2>/dev/null || true
        msg_ok "  dovecot restored"
    fi

    if [[ -d "$src/exim4" ]]; then
        cp -a "$src/exim4/." /etc/exim4/ 2>/dev/null || true
        systemctl restart exim4 2>/dev/null || true
    fi

    [[ -d "$src/opendkim" ]] && cp -a "$src/opendkim/." /etc/opendkim/ 2>/dev/null || true
    [[ -d "$src/opendmarc" ]] && cp -a "$src/opendmarc/." /etc/opendmarc/ 2>/dev/null || true

    msg_ok "Mail restore completed"
    log_ok "Mail restore completed"
}
