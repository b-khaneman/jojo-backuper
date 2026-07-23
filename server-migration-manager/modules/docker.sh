#!/usr/bin/env bash
#===============================================================================
# MODULE: Docker Backup & Restore
# SERVER MIGRATION MANAGER v1.0 | JOJO BACKUP
#===============================================================================

backup_docker() {
    local out="${1:-}"
    [[ -z "$out" ]] && out="${METADATA_DIR:-/tmp}/docker"
    mkdir -p "$out"

    if ! check_command docker; then
        msg_dim "Docker not installed — skipping"
        echo "not_installed" > "$out/STATUS.txt"
        return 0
    fi

    if ! docker info &>/dev/null; then
        msg_warn "Docker installed but daemon not reachable — skipping runtime dump"
        echo "daemon_unavailable" > "$out/STATUS.txt"
        # Still try to copy compose files and config
    else
        msg_info "Backing up Docker state..."

        docker ps -a --no-trunc > "$out/containers.txt" 2>/dev/null || true
        docker ps -a --format '{{json .}}' > "$out/containers.jsonl" 2>/dev/null || true
        docker images --no-trunc > "$out/images.txt" 2>/dev/null || true
        docker images --format '{{json .}}' > "$out/images.jsonl" 2>/dev/null || true
        docker volume ls > "$out/volumes.txt" 2>/dev/null || true
        docker network ls > "$out/networks.txt" 2>/dev/null || true
        docker network ls --format '{{json .}}' > "$out/networks.jsonl" 2>/dev/null || true
        docker info > "$out/docker.info" 2>/dev/null || true
        docker version > "$out/docker.version" 2>/dev/null || true

        # Inspect each container
        mkdir -p "$out/inspect/containers" "$out/inspect/volumes" "$out/inspect/networks"
        local id
        while read -r id; do
            [[ -z "$id" ]] && continue
            docker inspect "$id" > "$out/inspect/containers/${id}.json" 2>/dev/null || true
        done < <(docker ps -aq 2>/dev/null)

        while read -r id; do
            [[ -z "$id" ]] && continue
            docker volume inspect "$id" > "$out/inspect/volumes/${id}.json" 2>/dev/null || true
        done < <(docker volume ls -q 2>/dev/null)

        while read -r id; do
            [[ -z "$id" ]] && continue
            docker network inspect "$id" > "$out/inspect/networks/${id}.json" 2>/dev/null || true
        done < <(docker network ls -q 2>/dev/null)

        # Save images (can be large — save list of images to export)
        msg_info "  Exporting Docker images (this may take time)..."
        mkdir -p "$out/images"
        local img count=0
        while read -r img; do
            [[ -z "$img" || "$img" == *"none"* ]] && continue
            local safe
            safe="$(echo "$img" | tr '/:' '__')"
            msg_dim "    Saving image: $img"
            docker save "$img" | zstd -T0 -3 -o "$out/images/${safe}.tar.zst" 2>/dev/null || \
                docker save -o "$out/images/${safe}.tar" "$img" 2>/dev/null || true
            ((count++)) || true
        done < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>' || true)

        # Volume data export
        msg_info "  Exporting Docker volumes..."
        mkdir -p "$out/volume-data"
        while read -r vol; do
            [[ -z "$vol" ]] && continue
            msg_dim "    Volume: $vol"
            docker run --rm -v "${vol}:/v:ro" -v "$out/volume-data:/backup" alpine:3.20 \
                tar czf "/backup/${vol}.tar.gz" -C /v . 2>/dev/null || \
            docker run --rm -v "${vol}:/v:ro" -v "$out/volume-data:/backup" busybox \
                tar czf "/backup/${vol}.tar.gz" -C /v . 2>/dev/null || \
                msg_warn "    Failed to export volume: $vol"
        done < <(docker volume ls -q 2>/dev/null)

        echo "ok images=$count" > "$out/STATUS.txt"
        msg_ok "Docker runtime state backed up ($count images)"
    fi

    # Compose files — search common locations
    msg_info "  Searching for docker-compose files..."
    mkdir -p "$out/compose"
    local compose_found=0
    while IFS= read -r -d '' f; do
        local rel
        rel="$(echo "$f" | sed 's|^/||;s|/|__|g')"
        cp -a "$f" "$out/compose/${rel}" 2>/dev/null || true
        ((compose_found++)) || true
    done < <(find /opt /home /root /srv /var/www /etc -maxdepth 5 \
        \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' \) \
        -print0 2>/dev/null)

    msg_dim "  Found $compose_found compose file(s)"

    # Docker daemon config
    [[ -f /etc/docker/daemon.json ]] && mkdir -p "$out/etc-docker" && cp -a /etc/docker "$out/etc-docker/" 2>/dev/null || true
    [[ -d /etc/docker ]] && cp -a /etc/docker "$out/etc-docker-full" 2>/dev/null || true

    log_ok "Docker backup → $out"
}

restore_docker() {
    local src="${1:-}"
    [[ -z "$src" || ! -d "$src" ]] && { msg_warn "No Docker backup found"; return 0; }

    if [[ "${RESTORE_DOCKER:-yes}" != "yes" ]]; then
        msg_dim "Docker restore skipped (config)"
        return 0
    fi

    msg_step "Restoring Docker..."
    log_info "Restoring Docker from $src"

    # Install docker if missing
    if ! check_command docker; then
        msg_info "  Installing Docker..."
        apt-get update -qq
        apt-get install -y docker.io docker-compose-v2 2>/dev/null || \
            apt-get install -y docker.io docker-compose 2>/dev/null || \
            msg_warn "  Could not install Docker automatically"
    fi

    # Restore daemon config
    if [[ -d "$src/etc-docker/docker" ]]; then
        mkdir -p /etc/docker
        cp -a "$src/etc-docker/docker/." /etc/docker/ 2>/dev/null || true
    elif [[ -d "$src/etc-docker-full" ]]; then
        mkdir -p /etc/docker
        cp -a "$src/etc-docker-full/." /etc/docker/ 2>/dev/null || true
    fi

    systemctl enable docker 2>/dev/null || true
    systemctl start docker 2>/dev/null || true
    sleep 2

    if ! docker info &>/dev/null; then
        msg_warn "Docker daemon not running — image/volume restore deferred"
        return 0
    fi

    # Load images
    if [[ -d "$src/images" ]]; then
        msg_info "  Loading Docker images..."
        local imgf
        for imgf in "$src/images"/*; do
            [[ -f "$imgf" ]] || continue
            msg_dim "    Loading $(basename "$imgf")"
            case "$imgf" in
                *.tar.zst) zstd -dc "$imgf" | docker load ;;
                *.tar) docker load -i "$imgf" ;;
                *) docker load -i "$imgf" 2>/dev/null || true ;;
            esac
        done
        msg_ok "  Images loaded"
    fi

    # Restore volumes
    if [[ -d "$src/volume-data" ]]; then
        msg_info "  Restoring Docker volumes..."
        local vf vol
        for vf in "$src/volume-data"/*.tar.gz; do
            [[ -f "$vf" ]] || continue
            vol="$(basename "$vf" .tar.gz)"
            docker volume create "$vol" >/dev/null 2>&1 || true
            docker run --rm -v "${vol}:/v" -v "$(dirname "$vf"):/backup:ro" alpine:3.20 \
                sh -c "cd /v && tar xzf /backup/$(basename "$vf")" 2>/dev/null || \
            docker run --rm -v "${vol}:/v" -v "$(dirname "$vf"):/backup:ro" busybox \
                sh -c "cd /v && tar xzf /backup/$(basename "$vf")" 2>/dev/null || true
            msg_dim "    Restored volume: $vol"
        done
    fi

    # Place compose files under /opt/smm-compose for admin
    if [[ -d "$src/compose" ]] && [[ -n "$(ls -A "$src/compose" 2>/dev/null)" ]]; then
        mkdir -p /opt/smm-compose
        cp -a "$src/compose/." /opt/smm-compose/
        msg_info "  Compose files placed in /opt/smm-compose"
    fi

    msg_ok "Docker restore completed"
    log_ok "Docker restore completed"
}
