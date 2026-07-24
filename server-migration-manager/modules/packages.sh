#!/usr/bin/env bash
#===============================================================================
# MODULE: Package restore — APT sources + dpkg selections
# SERVER MIGRATION MANAGER v1.1 | JOJO BACKUP
#===============================================================================

backup_packages_extra() {
    local out="${1:-}"
    [[ -z "$out" ]] && out="${METADATA_DIR:-/tmp}/packages"
    mkdir -p "$out"

    msg_info "Backing up APT sources and package state..."

    [[ -d /etc/apt ]] && cp -a /etc/apt "$out/" 2>/dev/null || true
    dpkg --get-selections > "$out/selections.txt" 2>/dev/null || true
    apt-mark showmanual > "$out/manual.txt" 2>/dev/null || true
    apt-mark showhold > "$out/hold.txt" 2>/dev/null || true
    dpkg -l > "$out/dpkg-l.txt" 2>/dev/null || true

    if check_command snap; then
        snap list > "$out/snap.list" 2>/dev/null || true
    fi

    check_command pip3 && pip3 freeze > "$out/pip3.freeze" 2>/dev/null || true
    check_command npm && npm list -g --depth=0 > "$out/npm-global.txt" 2>/dev/null || true
    dpkg -l 'linux-image-*' 'linux-headers-*' > "$out/kernels.txt" 2>/dev/null || true

    msg_ok "Package metadata saved"
    log_ok "Packages extra → $out"
}

restore_packages() {
    local src="${1:-}"
    [[ "${RESTORE_PACKAGES:-yes}" == "yes" ]] || { msg_dim "Package restore skipped"; return 0; }

    msg_step "Restoring APT sources and packages..."

    if [[ -n "$src" && -d "$src/apt" ]]; then
        mkdir -p /etc/apt.smm-bak
        cp -a /etc/apt /etc/apt.smm-bak/ 2>/dev/null || true
        [[ -f "$src/apt/sources.list" ]] && cp -a "$src/apt/sources.list" /etc/apt/
        [[ -d "$src/apt/sources.list.d" ]] && cp -a "$src/apt/sources.list.d/." /etc/apt/sources.list.d/ 2>/dev/null || true
        [[ -d "$src/apt/trusted.gpg.d" ]] && cp -a "$src/apt/trusted.gpg.d/." /etc/apt/trusted.gpg.d/ 2>/dev/null || true
        [[ -d "$src/apt/keyrings" ]] && mkdir -p /etc/apt/keyrings && cp -a "$src/apt/keyrings/." /etc/apt/keyrings/ 2>/dev/null || true
        [[ -d "$src/apt/preferences.d" ]] && cp -a "$src/apt/preferences.d/." /etc/apt/preferences.d/ 2>/dev/null || true
        msg_ok "  APT sources restored"
    fi

    apt-get update -qq 2>/dev/null || apt-get update || true

    local sel=""
    [[ -n "$src" && -f "$src/selections.txt" ]] && sel="$src/selections.txt"
    if [[ -z "$sel" && -n "${SMM_SESSION_DIR:-}" && -f "${SMM_SESSION_DIR}/metadata/packages.dpkg" ]]; then
        sel="${SMM_SESSION_DIR}/metadata/packages.dpkg"
    fi

    if [[ -n "$sel" && -f "$sel" ]]; then
        msg_info "  Applying dpkg selections (this can take a long time)..."
        awk '$2=="install"{print}' "$sel" > /tmp/smm-selections.install 2>/dev/null || cp "$sel" /tmp/smm-selections.install
        dpkg --set-selections < /tmp/smm-selections.install 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get -y dselect-upgrade \
            2>>"${LOG_DIR:-/var/log/server-migration}/restore.log" || \
            DEBIAN_FRONTEND=noninteractive apt-get -y --fix-missing install 2>/dev/null || \
            msg_warn "  Some packages failed to install — review restore.log"
        msg_ok "  Package selections applied"
    else
        msg_dim "  No package selections file found"
    fi

    if [[ -n "$src" && -f "$src/hold.txt" ]]; then
        while read -r pkg; do
            [[ -z "$pkg" ]] && continue
            apt-mark hold "$pkg" 2>/dev/null || true
        done < "$src/hold.txt"
    fi

    msg_ok "Package restore phase completed"
    log_ok "Package restore completed"
}

# After /etc restore without /usr, old cloud virt apt hooks (e.g. apt_hook_ubuntu_virt)
# break apt-get. Drop conf lines that reference missing /usr binaries.
repair_apt_after_restore() {
    local confdir="/etc/apt/apt.conf.d"
    [[ -d "$confdir" ]] || return 0

    local f repaired=0
    shopt -s nullglob
    for f in "$confdir"/*; do
        [[ -f "$f" && -r "$f" ]] || continue

        local refs missing=0
        refs="$(grep -oE '/usr/[^"'\''[:space:];{}]+' "$f" 2>/dev/null || true)"
        [[ -z "$refs" ]] && continue

        while IFS= read -r ref; do
            [[ -z "$ref" ]] && continue
            if [[ ! -e "$ref" ]]; then
                missing=1
                break
            fi
        done <<< "$refs"
        [[ $missing -eq 0 ]] && continue

        local tmp
        tmp="$(mktemp)" || continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            local skip=0
            while IFS= read -r ref; do
                [[ -z "$ref" ]] && continue
                if [[ ! -e "$ref" ]]; then
                    skip=1
                    msg_warn "  Dropping apt hook ($(basename "$f")): missing $ref"
                    break
                fi
            done < <(echo "$line" | grep -oE '/usr/[^"'\''[:space:];{}]+' 2>/dev/null || true)
            if [[ $skip -eq 1 ]]; then
                repaired=1
                continue
            fi
            printf '%s\n' "$line" >> "$tmp"
        done < "$f"

        if [[ ! -s "$tmp" ]]; then
            rm -f "$f"
        else
            cat "$tmp" > "$f"
        fi
        rm -f "$tmp"
    done
    shopt -u nullglob

    if [[ $repaired -eq 1 ]]; then
        msg_ok "Repaired apt.conf.d (removed hooks to missing binaries)"
        log_ok "repair_apt_after_restore cleaned broken hooks"
    fi
    return 0
}
