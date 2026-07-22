#!/usr/bin/env bash
#===============================================================================
# MODULE: Backup encryption (GPG / OpenSSL) + optional split
# JOJO BACKUPER v1.1.1 | @B_KHANEMAN
#===============================================================================

# Sets global: ENCRYPTED_BACKUP_FILE (path to encrypted artifact)
encrypt_backup_file() {
    local file="$1"
    ENCRYPTED_BACKUP_FILE=""
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

    # Keep encrypted as sibling file (.gpg / .enc) — do NOT overwrite .tar.zst
    local plain="$file"
    {
        echo "archive=$(basename "$out")"
        echo "path=$out"
        echo "plaintext=$(basename "$plain")"
        echo "created=$(date -Iseconds)"
        echo "encrypted=yes"
        echo "encrypt_method=${ENCRYPT_METHOD}"
        echo "smm_version=${SMM_VERSION:-1.1.1}"
    } > "${out}.manifest"

    create_checksum "$out"

    # Remove plaintext after successful encrypt (safer default)
    if [[ "${KEEP_PLAINTEXT_AFTER_ENCRYPT:-no}" != "yes" ]]; then
        rm -f "$plain" "${plain}.sha256"
        # Keep a pointer from old manifest name if present
        [[ -f "${plain}.manifest" ]] && mv -f "${plain}.manifest" "${plain}.manifest.pre-encrypt" 2>/dev/null || true
        msg_info "Plaintext archive removed (KEEP_PLAINTEXT_AFTER_ENCRYPT=no)"
    fi

    ENCRYPTED_BACKUP_FILE="$out"
    msg_ok "Encrypted archive: $out"
    log_ok "Encrypted → $out via $ENCRYPT_METHOD"
    return 0
}

# Sets global: DECRYPTED_BACKUP_FILE
decrypt_backup_file() {
    local file="$1"
    local dest="${2:-/tmp/smm-decrypted-$$.tar.zst}"
    DECRYPTED_BACKUP_FILE=""
    [[ -f "$file" ]] || return 1

    local method="${ENCRYPT_METHOD:-gpg}"
    local manifest=""
    for manifest in "${file}.manifest" "${file%.gpg}.manifest" "${file%.enc}.manifest"; do
        if [[ -f "$manifest" ]] && grep -q 'encrypted=yes' "$manifest" 2>/dev/null; then
            method="$(grep '^encrypt_method=' "$manifest" | head -1 | cut -d= -f2)"
            method="${method:-gpg}"
            break
        fi
    done

    # Auto-detect by extension
    case "$file" in
        *.gpg) method="gpg" ;;
        *.enc) method="openssl" ;;
    esac

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
            [[ -n "${ENCRYPT_PASSPHRASE:-}" ]] || die "ENCRYPT_PASSPHRASE required to decrypt"
            openssl enc -d -aes-256-cbc -pbkdf2 -in "$file" -out "$dest" \
                -pass pass:"${ENCRYPT_PASSPHRASE}" || return 1
            ;;
        *)
            msg_error "Unknown decrypt method: $method"
            return 1
            ;;
    esac

    DECRYPTED_BACKUP_FILE="$dest"
    msg_ok "Decrypted → $dest"
    log_ok "Decrypted $file → $dest"
    return 0
}

is_encrypted_backup() {
    local file="$1"
    [[ -f "${file}.manifest" ]] && grep -q 'encrypted=yes' "${file}.manifest" 2>/dev/null && return 0
    case "$file" in
        *.gpg|*.enc) return 0 ;;
    esac
    return 1
}

split_backup_if_needed() {
    local file="$1"
    local size_mb="${SPLIT_SIZE_MB:-0}"
    [[ "$size_mb" =~ ^[0-9]+$ ]] || return 0
    [[ "$size_mb" -gt 0 ]] || return 0

    msg_step "Splitting backup into ${size_mb}MB chunks..."
    local prefix="${file}.part."
    split -b "${size_mb}M" -d "$file" "$prefix" || return 1
    # Absolute paths in parts list for safe join
    ls -1 "$prefix"* | while read -r p; do
        readlink -f "$p" 2>/dev/null || realpath "$p" 2>/dev/null || echo "$p"
    done > "${file}.parts.list"
    msg_ok "Split parts listed in ${file}.parts.list"
    log_ok "Split backup $file into ${size_mb}MB parts"
}

join_backup_parts() {
    local listfile="$1"
    local dest="$2"
    [[ -f "$listfile" ]] || return 1
    msg_step "Joining split parts..."
    : > "$dest"
    local part
    while IFS= read -r part; do
        [[ -z "$part" ]] && continue
        [[ -f "$part" ]] || { msg_error "Missing part: $part"; return 1; }
        cat "$part" >> "$dest" || return 1
    done < "$listfile"
    msg_ok "Joined → $dest"
}
