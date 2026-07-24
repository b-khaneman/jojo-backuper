#!/usr/bin/env bash
#===============================================================================
# MODULE: Auto-heal after migration (APT / Docker / PasarGuard / shell noise)
# JOJO BACKUPER | @B_KHANEMAN
#===============================================================================

# Broken profile.d / bash-completion leftovers from mixed /etc restore
heal_shell_noise() {
    msg_step "Healing shell profile noise..."
    local f
    for f in /etc/profile.d/70-systemd-shell-extra.sh /etc/profile.d/80-systemd-osc-context.sh; do
        if [[ -L "$f" || -e "$f" ]]; then
            [[ -e "$f" ]] || rm -f "$f" 2>/dev/null || true
        fi
        # dangling symlink
        if [[ -L "$f" && ! -e "$f" ]]; then
            rm -f "$f" 2>/dev/null || true
        fi
    done
    # Remove profile.d entries that point to missing files
    if [[ -d /etc/profile.d ]]; then
        while IFS= read -r -d '' f; do
            if [[ -L "$f" && ! -e "$f" ]]; then
                rm -f "$f" 2>/dev/null || true
            fi
        done < <(find /etc/profile.d -maxdepth 1 -type l -print0 2>/dev/null)
    fi
    msg_ok "Shell profile cleaned"
}

# APT hooks + conflicting Docker apt sources from old host
heal_apt() {
    msg_step "Healing APT..."
    declare -f repair_apt_after_restore &>/dev/null && repair_apt_after_restore

    # Official Docker CE lists conflict with Ubuntu docker.io / containerd
    rm -f /etc/apt/sources.list.d/docker*.list 2>/dev/null || true
    rm -f /etc/apt/keyrings/docker.gpg /etc/apt/keyrings/docker.asc 2>/dev/null || true
    # Drop any apt.conf.d line pointing at missing binaries
    local conf
    for conf in /etc/apt/apt.conf.d/*; do
        [[ -f "$conf" ]] || continue
        if grep -qE '/usr/bin/apt_hook|/usr/lib/.*/apt' "$conf" 2>/dev/null; then
            while read -r bin; do
                [[ -z "$bin" ]] && continue
                [[ -x "$bin" ]] && continue
                sed -i "\#${bin}#d" "$conf" 2>/dev/null || true
            done < <(grep -oE '/usr[^ \"'\'']+' "$conf" 2>/dev/null || true)
        fi
    done
    apt-get update -qq 2>/dev/null || apt-get update 2>/dev/null || true
    msg_ok "APT healed"
}

# Purge conflicting Docker packages and install a clean Ubuntu docker.io stack
heal_docker_install() {
    msg_step "Healing Docker install (purge conflicts → docker.io)..."
    heal_apt

    export DEBIAN_FRONTEND=noninteractive
    systemctl stop docker.socket docker.service containerd 2>/dev/null || true

    # Remove BOTH Ubuntu and Docker-CE stacks to end conflicts
    apt-get remove -y \
        docker.io docker-doc docker-compose docker-compose-v2 docker-compose-plugin \
        docker-ce docker-ce-cli containerd containerd.io docker-buildx-plugin \
        podman-docker 2>/dev/null || true
    apt-get purge -y \
        docker.io docker-compose docker-compose-v2 docker-compose-plugin \
        docker-ce docker-ce-cli containerd containerd.io 2>/dev/null || true
    dpkg --remove --force-remove-reinstreq docker-compose-plugin 2>/dev/null || true
    apt-get -f install -y 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true

    apt-get update -qq 2>/dev/null || true
    if ! apt-get install -y docker.io docker-compose-v2; then
        apt-get -f install -y || true
        apt-get install -y docker.io || true
        apt-get install -y docker-compose-v2 || apt-get install -y docker-compose || true
    fi

    systemctl enable docker 2>/dev/null || true
    systemctl start containerd 2>/dev/null || true
    systemctl start docker 2>/dev/null || true
    sleep 2

    if check_command docker && docker info &>/dev/null; then
        msg_ok "Docker ready: $(docker --version 2>/dev/null | head -1)"
        docker compose version &>/dev/null && msg_ok "Compose ready" || msg_warn "Compose plugin missing — will try docker-compose"
        return 0
    fi
    msg_error "Docker still not working after heal"
    journalctl -u docker -n 20 --no-pager 2>/dev/null || true
    return 1
}

# Wipe stale container/network metadata from old host (keeps volumes + images)
heal_docker_runtime() {
    msg_step "Healing Docker runtime (clear stale container IDs)..."
    systemctl stop docker.socket docker.service 2>/dev/null || true
    sleep 1
    # Soft remove via CLI if daemon still up
    if check_command docker; then
        docker rm -f $(docker ps -aq) 2>/dev/null || true
    fi
    systemctl stop docker.socket docker.service containerd 2>/dev/null || true
    sleep 1
    rm -rf /var/lib/docker/containers /var/lib/docker/network
    mkdir -p /var/lib/docker/containers /var/lib/docker/network
    # Do NOT delete volumes/ or image/ — panel DB lives in volumes or bind mounts
    systemctl start containerd 2>/dev/null || true
    systemctl start docker 2>/dev/null || true
    sleep 2
    if docker info &>/dev/null; then
        msg_ok "Docker runtime cleaned (volumes preserved)"
        return 0
    fi
    msg_warn "Docker daemon not healthy after runtime clean"
    return 1
}

_pg_compose() {
    # Prefer project name pasarguard
    if docker compose version &>/dev/null; then
        docker compose -p pasarguard "$@"
    elif check_command docker-compose; then
        docker-compose -p pasarguard "$@"
    else
        return 1
    fi
}

# Official PasarGuard CLI (/usr/local/bin/pasarguard) — panel dir can exist without this
ensure_pasarguard_cli() {
    if command -v pasarguard &>/dev/null && [[ -x "$(command -v pasarguard)" ]]; then
        msg_ok "PasarGuard CLI present: $(command -v pasarguard)"
        return 0
    fi
    # Local copy already shipped with panel?
    for cand in /opt/pasarguard/pasarguard.sh /opt/pasarguard/pasarguard /usr/local/bin/pasarguard.sh; do
        if [[ -f "$cand" ]]; then
            cp -a "$cand" /usr/local/bin/pasarguard
            chmod +x /usr/local/bin/pasarguard
            msg_ok "PasarGuard CLI linked from $cand"
            return 0
        fi
    done
    msg_step "Installing official PasarGuard CLI → /usr/local/bin/pasarguard"
    if curl -fsSL "https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh" -o /usr/local/bin/pasarguard; then
        chmod +x /usr/local/bin/pasarguard
        msg_ok "PasarGuard CLI installed"
        return 0
    fi
    # Offline-safe wrapper
    cat > /usr/local/bin/pasarguard <<'EOF'
#!/bin/bash
exec bash -c "$(curl -fsSL https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh)" -- "$@"
EOF
    chmod +x /usr/local/bin/pasarguard
    msg_warn "PasarGuard CLI wrapper installed (needs network on first run)"
    return 0
}

# Bring PasarGuard panel up cleanly
heal_pasarguard() {
    if [[ ! -d /opt/pasarguard ]]; then
        msg_dim "No /opt/pasarguard — skip panel heal"
        return 0
    fi
    msg_step "Healing PasarGuard panel..."

    ensure_pasarguard_cli || true

    # Strip bad COMPOSE_PROJECT_NAME if it looks like a container id
    if [[ -f /opt/pasarguard/.env ]]; then
        if grep -qE '^COMPOSE_PROJECT_NAME=[0-9a-f]{12}' /opt/pasarguard/.env 2>/dev/null; then
            sed -i '/^COMPOSE_PROJECT_NAME=/d' /opt/pasarguard/.env
            msg_dim "  Removed broken COMPOSE_PROJECT_NAME from .env"
        fi
    fi

    (
        cd /opt/pasarguard || exit 0
        _pg_compose down --remove-orphans 2>/dev/null || true
        docker compose down --remove-orphans 2>/dev/null || true
    )

    docker rm -f $(docker ps -aq) 2>/dev/null || true

    # Pull images if missing (panel/mariadb)
    (
        cd /opt/pasarguard || exit 0
        _pg_compose pull 2>/dev/null || true
        if ! _pg_compose up -d --force-recreate --remove-orphans; then
            msg_warn "  compose up failed once — wiping containers again and retry"
            systemctl stop docker 2>/dev/null || true
            rm -rf /var/lib/docker/containers/*
            mkdir -p /var/lib/docker/containers
            systemctl start docker 2>/dev/null || true
            sleep 2
            _pg_compose up -d --force-recreate --remove-orphans || true
        fi
    )

    sleep 5
    # Import staged MariaDB dumps if containers are up and dumps exist
    if [[ -d /root/smm-pasarguard-mariadb ]] && declare -f _pg_import_mariadb_dumps &>/dev/null; then
        _pg_import_mariadb_dumps /root/smm-pasarguard-mariadb 2>/dev/null || true
    elif [[ -d /root/smm-docker-db-restore ]]; then
        true
    fi

    ensure_pasarguard_cli || true

    echo
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null || docker ps
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qiE 'pasar|mariadb|panel'; then
        msg_ok "PasarGuard containers are running"
        return 0
    fi
    msg_warn "PasarGuard may still need attention — check: cd /opt/pasarguard && docker compose -p pasarguard logs"
    return 1
}

# Full automatic heal pipeline for NEW server after restore / manual fix
heal_new_server() {
    require_root
    export TERM="${TERM:-xterm-256color}"
    export DEBIAN_FRONTEND=noninteractive
    set_log_file "${LOG_DIR:-/var/log/server-migration}/heal.log"

    echo
    msg_info "JOJO AUTO-HEAL starting..."
    log_info "=== AUTO-HEAL START ==="

    heal_shell_noise
    heal_apt
    heal_docker_install || true
    heal_docker_runtime || true
    # Re-ensure docker after runtime wipe
    systemctl start docker 2>/dev/null || true
    sleep 2
    heal_pasarguard || true
    ensure_pasarguard_cli || true

    # SSH keep-alive drop-in
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-smm-keep-access.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
EOF
    sshd -t 2>/dev/null && systemctl reload ssh 2>/dev/null || true

    echo
    msg_ok "AUTO-HEAL finished"
    msg_dim "Panel dir: /opt/pasarguard"
    command -v pasarguard &>/dev/null && msg_dim "CLI: $(command -v pasarguard)"
    msg_dim "Logs: ${LOG_DIR:-/var/log/server-migration}/heal.log"
    log_ok "AUTO-HEAL done"
    return 0
}

# Replace weak ensure_docker_installed with conflict-aware install
ensure_docker_installed() {
    export TERM="${TERM:-xterm-256color}"
    declare -f repair_apt_after_restore &>/dev/null && repair_apt_after_restore

    if check_command docker && docker info &>/dev/null; then
        if docker compose version &>/dev/null || check_command docker-compose; then
            systemctl enable docker 2>/dev/null || true
            msg_ok "Docker already available: $(docker --version 2>/dev/null | head -1)"
            return 0
        fi
    fi
    heal_docker_install
}
