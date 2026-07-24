#!/usr/bin/env bash
#===============================================================================
# MODULE: Common utilities — colors, logging, progress, checks
# SERVER MIGRATION MANAGER v1.1 | JOJO BACKUP
#===============================================================================

# Prevent double-sourcing
[[ -n "${_SMM_COMMON_LOADED:-}" ]] && return 0
_SMM_COMMON_LOADED=1

#-------------------------------------------------------------------------------
# Colors
#-------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'
    C_MAGENTA='\033[0;35m'
    C_WHITE='\033[1;37m'
else
    C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW=''
    C_BLUE='' C_CYAN='' C_MAGENTA='' C_WHITE=''
fi

#-------------------------------------------------------------------------------
# Messaging
#-------------------------------------------------------------------------------
msg_info()    { echo -e "${C_CYAN}[+]${C_RESET} $*"; }
msg_ok()      { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
msg_warn()    { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
msg_error()   { echo -e "${C_RED}[ERROR]${C_RESET} $*"; }
msg_step()    { echo -e "${C_BLUE}[>>]${C_RESET} $*"; }
msg_dim()     { echo -e "${C_DIM}$*${C_RESET}"; }

die() {
    msg_error "$*"
    exit 1
}

#-------------------------------------------------------------------------------
# Logging
#-------------------------------------------------------------------------------
_ensure_log_dirs() {
    mkdir -p "${PROJECT_LOG_DIR:-./logs}" 2>/dev/null || true
    if [[ -w /var/log ]] || [[ "$(id -u)" -eq 0 ]]; then
        mkdir -p "${LOG_DIR:-/var/log/server-migration}" 2>/dev/null || true
    fi
}

log_write() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[$ts] [$level] $msg"
    _ensure_log_dirs
    local logfile="${CURRENT_LOG_FILE:-${PROJECT_LOG_DIR}/smm.log}"
    echo "$line" >> "$logfile" 2>/dev/null || true
    if [[ -d "${LOG_DIR:-}" ]] && [[ -w "${LOG_DIR:-}" ]]; then
        echo "$line" >> "${LOG_DIR}/$(basename "$logfile")" 2>/dev/null || true
    fi
}

log_info()  { log_write "INFO"  "$*"; }
log_ok()    { log_write "OK"    "$*"; }
log_warn()  { log_write "WARN"  "$*"; }
log_error() { log_write "ERROR" "$*"; }

set_log_file() {
    CURRENT_LOG_FILE="$1"
    _ensure_log_dirs
    touch "$CURRENT_LOG_FILE" 2>/dev/null || true
}

#-------------------------------------------------------------------------------
# Progress bar & spinner
#-------------------------------------------------------------------------------
progress_bar() {
    local percent="$1"
    local width="${2:-40}"
    local filled=$(( percent * width / 100 ))
    local empty=$(( width - filled ))
    local bar
    bar="$(printf '%0.s#' $(seq 1 "$filled" 2>/dev/null) 2>/dev/null || printf '#%.0s' $(eval echo "{1..$filled}"))"
    local pad
    pad="$(printf '%0.s-' $(seq 1 "$empty" 2>/dev/null) 2>/dev/null || printf '-%.0s' $(eval echo "{1..$empty}"))"
    printf "\r${C_CYAN}[%s%s]${C_RESET} %3d%%" "$bar" "$pad" "$percent"
    [[ "$percent" -ge 100 ]] && echo
}

# Simpler portable progress bar
show_progress() {
    local percent="$1"
    local width="${2:-40}"
    (( percent > 100 )) && percent=100
    (( percent < 0 )) && percent=0
    local filled=$(( percent * width / 100 ))
    local empty=$(( width - filled ))
    printf "\r${C_CYAN}["
    printf "%${filled}s" | tr ' ' '#'
    printf "%${empty}s" | tr ' ' '-'
    printf "]${C_RESET} %3d%%" "$percent"
    [[ "$percent" -ge 100 ]] && echo
}

spinner_pid=""
start_spinner() {
    local msg="${1:-Working...}"
    (
        local frames=('|' '/' '-' '\')
        local i=0
        while true; do
            printf "\r${C_CYAN}[%s]${C_RESET} %s" "${frames[$i]}" "$msg"
            i=$(( (i + 1) % 4 ))
            sleep 0.12
        done
    ) &
    spinner_pid=$!
    disown "$spinner_pid" 2>/dev/null || true
}

stop_spinner() {
    if [[ -n "${spinner_pid:-}" ]] && kill -0 "$spinner_pid" 2>/dev/null; then
        kill "$spinner_pid" 2>/dev/null || true
        wait "$spinner_pid" 2>/dev/null || true
    fi
    spinner_pid=""
    printf "\r%*s\r" 80 ""
}

# Animated loading dots
loading_anim() {
    local msg="$1"
    local duration="${2:-2}"
    local end=$(( SECONDS + duration ))
    local frames=('.  ' '.. ' '...' '   ')
    local i=0
    while (( SECONDS < end )); do
        printf "\r${C_CYAN}[+]${C_RESET} %s%s" "$msg" "${frames[$i]}"
        i=$(( (i + 1) % 4 ))
        sleep 0.25
    done
    printf "\r${C_CYAN}[+]${C_RESET} %s   \n" "$msg"
}

#-------------------------------------------------------------------------------
# System checks
#-------------------------------------------------------------------------------
require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "This tool must be run as root. Use: sudo $0"
    fi
}

check_command() {
    command -v "$1" &>/dev/null
}

require_commands() {
    local missing=()
    for cmd in "$@"; do
        check_command "$cmd" || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        msg_error "Missing required commands: ${missing[*]}"
        msg_info "Install with: apt-get install -y ${missing[*]}"
        return 1
    fi
    return 0
}

check_dependencies() {
    msg_step "Checking dependencies..."
    local required=(tar rsync ssh scp sha256sum df awk sed grep)
    local optional=(zstd pv gzip xz iptables nft docker systemctl)
    local missing=()

    for cmd in "${required[@]}"; do
        if ! check_command "$cmd"; then
            missing+=("$cmd")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        msg_warn "Installing missing required packages: ${missing[*]}"
        apt-get update -qq 2>/dev/null || true
        apt-get install -y "${missing[@]}" 2>/dev/null || {
            die "Failed to install: ${missing[*]}"
        }
    fi

    # Ensure zstd
    if ! check_command zstd; then
        msg_info "Installing zstd..."
        apt-get update -qq && apt-get install -y zstd || die "Cannot install zstd"
    fi

    # Optional: pv for progress
    if ! check_command pv; then
        msg_dim "Installing pv (progress monitor)..."
        apt-get install -y pv 2>/dev/null || msg_warn "pv not available — progress bars will be limited"
    fi

    # sshpass for password auth
    if ! check_command sshpass; then
        apt-get install -y sshpass 2>/dev/null || true
    fi

    # flock for process lock
    if ! check_command flock; then
        apt-get install -y util-linux 2>/dev/null || true
    fi

    # curl for notifications / postcheck
    if ! check_command curl; then
        apt-get install -y curl 2>/dev/null || true
    fi

    msg_ok "Dependencies OK"
    log_ok "Dependency check passed"
}

check_disk_space() {
    local target_dir="${1:-$BACKUP_DIR}"
    local min_gb="${2:-${MIN_FREE_SPACE_GB:-10}}"
    mkdir -p "$target_dir"
    local avail_kb
    avail_kb="$(df -Pk "$target_dir" | awk 'NR==2 {print $4}')"
    local avail_gb=$(( avail_kb / 1024 / 1024 ))
    msg_info "Available disk space: ${avail_gb} GB (required: ${min_gb} GB)"
    if (( avail_gb < min_gb )); then
        die "Insufficient disk space on $target_dir (${avail_gb} GB < ${min_gb} GB)"
    fi
    log_info "Disk space check OK: ${avail_gb} GB free"
}

confirm_action() {
    local prompt="${1:-Continue?}"
    if [[ "${REQUIRE_CONFIRMATION:-yes}" != "yes" ]]; then
        return 0
    fi
    echo
    echo -e "${C_YELLOW}${C_BOLD}WARNING:${C_RESET}"
    echo -e "${C_YELLOW}$prompt${C_RESET}"
    echo
    local answer=""
    if [[ -r /dev/tty ]]; then
        read -r -p "Type 'YES' to continue: " answer < /dev/tty || true
    else
        read -r -p "Type 'YES' to continue: " answer || true
    fi
    if [[ "$answer" != "YES" ]]; then
        msg_warn "Aborted by user."
        return 1
    fi
    return 0
}

pause_enter() {
    echo
    if [[ -r /dev/tty ]]; then
        read -r -p "Press ENTER to continue..." _ < /dev/tty || true
    else
        read -r -p "Press ENTER to continue..." _ || true
    fi
}

#-------------------------------------------------------------------------------
# SSH helpers
#-------------------------------------------------------------------------------
build_ssh_opts() {
    local opts=(
        -o StrictHostKeyChecking=accept-new
        -o UserKnownHostsFile="${HOME}/.ssh/known_hosts"
        -o ConnectTimeout=20
        -o ServerAliveInterval=30
        -o ServerAliveCountMax=3
        -o LogLevel=ERROR
    )
    opts+=(-p "${REMOTE_PORT:-22}")

    if [[ "${AUTH_METHOD:-key}" == "password" ]]; then
        # Prefer password; keep keyboard-interactive (Ubuntu often uses it for passwords)
        opts+=(
            -o PreferredAuthentications=password,keyboard-interactive
            -o PubkeyAuthentication=no
            -o PasswordAuthentication=yes
            -o NumberOfPasswordPrompts=1
            -o IdentitiesOnly=yes
            -o IdentityAgent=none
        )
    elif [[ -n "${SSH_KEY:-}" && -f "${SSH_KEY}" ]]; then
        opts+=(-i "$SSH_KEY" -o IdentitiesOnly=yes -o PreferredAuthentications=publickey)
    fi

    printf '%s\n' "${opts[@]}"
}

ssh_cmd() {
    local remote_cmd="$1"
    local opts
    mapfile -t opts < <(build_ssh_opts)

    if [[ "${AUTH_METHOD:-key}" == "password" ]]; then
        if [[ -z "${SSH_PASSWORD:-}" && -f "${PROJECT_LOG_DIR:-}/.ssh_password" ]]; then
            SSH_PASSWORD="$(cat "${PROJECT_LOG_DIR}/.ssh_password")"
        fi
        if [[ -z "${SSH_PASSWORD:-}" ]]; then
            msg_error "SSH password is empty — re-enter connection details"
            return 1
        fi
        if ! check_command sshpass; then
            apt-get install -y sshpass >/dev/null 2>&1 || die "sshpass required: apt-get install -y sshpass"
        fi
        # -e uses SSHPASS env (safer than -p for special chars)
        # -P 'assword' matches password / Password / keyboard-interactive prompts
        SSHPASS="$SSH_PASSWORD" sshpass -e -P 'assword' ssh "${opts[@]}" \
            "${REMOTE_USER}@${REMOTE_HOST}" "$remote_cmd"
    else
        ssh "${opts[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "$remote_cmd"
    fi
}

scp_cmd() {
    local src="$1"
    local dst="$2"
    local scp_opts=(
        -o StrictHostKeyChecking=accept-new
        -o ConnectTimeout=20
        -P "${REMOTE_PORT:-22}"
    )
    if [[ "${AUTH_METHOD:-key}" == "password" ]]; then
        scp_opts+=(
            -o PreferredAuthentications=password,keyboard-interactive
            -o PubkeyAuthentication=no
            -o PasswordAuthentication=yes
            -o IdentitiesOnly=yes
            -o IdentityAgent=none
        )
        if [[ -z "${SSH_PASSWORD:-}" && -f "${PROJECT_LOG_DIR:-}/.ssh_password" ]]; then
            SSH_PASSWORD="$(cat "${PROJECT_LOG_DIR}/.ssh_password")"
        fi
        SSHPASS="$SSH_PASSWORD" sshpass -e -P 'assword' scp "${scp_opts[@]}" "$src" "$dst"
    else
        if [[ -n "${SSH_KEY:-}" && -f "${SSH_KEY}" ]]; then
            scp_opts+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
        fi
        scp "${scp_opts[@]}" "$src" "$dst"
    fi
}

_probe_tcp_port() {
    local host="$1" port="$2"
    if check_command timeout && check_command bash; then
        timeout 5 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null && return 0
    fi
    if check_command nc; then
        nc -z -w 5 "$host" "$port" 2>/dev/null && return 0
    fi
    return 1
}

test_ssh_connection() {
    msg_step "Testing SSH connection to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}..."
    msg_dim "  Auth method: ${AUTH_METHOD:-key}"

    if [[ -z "${REMOTE_HOST:-}" ]]; then
        msg_error "REMOTE_HOST is empty"
        return 1
    fi

    # Port reachability
    if _probe_tcp_port "$REMOTE_HOST" "${REMOTE_PORT:-22}"; then
        msg_ok "Port ${REMOTE_PORT} is reachable"
    else
        msg_warn "Cannot confirm port ${REMOTE_PORT} is open (firewall / wrong IP / SSH down?)"
    fi

    if [[ "${AUTH_METHOD:-key}" == "password" ]]; then
        if ! check_command sshpass; then
            msg_info "Installing sshpass..."
            apt-get update -qq && apt-get install -y sshpass || die "Cannot install sshpass"
        fi
        if [[ -z "${SSH_PASSWORD:-}" ]]; then
            msg_error "Password is empty"
            return 1
        fi
        msg_dim "  Password length: ${#SSH_PASSWORD} chars"
    fi

    local out err tmp_err
    tmp_err="$(mktemp /tmp/smm-ssh-err.XXXXXX 2>/dev/null || echo /tmp/smm-ssh-err.$$)"
    out="$(ssh_cmd "echo SMM_OK; whoami; uname -n" 2>"$tmp_err")" || true
    err="$(cat "$tmp_err" 2>/dev/null || true)"
    rm -f "$tmp_err"

    if echo "$out" | grep -q "SMM_OK"; then
        msg_ok "SSH connection successful"
        msg_dim "  $(echo "$out" | tr '\n' ' ')"
        log_ok "SSH connected to ${REMOTE_HOST}"
        return 0
    fi

    msg_error "SSH connection failed"
    if [[ -n "$err" ]]; then
        echo -e "${C_YELLOW}── SSH error detail ──${C_RESET}"
        echo "$err" | sed 's/^/  /'
        echo -e "${C_YELLOW}──────────────────────${C_RESET}"
        log_error "SSH fail: $err"
    else
        msg_dim "  (no stderr captured)"
    fi

    echo
    msg_info "Checklist on NEW server (${REMOTE_HOST}):"
    msg_dim "  1) SSH running:          systemctl status ssh"
    msg_dim "  2) Password auth ON:     grep PasswordAuthentication /etc/ssh/sshd_config"
    msg_dim "  3) Root login allowed:   grep PermitRootLogin /etc/ssh/sshd_config"
    msg_dim "  4) Firewall allows 22:   ufw status / iptables"
    msg_dim "  5) Test manually:        ssh -p ${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST}"
    return 1
}

#-------------------------------------------------------------------------------
# Checksum
#-------------------------------------------------------------------------------
create_checksum() {
    local file="$1"
    local sumfile="${file}.sha256"
    msg_step "Generating SHA256 checksum..."
    sha256sum "$file" > "$sumfile"
    msg_ok "Checksum: $(awk '{print $1}' "$sumfile")"
    log_ok "Checksum created: $sumfile"
    echo "$sumfile"
}

verify_checksum() {
    local file="$1"
    local sumfile="${2:-${file}.sha256}"
    if [[ ! -f "$sumfile" ]]; then
        msg_error "Checksum file not found: $sumfile"
        return 1
    fi
    msg_step "Verifying SHA256 integrity..."
    if (cd "$(dirname "$file")" && sha256sum -c "$(basename "$sumfile")" 2>/dev/null) || \
       sha256sum -c "$sumfile" --ignore-missing 2>/dev/null; then
        # Fallback manual verify
        local expected actual
        expected="$(awk '{print $1}' "$sumfile")"
        actual="$(sha256sum "$file" | awk '{print $1}')"
        if [[ "$expected" == "$actual" ]]; then
            msg_ok "Checksum verified"
            log_ok "Checksum OK for $file"
            return 0
        fi
    fi
    # Manual compare always
    local expected actual
    expected="$(awk '{print $1}' "$sumfile")"
    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [[ "$expected" == "$actual" ]]; then
        msg_ok "Checksum verified"
        log_ok "Checksum OK for $file"
        return 0
    fi
    msg_error "Checksum MISMATCH!"
    msg_dim "Expected: $expected"
    msg_dim "Actual:   $actual"
    log_error "Checksum mismatch for $file"
    return 1
}

#-------------------------------------------------------------------------------
# Timestamp helper
#-------------------------------------------------------------------------------
timestamp() {
    date '+%Y%m%d-%H%M%S'
}

# Convert compact ts (YYYYMMDD-HHMMSS) → human "YYYY-MM-DD HH:MM:SS"
format_backup_datetime() {
    local ts="${1:-}"
    if [[ "$ts" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
        echo "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}"
        return 0
    fi
    date '+%Y-%m-%d %H:%M:%S'
}

# Extract / format date-time from a backup filename or fall back to file mtime
backup_datetime_label() {
    local path="${1:-}"
    local base ts
    base="$(basename "$path" 2>/dev/null || echo "$path")"
    if [[ "$base" =~ ([0-9]{8}-[0-9]{6}) ]]; then
        format_backup_datetime "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ -f "$path" ]]; then
        ts="$(stat -c%y "$path" 2>/dev/null | cut -d. -f1)"
        [[ -n "$ts" ]] && { echo "$ts"; return 0; }
    fi
    date '+%Y-%m-%d %H:%M:%S'
}

human_size() {
    local bytes="$1"
    if check_command numfmt; then
        numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B"
    else
        awk -v b="$bytes" 'BEGIN{
            split("B KB MB GB TB", u, " ");
            for(i=1;b>=1024&&i<5;i++) b/=1024;
            printf "%.2f %s\n", b, u[i]
        }'
    fi
}

#-------------------------------------------------------------------------------
# Banner
#-------------------------------------------------------------------------------
print_banner() {
    clear
    echo -e "${C_CYAN}${C_BOLD}"
    echo "========================================="
    echo "  JOJO BACKUPER  ·  SMM v${SMM_VERSION:-1.1}"
    echo "  by @B_KHANEMAN"
    echo "========================================="
    echo -e "${C_RESET}"
}

print_menu() {
    print_banner
    echo -e "  ${C_GREEN}${C_BOLD}─── Quick / Core ───${C_RESET}"
    echo -e "  ${C_WHITE} 1)${C_RESET} ${C_GREEN}Deploy to New Server${C_RESET}  ${C_DIM}(ask details + upload backups + install scripts)${C_RESET}"
    echo -e "  ${C_WHITE} 2)${C_RESET} ${C_YELLOW}Restore Backup (sudo)${C_RESET} ${C_DIM}(overwrite new server safely)${C_RESET}"
    echo -e "  ${C_WHITE} 3)${C_RESET} ${C_MAGENTA}انتقال پنل پاسارگارد${C_RESET} / ${C_MAGENTA}Migrate PasarGuard Panel${C_RESET}"
    echo -e "      ${C_DIM}(certs + nodes DB + /opt + /var/lib + MariaDB + compose)${C_RESET}"
    echo -e "  ${C_WHITE} 4)${C_RESET} Create Full Server Backup"
    echo
    echo -e "  ${C_CYAN}${C_BOLD}─── Connection & Transfer ───${C_RESET}"
    echo -e "  ${C_WHITE} 5)${C_RESET} Connect To New Server"
    echo -e "  ${C_WHITE} 6)${C_RESET} Upload Backup Only"
    echo
    echo -e "  ${C_DIM}─── Tools ───${C_RESET}"
    echo -e "  ${C_WHITE} 7)${C_RESET} Verify Backup"
    echo -e "  ${C_WHITE} 8)${C_RESET} Show Backup Information"
    echo -e "  ${C_WHITE} 9)${C_RESET} ${C_RED}حذف بکاپ${C_RESET} / ${C_RED}Delete Backup${C_RESET}"
    echo -e "  ${C_WHITE}10)${C_RESET} Pre-flight Check"
    echo -e "  ${C_WHITE}11)${C_RESET} Post-Migration Health Check"
    echo -e "  ${C_WHITE}12)${C_RESET} ${C_MAGENTA}Update from GitHub${C_RESET}  ${C_DIM}(auto-pull latest JOJO BACKUPER)${C_RESET}"
    echo -e "  ${C_WHITE}13)${C_RESET} Exit"
    echo
    echo -e "  ${C_YELLOW}${C_BOLD}─── More ───${C_RESET}"
    echo -e "  ${C_WHITE}14)${C_RESET} Advanced tools  ${C_DIM}(estimate, wizard, cleanup, report, schedule, notify)${C_RESET}"
    echo
    echo -e "${C_DIM}-----------------------------------------${C_RESET}"
    if [[ -n "${REMOTE_HOST:-}" ]]; then
        echo -e "  Remote: ${C_GREEN}${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}${C_RESET}"
    else
        echo -e "  Remote: ${C_YELLOW}(not configured)${C_RESET}"
    fi
    local latest
    latest="$(ls -1t "${BACKUP_DIR}"/server-backup-* "${BACKUP_DIR}"/pasarguard-panel-* 2>/dev/null | grep -E '\.tar\.zst(\.gpg|\.enc)?$' | head -1)"
    if [[ -n "$latest" ]]; then
        echo -e "  Latest: ${C_CYAN}$(basename "$latest")${C_RESET}"
        echo -e "  Date   : ${C_WHITE}$(backup_datetime_label "$latest")${C_RESET}"
    fi
    if [[ -f "${PROJECT_LOG_DIR}/.last_deploy" ]]; then
        echo -e "  Deploy: ${C_GREEN}ready for restore${C_RESET}"
    fi
    local ver
    ver="$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo "${SMM_VERSION:-?}")"
    echo -e "  Version: ${C_WHITE}v${ver}${C_RESET}  ${C_DIM}@B_KHANEMAN${C_RESET}"
    [[ "${ENCRYPT_BACKUP:-no}" == "yes" ]] && echo -e "  Crypto: ${C_YELLOW}ON (${ENCRYPT_METHOD})${C_RESET}"
    [[ "${NOTIFY_ENABLED:-no}" == "yes" ]] && echo -e "  Notify: ${C_GREEN}ON${C_RESET}"
    echo -e "${C_DIM}-----------------------------------------${C_RESET}"
    echo
}

print_advanced_menu() {
    echo
    echo -e "  ${C_YELLOW}${C_BOLD}─── Advanced tools ───${C_RESET}"
    echo -e "  ${C_WHITE} 1)${C_RESET} Estimate Backup Size"
    echo -e "  ${C_WHITE} 2)${C_RESET} Full Migration Wizard"
    echo -e "  ${C_WHITE} 3)${C_RESET} Cleanup / Delete Backups  ${C_DIM}(interactive)${C_RESET}"
    echo -e "  ${C_WHITE} 4)${C_RESET} Generate Migration Report"
    echo -e "  ${C_WHITE} 5)${C_RESET} Schedule Weekly Backup"
    echo -e "  ${C_WHITE} 6)${C_RESET} Test Notifications"
    echo -e "  ${C_WHITE} 0)${C_RESET} Back to main menu"
    echo
}

#-------------------------------------------------------------------------------
# Cloud-init cleanup (after restore — keep datasources)
#-------------------------------------------------------------------------------
clean_cloud_init() {
    if [[ "${CLEAN_CLOUD_INIT:-yes}" != "yes" ]]; then
        return 0
    fi
    msg_step "Cleaning cloud-init instance state (keep datasources)..."
    # Do NOT wipe /etc/netplan — KEEP_TARGET_NETWORK already restored it
    cloud-init clean --logs 2>/dev/null || true
    rm -rf /var/lib/cloud/instances/* 2>/dev/null || true
    rm -f /var/lib/cloud/instance 2>/dev/null || true
    # Prevent cloud-init from rewriting network on next boot if we keep target netplan
    if [[ "${KEEP_TARGET_NETWORK:-yes}" == "yes" ]]; then
        mkdir -p /etc/cloud/cloud.cfg.d
        cat > /etc/cloud/cloud.cfg.d/99-smm-disable-network.cfg <<'EOF'
network:
  config: disabled
EOF
    fi
    msg_ok "cloud-init cleaned"
}

#-------------------------------------------------------------------------------
# Hard safety guards — prevent brick / SSH lockout / CPU death
# Old config.conf from previous installs may still have dangerous =yes values.
#-------------------------------------------------------------------------------
enforce_safe_restore_guards() {
    if [[ "${SAFE_RESTORE_GUARDS:-yes}" != "yes" ]]; then
        msg_warn "SAFE_RESTORE_GUARDS=no — brick/lockout protections DISABLED"
        return 0
    fi
    RESTORE_BOOT="no"
    RESTORE_USR="no"
    RESTORE_FSTAB="no"
    KEEP_TARGET_NETWORK="yes"
    RESTORE_NETWORK="no"
    RESTORE_FIREWALL="no"
    RESTORE_SECURITY="no"
    RESTORE_SSHD_CONFIG="no"
    RESTORE_TUNNELS="no"
    RESTORE_DOCKER_AUTO_START="no"
    RESTORE_DOCKER_IMAGES="no"
    RESTORE_MAIL="no"
    # Reboot only if caller explicitly set do_reboot path; default config stays no
    if [[ "${REBOOT_AFTER_RESTORE:-no}" == "yes" ]]; then
        msg_warn "REBOOT_AFTER_RESTORE was yes — forcing no (reboot manually after SSH check)"
        REBOOT_AFTER_RESTORE="no"
    fi
    msg_ok "Safe restore guards ON (boot/usr/fstab/net/fw/sshd/docker-start locked)"
}

# Merge critical safe keys into an existing config.conf (used by update)
merge_safe_config_keys() {
    local cfg="${1:-}"
    [[ -f "$cfg" ]] || return 0
    local tmp="${cfg}.safe-merge.$$"
    cp -a "$cfg" "$tmp"
    _set_cfg_key() {
        local key="$1" val="$2" file="$3"
        if grep -qE "^[[:space:]]*${key}=" "$file" 2>/dev/null; then
            sed -i "s|^[[:space:]]*${key}=.*|${key}=\"${val}\"|" "$file"
        else
            printf '\n%s="%s"\n' "$key" "$val" >> "$file"
        fi
    }
    _set_cfg_key REBOOT_AFTER_RESTORE no "$tmp"
    _set_cfg_key RESTORE_BOOT no "$tmp"
    _set_cfg_key RESTORE_USR no "$tmp"
    _set_cfg_key RESTORE_FSTAB no "$tmp"
    _set_cfg_key KEEP_TARGET_NETWORK yes "$tmp"
    _set_cfg_key RESTORE_NETWORK no "$tmp"
    _set_cfg_key RESTORE_FIREWALL no "$tmp"
    _set_cfg_key RESTORE_SECURITY no "$tmp"
    _set_cfg_key RESTORE_SSHD_CONFIG no "$tmp"
    _set_cfg_key RESTORE_TUNNELS no "$tmp"
    _set_cfg_key RESTORE_DOCKER_AUTO_START no "$tmp"
    _set_cfg_key RESTORE_DOCKER_IMAGES no "$tmp"
    _set_cfg_key RESTORE_MAIL no "$tmp"
    _set_cfg_key SAFE_RESTORE_GUARDS yes "$tmp"
    mv -f "$tmp" "$cfg"
}