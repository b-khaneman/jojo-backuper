#!/usr/bin/env bash
#===============================================================================
# MODULE: SSL / TLS Certificate Backup & Restore
# SERVER MIGRATION MANAGER v1.0 | JOJO BACKUP
#===============================================================================

backup_ssl() {
    local out="${1:-}"
    [[ -z "$out" ]] && out="${METADATA_DIR:-/tmp}/ssl"
    mkdir -p "$out"

    msg_info "Backing up SSL certificates and keys..."

    # Let's Encrypt
    if [[ -d /etc/letsencrypt ]]; then
        cp -a /etc/letsencrypt "$out/" 2>/dev/null || true
        msg_dim "  /etc/letsencrypt copied"
    fi

    # System SSL
    if [[ -d /etc/ssl ]]; then
        mkdir -p "$out/etc-ssl"
        # Copy certs and private (preserve perms)
        cp -a /etc/ssl/certs "$out/etc-ssl/" 2>/dev/null || true
        cp -a /etc/ssl/private "$out/etc-ssl/" 2>/dev/null || true
        [[ -f /etc/ssl/openssl.cnf ]] && cp -a /etc/ssl/openssl.cnf "$out/etc-ssl/" 2>/dev/null || true
        msg_dim "  /etc/ssl copied"
    fi

    # Common web server cert paths
    for d in /etc/nginx/ssl /etc/nginx/certs /etc/apache2/ssl /etc/httpd/ssl \
             /etc/haproxy/certs /usr/local/share/ca-certificates; do
        if [[ -d "$d" ]]; then
            local name
            name="$(echo "$d" | sed 's|^/||;s|/|_|g')"
            cp -a "$d" "$out/${name}" 2>/dev/null || true
            msg_dim "  $d copied"
        fi
    done

    # Certbot renewal hooks / timers
    systemctl list-timers 'certbot*' --no-pager > "$out/certbot.timers" 2>/dev/null || true
    [[ -d /etc/letsencrypt/renewal ]] && ls -la /etc/letsencrypt/renewal > "$out/renewal.list" 2>/dev/null || true

    # Snapshot of certificate expiry info
    if check_command openssl && [[ -d /etc/letsencrypt/live ]]; then
        mkdir -p "$out/cert-info"
        local domain
        for domain in /etc/letsencrypt/live/*/; do
            [[ -d "$domain" ]] || continue
            local dname
            dname="$(basename "$domain")"
            [[ "$dname" == "README" ]] && continue
            if [[ -f "${domain}/fullchain.pem" ]]; then
                openssl x509 -in "${domain}/fullchain.pem" -noout -subject -issuer -dates \
                    > "$out/cert-info/${dname}.txt" 2>/dev/null || true
            fi
        done
    fi

    msg_ok "SSL backup completed"
    log_ok "SSL backup → $out"
}

restore_ssl() {
    local src="${1:-}"
    [[ -z "$src" || ! -d "$src" ]] && { msg_warn "No SSL backup found"; return 0; }

    if [[ "${RESTORE_SSL:-yes}" != "yes" ]]; then
        msg_dim "SSL restore skipped (config)"
        return 0
    fi

    msg_step "Restoring SSL certificates..."
    log_info "Restoring SSL from $src"

    if [[ -d "$src/letsencrypt" ]]; then
        mkdir -p /etc/letsencrypt
        # Backup existing
        [[ -d /etc/letsencrypt ]] && [[ -n "$(ls -A /etc/letsencrypt 2>/dev/null)" ]] && \
            cp -a /etc/letsencrypt "/etc/letsencrypt.smm-bak.$(date +%s)" 2>/dev/null || true
        cp -a "$src/letsencrypt/." /etc/letsencrypt/
        # Fix permissions
        chmod 0700 /etc/letsencrypt/live /etc/letsencrypt/archive 2>/dev/null || true
        find /etc/letsencrypt/archive -name 'privkey*.pem' -exec chmod 0600 {} \; 2>/dev/null || true
        msg_ok "  Let's Encrypt restored"
    fi

    if [[ -d "$src/etc-ssl" ]]; then
        [[ -d "$src/etc-ssl/certs" ]] && cp -a "$src/etc-ssl/certs/." /etc/ssl/certs/ 2>/dev/null || true
        if [[ -d "$src/etc-ssl/private" ]]; then
            mkdir -p /etc/ssl/private
            cp -a "$src/etc-ssl/private/." /etc/ssl/private/
            chmod 0700 /etc/ssl/private
            find /etc/ssl/private -type f -exec chmod 0600 {} \; 2>/dev/null || true
        fi
        msg_ok "  /etc/ssl restored"
    fi

    # Other common paths
    for item in "$src"/etc_nginx_ssl "$src"/etc_nginx_certs "$src"/etc_apache2_ssl \
                "$src"/etc_haproxy_certs "$src"/usr_local_share_ca-certificates; do
        [[ -d "$item" ]] || continue
        case "$(basename "$item")" in
            etc_nginx_ssl) mkdir -p /etc/nginx/ssl; cp -a "$item/." /etc/nginx/ssl/ ;;
            etc_nginx_certs) mkdir -p /etc/nginx/certs; cp -a "$item/." /etc/nginx/certs/ ;;
            etc_apache2_ssl) mkdir -p /etc/apache2/ssl; cp -a "$item/." /etc/apache2/ssl/ ;;
            etc_haproxy_certs) mkdir -p /etc/haproxy/certs; cp -a "$item/." /etc/haproxy/certs/ ;;
            usr_local_share_ca-certificates)
                mkdir -p /usr/local/share/ca-certificates
                cp -a "$item/." /usr/local/share/ca-certificates/
                update-ca-certificates 2>/dev/null || true
                ;;
        esac
    done

    # Re-enable certbot timer if present
    systemctl enable certbot.timer 2>/dev/null || true
    systemctl start certbot.timer 2>/dev/null || true

    msg_ok "SSL restore completed"
    log_ok "SSL restore completed"
}
