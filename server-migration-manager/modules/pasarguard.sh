#!/usr/bin/env bash
#===============================================================================
# MODULE: PasarGuard panel + node migration
# JOJO BACKUPER | @B_KHANEMAN
#
# Official panel layout (pasarguard.sh @ install --database mariadb):
#   APP_DIR  = /opt/pasarguard          (.env, docker-compose.yml)
#   DATA_DIR = /var/lib/pasarguard      (certs, sqlite/db files, app data)
#   Compose project: pasarguard         (includes mariadb service)
#   Optional local node: /var/lib/pg-node
#
# Used by:
#   - Full server backup extras (backup_pasarguard / restore_pasarguard)
#   - Menu: Migrate PasarGuard Panel (migrate_pasarguard_panel)
#===============================================================================

_pg_app_dir() { echo "${PASARGUARD_APP_DIR:-/opt/pasarguard}"; }
_pg_data_dir() { echo "${PASARGUARD_DATA_DIR:-/var/lib/pasarguard}"; }

_pg_find_compose_dirs() {
    find /opt /root /home /srv /var/lib /etc \
        -maxdepth 4 -type f \
        \( -iname '*pasar*' -o -iname '*pg-node*' -o -iname '*pasarguard*' \) \
        \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' \) \
        2>/dev/null | while read -r f; do dirname "$f"; done | sort -u
}

_pg_dump_mariadb() {
    local out_db="$1"
    mkdir -p "$out_db"
    local dumped=0
    local app_dir
    app_dir="$(_pg_app_dir)"

    # Host mysqldump (rare for official install — usually Docker)
    if check_command mysqldump; then
        msg_dim "  Trying host mysqldump..."
        if mysqldump --all-databases --single-transaction --quick --routines --triggers --events 2>/dev/null \
            | gzip > "$out_db/host-mysql-all.sql.gz" && [[ -s "$out_db/host-mysql-all.sql.gz" ]]; then
            dumped=1
            msg_ok "  Host MySQL/MariaDB dump OK"
        else
            rm -f "$out_db/host-mysql-all.sql.gz"
        fi
    fi

    if ! check_command docker || ! docker info &>/dev/null; then
        return $(( dumped == 0 ? 1 : 0 ))
    fi

    local cid cname img
    # Prefer pasarguard compose MariaDB/MySQL containers
    while read -r cid; do
        [[ -z "$cid" ]] && continue
        cname="$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')"
        img="$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null)"
        if ! echo "$cname $img" | grep -qiE 'mariadb|mysql|pasarguard'; then
            continue
        fi
        # Skip non-db pasarguard app containers
        if echo "$cname $img" | grep -qiE 'mariadb|mysql|percona'; then
            :
        elif echo "$cname" | grep -qiE 'mariadb|mysql'; then
            :
        else
            continue
        fi
        msg_info "  Dumping MariaDB/MySQL container: $cname"
        local dump_file="$out_db/${cname}-mariadb.sql.gz"
        # Try MYSQL_ROOT_PASSWORD from container env, then from panel .env
        if docker exec "$cid" sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --all-databases --single-transaction --quick --routines --triggers --events 2>/dev/null' \
            | gzip > "$dump_file" && [[ -s "$dump_file" ]]; then
            dumped=1
            msg_ok "  Dump OK: $cname"
            continue
        fi
        rm -f "$dump_file"
        local root_pw=""
        if [[ -f "${app_dir}/.env" ]]; then
            root_pw="$(grep -E '^MYSQL_ROOT_PASSWORD=' "${app_dir}/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
        fi
        if [[ -n "$root_pw" ]]; then
            if docker exec -e MYSQL_PWD="$root_pw" "$cid" mysqldump -uroot --all-databases --single-transaction --quick --routines --triggers --events 2>/dev/null \
                | gzip > "$dump_file" && [[ -s "$dump_file" ]]; then
                dumped=1
                msg_ok "  Dump OK via .env password: $cname"
                continue
            fi
            rm -f "$dump_file"
        fi
        # Last resort: no password
        if docker exec "$cid" mysqldump -uroot --all-databases --single-transaction --quick 2>/dev/null \
            | gzip > "$dump_file" && [[ -s "$dump_file" ]]; then
            dumped=1
            msg_ok "  Dump OK (no pass): $cname"
        else
            rm -f "$dump_file"
            msg_warn "  Could not dump $cname — volume/bind data still copied"
        fi
    done < <(docker ps -q 2>/dev/null)

    # Also try compose project name
    if [[ -f "${app_dir}/docker-compose.yml" ]] || [[ -f "${app_dir}/compose.yml" ]]; then
        local qid
        qid="$(cd "$app_dir" && (docker compose -p pasarguard ps -q mariadb 2>/dev/null || docker compose ps -q mariadb 2>/dev/null) | head -1)"
        if [[ -n "$qid" && $dumped -eq 0 ]]; then
            msg_info "  Dumping compose mariadb ($qid)..."
            docker exec "$qid" sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --all-databases --single-transaction --quick --routines --triggers --events 2>/dev/null' \
                | gzip > "$out_db/compose-mariadb.sql.gz" 2>/dev/null || true
            [[ -s "$out_db/compose-mariadb.sql.gz" ]] && dumped=1 && msg_ok "  Compose mariadb dump OK"
        fi
    fi

    [[ $dumped -eq 1 ]] && echo "ok" > "$out_db/STATUS.txt" || echo "none" > "$out_db/STATUS.txt"
    return 0
}

backup_pasarguard() {
    local out="${1:-}"
    [[ -z "$out" ]] && out="${METADATA_DIR:-/tmp}/pasarguard"
    mkdir -p "$out"

    msg_info "Detecting PasarGuard panel/node data..."
    local any=0
    local app_dir data_dir
    app_dir="$(_pg_app_dir)"
    data_dir="$(_pg_data_dir)"

    # Canonical paths (panel + local node)
    local d
    for d in "$data_dir" "$app_dir" /var/lib/pg-node /var/lib/pg-panel /opt/pg-node /opt/PasarGuard; do
        if [[ -d "$d" ]]; then
            local name
            name="$(echo "$d" | sed 's|^/||;s|/|_|g')"
            msg_dim "  Archiving $d"
            mkdir -p "$out/bind"
            if tar -C "$(dirname "$d")" -cpf - "$(basename "$d")" 2>/dev/null \
                | zstd -T0 -3 -o "$out/bind/${name}.tar.zst" 2>/dev/null; then
                any=1
            else
                mkdir -p "$out/bind/$name"
                cp -a "$d"/. "$out/bind/$name/" 2>/dev/null && any=1 || true
            fi
        fi
    done

    # Explicit .env + compose copies (easy restore verification)
    mkdir -p "$out/panel-files"
    if [[ -f "${app_dir}/.env" ]]; then
        cp -a "${app_dir}/.env" "$out/panel-files/env" 2>/dev/null || true
        any=1
        msg_dim "  Saved ${app_dir}/.env"
    fi
    for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        [[ -f "${app_dir}/$f" ]] && cp -a "${app_dir}/$f" "$out/panel-files/" && any=1
    done

    # SSL certs live under DATA_DIR/certs (official install)
    if [[ -d "${data_dir}/certs" ]]; then
        msg_dim "  Archiving SSL certs ${data_dir}/certs"
        mkdir -p "$out/certs"
        tar -C "$data_dir" -cpf - certs 2>/dev/null | zstd -T0 -3 -o "$out/certs/certs.tar.zst" 2>/dev/null \
            || cp -a "${data_dir}/certs" "$out/certs/" 2>/dev/null || true
        any=1
    fi

    # acme.sh store (Let's Encrypt) if present
    if [[ -d /root/.acme.sh ]]; then
        msg_dim "  Archiving /root/.acme.sh"
        tar -C /root -cpf - .acme.sh 2>/dev/null | zstd -T0 -3 -o "$out/acme.sh.tar.zst" 2>/dev/null || true
        any=1
    fi

    # Compose project directories (broader search)
    mkdir -p "$out/compose-dirs"
    local dir
    while read -r dir; do
        [[ -z "$dir" || ! -d "$dir" ]] && continue
        local safe
        safe="$(echo "$dir" | sed 's|^/||;s|/|__|g')"
        msg_dim "  Compose project: $dir"
        mkdir -p "$out/compose-dirs/$safe"
        rsync -a --exclude '.git' --exclude 'node_modules' \
            "$dir/" "$out/compose-dirs/$safe/" 2>/dev/null || \
            cp -a "$dir"/. "$out/compose-dirs/$safe/" 2>/dev/null || true
        echo "$dir" > "$out/compose-dirs/$safe/.original_path"
        any=1
    done < <(_pg_find_compose_dirs)

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

    # MariaDB / MySQL logical dump (nodes list lives here)
    msg_info "  Dumping PasarGuard MariaDB/MySQL..."
    _pg_dump_mariadb "$out/mariadb"
    [[ -f "$out/mariadb/STATUS.txt" && "$(cat "$out/mariadb/STATUS.txt")" == "ok" ]] && any=1

    # Docker volumes related to pasarguard
    if check_command docker && docker info &>/dev/null; then
        mkdir -p "$out/volumes"
        local vol
        while read -r vol; do
            [[ -z "$vol" ]] && continue
            echo "$vol" | grep -qiE 'pasar|pg.?node|pg.?panel|mariadb' || continue
            msg_dim "  Docker volume: $vol"
            docker run --rm -v "${vol}:/v:ro" -v "$out/volumes:/backup" alpine:3.20 \
                tar czf "/backup/${vol}.tar.gz" -C /v . 2>/dev/null || \
            docker run --rm -v "${vol}:/v:ro" -v "$out/volumes:/backup" busybox \
                tar czf "/backup/${vol}.tar.gz" -C /v . 2>/dev/null || true
            any=1
        done < <(docker volume ls -q 2>/dev/null)

        docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null \
            | grep -iE 'pasar|pg-node|pg-panel|mariadb' > "$out/containers.txt" 2>/dev/null || true

        # Save images used by pasarguard project (optional, can be large)
        if [[ "${PASARGUARD_BACKUP_IMAGES:-no}" == "yes" ]]; then
            mkdir -p "$out/images"
            local img
            while read -r img; do
                [[ -z "$img" || "$img" == *"<none>"* ]] && continue
                local safe
                safe="$(echo "$img" | tr '/:' '__')"
                msg_dim "  Saving image $img"
                docker save "$img" | zstd -T0 -3 -o "$out/images/${safe}.tar.zst" 2>/dev/null || true
            done < <(docker ps -a --format '{{.Image}}' 2>/dev/null | grep -iE 'pasar|mariadb|mysql|ghcr.io/pasarguard' | sort -u)
        fi
    fi

    cat > "$out/README-PANEL.txt" <<'EOF'
PasarGuard PANEL migration notes (JOJO BACKUPER)
================================================
Official paths:
  /opt/pasarguard          → compose + .env
  /var/lib/pasarguard      → data + SSL certs (certs/<domain>/)
  MariaDB in docker        → nodes/users live in DB

After restore on NEW server:
  1) systemctl start docker
  2) cd /opt/pasarguard && docker compose -p pasarguard up -d
  3) Wait for mariadb healthy, then import dump if needed:
       gunzip -c /root/smm-pasarguard-mariadb/*.sql.gz | docker exec -i <mariadb> mysql -uroot -p"$MYSQL_ROOT_PASSWORD"
  4) Panel UI → Nodes: verify Online
  5) If panel IP/domain changed: update each REMOTE node to new panel address

Install reference:
  sudo bash -c "$(curl -fsSL https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh)" @ install --database mariadb
EOF

    if [[ $any -eq 0 ]]; then
        msg_dim "  No PasarGuard paths detected on this host"
        echo "none" > "$out/STATUS.txt"
    else
        echo "ok" > "$out/STATUS.txt"
        {
            echo "app_dir=$app_dir"
            echo "data_dir=$data_dir"
            echo "backed_up_at=$(date -Iseconds)"
            echo "hostname=$(hostname)"
        } > "$out/META.txt"
        msg_ok "PasarGuard panel data collected"
    fi
    log_ok "PasarGuard backup → $out"
}

_pg_import_mariadb_dumps() {
    local src_db="$1"
    [[ -d "$src_db" ]] || return 0
    check_command docker || return 0
    docker info &>/dev/null || return 0

    local app_dir
    app_dir="$(_pg_app_dir)"
    local cid=""
    if [[ -d "$app_dir" ]]; then
        cid="$(cd "$app_dir" && (docker compose -p pasarguard ps -q mariadb 2>/dev/null || docker compose ps -q mariadb 2>/dev/null) | head -1)"
    fi
    [[ -z "$cid" ]] && cid="$(docker ps -q --filter name=mariadb 2>/dev/null | head -1)"
    [[ -z "$cid" ]] && cid="$(docker ps -q --filter name=pasarguard 2>/dev/null | head -1)"

    if [[ -z "$cid" ]]; then
        mkdir -p /root/smm-pasarguard-mariadb
        cp -a "$src_db"/. /root/smm-pasarguard-mariadb/ 2>/dev/null || true
        msg_warn "  MariaDB container not running — dumps staged in /root/smm-pasarguard-mariadb"
        return 0
    fi

    local dumpf root_pw=""
    [[ -f "${app_dir}/.env" ]] && root_pw="$(grep -E '^MYSQL_ROOT_PASSWORD=' "${app_dir}/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")"

    for dumpf in "$src_db"/*.sql.gz; do
        [[ -f "$dumpf" ]] || continue
        msg_dim "  Importing $(basename "$dumpf") → $cid"
        if [[ -n "$root_pw" ]]; then
            gunzip -c "$dumpf" | docker exec -i -e MYSQL_PWD="$root_pw" "$cid" mysql -uroot 2>/dev/null \
                && msg_ok "  Imported $(basename "$dumpf")" \
                || msg_warn "  Import had errors for $(basename "$dumpf")"
        else
            gunzip -c "$dumpf" | docker exec -i "$cid" sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" 2>/dev/null || mysql -uroot' 2>/dev/null \
                && msg_ok "  Imported $(basename "$dumpf")" \
                || msg_warn "  Import had errors for $(basename "$dumpf")"
        fi
    done
}

restore_pasarguard() {
    local src="${1:-}"
    [[ -z "$src" || ! -d "$src" ]] && return 0
    [[ -f "$src/STATUS.txt" && "$(cat "$src/STATUS.txt" 2>/dev/null)" == "none" ]] && return 0

    msg_step "Restoring PasarGuard panel/node data..."

    # Panel needs docker CLI even when we do not auto-start compose
    if declare -f ensure_docker_installed &>/dev/null; then
        ensure_docker_installed || msg_warn "  Docker not installed — panel files will still be restored"
    fi

    # Bind dirs from tar.zst
    if [[ -d "$src/bind" ]]; then
        local f
        for f in "$src/bind"/*.tar.zst; do
            [[ -f "$f" ]] || continue
            msg_dim "  Extracting $(basename "$f")"
            zstd -dc "$f" | tar -xpf - -C / 2>/dev/null || true
        done
        local d
        for d in "$src/bind"/*/; do
            [[ -d "$d" ]] || continue
            local bname
            bname="$(basename "$d")"
            case "$bname" in
                var_lib_pg-node) mkdir -p /var/lib/pg-node; cp -a "$d"/. /var/lib/pg-node/ 2>/dev/null || true ;;
                var_lib_pasarguard) mkdir -p /var/lib/pasarguard; cp -a "$d"/. /var/lib/pasarguard/ 2>/dev/null || true ;;
                opt_pasarguard) mkdir -p /opt/pasarguard; cp -a "$d"/. /opt/pasarguard/ 2>/dev/null || true ;;
                *)
                    # Reconstruct path from underscores carefully for known prefixes
                    if [[ "$bname" == var_lib_* ]]; then
                        mkdir -p "/var/lib/${bname#var_lib_}"
                        cp -a "$d"/. "/var/lib/${bname#var_lib_}/" 2>/dev/null || true
                    elif [[ "$bname" == opt_* ]]; then
                        mkdir -p "/opt/${bname#opt_}"
                        cp -a "$d"/. "/opt/${bname#opt_}/" 2>/dev/null || true
                    fi
                    ;;
            esac
        done
    fi

    # Panel files overlay
    if [[ -d "$src/panel-files" ]]; then
        mkdir -p /opt/pasarguard
        [[ -f "$src/panel-files/env" ]] && cp -a "$src/panel-files/env" /opt/pasarguard/.env
        local pf
        for pf in "$src/panel-files"/docker-compose.yml "$src/panel-files"/docker-compose.yaml \
                  "$src/panel-files"/compose.yml "$src/panel-files"/compose.yaml; do
            [[ -f "$pf" ]] && cp -a "$pf" /opt/pasarguard/
        done
    fi

    # Certs
    if [[ -f "$src/certs/certs.tar.zst" ]]; then
        mkdir -p /var/lib/pasarguard
        zstd -dc "$src/certs/certs.tar.zst" | tar -xpf - -C /var/lib/pasarguard 2>/dev/null || true
    elif [[ -d "$src/certs/certs" ]]; then
        mkdir -p /var/lib/pasarguard/certs
        cp -a "$src/certs/certs/." /var/lib/pasarguard/certs/ 2>/dev/null || true
    fi

    # acme.sh
    if [[ -f "$src/acme.sh.tar.zst" ]]; then
        zstd -dc "$src/acme.sh.tar.zst" | tar -xpf - -C /root 2>/dev/null || true
    fi

    # Compose projects
    if [[ -d "$src/compose-dirs" ]]; then
        local proj
        for proj in "$src/compose-dirs"/*/; do
            [[ -d "$proj" ]] || continue
            local orig="/opt/pasarguard"
            [[ -f "${proj}/.original_path" ]] && orig="$(tr -d '\r\n' < "${proj}/.original_path")"
            [[ -z "$orig" ]] && orig="/opt/pasarguard"
            msg_dim "  Restoring compose → $orig"
            mkdir -p "$orig"
            rsync -a --exclude '.original_path' "$proj" "$orig/" 2>/dev/null || cp -a "$proj"/. "$orig/" 2>/dev/null || true
        done
    fi

    # Volumes
    if [[ -d "$src/volumes" ]] && check_command docker; then
        systemctl start docker 2>/dev/null || true
        sleep 2
        local vf vol
        for vf in "$src/volumes"/*.tar.gz; do
            [[ -f "$vf" ]] || continue
            vol="$(basename "$vf" .tar.gz)"
            docker volume create "$vol" >/dev/null 2>&1 || true
            docker run --rm -v "${vol}:/v" -v "$(dirname "$vf"):/backup:ro" alpine:3.20 \
                sh -c "cd /v && tar xzf /backup/$(basename "$vf")" 2>/dev/null || \
            docker run --rm -v "${vol}:/v" -v "$(dirname "$vf"):/backup:ro" busybox \
                sh -c "cd /v && tar xzf /backup/$(basename "$vf")" 2>/dev/null || true
        done
    fi

    # Load optional images
    if [[ -d "$src/images" ]] && check_command docker; then
        local imgf
        for imgf in "$src/images"/*.tar.zst; do
            [[ -f "$imgf" ]] || continue
            nice -n 19 zstd -dc -T1 "$imgf" | nice -n 19 docker load 2>/dev/null || true
            sleep 1
        done
    fi

    [[ -d /var/lib/pg-node ]] && chmod -R u+rwX /var/lib/pg-node 2>/dev/null || true
    [[ -d /var/lib/pasarguard ]] && chmod -R u+rwX /var/lib/pasarguard 2>/dev/null || true

    # Stage MariaDB dumps always
    if [[ -d "$src/mariadb" ]]; then
        mkdir -p /root/smm-pasarguard-mariadb
        cp -a "$src/mariadb"/. /root/smm-pasarguard-mariadb/ 2>/dev/null || true
    fi

    # Auto-start only when explicitly enabled (safe default = no)
    if [[ "${RESTORE_DOCKER_AUTO_START:-no}" == "yes" || "${PASARGUARD_AUTO_START:-no}" == "yes" ]]; then
        if check_command docker; then
            systemctl start docker 2>/dev/null || true
            sleep 2
            if [[ -d /opt/pasarguard ]]; then
                msg_info "  Starting /opt/pasarguard (compose)..."
                (cd /opt/pasarguard && nice -n 10 docker compose -p pasarguard up -d 2>/dev/null) \
                    || (cd /opt/pasarguard && nice -n 10 docker compose up -d 2>/dev/null) \
                    || (cd /opt/pasarguard && nice -n 10 docker-compose up -d 2>/dev/null) || true
                sleep 8
                _pg_import_mariadb_dumps "${src}/mariadb"
            fi
        fi
    else
        msg_warn "  Panel files restored — NOT auto-started (safe mode)"
        msg_dim "    systemctl start docker"
        msg_dim "    cd /opt/pasarguard && docker compose -p pasarguard up -d"
        msg_dim "    # then import DB if needed from /root/smm-pasarguard-mariadb/"
    fi

    echo
    msg_warn "PasarGuard checklist:"
    msg_dim "  1) cd /opt/pasarguard && docker compose -p pasarguard up -d"
    msg_dim "  2) Panel UI → Nodes Online?"
    msg_dim "  3) If IP changed: update remote nodes to new panel address"
    msg_dim "  4) Certs: /var/lib/pasarguard/certs"
    msg_dim "  5) DB dumps: /root/smm-pasarguard-mariadb/"
    [[ -f "$src/README-PANEL.txt" ]] && cp -a "$src/README-PANEL.txt" /root/pasarguard-migration-notes.txt
    [[ -f "$src/README-NODES.txt" ]] && cp -a "$src/README-NODES.txt" /root/pasarguard-nodes-notes.txt 2>/dev/null || true

    msg_ok "PasarGuard restore phase completed"
    log_ok "PasarGuard restore completed"
}

#-------------------------------------------------------------------------------
# Standalone panel archive (not full OS)
#-------------------------------------------------------------------------------
create_pasarguard_panel_backup() {
    require_root
    set_log_file "${PROJECT_LOG_DIR:-/var/log/server-migration}/pasarguard-backup.log"
    check_dependencies

    local ts
    ts="$(timestamp 2>/dev/null || date '+%Y%m%d-%H%M%S')"
    local work="${BACKUP_DIR}/pasarguard-work-$$"
    local out_dir="$work/pasarguard"
    mkdir -p "$out_dir" "$BACKUP_DIR"

    msg_step "Creating PasarGuard PANEL backup bundle..."
    backup_pasarguard "$out_dir"

    if [[ -f "$out_dir/STATUS.txt" && "$(cat "$out_dir/STATUS.txt")" == "none" ]]; then
        msg_error "No PasarGuard panel found on this server"
        msg_dim "Expected: /opt/pasarguard and/or /var/lib/pasarguard"
        rm -rf "$work"
        return 1
    fi

    cat > "$work/MANIFEST.txt" <<EOF
type=pasarguard-panel
created=$(date -Iseconds)
hostname=$(hostname)
tool=JOJO_BACKUPER_v${SMM_VERSION:-?}
install_ref=pasarguard.sh @ install --database mariadb
EOF

    local archive="${BACKUP_DIR}/pasarguard-panel-${ts}.tar.zst"
    msg_step "Compressing bundle → $(basename "$archive")"
    nice -n 19 ionice -c3 tar -C "$work" -cf - . 2>/dev/null | nice -n 19 zstd -T2 -3 -o "$archive" \
        || tar -C "$work" -cf - . | zstd -T2 -3 -o "$archive"
    rm -rf "$work"

    if [[ ! -s "$archive" ]]; then
        msg_error "Failed to create panel archive"
        return 1
    fi

    create_checksum "$archive" >/dev/null 2>&1 || {
        local _h _b
        _h="$(sha256sum "$archive" | awk '{print $1}')"
        _b="$(basename "$archive")"
        printf '%s  %s\n' "$_h" "$_b" > "${archive}.sha256"
    }
    local size when
    size="$(human_size "$(stat -c%s "$archive")" 2>/dev/null || du -h "$archive" | awk '{print $1}')"
    when="$(format_backup_datetime "$ts")"
    msg_ok "PasarGuard panel backup ready: $(basename "$archive") ($size)"
    echo -e "  ${C_GREEN}${C_BOLD}Backup saved: $(basename "$archive") | ${when}${C_RESET}"
    msg_info "Date/Time: $when"
    mkdir -p "${PROJECT_LOG_DIR:-$BACKUP_DIR}"
    echo "$archive" > "${PROJECT_LOG_DIR:-$BACKUP_DIR}/.last_pasarguard_backup"
    PASARGUARD_LAST_ARCHIVE="$archive"
    log_ok "Panel archive $archive at $when"
    return 0
}

restore_pasarguard_panel_archive() {
    local archive="$1"
    local auto_start="${2:-no}"
    require_root
    [[ -f "$archive" ]] || die "Panel archive not found: $archive"

    if declare -f enforce_safe_restore_guards &>/dev/null; then
        # Keep SSH/boot safe; panel-only restore does not touch /boot anyway
        SAFE_RESTORE_GUARDS="${SAFE_RESTORE_GUARDS:-yes}"
    fi

    msg_step "Restoring PasarGuard panel from $(basename "$archive")..."
    local work="/tmp/smm-pg-restore-$$"
    mkdir -p "$work"
    nice -n 19 zstd -dc -T2 "$archive" | nice -n 19 tar -xpf - -C "$work" 2>/dev/null \
        || zstd -dc "$archive" | tar -xpf - -C "$work"

    local src=""
    if [[ -d "$work/pasarguard" ]]; then
        src="$work/pasarguard"
    else
        src="$(find "$work" -type d -name 'pasarguard' 2>/dev/null | head -1)"
    fi
    [[ -n "$src" && -d "$src" ]] || die "Invalid panel archive (no pasarguard/ payload)"

    # Ensure docker present (panel needs it) — package only; compose start gated by auto_start
    if declare -f ensure_docker_installed &>/dev/null; then
        ensure_docker_installed || msg_warn "Docker install failed — panel files restored anyway"
    elif ! check_command docker; then
        msg_info "Installing Docker for PasarGuard..."
        apt-get update -qq
        apt-get install -y docker.io docker-compose-v2 2>/dev/null \
            || apt-get install -y docker.io docker-compose 2>/dev/null || true
        systemctl enable docker 2>/dev/null || true
        systemctl start docker 2>/dev/null || true
    fi

    PASARGUARD_AUTO_START="$auto_start"
    RESTORE_DOCKER_AUTO_START="$auto_start"
    restore_pasarguard "$src"
    rm -rf "$work"
    msg_ok "PasarGuard panel restore finished"
}

#-------------------------------------------------------------------------------
# End-to-end: backup → connect → upload → remote restore (SAFE)
#-------------------------------------------------------------------------------
migrate_pasarguard_panel() {
    require_root
    set_log_file "${PROJECT_LOG_DIR:-/var/log/server-migration}/pasarguard-migrate.log"

    echo
    echo -e "${C_CYAN}${C_BOLD}════════════════════════════════════════${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}  انتقال پنل پاسارگارد                  ${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}  Migrate PasarGuard Panel              ${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}  JOJO BACKUPER · @B_KHANEMAN           ${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}════════════════════════════════════════${C_RESET}"
    echo
    msg_info "This migrates ONLY the PasarGuard panel (not full OS)."
    msg_dim "  Includes: /opt/pasarguard, /var/lib/pasarguard, SSL certs,"
    msg_dim "  MariaDB dump (nodes/users), compose, volumes, optional /var/lib/pg-node"
    msg_dim "  Safe: no /boot overwrite, no auto-reboot, no SSH lockout"
    echo

    if ! confirm_action "Create PasarGuard panel backup and transfer to NEW server?"; then
        return 1
    fi

    local archive
    create_pasarguard_panel_backup || return 1
    archive="${PASARGUARD_LAST_ARCHIVE:-}"
    [[ -n "$archive" && -f "$archive" ]] || {
        # Fallback: newest panel archive
        archive="$(ls -1t "${BACKUP_DIR}"/pasarguard-panel-*.tar.zst 2>/dev/null | head -1)"
    }
    [[ -f "$archive" ]] || { msg_error "Panel archive missing after backup"; return 1; }

    if [[ -z "${REMOTE_HOST:-}" ]]; then
        connect_new_server || return 1
    else
        msg_info "Using existing remote: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}"
        if ! test_ssh_connection; then
            connect_new_server || return 1
        fi
    fi

    local remote_path="${REMOTE_PATH:-/backup}"
    msg_step "Preparing remote ${REMOTE_HOST}:${remote_path} ..."
    remote_sudo "mkdir -p '${remote_path}' /opt/jojo-backup /var/log/server-migration" || return 1

    # Upload toolkit (for restore helpers)
    msg_step "Uploading JOJO toolkit..."
    local toolkit_tar="/tmp/jojo-pg-toolkit-$$.tar.zst"
    tar -C "$SCRIPT_DIR" -cf - \
        migrate.sh restore-agent.sh install.sh config.conf VERSION modules \
        2>/dev/null | zstd -T0 -3 -o "$toolkit_tar"

    _build_ssh_rsh 2>/dev/null || true
    local ssh_rsh="${SSH_RSH:-ssh}"
    if declare -f _build_ssh_rsh &>/dev/null; then
        _build_ssh_rsh
        ssh_rsh="$SSH_RSH"
    fi

    rsync -avz --progress -e "$ssh_rsh" "$toolkit_tar" \
        "${REMOTE_USER}@${REMOTE_HOST}:${remote_path}/jojo-backup-toolkit.tar.zst" || {
        msg_error "Toolkit upload failed"; rm -f "$toolkit_tar"; return 1
    }
    rm -f "$toolkit_tar"

    msg_step "Uploading panel archive $(basename "$archive")..."
    local files=("$archive")
    [[ -f "${archive}.sha256" ]] && files+=("${archive}.sha256")
    rsync -avz --progress -e "$ssh_rsh" "${files[@]}" \
        "${REMOTE_USER}@${REMOTE_HOST}:${remote_path}/" || {
        msg_error "Panel archive upload failed"; return 1
    }
    msg_ok "Upload complete"

    # Install toolkit remotely
    remote_sudo_script "set -e
mkdir -p /opt/jojo-backup
zstd -dc '${remote_path}/jojo-backup-toolkit.tar.zst' | tar -xf - -C /opt/jojo-backup
chmod +x /opt/jojo-backup/migrate.sh /opt/jojo-backup/restore-agent.sh /opt/jojo-backup/install.sh 2>/dev/null || true
cd /opt/jojo-backup && bash ./install.sh >/dev/null 2>&1 || true
echo TOOLKIT_OK
" || msg_warn "Toolkit install returned warnings — continuing"

    local start_flag="no"
    local ans=""
    if declare -f tty_read &>/dev/null; then
        tty_read "Start PasarGuard compose on NEW server after restore? [y/N]: " ans
    else
        read -r -p "Start PasarGuard compose on NEW server after restore? [y/N]: " ans < /dev/tty || true
    fi
    case "${ans:-N}" in y|Y|yes|YES) start_flag="yes" ;; *) start_flag="no" ;; esac

    msg_step "Restoring PasarGuard panel on ${REMOTE_HOST} (no reboot)..."
    local remote_archive="${remote_path}/$(basename "$archive")"
    local restore_remote
    restore_remote=$(cat <<EOF
set -e
export PASARGUARD_AUTO_START='${start_flag}'
export RESTORE_DOCKER_AUTO_START='${start_flag}'
export REBOOT_AFTER_RESTORE=no
export SAFE_RESTORE_GUARDS=yes
cd /opt/jojo-backup
# shellcheck disable=SC1091
source modules/common.sh
source modules/docker.sh
source modules/pasarguard.sh
[[ -f config.conf ]] && source config.conf
REBOOT_AFTER_RESTORE=no
SAFE_RESTORE_GUARDS=yes
PASARGUARD_AUTO_START='${start_flag}'
restore_pasarguard_panel_archive '${remote_archive}' '${start_flag}'
echo PG_RESTORE_OK
EOF
)

    if remote_sudo_script "$restore_remote"; then
        msg_ok "PasarGuard panel migrated to ${REMOTE_HOST}"
    else
        msg_error "Remote panel restore failed — check /var/log/server-migration/ on new server"
        return 1
    fi

    echo
    msg_ok "Done. On NEW server verify:"
    msg_dim "  ssh ${REMOTE_USER}@${REMOTE_HOST}"
    msg_dim "  ls -la /opt/pasarguard /var/lib/pasarguard"
    msg_dim "  cd /opt/pasarguard && docker compose -p pasarguard ps"
    msg_dim "  # if not started: docker compose -p pasarguard up -d"
    msg_warn "If panel IP/domain changed, update each remote NODE to the new address."
    log_ok "migrate_pasarguard_panel finished → $REMOTE_HOST"
}
