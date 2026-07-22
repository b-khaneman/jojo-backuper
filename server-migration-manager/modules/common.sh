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
    read -r -p "Type 'YES' to continue: " answer
    if [[ "$answer" != "YES" ]]; then
        msg_warn "Aborted by user."
        return 1
    fi
    return 0
}

pause_enter() {
    echo
    read -r -p "Press ENTER to continue..." _
}

#-------------------------------------------------------------------------------
# SSH helpers
#-------------------------------------------------------------------------------
build_ssh_opts() {
    local opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=30)
    opts+=(-p "${REMOTE_PORT:-22}")
    if [[ "${AUTH_METHOD:-key}" == "key" && -n "${SSH_KEY:-}" ]]; then
        opts+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
    fi
    printf '%s\n' "${opts[@]}"
}

ssh_cmd() {
    local remote_cmd="$1"
    local opts
    mapfile -t opts < <(build_ssh_opts)
    if [[ "${AUTH_METHOD:-key}" == "password" && -n "${SSH_PASSWORD:-}" ]]; then
        if check_command sshpass; then
            SSHPASS="$SSH_PASSWORD" sshpass -e ssh "${opts[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "$remote_cmd"
        else
            die "sshpass is required for password authentication. Install: apt-get install -y sshpass"
        fi
    else
        ssh "${opts[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "$remote_cmd"
    fi
}

scp_cmd() {
    local src="$1"
    local dst="$2"
    local opts
    mapfile -t opts < <(build_ssh_opts)
    # scp uses -P for port
    local scp_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -P "${REMOTE_PORT:-22}")
    if [[ "${AUTH_METHOD:-key}" == "key" && -n "${SSH_KEY:-}" ]]; then
        scp_opts+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
    fi
    if [[ "${AUTH_METHOD:-key}" == "password" && -n "${SSH_PASSWORD:-}" ]]; then
        SSHPASS="$SSH_PASSWORD" sshpass -e scp "${scp_opts[@]}" "$src" "$dst"
    else
        scp "${scp_opts[@]}" "$src" "$dst"
    fi
}

test_ssh_connection() {
    msg_step "Testing SSH connection to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}..."
    if ssh_cmd "echo SMM_OK && uname -a && whoami" 2>/dev/null | grep -q "SMM_OK"; then
        msg_ok "SSH connection successful"
        log_ok "SSH connected to ${REMOTE_HOST}"
        return 0
    else
        msg_error "SSH connection failed"
        log_error "SSH connection failed to ${REMOTE_HOST}"
        return 1
    fi
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
    echo -e "  ${C_GREEN}${C_BOLD}─── Quick Migration ───${C_RESET}"
    echo -e "  ${C_WHITE} 1)${C_RESET} ${C_GREEN}Deploy to New Server${C_RESET}  ${C_DIM}(ask details + upload backups + install scripts)${C_RESET}"
    echo -e "  ${C_WHITE} 2)${C_RESET} ${C_YELLOW}Restore Backup (sudo)${C_RESET} ${C_DIM}(overwrite new server safely)${C_RESET}"
    echo
    echo -e "  ${C_DIM}─── Backup & Tools ───${C_RESET}"
    echo -e "  ${C_WHITE} 3)${C_RESET} Create Full Server Backup"
    echo -e "  ${C_WHITE} 4)${C_RESET} Connect To New Server"
    echo -e "  ${C_WHITE} 5)${C_RESET} Upload Backup Only"
    echo -e "  ${C_WHITE} 6)${C_RESET} Verify Backup"
    echo -e "  ${C_WHITE} 7)${C_RESET} Show Backup Information"
    echo -e "  ${C_WHITE} 8)${C_RESET} Cleanup Backup Files"
    echo -e "  ${C_WHITE} 9)${C_RESET} Pre-flight Check"
    echo -e "  ${C_WHITE}10)${C_RESET} Estimate Backup Size"
    echo -e "  ${C_WHITE}11)${C_RESET} Full Migration Wizard"
    echo -e "  ${C_WHITE}12)${C_RESET} Post-Migration Health Check"
    echo -e "  ${C_WHITE}13)${C_RESET} Generate Migration Report"
    echo -e "  ${C_WHITE}14)${C_RESET} Schedule Weekly Backup"
    echo -e "  ${C_WHITE}15)${C_RESET} Test Notifications"
    echo -e "  ${C_WHITE}16)${C_RESET} Exit"
    echo
    echo -e "${C_DIM}-----------------------------------------${C_RESET}"
    if [[ -n "${REMOTE_HOST:-}" ]]; then
        echo -e "  Remote: ${C_GREEN}${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}${C_RESET}"
    else
        echo -e "  Remote: ${C_YELLOW}(not configured)${C_RESET}"
    fi
    local latest
    latest="$(ls -1t "${BACKUP_DIR}"/server-backup-*.tar.zst 2>/dev/null | head -1)"
    if [[ -n "$latest" ]]; then
        echo -e "  Latest: ${C_CYAN}$(basename "$latest")${C_RESET}"
    fi
    if [[ -f "${PROJECT_LOG_DIR}/.last_deploy" ]]; then
        echo -e "  Deploy: ${C_GREEN}ready for restore${C_RESET}"
    fi
    [[ "${ENCRYPT_BACKUP:-no}" == "yes" ]] && echo -e "  Crypto: ${C_YELLOW}ON (${ENCRYPT_METHOD})${C_RESET}"
    [[ "${NOTIFY_ENABLED:-no}" == "yes" ]] && echo -e "  Notify: ${C_GREEN}ON${C_RESET}"
    echo -e "${C_DIM}-----------------------------------------${C_RESET}"
    echo
}
