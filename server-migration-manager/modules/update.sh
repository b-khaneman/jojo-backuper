#!/usr/bin/env bash
#===============================================================================
# MODULE: Self-update from GitHub
# JOJO BACKUPER v1.2.0 | @B_KHANEMAN
#===============================================================================

JOJO_GITHUB_REPO="${JOJO_GITHUB_REPO:-https://github.com/b-khaneman/jojo-backuper.git}"
JOJO_GITHUB_BRANCH="${JOJO_GITHUB_BRANCH:-main}"

_find_repo_root() {
    local dir="${SCRIPT_DIR:-.}"
    # SCRIPT_DIR is .../server-migration-manager → parent is repo root
    if [[ -d "${dir}/../.git" ]]; then
        (cd "${dir}/.." && pwd)
        return 0
    fi
    if [[ -d "${dir}/.git" ]]; then
        (cd "$dir" && pwd)
        return 0
    fi
    if [[ -d /opt/jojo-backuper/.git ]]; then
        echo "/opt/jojo-backuper"
        return 0
    fi
    return 1
}

update_from_github() {
    set_log_file "${PROJECT_LOG_DIR}/update.log"
    require_root

    echo
    echo -e "${C_CYAN}${C_BOLD}════════════════════════════════════════${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}  UPDATE FROM GITHUB                    ${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}  JOJO BACKUPER · @B_KHANEMAN           ${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}════════════════════════════════════════${C_RESET}"
    echo

    if ! check_command git; then
        msg_info "Installing git..."
        apt-get update -qq && apt-get install -y git || die "Cannot install git"
    fi

    local repo_root
    if ! repo_root="$(_find_repo_root)"; then
        msg_warn "Git repo not found — cloning fresh to /opt/jojo-backuper"
        local tmp="/tmp/jojo-backuper-update-$$"
        git clone --branch "$JOJO_GITHUB_BRANCH" --depth 1 "$JOJO_GITHUB_REPO" "$tmp" || die "Clone failed"
        mkdir -p /opt/jojo-backuper
        # Preserve local backups/logs/config
        if [[ -d "${SCRIPT_DIR}/backups" ]]; then
            mkdir -p /opt/jojo-backuper/server-migration-manager/backups
            cp -a "${SCRIPT_DIR}/backups/." /opt/jojo-backuper/server-migration-manager/backups/ 2>/dev/null || true
        fi
        if [[ -d "${SCRIPT_DIR}/logs" ]]; then
            mkdir -p /opt/jojo-backuper/server-migration-manager/logs
            cp -a "${SCRIPT_DIR}/logs/." /opt/jojo-backuper/server-migration-manager/logs/ 2>/dev/null || true
        fi
        [[ -f "${SCRIPT_DIR}/config.conf" ]] && cp -a "${SCRIPT_DIR}/config.conf" /tmp/jojo-config.conf.bak
        rsync -a --delete \
            --exclude 'server-migration-manager/backups/' \
            --exclude 'server-migration-manager/logs/' \
            "${tmp}/" /opt/jojo-backuper/
        rm -rf "$tmp"
        [[ -f /tmp/jojo-config.conf.bak ]] && cp -a /tmp/jojo-config.conf.bak /opt/jojo-backuper/server-migration-manager/config.conf
        repo_root="/opt/jojo-backuper"
        SCRIPT_DIR="${repo_root}/server-migration-manager"
    fi

    msg_info "Repo: $repo_root"
    msg_info "Remote: $JOJO_GITHUB_REPO ($JOJO_GITHUB_BRANCH)"

    local app_dir="${repo_root}/server-migration-manager"
    local cfg_bak="/tmp/jojo-config.conf.$$"
    local state_bak="/tmp/jojo-remote-state.$$"
    local pass_bak="/tmp/jojo-ssh-pass.$$"

    [[ -f "${app_dir}/config.conf" ]] && cp -a "${app_dir}/config.conf" "$cfg_bak"
    [[ -f "${app_dir}/logs/.remote_state" ]] && cp -a "${app_dir}/logs/.remote_state" "$state_bak"
    [[ -f "${app_dir}/logs/.ssh_password" ]] && cp -a "${app_dir}/logs/.ssh_password" "$pass_bak"

    local before after
    before="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo none)"

    msg_step "Fetching latest from GitHub..."
    loading_anim "Updating" 1

    (
        cd "$repo_root"
        git remote set-url origin "$JOJO_GITHUB_REPO" 2>/dev/null || \
            git remote add origin "$JOJO_GITHUB_REPO" 2>/dev/null || true
        git fetch --all --prune
        git checkout "$JOJO_GITHUB_BRANCH" 2>/dev/null || git checkout -b "$JOJO_GITHUB_BRANCH" "origin/${JOJO_GITHUB_BRANCH}" 2>/dev/null || true
        if ! git pull --ff-only origin "$JOJO_GITHUB_BRANCH"; then
            msg_warn "Fast-forward failed — hard reset to origin/${JOJO_GITHUB_BRANCH}"
            git reset --hard "origin/${JOJO_GITHUB_BRANCH}"
        fi
    ) || die "Git update failed"

    after="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo unknown)"

    # Restore local runtime config / secrets
    if [[ -f "$cfg_bak" ]]; then
        cp -a "$cfg_bak" "${app_dir}/config.conf"
        msg_dim "Preserved local config.conf"
    fi
    mkdir -p "${app_dir}/logs" "${app_dir}/backups"
    [[ -f "$state_bak" ]] && cp -a "$state_bak" "${app_dir}/logs/.remote_state"
    [[ -f "$pass_bak" ]] && cp -a "$pass_bak" "${app_dir}/logs/.ssh_password"
    rm -f "$cfg_bak" "$state_bak" "$pass_bak"

    chmod +x "${app_dir}/install.sh" "${app_dir}/migrate.sh" "${app_dir}/restore-agent.sh" 2>/dev/null || true
    find "${app_dir}/modules" -type f -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true

    msg_step "Re-running dependency installer..."
    bash "${app_dir}/install.sh" || msg_warn "install.sh reported errors — continuing"

    rm -f /usr/local/bin/smm /usr/local/bin/jojo /usr/local/bin/jojo-backuper
    ln -sfn "${app_dir}/migrate.sh" /usr/local/bin/smm
    ln -sfn "${app_dir}/migrate.sh" /usr/local/bin/jojo
    ln -sfn "${app_dir}/migrate.sh" /usr/local/bin/jojo-backuper

    local ver
    ver="$(cat "${app_dir}/VERSION" 2>/dev/null || echo '?')"
    echo
    if [[ "$before" == "$after" ]]; then
        msg_ok "Already up to date (${after}) · v${ver}"
    else
        msg_ok "Updated ${before} → ${after} · v${ver}"
    fi
    log_ok "Updated from GitHub ${before} -> ${after}"

    echo
    msg_info "Restarting JOJO BACKUPER to load new code..."
    sleep 1
    if [[ ! -t 0 ]] && [[ -r /dev/tty ]]; then
        exec </dev/tty
    fi
    exec bash "${app_dir}/migrate.sh"
}
