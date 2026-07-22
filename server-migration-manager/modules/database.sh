#!/usr/bin/env bash
#===============================================================================
# MODULE: Database Backup & Restore
# MySQL / MariaDB / PostgreSQL / Redis / MongoDB
# SERVER MIGRATION MANAGER v1.0 | JOJO BACKUP
#===============================================================================

backup_databases() {
    local out="${1:-}"
    [[ -z "$out" ]] && out="${METADATA_DIR:-/tmp}/databases"
    mkdir -p "$out"

    msg_info "Detecting and backing up databases..."
    local any=0

    #----- MySQL / MariaDB -----
    if check_command mysqldump || systemctl is-active --quiet mysql 2>/dev/null || \
       systemctl is-active --quiet mariadb 2>/dev/null || \
       check_command mysql; then
        if check_command mysqldump; then
            msg_info "  Dumping MySQL/MariaDB (all databases)..."
            local mysql_opts=(--all-databases --single-transaction --quick --lock-tables=false --routines --triggers --events)
            # Prefer socket auth as root
            if mysqldump "${mysql_opts[@]}" 2>/dev/null | gzip > "$out/mysql-all.sql.gz"; then
                if [[ -s "$out/mysql-all.sql.gz" ]]; then
                    msg_ok "  MySQL/MariaDB dump OK"
                    any=1
                else
                    rm -f "$out/mysql-all.sql.gz"
                    msg_warn "  MySQL dump empty — may need credentials"
                fi
            else
                # Try with debian-sys-maint
                if [[ -f /etc/mysql/debian.cnf ]]; then
                    mysqldump --defaults-file=/etc/mysql/debian.cnf "${mysql_opts[@]}" 2>/dev/null \
                        | gzip > "$out/mysql-all.sql.gz" && any=1 && msg_ok "  MySQL dump via debian.cnf OK"
                else
                    msg_warn "  mysqldump failed — ensure root can connect without password or set ~/.my.cnf"
                fi
            fi
            # Also copy datadir hint
            mysql -Nse "SHOW VARIABLES LIKE 'datadir';" > "$out/mysql.datadir" 2>/dev/null || true
        fi
        [[ -d /etc/mysql ]] && cp -a /etc/mysql "$out/mysql-config" 2>/dev/null || true
    fi

    #----- PostgreSQL -----
    if check_command pg_dumpall || systemctl is-active --quiet postgresql 2>/dev/null || \
       check_command psql; then
        if check_command pg_dumpall; then
            msg_info "  Dumping PostgreSQL (pg_dumpall)..."
            if sudo -u postgres pg_dumpall 2>/dev/null | gzip > "$out/postgresql-all.sql.gz"; then
                if [[ -s "$out/postgresql-all.sql.gz" ]]; then
                    msg_ok "  PostgreSQL dump OK"
                    any=1
                else
                    rm -f "$out/postgresql-all.sql.gz"
                    msg_warn "  PostgreSQL dump empty"
                fi
            else
                msg_warn "  pg_dumpall failed — check postgres user access"
            fi
        fi
        [[ -d /etc/postgresql ]] && cp -a /etc/postgresql "$out/postgresql-config" 2>/dev/null || true
    fi

    #----- Redis -----
    if check_command redis-cli || systemctl is-active --quiet redis 2>/dev/null || \
       systemctl is-active --quiet redis-server 2>/dev/null; then
        msg_info "  Backing up Redis..."
        if check_command redis-cli; then
            redis-cli BGSAVE >/dev/null 2>&1 || true
            sleep 2
            # Find dump.rdb
            local rdb
            rdb="$(redis-cli CONFIG GET dir 2>/dev/null | tail -1)/dump.rdb"
            [[ -f "$rdb" ]] && cp -a "$rdb" "$out/redis-dump.rdb" && any=1 && msg_ok "  Redis RDB copied"
            redis-cli --rdb "$out/redis-dump.rdb" 2>/dev/null && any=1 || true
            redis-cli INFO > "$out/redis.info" 2>/dev/null || true
        fi
        [[ -f /etc/redis/redis.conf ]] && cp -a /etc/redis/redis.conf "$out/" 2>/dev/null || true
        [[ -d /etc/redis ]] && cp -a /etc/redis "$out/redis-config" 2>/dev/null || true
    fi

    #----- MongoDB -----
    if check_command mongodump || systemctl is-active --quiet mongod 2>/dev/null || \
       check_command mongosh || check_command mongo; then
        if check_command mongodump; then
            msg_info "  Dumping MongoDB..."
            mkdir -p "$out/mongodb"
            if mongodump --out "$out/mongodb" 2>/dev/null; then
                msg_ok "  MongoDB dump OK"
                any=1
            else
                msg_warn "  mongodump failed — check auth"
            fi
        fi
        [[ -d /etc/mongod.conf ]] || [[ -f /etc/mongod.conf ]] && cp -a /etc/mongod.conf "$out/" 2>/dev/null || true
    fi

    if [[ $any -eq 0 ]]; then
        msg_dim "  No databases detected or dumps were empty"
        echo "none" > "$out/STATUS.txt"
    else
        echo "ok" > "$out/STATUS.txt"
    fi

    log_ok "Database backup → $out"
}

restore_databases() {
    local src="${1:-}"
    [[ -z "$src" || ! -d "$src" ]] && { msg_warn "No database backup found"; return 0; }

    if [[ "${RESTORE_DATABASES:-yes}" != "yes" ]]; then
        msg_dim "Database restore skipped (config)"
        return 0
    fi

    msg_step "Restoring databases..."
    log_info "Restoring databases from $src"

    # MySQL
    if [[ -f "$src/mysql-all.sql.gz" ]]; then
        msg_info "  Restoring MySQL/MariaDB..."
        # Ensure server is running
        systemctl start mysql 2>/dev/null || systemctl start mariadb 2>/dev/null || true
        sleep 2
        if check_command mysql; then
            if gunzip -c "$src/mysql-all.sql.gz" | mysql 2>/dev/null; then
                msg_ok "  MySQL restored"
            elif [[ -f /etc/mysql/debian.cnf ]]; then
                gunzip -c "$src/mysql-all.sql.gz" | mysql --defaults-file=/etc/mysql/debian.cnf 2>/dev/null \
                    && msg_ok "  MySQL restored (debian.cnf)" \
                    || msg_warn "  MySQL restore failed — import manually: gunzip -c mysql-all.sql.gz | mysql"
            else
                msg_warn "  MySQL restore failed — import manually"
            fi
        fi
        [[ -d "$src/mysql-config" ]] && cp -a "$src/mysql-config/." /etc/mysql/ 2>/dev/null || true
    fi

    # PostgreSQL
    if [[ -f "$src/postgresql-all.sql.gz" ]]; then
        msg_info "  Restoring PostgreSQL..."
        systemctl start postgresql 2>/dev/null || true
        sleep 2
        if check_command psql; then
            gunzip -c "$src/postgresql-all.sql.gz" | sudo -u postgres psql 2>/dev/null \
                && msg_ok "  PostgreSQL restored" \
                || msg_warn "  PostgreSQL restore had errors (often OK for role exists)"
        fi
        [[ -d "$src/postgresql-config" ]] && cp -a "$src/postgresql-config/." /etc/postgresql/ 2>/dev/null || true
    fi

    # Redis
    if [[ -f "$src/redis-dump.rdb" ]]; then
        msg_info "  Restoring Redis..."
        systemctl stop redis-server 2>/dev/null || systemctl stop redis 2>/dev/null || true
        local rdir="/var/lib/redis"
        [[ -d "$rdir" ]] || rdir="/var/lib/redis/dump"
        mkdir -p /var/lib/redis
        cp -a "$src/redis-dump.rdb" /var/lib/redis/dump.rdb
        chown redis:redis /var/lib/redis/dump.rdb 2>/dev/null || true
        systemctl start redis-server 2>/dev/null || systemctl start redis 2>/dev/null || true
        msg_ok "  Redis RDB restored"
    fi

    # MongoDB
    if [[ -d "$src/mongodb" ]] && check_command mongorestore; then
        msg_info "  Restoring MongoDB..."
        systemctl start mongod 2>/dev/null || true
        sleep 2
        mongorestore "$src/mongodb" 2>/dev/null \
            && msg_ok "  MongoDB restored" \
            || msg_warn "  MongoDB restore had errors"
    fi

    msg_ok "Database restore phase completed"
    log_ok "Database restore completed"
}
