#!/usr/bin/env bash
#===============================================================================
# MODULE: Notifications — Webhook / Telegram / Discord
# SERVER MIGRATION MANAGER v1.1 | JOJO BACKUP
#===============================================================================

notify_send() {
    local title="$1"
    local body="$2"
    [[ "${NOTIFY_ENABLED:-no}" == "yes" ]] || return 0

    local host
    host="$(hostname 2>/dev/null || echo unknown)"
    local text="*[JOJO BACKUP / SMM]* ${title}%0AHost: ${host}%0A${body}"

    # Telegram
    if [[ -n "${NOTIFY_TELEGRAM_BOT_TOKEN:-}" && -n "${NOTIFY_TELEGRAM_CHAT_ID:-}" ]]; then
        curl -sS -X POST \
            "https://api.telegram.org/bot${NOTIFY_TELEGRAM_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${NOTIFY_TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=$(echo -e "[JOJO BACKUPER] ${title}\nHost: ${host}\n${body}\n@B_KHANEMAN")" \
            >/dev/null 2>&1 || msg_dim "Telegram notify failed"
    fi

    # Generic / Discord / Slack webhook
    if [[ -n "${NOTIFY_WEBHOOK_URL:-}" ]]; then
        local payload
        payload="$(printf '{"content":"[JOJO BACKUPER] %s — %s\n%s","text":"[JOJO BACKUPER] %s — %s\n%s"}' \
            "$title" "$host" "$body" "$title" "$host" "$body")"
        curl -sS -X POST -H 'Content-Type: application/json' \
            -d "$payload" "$NOTIFY_WEBHOOK_URL" >/dev/null 2>&1 || msg_dim "Webhook notify failed"
    fi

    log_info "Notify: $title — $body"
}

notify_backup_done() {
    local file="$1"
    local size="$2"
    notify_send "Backup OK" "File: $(basename "$file") Size: $size"
}

notify_backup_fail() {
    notify_send "Backup FAILED" "${1:-unknown error}"
}

notify_transfer_done() {
    notify_send "Upload OK" "To: ${REMOTE_HOST} File: $1"
}

notify_restore_done() {
    notify_send "Restore OK" "Target: ${REMOTE_HOST:-local}"
}

notify_restore_fail() {
    notify_send "Restore FAILED" "${1:-unknown}"
}

test_notifications() {
    if [[ "${NOTIFY_ENABLED:-no}" != "yes" ]]; then
        msg_warn "NOTIFY_ENABLED=no — enable in config.conf"
        return 1
    fi
    msg_info "Sending test notification..."
    notify_send "Test" "Notification channel works ($(date -Iseconds))"
    msg_ok "Test notification dispatched"
}
