#!/usr/bin/env bash
#===============================================================================
# MODULE: PasarGuard panel + node migration support
# JOJO BACKUPER | @B_KHANEMAN
#
# Covers:
#   - /var/lib/pg-node (node certs + generated configs)
#   - Panel/node docker-compose dirs
#   - Related Docker volumes
#   - Post-restore compose up + checklist for remote nodes
#===============================================================================

_pg_find_compose_dirs() {
    find /opt /root /home /srv /var/lib /etc \
        -maxdepth 4 -type f \
        \( -iname '*pasar*' -o -iname '*pg-node*' -o -iname '*pasarguard*' \) \
        \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' \) \
        2>/dev/null | while read -r f; do dirname "$f"; done | sort -u
}

backup_pasarguard() {
    local out="${1:-}"
    [[ -z "$out" ]] && out="${METADATA_DIR:-/tmp}/pasarguard"
    mkdir -p "$out"

    msg_info "Detecting PasarGuard panel/node data..."
    local any=0

    # Canonical node data dir (bind mount in official compose)
    for d in /var/lib/pg-node /var/lib/pasarguard /var/lib/pg-panel /opt/pasarguard /opt/pg-node /opt/PasarGuard; do
        if [[ -d "$d" ]]; then
            local name
            name="$(echo "$d" | sed 's|^/||;s|/|_|g')"
            msg_dim "  Copying $d"
            mkdir -p "$out/bind/$name"
            # Prefer tar for speed/permissions
            tar -C "$(dirname "$d")" -cpf - "$(basename "$d")" 2>/dev/null \
                | zstd -T0 -3 -o "$out/bind/${name}.tar.zst" 2>/dev/null \
                || cp -a "$d" "$out/bind/${name}" 2>/dev/null || true
            any=1
        fi
    done

    # Compose project directories
    mkdir -p "$out/compose-dirs"
    local dir
    while read -r dir; do
        [[ -z "$dir" || ! -d "$dir" ]] && continue
        local safe
        safe="$(echo "$dir" | sed 's|^/||;s|/|__|g')"
        msg_dim "  Compose project: $dir"
        mkdir -p "$out/compose-dirs/$safe"
        # Copy project files (not huge runtime data)
        rsync -a --exclude '.git' --exclude 'node_modules' \
            "$dir/" "$out/compose-dirs/$safe/" 2>/dev/null || \
            cp -a "$dir"/. "$out/compose-dirs/$safe/" 2>/dev/null || true
        echo "$dir" > "$out/compose-dirs/$safe/.original_path"
        any=1
    done < <(_pg_find_compose_dirs)

    # Broader search for compose mentioning pasarguard/pg-node
    mkdir -p "$out/compose-refs"
    while IFS= read -r -d '' f; do
        if grep -qiE 'pasarguard|pg-node|pasar.?guard' "$f" 2>/dev/null; then
            local rel
            rel="$(echo "$f" | sed 's|^/||;s|/|__|g')"
            cp -a "$f" "$out/compose-refs/$rel" 2>/dev/null || true
            any=1
        fi
    done < <(find /opt /root /home /srv /var/lib -maxdepth 5 -type f \
        \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name '.env' \) \
        -print0 2>/dev/null)

    # Docker volumes related to pasarguard
    if check_command docker && docker info &>/dev/null; then
        mkdir -p "$out/volumes"
        local vol
        while read -r vol; do
            [[ -z "$vol" ]] && continue
            echo "$vol" | grep -qiE 'pasar|pg.?node|pg.?panel|marzban' || continue
            msg_dim "  Docker volume: $vol"
            docker run --rm -v "${vol}:/v:ro" -v "$out/volumes:/backup" alpine:3.20 \
                tar czf "/backup/${vol}.tar.gz" -C /v . 2>/dev/null || \
            docker run --rm -v "${vol}:/v:ro" -v "$out/volumes:/backup" busybox \
                tar czf "/backup/${vol}.tar.gz" -C /v . 2>/dev/null || true
            any=1
        done < <(docker volume ls -q 2>/dev/null)

        # Snapshot running pasar containers
        docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null \
            | grep -iE 'pasar|pg-node|pg-panel' > "$out/containers.txt" 2>/dev/null || true
    fi

    # Reminder file
    cat > "$out/README-NODES.txt" <<'EOF'
PasarGuard migration notes
==========================
1) Panel DB holds the list of nodes (address, port, API key, certs).
2) Each NODE server also has /var/lib/pg-node (certs + generated configs).
3) After moving the PANEL to a new IP:
   - Update each node's connection settings to the NEW panel IP/domain
   - Or re-add nodes in the panel UI
4) On each remote NODE server, reinstall/update node if needed:
   sudo bash -c "$(curl -sL https://github.com/PasarGuard/scripts/raw/main/pg-node.sh)" @ install
EOF

    if [[ $any -eq 0 ]]; then
        msg_dim "  No PasarGuard paths detected on this host"
        echo "none" > "$out/STATUS.txt"
    else
        echo "ok" > "$out/STATUS.txt"
        msg_ok "PasarGuard data collected"
    fi
    log_ok "PasarGuard backup → $out"
}

restore_pasarguard() {
    local src="${1:-}"
    [[ -z "$src" || ! -d "$src" ]] && return 0
    [[ -f "$src/STATUS.txt" && "$(cat "$src/STATUS.txt" 2>/dev/null)" == "none" ]] && return 0

    msg_step "Restoring PasarGuard data..."

    # Bind dirs from tar.zst
    if [[ -d "$src/bind" ]]; then
        local f
        for f in "$src/bind"/*.tar.zst; do
            [[ -f "$f" ]] || continue
            msg_dim "  Extracting $(basename "$f")"
            zstd -dc "$f" | tar -xpf - -C / 2>/dev/null || true
        done
        # Raw copied dirs
        local d
        for d in "$src/bind"/*/; do
            [[ -d "$d" ]] || continue
            local bname
            bname="$(basename "$d")"
            case "$bname" in
                var_lib_pg-node) mkdir -p /var/lib; cp -a "$d" /var/lib/pg-node 2>/dev/null || true ;;
                var_lib_pasarguard) mkdir -p /var/lib; cp -a "$d" /var/lib/pasarguard 2>/dev/null || true ;;
                opt_pasarguard) mkdir -p /opt; cp -a "$d" /opt/pasarguard 2>/dev/null || true ;;
                *) cp -a "$d" "/${bname//_//}" 2>/dev/null || true ;;
            esac
        done
    fi

    # Compose projects back to original paths
    if [[ -d "$src/compose-dirs" ]]; then
        local proj
        for proj in "$src/compose-dirs"/*/; do
            [[ -d "$proj" ]] || continue
            local orig="/opt/pasarguard-restored/$(basename "$proj")"
            [[ -f "${proj}/.original_path" ]] && orig="$(tr -d '\r' < "${proj}/.original_path")"
            msg_dim "  Restoring compose → $orig"
            mkdir -p "$orig"
            rsync -a --exclude '.original_path' "$proj" "$orig/" 2>/dev/null || cp -a "$proj"/. "$orig/" 2>/dev/null || true
            if [[ -f "$orig/docker-compose.yml" || -f "$orig/compose.yml" ]]; then
                (cd "$orig" && (docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null)) || \
                    msg_warn "  Could not start compose in $orig — start manually"
            fi
        done
    fi

    # Volumes
    if [[ -d "$src/volumes" ]] && check_command docker; then
        local vf vol
        for vf in "$src/volumes"/*.tar.gz; do
            [[ -f "$vf" ]] || continue
            vol="$(basename "$vf" .tar.gz)"
            docker volume create "$vol" >/dev/null 2>&1 || true
            docker run --rm -v "${vol}:/v" -v "$(dirname "$vf"):/backup:ro" alpine:3.20 \
                sh -c "cd /v && tar xzf /backup/$(basename "$vf")" 2>/dev/null || true
        done
    fi

    # Ensure node data dir exists with sane perms
    if [[ -d /var/lib/pg-node ]]; then
        chmod -R u+rwX /var/lib/pg-node 2>/dev/null || true
    fi

    # Try restart pasar containers
    if check_command docker; then
        local c
        while read -r c; do
            [[ -z "$c" ]] && continue
            docker start "$c" 2>/dev/null || true
        done < <(docker ps -aq --filter name=pasar 2>/dev/null; docker ps -aq --filter name=pg-node 2>/dev/null; docker ps -aq --filter name=pasarguard 2>/dev/null)
    fi

    # Official panel path
    if [[ -d /opt/pasarguard ]]; then
        msg_info "  Starting /opt/pasarguard stack..."
        (cd /opt/pasarguard && (docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null)) || true
        sleep 5
    fi

    # Import staged Docker DB dumps (nodes live in panel DB)
    if [[ -d /root/smm-docker-db-restore ]] && check_command docker; then
        local dumpf cid cname
        for dumpf in /root/smm-docker-db-restore/*-mysql.sql.gz; do
            [[ -f "$dumpf" ]] || continue
            cname="$(basename "$dumpf" -mysql.sql.gz)"
            cid="$(docker ps -q -f "name=^/${cname}$" 2>/dev/null | head -1)"
            [[ -z "$cid" ]] && cid="$(docker ps -q --filter "name=${cname}" 2>/dev/null | head -1)"
            if [[ -n "$cid" ]]; then
                msg_dim "  Importing MySQL dump into $cname"
                gunzip -c "$dumpf" | docker exec -i "$cid" sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" 2>/dev/null || mysql -uroot' 2>/dev/null || true
            fi
        done
        for dumpf in /root/smm-docker-db-restore/*-postgres.sql.gz; do
            [[ -f "$dumpf" ]] || continue
            cname="$(basename "$dumpf" -postgres.sql.gz)"
            cid="$(docker ps -q -f "name=^/${cname}$" 2>/dev/null | head -1)"
            [[ -z "$cid" ]] && cid="$(docker ps -q --filter "name=${cname}" 2>/dev/null | head -1)"
            if [[ -n "$cid" ]]; then
                msg_dim "  Importing Postgres dump into $cname"
                gunzip -c "$dumpf" | docker exec -i "$cid" sh -c 'psql -U "${POSTGRES_USER:-postgres}" postgres 2>/dev/null || psql -U postgres postgres' 2>/dev/null || true
            fi
        done
    fi

    echo
    msg_warn "PasarGuard checklist after migration:"
    msg_dim "  1) Panel UI → Nodes: verify each node is Online"
    msg_dim "  2) If panel IP changed: update node address / API endpoint on EVERY remote node"
    msg_dim "  3) Panel data: /var/lib/pasarguard + /opt/pasarguard"
    msg_dim "  4) Local node data (if this host is also a node): /var/lib/pg-node"
    msg_dim "  5) Restart: cd /opt/pasarguard && docker compose up -d"
    [[ -f "$src/README-NODES.txt" ]] && cp -a "$src/README-NODES.txt" /root/pasarguard-migration-notes.txt

    msg_ok "PasarGuard restore phase completed"
    log_ok "PasarGuard restore completed"
}
