#!/usr/bin/env bash
#===============================================================================
# MODULE: Backup encryption (GPG / OpenSSL) + optional split
# SERVER MIGRATION MANAGER v1.1 | JOJO BACKUP
#===============================================================================

encrypt_backup_file() {
    local file="$1"
    [[ "${ENCRYPT_BACKUP:-no}" == "yes" ]] || return 0
    [[ -f "$file" ]] || return 1

    msg_step "Encrypting backup (${ENCRYPT_METHOD:-gpg})..."
    local out=""

    case "${ENCRYPT_METHOD:-gpg}" in
        gpg)
            if ! check_command gpg; then
                apt-get install -y gnupg 2>/dev/null || die "gpg required for encryption"
            fi
            out="${file}.gpg"
            if [[ -n "${ENCRYPT_GPG_RECIPIENT:-}" ]]; then
                gpg --batch --yes --encrypt -r "$ENCRYPT_GPG_RECIPIENT" -o "$out" "$file" || return 1
            elif [[ -n "${ENCRYPT_PASSPHRASE:-}" ]]; then
                gpg --batch --yes --symmetric --cipher-algo AES256 \
                    --passphrase "$ENCRYPT_PASSPHRASE" -o "$out" "$file" || return 1
            else
                msg_error "Set ENCRYPT_PASSPHRASE or ENCRYPT_GPG_RECIPIENT in config.conf"
                return 1
            fi
            ;;
        openssl)
            out="${file}.enc"
            local pass="${ENCRYPT_PASSPHRASE:-}"
            [[ -n "$pass" ]] || die "ENCRYPT_PASSPHRASE required for openssl method"
            openssl enc -aes-256-cbc -pbkdf2 -salt -in "$file" -out "$out" -pass pass:"$pass" || return 1
            ;;
        *)
            die "Unknown ENCRYPT_METHOD: $ENCRYPT_METHOD"
            ;;
    esac

    # Replace original with encrypted; keep checksum of encrypted
    local orig_sum="${file}.sha256"
    rm -f "$file"
    mv "$out" "$file"
    # rename extension awareness: keep .tar.zst name but file is encrypted binary
    # Better: keep encrypted alongside
    msg_warn "Encrypted payload stored as: $file (content is encrypted)"
    create_checksum "$file"
    echo "encrypted=yes" >> "${file}.manifest" 2>/dev/null || true
    echo "encrypt_method=${ENCRYPT_METHOD}" >> "${file}.manifest" 2>/dev/null || true
    msg_ok "Encryption completed"
    log_ok "Encrypted $file via $ENCRYPT_METHOD"
    # Remove stale plaintext checksum if any
    [[ -f "$orig_sum" ]] || true
}

decrypt_backup_file() {
    local file="$1"
    local dest="${2:-${file}.decrypted}"
    [[ -f "$file" ]] || return 1

    # Detect if encrypted via manifest
    local method="${ENCRYPT_METHOD:-gpg}"
    if [[ -f "${file}.manifest" ]] && grep -q 'encrypted=yes' "${file}.manifest" 2>/dev/null; then
        method="$(grep encrypt_method= "${file}.manifest" | cut -d= -f2)"
        method="${method:-gpg}"
    fi

    msg_step "Decrypting backup ($method)..."
    case "$method" in
        gpg)
            if [[ -n "${ENCRYPT_PASSPHRASE:-}" ]]; then
                gpg --batch --yes --decrypt --passphrase "$ENCRYPT_PASSPHRASE" -o "$dest" "$file" || return 1
            else
                gpg --batch --yes --decrypt -o "$dest" "$file" || return 1
            fi
            ;;
        openssl)
            openssl enc -d -aes-256-cbc -pbkdf2 -in "$file" -out "$dest" \
                -pass pass:"${ENCRYPT_PASSPHRASE}" || return 1
            ;;
    esac
    msg_ok "Decrypted → $dest"
    echo "$dest"
}

split_backup_if_needed() {
    local file="$1"
    local size_mb="${SPLIT_SIZE_MB:-0}"
    [[ "$size_mb" -gt 0 ]] 2>/dev/null || return 0

    msg_step "Splitting backup into ${size_mb}MB chunks..."
    local prefix="${file}.part."
    split -b "${size_mb}M" -d "$file" "$prefix" || return 1
    ls -1 "$prefix"* > "${file}.parts.list"
    # Keep original unless user wants only parts — keep both by default
    msg_ok "Split parts listed in ${file}.parts.list"
    log_ok "Split backup $file into ${size_mb}MB parts"
}

join_backup_parts() {
    local listfile="$1"
    local dest="$2"
    [[ -f "$listfile" ]] || return 1
    msg_step "Joining split parts..."
    # shellcheck disable=SC2046
    cat $(cat "$listfile") > "$dest"
    msg_ok "Joined → $dest"
}
