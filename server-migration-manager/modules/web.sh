#!/usr/bin/env bash
#===============================================================================
# MODULE: Web stack — nginx / apache / php-fpm / caddy
# SERVER MIGRATION MANAGER v1.1 | JOJO BACKUP
#===============================================================================

backup_web() {
    local out="${1:-}"
    [[ -z "$out" ]] && out="${METADATA_DIR:-/tmp}/web"
    mkdir -p "$out"

    msg_info "Backing up web server configs..."

    for d in /etc/nginx /etc/apache2 /etc/httpd /etc/caddy /etc/php /etc/letsencrypt; do
        if [[ -d "$d" ]]; then
            local name
            name="$(basename "$d")"
            # letsencrypt also in ssl module; skip duplicate heavy copy if ssl already ran
            [[ "$name" == "letsencrypt" ]] && continue
            cp -a "$d" "$out/" 2>/dev/null || true
            msg_dim "  $d"
        fi
    done

    # Document roots listing (content is in /var /srv via full backup)
    mkdir -p "$out/docroots"
    for d in /var/www /srv/www /usr/share/nginx/html; do
        [[ -d "$d" ]] || continue
        du -sh "$d"/* > "$out/docroots/$(echo "$d" | tr '/' '_').sizes" 2>/dev/null || true
        find "$d" -maxdepth 3 -type f \( -name '*.conf' -o -name '.env' -o -name 'wp-config.php' \) \
            > "$out/docroots/$(echo "$d" | tr '/' '_').important" 2>/dev/null || true
    done

    # Enabled sites snapshot
    [[ -d /etc/nginx/sites-enabled ]] && ls -la /etc/nginx/sites-enabled > "$out/nginx-sites-enabled.txt" 2>/dev/null || true
    [[ -d /etc/apache2/sites-enabled ]] && ls -la /etc/apache2/sites-enabled > "$out/apache-sites-enabled.txt" 2>/dev/null || true

    # Test configs if binaries exist
    nginx -t > "$out/nginx-t.txt" 2>&1 || true
    apache2ctl -t > "$out/apache-t.txt" 2>&1 || apachectl -t > "$out/apache-t.txt" 2>&1 || true

    msg_ok "Web config backup completed"
    log_ok "Web backup → $out"
}

restore_web() {
    local src="${1:-}"
    [[ -z "$src" || ! -d "$src" ]] && { msg_warn "No web backup found"; return 0; }
    [[ "${RESTORE_WEB:-yes}" == "yes" ]] || { msg_dim "Web restore skipped"; return 0; }

    msg_step "Restoring web server configs..."

    if [[ -d "$src/nginx" ]]; then
        apt-get install -y nginx 2>/dev/null || true
        cp -a "$src/nginx/." /etc/nginx/ 2>/dev/null || true
        nginx -t 2>/dev/null && systemctl enable nginx && systemctl restart nginx 2>/dev/null || \
            msg_warn "  nginx config restored but test/restart failed — fix manually"
        msg_ok "  nginx restored"
    fi

    if [[ -d "$src/apache2" ]]; then
        apt-get install -y apache2 2>/dev/null || true
        cp -a "$src/apache2/." /etc/apache2/ 2>/dev/null || true
        apache2ctl -t 2>/dev/null && systemctl enable apache2 && systemctl restart apache2 2>/dev/null || true
        msg_ok "  apache2 restored"
    fi

    if [[ -d "$src/php" ]]; then
        cp -a "$src/php/." /etc/php/ 2>/dev/null || true
        systemctl restart 'php*-fpm' 2>/dev/null || true
        msg_ok "  php configs restored"
    fi

    if [[ -d "$src/caddy" ]]; then
        cp -a "$src/caddy/." /etc/caddy/ 2>/dev/null || true
        systemctl restart caddy 2>/dev/null || true
    fi

    msg_ok "Web restore completed"
    log_ok "Web restore completed"
}
