#!/usr/bin/env bash
#
# setup.sh
# Interactive setup that turns a fresh Debian-family install (Debian, Ubuntu,
# Raspberry Pi OS) into a production-ready IPFS (Kubo) node:
#
#   - installs Docker Engine + the compose plugin
#   - mounts a NAS share over SMB/CIFS (SMB 1.0 - 3.1.1)
#   - runs Kubo in Docker with host networking
#   - configures CORS, CID version and the address announced to outside peers
#   - opens the firewall for IPFS (API and gateway LAN-only)
#   - optionally imports an existing NAS backup into MFS and pins it
#   - schedules a backup of MFS to the NAS with a systemd timer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/StrungSafe/setup_ipfs/main/setup.sh | sudo bash
#   curl -fsSL .../setup.sh | sudo bash -s -- --dry-run
#
# Answers are saved to /etc/ipfs-setup/setup.conf and become the defaults on
# the next run, so it is safe to run again.

# Everything lives in functions and main() is called on the last line, so a
# partially downloaded script never runs.

set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"

# ------------------------------------------------------------------ paths --
CONF_DIR="/etc/ipfs-setup"
CONF_FILE="$CONF_DIR/setup.conf"
CRED_FILE="$CONF_DIR/smb-credentials"
BACKUP_ENV_FILE="$CONF_DIR/backup.env"
IPFS_DIR="/opt/ipfs"
COMPOSE_FILE="$IPFS_DIR/docker-compose.yml"
INIT_DIR="$IPFS_DIR/init.d"
INIT_SCRIPT="$INIT_DIR/001-ipfs-setup.sh"
IMPORT_DIR="$IPFS_DIR/import"
DATA_DIR="$IPFS_DIR/data"
BACKUP_SCRIPT="/usr/local/sbin/ipfs_mfs_backup.sh"
BACKUP_SERVICE="/etc/systemd/system/ipfs-mfs-backup.service"
BACKUP_TIMER="/etc/systemd/system/ipfs-mfs-backup.timer"
LOGROTATE_FILE="/etc/logrotate.d/ipfs_mfs_backup"
CONTAINER_NAME="ipfs"
SWARM_PORT=4001
API_PORT=5001
GATEWAY_PORT=8080
CHUNK_MAX=2096896   # largest chunk size Kubo accepts (v0.43)
FSTAB_BEGIN="# >>> ipfs-setup (managed by setup.sh; edits between these lines are overwritten) >>>"
FSTAB_END="# <<< ipfs-setup <<<"

# Answers that are saved to $CONF_FILE (the NAS password is not one of them).
CONF_VARS=(
    NAS_SHARE NAS_MOUNT NAS_USER NAS_DOMAIN SMB_VERS
    KUBO_TAG RESTART_POLICY
    CORS_ORIGINS CORS_METHODS CID_VERSION IMPORT_CHUNKER ANNOUNCE_HOST
    LAN_CIDR
    BACKUP_SUBDIR MIRROR_DELETES BACKUP_NODE_CONFIG
    BACKUP_FREQUENCY BACKUP_TIME BACKUP_EVERY_HOURS BACKUP_DAYS BACKUP_MONTHDAY
    BACKUP_SCHEDULE
    IMPORT_HIDDEN IMPORT_CONFLICT
)

# Results of nas_login_check.
NAS_E_LOGIN=10
NAS_E_SHARE=11
NAS_E_HOST=12
NAS_E_PROTO=13
NAS_E_READONLY=14
NAS_E_OTHER=15
NAS_E_CANT_TEST=16

# ---------------------------------------------------------------- runtime --
DRY_RUN=false
IMPORT_ONLY=false
CONFIG_FILE=""
INTERACTIVE=false
FILE_CHANGED=false
NODE_FILES_CHANGED=false
LAN_IF=""
LAN_IP=""
DETECTED_CIDR=""
NAS_PASS=""
NAS_MOUNT_ERR=""
TMP_PATHS=()
IMPORT_SUMMARY="not run"

# ---------------------------------------------------------------- output --
if [[ -t 2 ]]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_RED=$'\e[31m'
    C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

info()    { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
ok()      { printf '%s ok%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn()    { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()     { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()     { err "$*"; exit 1; }
section() { printf '\n%s%s== %s ==%s\n' "$C_BOLD" "$C_BLUE" "$*" "$C_RESET" >&2; }

on_error() {
    local rc=$? line=$1 cmd=$2
    err "command failed (exit $rc) at line $line: $cmd"
}

# Runs a command, or only prints it in --dry-run mode.
run() {
    if $DRY_RUN; then
        printf '%s[dry-run]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
    else
        "$@"
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# Removes temporary files (e.g. the test-mount credentials) on exit.
cleanup_tmp() {
    local p
    for p in "${TMP_PATHS[@]}"; do
        if [[ -d "$p" ]]; then
            umount "$p" 2>/dev/null || true
            rmdir "$p" 2>/dev/null || true
        else
            rm -f "$p"
        fi
    done
}

# Writes stdin to a file if the content differs. Sets FILE_CHANGED.
#   write_file <path> <mode> [secret]   ("secret" hides the content in --dry-run)
write_file() {
    local path=$1 mode=$2 secret=${3-} tmp
    tmp="$(mktemp)"
    cat >"$tmp"
    if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
        FILE_CHANGED=false
        rm -f "$tmp"
        return 0
    fi
    FILE_CHANGED=true
    if $DRY_RUN; then
        printf '%s[dry-run]%s would write %s (mode %s)\n' "$C_YELLOW" "$C_RESET" "$path" "$mode" >&2
        if [[ "$secret" == "secret" ]]; then
            :
        elif [[ -f "$path" ]]; then
            diff -u "$path" "$tmp" | sed 's/^/    /' >&2 || true
        else
            sed 's/^/    /' "$tmp" >&2
        fi
        rm -f "$tmp"
        return 0
    fi
    mkdir -p "$(dirname "$path")"
    install -m "$mode" "$tmp" "$path"
    rm -f "$tmp"
}

# --------------------------------------------------------------- prompts --
# All prompts read from fd 3, which is /dev/tty when the script is piped in
# (curl ... | bash), because stdin is the script itself in that case.
setup_tty() {
    INTERACTIVE=false
    [[ -n "$CONFIG_FILE" ]] && return 0
    if [[ -t 0 ]]; then
        exec 3<&0
        INTERACTIVE=true
    elif (: </dev/tty) 2>/dev/null; then
        exec 3</dev/tty
        INTERACTIVE=true
    fi
}

# ask <var> <prompt> <default> [validator]
# Without a terminal (or with --config) the default is used as the answer.
ask() {
    local __var=$1 __prompt=$2 __def=${3-} __check=${4-} __val
    while true; do
        if $INTERACTIVE; then
            if [[ -n "$__def" ]]; then
                printf '%s %s[%s]%s: ' "$__prompt" "$C_BOLD" "$__def" "$C_RESET" >&2
            else
                printf '%s: ' "$__prompt" >&2
            fi
            IFS= read -r __val <&3 || die "input closed"
            __val="${__val:-$__def}"
        else
            __val="$__def"
        fi
        if [[ -n "$__check" ]] && ! "$__check" "$__val"; then
            $INTERACTIVE || die "invalid or missing value for $__var: '$__val'"
            continue
        fi
        printf -v "$__var" '%s' "$__val"
        return 0
    done
}

# ask_yn <var> <prompt> <default true|false>   -> sets var to true|false
ask_yn() {
    local __var=$1 __prompt=$2 __def=$3 __hint __val
    if [[ "$__def" == true ]]; then __hint="Y/n"; else __hint="y/N"; fi
    while true; do
        if $INTERACTIVE; then
            printf '%s %s[%s]%s: ' "$__prompt" "$C_BOLD" "$__hint" "$C_RESET" >&2
            IFS= read -r __val <&3 || die "input closed"
        else
            __val=""
        fi
        case "${__val,,}" in
            "") printf -v "$__var" '%s' "$__def"; return 0 ;;
            y|yes) printf -v "$__var" true; return 0 ;;
            n|no) printf -v "$__var" false; return 0 ;;
            *) warn "please answer y or n" ;;
        esac
    done
}

# ask_choice <var> <prompt> <default> <choice>...
ask_choice() {
    local __var=$1 __prompt=$2 __def=$3 __choice __c
    shift 3
    while true; do
        ask __choice "$__prompt ($(IFS=/; echo "$*"))" "$__def"
        for __c in "$@"; do
            if [[ "$__choice" == "$__c" ]]; then
                printf -v "$__var" '%s' "$__choice"
                return 0
            fi
        done
        $INTERACTIVE || die "invalid value for $__var: '$__choice' (expected one of: $*)"
        warn "choose one of: $*"
    done
}

# ask_menu <var> <prompt> <default key> <key:label>...
# Shows a numbered list; the answer can be the number or the key.
ask_menu() {
    local __var=$1 __prompt=$2 __defkey=$3 __ans __i=0 __item __def=1
    shift 3
    for __item in "$@"; do
        __i=$((__i + 1))
        [[ "${__item%%:*}" == "$__defkey" ]] && __def=$__i
    done
    while true; do
        if $INTERACTIVE; then
            printf '%s\n' "$__prompt" >&2
            __i=0
            for __item in "$@"; do
                __i=$((__i + 1))
                printf '  %d) %s\n' "$__i" "${__item#*:}" >&2
            done
        fi
        ask __ans "Choose 1-$#" "$__def"
        if [[ "$__ans" =~ ^[0-9]+$ ]] && ((__ans >= 1 && __ans <= $#)); then
            __item="${!__ans}"
            printf -v "$__var" '%s' "${__item%%:*}"
            return 0
        fi
        for __item in "$@"; do
            if [[ "${__item%%:*}" == "${__ans,,}" ]]; then
                printf -v "$__var" '%s' "${__item%%:*}"
                return 0
            fi
        done
        $INTERACTIVE || die "invalid value for $__var: '$__ans'"
        warn "choose a number from 1 to $#"
    done
}

ask_secret() {
    local __var=$1 __prompt=$2 __val
    $INTERACTIVE || die "$__prompt is required; set NAS_PASSWORD in the environment"
    while true; do
        printf '%s: ' "$__prompt" >&2
        IFS= read -rs __val <&3 || die "input closed"
        printf '\n' >&2
        [[ -n "$__val" ]] && break
        warn "value cannot be empty"
    done
    printf -v "$__var" '%s' "$__val"
}

# ------------------------------------------------------------- validators --
v_not_empty() { [[ -n "$1" ]] || { warn "value cannot be empty"; return 1; }; }

# mount.cifs rejects commas in the user name with "invalid argument", which
# would look like an SMB version problem, so catch it here.
v_nas_user() {
    [[ -n "$1" && "$1" != *,* && "$1" == "$(trim "$1")" ]] && return 0
    warn "enter a user name without commas or leading/trailing spaces"
    return 1
}

v_share() {
    local s
    s="$(to_slashes "$1")"   # \\nas\share is accepted too
    [[ "$s" =~ ^//[^/[:space:]]+/[^/].*$ ]] && return 0
    warn "expected a share like //nas.example.lan/ipfs"
    return 1
}

v_abs_path() {
    [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ && "$1" != "/" ]] && return 0
    warn "expected an absolute path without spaces, e.g. /mnt/ipfs"
    return 1
}

v_subdir() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "$1" != *..* ]] && return 0
    warn "expected a relative folder name without spaces, e.g. backup"
    return 1
}

v_optional_word() {
    [[ -z "$1" || "$1" =~ ^[A-Za-z0-9._-]+$ ]] && return 0
    warn "letters, digits, '.', '_' and '-' only"
    return 1
}

v_docker_tag() {
    [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] && return 0
    warn "not a valid image tag"
    return 1
}

v_origins() {
    local o
    [[ -n "$1" ]] || { warn "enter at least one origin"; return 1; }
    IFS=',' read -ra _items <<<"$1"
    for o in "${_items[@]}"; do
        o="$(trim "$o")"
        if [[ "$o" == "*" ]]; then
            warn "'*' allows any website to use your node's API"
            continue
        fi
        [[ "$o" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] || {
            warn "invalid origin '$o' (expected e.g. http://myhost.local:5001)"
            return 1
        }
    done
}

v_methods() {
    [[ "$1" =~ ^[[:space:]]*[A-Za-z]+([[:space:]]*,[[:space:]]*[A-Za-z]+)*[[:space:]]*$ ]] && return 0
    warn "expected a comma-separated list, e.g. PUT,POST,GET"
    return 1
}

v_announce() {
    [[ -z "$1" || "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && return 0
    warn "expected a host name like myhome.ddns.example (or blank)"
    return 1
}

v_cidr() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] && return 0
    warn "expected an IPv4 network like 192.168.1.0/24"
    return 1
}

v_time() {
    parse_time "$1" >/dev/null && return 0
    warn "expected a time like 02:00, 21:30, 2am or 9:30pm"
    return 1
}

v_days() {
    parse_days "$1" >/dev/null && return 0
    warn "expected day names like sun, or mon,thu, or weekdays / weekends"
    return 1
}

v_monthday() {
    [[ "$1" =~ ^[0-9]{1,2}$ ]] && ((10#$1 >= 1 && 10#$1 <= 28)) && return 0
    warn "expected a day from 1 to 28 (later days are skipped in short months)"
    return 1
}

v_chunker() {
    parse_chunker "$1" >/dev/null && return 0
    warn "expected a size like 512KiB, 1MiB or 1.5MiB (1 byte to $(group_digits "$CHUNK_MAX") bytes),"
    warn "or a Kubo chunker such as size-1048576, rabin-262144-524288-1048576 or buzhash"
    return 1
}

v_calendar() {
    if have systemd-analyze && ! systemd-analyze calendar "$1" >/dev/null 2>&1; then
        warn "not a valid systemd OnCalendar expression (e.g. '*-*-* 02:00:00' or 'daily')"
        return 1
    fi
    [[ -n "$1" ]]
}

# ---------------------------------------------------------------- helpers --
trim() {
    local s=$1
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

to_slashes() { # \\nas\share -> //nas/share
    local bs=$'\\'
    printf '%s' "${1//"$bs"//}"
}

# "a, b ,c" -> ["a","b","c"]   (values are validated, so no escaping needed)
to_json_array() {
    local out="" item
    IFS=',' read -ra _items <<<"$1"
    for item in "${_items[@]}"; do
        item="$(trim "$item")"
        [[ -z "$item" ]] && continue
        out+="${out:+,}\"$item\""
    done
    printf '[%s]' "$out"
}

normalize_list() { # "a , b" -> "a,b"
    local out="" item
    IFS=',' read -ra _items <<<"$1"
    for item in "${_items[@]}"; do
        item="$(trim "$item")"
        [[ -n "$item" ]] && out+="${out:+,}$item"
    done
    printf '%s' "$out"
}

human_size() {
    awk -v b="$1" 'BEGIN { split("B KiB MiB GiB TiB", u); i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        fmt = (i == 1 ? "%d %s" : "%.1f %s"); printf fmt, b, u[i] }'
}

group_digits() { # 1048576 -> 1,048,576
    local n=$1 out=""
    while ((${#n} > 3)); do
        out=",${n: -3}$out"
        n="${n:0:${#n}-3}"
    done
    printf '%s%s' "$n" "$out"
}

# ------------------------------------------------------------- chunk size --
# "1MiB", "1.5 MB", "512k", "786432", "size-N", "rabin-...", "buzhash"
#   -> a Kubo chunker string. KB/MB are binary units (1 MB = 1,048,576 bytes).
parse_chunker() {
    local s="${1,,}" num mult bytes
    s="${s// /}"
    if [[ "$s" == "buzhash" || "$s" =~ ^rabin(-[0-9]{1,10}(-[0-9]{1,10}-[0-9]{1,10})?)?$ ]]; then
        printf '%s' "$s"
        return 0
    fi
    if [[ "$s" =~ ^size-([0-9]{1,10})$ ]]; then
        bytes=$((10#${BASH_REMATCH[1]}))
    elif [[ "$s" =~ ^([0-9]{1,10}(\.[0-9]+)?)(b|k|kb|kib|m|mb|mib)?$ ]]; then
        num="${BASH_REMATCH[1]}"
        case "${BASH_REMATCH[3]}" in
            ""|b) mult=1 ;;
            k|kb|kib) mult=1024 ;;
            *) mult=1048576 ;;
        esac
        bytes="$(awk -v n="$num" -v m="$mult" 'BEGIN { printf "%d", n * m }')"
    else
        return 1
    fi
    ((bytes >= 1 && bytes <= CHUNK_MAX)) || return 1
    printf 'size-%s' "$bytes"
}

#   describe_chunker <chunker string, "" for Kubo's default>
describe_chunker() {
    local c="$1" n
    case "$c" in
        "")
            printf "256 KiB (Kubo's default)" ;;
        size-*)
            n="${c#size-}"
            if ((n % 1048576 == 0)); then
                printf '%d MiB' $((n / 1048576))
            elif ((n < 1048576 && n % 1024 == 0)); then
                printf '%d KiB' $((n / 1024))
            else
                human_size "$n"
            fi
            printf ' (%s bytes)' "$(group_digits "$n")" ;;
        *)
            printf '%s' "$c" ;;
    esac
}

ask_chunker() {
    local def choice custom="512KiB"
    case "${IMPORT_CHUNKER:-}" in
        "") def=default ;;
        size-1048576) def=1mib ;;
        *) def=custom; custom="$IMPORT_CHUNKER" ;;
    esac
    echo "Files up to the chunk size are stored as one block; bigger files are split into chunks." >&2
    echo "It applies to content added without its own chunk size, including the backup import." >&2
    echo "Content already on the node is not re-chunked." >&2
    ask_menu choice "Chunk size for new files" "$def" \
        "default:256 KiB (Kubo's default)" \
        "1mib:1 MiB" \
        "custom:Custom (a size like 512KiB or 1.5MiB, or a Kubo chunker string)"
    case "$choice" in
        default) IMPORT_CHUNKER="" ;;
        1mib) IMPORT_CHUNKER="size-1048576" ;;
        custom)
            ask IMPORT_CHUNKER "Chunk size" "$custom" v_chunker
            IMPORT_CHUNKER="$(parse_chunker "$IMPORT_CHUNKER")" ;;
    esac
    info "chunk size: $(describe_chunker "$IMPORT_CHUNKER")"
    if [[ "$IMPORT_CHUNKER" =~ ^size-([0-9]+)$ ]] && ((BASH_REMATCH[1] > 1048576)); then
        warn "blocks over 1 MiB can be refused by peers and gateways running older or other IPFS software"
    fi
}

# Always go through the daemon's API. Without --api, commands like "ipfs id"
# also succeed offline while the daemon is still starting, and can then clash
# with it over the repo lock.
ipfs_exec() { docker exec "$CONTAINER_NAME" ipfs "--api=/ip4/127.0.0.1/tcp/$API_PORT" "$@"; }

container_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" == "true" ]]
}

# --------------------------------------------------------------- args/conf --
usage() {
    cat >&2 <<EOF
setup.sh $SCRIPT_VERSION - prepare a Debian-family host as an IPFS (Kubo) node

Usage: sudo bash setup.sh [options]
       curl -fsSL <url>/setup.sh | sudo bash -s -- [options]

Options:
  --dry-run          show what would change without changing anything
  --config <file>    run without prompts, using answers from <file>
                     (see examples/setup.conf.example; the NAS password is
                     read from the NAS_PASSWORD environment variable or the
                     saved credentials file)
  --import-backup    only import the NAS backup folder into MFS and pin it
  -h, --help         show this help
  --version          print the version
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            --dry-run) DRY_RUN=true ;;
            --config)
                [[ $# -ge 2 ]] || die "--config needs a file"
                CONFIG_FILE=$2; shift ;;
            --config=*) CONFIG_FILE=${1#*=} ;;
            --import-backup) IMPORT_ONLY=true ;;
            -h|--help) usage; exit 0 ;;
            --version) echo "$SCRIPT_VERSION"; exit 0 ;;
            *) usage; die "unknown option: $1" ;;
        esac
        shift
    done
}

load_conf() {
    # shellcheck disable=SC1090
    if [[ -r "$CONF_FILE" ]]; then
        source "$CONF_FILE"
        info "loaded saved answers from $CONF_FILE"
    fi
    # shellcheck disable=SC1090
    if [[ -n "$CONFIG_FILE" ]]; then
        [[ -r "$CONFIG_FILE" ]] || die "cannot read config file: $CONFIG_FILE"
        source "$CONFIG_FILE"
        info "loaded answers from $CONFIG_FILE"
    fi
    NAS_PASS="${NAS_PASSWORD:-}"
}

save_conf() {
    local v
    {
        echo "# Answers saved by setup.sh $SCRIPT_VERSION on $(date '+%Y-%m-%d %H:%M:%S')."
        echo "# They are used as defaults the next time setup.sh runs."
        for v in "${CONF_VARS[@]}"; do
            printf '%s=%q\n' "$v" "${!v-}"
        done
    } | write_file "$CONF_FILE" 0600
}

# --------------------------------------------------------------- preflight --
preflight() {
    section "Checking this system"
    if [[ $EUID -ne 0 ]]; then
        $DRY_RUN || die "run as root, e.g.: curl -fsSL <url> | sudo bash"
        warn "not running as root; the dry run may miss some details"
    fi

    [[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
    case " $OS_ID $OS_LIKE " in
        *" debian "*|*" ubuntu "*|*" raspbian "*) ;;
        *) die "unsupported OS '${PRETTY_NAME:-$OS_ID}'; this script supports Debian, Ubuntu and Raspberry Pi OS" ;;
    esac
    ok "OS: ${PRETTY_NAME:-$OS_ID} ($(dpkg --print-architecture 2>/dev/null || uname -m))"

    if ! have systemctl || [[ ! -d /run/systemd/system ]]; then
        $DRY_RUN || die "systemd is required"
        warn "systemd is not running (fine for a dry run)"
    fi

    detect_network
    if [[ -n "$LAN_IP" ]]; then
        ok "LAN: $LAN_IP on $LAN_IF (${DETECTED_CIDR:-unknown subnet})"
    else
        warn "could not detect the LAN address"
    fi
}

detect_network() {
    local route
    route="$(ip -o -4 route get 1.1.1.1 2>/dev/null || true)"
    LAN_IF="$(awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}' <<<"$route")"
    LAN_IP="$(awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}' <<<"$route")"
    if [[ -n "$LAN_IF" ]]; then
        DETECTED_CIDR="$(ip -o -4 route show dev "$LAN_IF" proto kernel scope link 2>/dev/null \
            | awk '{ print $1; exit }')"
    fi
}

latest_kubo_tag() {
    curl -fsSL --max-time 10 https://api.github.com/repos/ipfs/kubo/releases/latest 2>/dev/null \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1
}

# ---------------------------------------------------------------- questions --
collect_answers() {
    local host default_origins public_ip use_public

    section "NAS share"
    echo "The NAS holds the scheduled MFS backup (and any backup to import)." >&2
    ask_nas_share
    ask NAS_MOUNT "Mount point on this machine" "${NAS_MOUNT:-/mnt/ipfs}" v_abs_path
    ask_nas_login
    ask_smb_version
    validate_nas_login

    section "IPFS node"
    if [[ -z "${KUBO_TAG:-}" ]]; then
        KUBO_TAG="$(latest_kubo_tag || true)"
        KUBO_TAG="${KUBO_TAG:-latest}"
    fi
    ask KUBO_TAG "Kubo image tag (ipfs/kubo:<tag>; 'latest' follows new releases)" "$KUBO_TAG" v_docker_tag
    ask_choice RESTART_POLICY "Container restart policy" "${RESTART_POLICY:-unless-stopped}" \
        unless-stopped always on-failure no

    host="$(hostname -s 2>/dev/null || hostname)"
    default_origins="http://$host.local:$API_PORT,http://localhost:$API_PORT,http://127.0.0.1:$API_PORT"
    [[ -n "$LAN_IP" ]] && default_origins+=",http://$LAN_IP:$API_PORT"
    echo "Allowed origins are the web pages that may call the node's API" \
         "(the WebUI, plus any web apps of your own, e.g. http://mydesktop.local:4173)." >&2
    ask CORS_ORIGINS "Allowed origins (comma-separated)" "${CORS_ORIGINS:-$default_origins}" v_origins
    CORS_ORIGINS="$(normalize_list "$CORS_ORIGINS")"
    ask CORS_METHODS "Allowed API methods (comma-separated)" "${CORS_METHODS:-PUT,POST,GET}" v_methods
    CORS_METHODS="$(normalize_list "${CORS_METHODS^^}")"
    ask_choice CID_VERSION "CID version for new content" "${CID_VERSION:-1}" 1 0
    ask_chunker

    section "Reachability from outside your home network"
    echo "Peers outside your network find you through your router's public address." >&2
    echo "Enter your router's dynamic DNS name so it is announced to them." >&2
    ask ANNOUNCE_HOST "Router DNS name (blank to skip)" "${ANNOUNCE_HOST:-}" v_announce
    if [[ -z "$ANNOUNCE_HOST" ]] && $INTERACTIVE; then
        public_ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
        if [[ "$public_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            ask_yn use_public "Announce your current public IP $public_ip instead? (stops working if it changes)" false
            if $use_public; then ANNOUNCE_HOST="$public_ip"; fi
        fi
    fi

    section "Firewall"
    ask LAN_CIDR "LAN subnet allowed to reach the API ($API_PORT) and gateway ($GATEWAY_PORT)" \
        "${LAN_CIDR:-${DETECTED_CIDR:-192.168.1.0/24}}" v_cidr

    section "Backup"
    ask BACKUP_SUBDIR "Backup folder inside the NAS share" "${BACKUP_SUBDIR:-backup}" v_subdir
    ask_schedule
    ask_yn MIRROR_DELETES "Delete files from the backup when they are deleted from MFS?" "${MIRROR_DELETES:-false}"
    echo "The node's config holds its private identity key. Backing it up lets you" \
         "restore the same peer ID, but puts the key on the NAS." >&2
    ask_yn BACKUP_NODE_CONFIG "Also back up the node config and keys?" "${BACKUP_NODE_CONFIG:-false}"

    section "Importing an existing backup"
    echo "If $NAS_MOUNT/$BACKUP_SUBDIR already has files, they can be imported into MFS and pinned." >&2
    ask_yn IMPORT_HIDDEN "Include hidden files (dotfiles) when importing?" "${IMPORT_HIDDEN:-false}"
    if ! $IMPORT_HIDDEN && $MIRROR_DELETES; then
        warn "hidden files will not be imported, but mirrored deletions are on:"
        warn "the first scheduled backup will delete any dotfiles from $NAS_MOUNT/$BACKUP_SUBDIR"
    fi
    ask_choice IMPORT_CONFLICT "If an item already exists in MFS" "${IMPORT_CONFLICT:-skip}" skip replace rename
}

smb1_warning() {
    warn "SMB 1.0 is insecure (no encryption, weak authentication, WannaCry-era protocol)."
    warn "Use it only if your NAS supports nothing newer, and only on a trusted network."
}

# ------------------------------------------------------- NAS questions/check --
nas_host() { local h="${NAS_SHARE#//}"; printf '%s' "${h%%/*}"; }
share_name() { local s="${NAS_SHARE#//}"; s="${s#*/}"; printf '%s' "${s%%/*}"; }

# shellcheck disable=SC2016  # $1/$2 expand in the inner bash, on purpose
port_open() { timeout 5 bash -c ': </dev/tcp/"$1"/"$2"' _ "$1" "$2" 2>/dev/null; }

# In --config mode a NAS problem cannot be fixed by asking again, so stop.
nas_retry_or_die() {
    $INTERACTIVE || die "$1"
}

# Asks for the share until its host resolves and answers on an SMB port.
ask_nas_share() {
    local host
    while true; do
        ask NAS_SHARE "SMB share (e.g. //nas.example.lan/ipfs)" "${NAS_SHARE:-}" v_share
        NAS_SHARE="$(to_slashes "$NAS_SHARE")"
        host="$(nas_host)"

        if [[ ! "$host" =~ ^[0-9.]+$ ]] && ! getent hosts "$host" >/dev/null 2>&1; then
            err "Can't find a NAS named '$host'."
            info "Use its IP address or full DNS name. Windows-style names (like NAS01) only work if your"
            info "router's DNS knows them, and '.local' names need avahi on this machine."
        elif port_open "$host" 445; then
            ok "'$host' answers on the SMB port (445)"
            return 0
        elif port_open "$host" 139; then
            ok "'$host' answers on the NetBIOS port (139) only; it probably needs SMB 1.0"
            return 0
        else
            err "'$host' doesn't answer on the SMB ports (445 or 139)."
            info "Check that the NAS is on and that SMB file sharing is enabled."
        fi
        nas_retry_or_die "fix NAS_SHARE in the config file"
        info "Fix the share, or press Enter to try the same one again."
    done
}

# Asks for user, domain and password. "force" asks for the password even if
# one is saved (after the NAS rejected it).
ask_nas_login() {
    local force=${1-} keep=false
    ask NAS_USER "NAS user name" "${NAS_USER:-}" v_nas_user
    ask NAS_DOMAIN "NAS domain/workgroup (blank for none)" "${NAS_DOMAIN:-}" v_optional_word
    if [[ -n "$force" ]]; then
        NAS_PASS=""
    elif [[ -n "$NAS_PASS" ]]; then
        return 0
    elif [[ -r "$CRED_FILE" ]]; then
        ask_yn keep "Keep the saved NAS password?" true
        if $keep; then
            NAS_PASS="$(sed -n 's/^password=//p' "$CRED_FILE")"
            [[ -n "$NAS_PASS" ]] && return 0
        fi
    fi
    ask_secret NAS_PASS "NAS password for $NAS_USER"
}

ask_smb_version() {
    ask_choice SMB_VERS "SMB protocol version" "${SMB_VERS:-3.1.1}" 3.1.1 3.0 2.1 2.0 1.0
    if [[ "$SMB_VERS" == "1.0" ]]; then
        smb1_warning
        smb1_kernel_check
    fi
}

# The login check needs root and mount.cifs. cifs-utils is the only package
# installed before the summary is confirmed.
nas_can_test() {
    if [[ $EUID -ne 0 ]]; then
        info "skipping the NAS login check (needs root)"
        return 1
    fi
    have mount.cifs && return 0
    if $DRY_RUN; then
        info "skipping the NAS login check: cifs-utils isn't installed, and a dry run installs nothing"
        return 1
    fi
    info "installing cifs-utils to check the NAS login (the only change made before you confirm)"
    { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cifs-utils; } >/dev/null \
        || die "could not install cifs-utils"
}

classify_mount_error() {
    case "$1" in
        *"error(13)"*) echo "$NAS_E_LOGIN" ;;
        *"error(2)"*|*"error(6)"*) echo "$NAS_E_SHARE" ;;
        # The port check already passed, so "host is down" means the NAS
        # refused the protocol version (typical for SMB1-only devices).
        *"error(112)"*|*"error(95)"*|*"error(22)"*|*"error(121)"*) echo "$NAS_E_PROTO" ;;
        *"could not resolve"*|*"error(110)"*|*"error(111)"*|*"error(113)"*|*"error(115)"*) echo "$NAS_E_HOST" ;;
        *"error(1)"*|*"only root"*) echo "$NAS_E_CANT_TEST" ;;
        *) echo "$NAS_E_OTHER" ;;
    esac
}

nas_error_message() {
    case "$1" in
        "$NAS_E_LOGIN") echo "The NAS rejected the user name or password for '$NAS_USER'." ;;
        "$NAS_E_SHARE") echo "The NAS has no share named '$(share_name)', or '$NAS_USER' isn't allowed to see it." ;;
        "$NAS_E_HOST") echo "Can't reach the NAS at '$(nas_host)'." ;;
        "$NAS_E_PROTO") echo "The NAS doesn't accept SMB $2." ;;
        "$NAS_E_READONLY") echo "Logged in, but '$NAS_USER' can't write to the share." ;;
        *) echo "Mounting the share failed: ${NAS_MOUNT_ERR:-unknown error}" ;;
    esac
}

# Test-mounts the share in a temporary folder with the current answers,
# writes and deletes a file, and unmounts. Returns 0 or a NAS_E_* code.
#   nas_login_check <smb version>
nas_login_check() {
    local vers=$1 cred tmp out rc=0
    NAS_MOUNT_ERR=""
    cred="$(mktemp)"
    tmp="$(mktemp -d /tmp/ipfs-setup-mount.XXXXXX)"
    TMP_PATHS+=("$cred" "$tmp")
    chmod 600 "$cred"
    credentials "$NAS_PASS" >"$cred"

    if out="$(mount -t cifs "$NAS_SHARE" "$tmp" -o "$(cifs_opts "$cred" "$vers")" 2>&1)"; then
        if ! { touch "$tmp/.ipfs-setup-write-test" && rm -f "$tmp/.ipfs-setup-write-test"; } 2>/dev/null; then
            rc=$NAS_E_READONLY
        fi
        umount "$tmp" 2>/dev/null || umount -l "$tmp" 2>/dev/null || true
    else
        NAS_MOUNT_ERR="$out"
        rc="$(classify_mount_error "$out")"
    fi
    rm -f "$cred"
    rmdir "$tmp" 2>/dev/null || true
    return "$rc"
}

# Finds the newest SMB 2.0+ version the NAS accepts, other than the one tried.
find_smb_version() {
    local v rc
    for v in 3.1.1 3.0 2.1 2.0; do
        [[ "$v" == "$SMB_VERS" ]] && continue
        rc=0
        nas_login_check "$v" || rc=$?
        if ((rc != NAS_E_PROTO)); then
            printf '%s' "$v"
            return 0
        fi
    done
    return 1
}

# Logs in to the NAS with the answers so far and asks again for just the part
# that is wrong.
validate_nas_login() {
    nas_can_test || return 0
    info "checking the login to $NAS_SHARE (SMB $SMB_VERS)"
    local rc alt use
    while true; do
        rc=0
        nas_login_check "$SMB_VERS" || rc=$?
        case "$rc" in
            0)
                ok "logged in to $NAS_SHARE as $NAS_USER with SMB $SMB_VERS; the share is writable"
                return 0 ;;
            "$NAS_E_CANT_TEST")
                warn "this system doesn't allow a test mount here; skipping the NAS login check"
                return 0 ;;
            "$NAS_E_LOGIN"|"$NAS_E_READONLY")
                err "$(nas_error_message "$rc")"
                nas_retry_or_die "check NAS_USER, NAS_DOMAIN and NAS_PASSWORD"
                ask_nas_login force ;;
            "$NAS_E_SHARE"|"$NAS_E_HOST")
                err "$(nas_error_message "$rc")"
                nas_retry_or_die "check NAS_SHARE in the config file"
                ask_nas_share ;;
            "$NAS_E_PROTO")
                err "$(nas_error_message "$rc" "$SMB_VERS")"
                if alt="$(find_smb_version)"; then
                    nas_retry_or_die "SMB $alt works with this NAS; set SMB_VERS=$alt in the config file"
                    ask_yn use "SMB $alt works with this NAS. Use it?" true
                    if $use; then SMB_VERS=$alt; else ask_smb_version; fi
                elif [[ "$SMB_VERS" != "1.0" ]]; then
                    warn "None of SMB 2.0 - 3.1.1 worked; this NAS may only speak SMB 1.0."
                    smb1_warning
                    nas_retry_or_die "set SMB_VERS=1.0 in the config file if you accept the risk"
                    ask_yn use "Try SMB 1.0?" false
                    $use || die "stopped: the NAS doesn't accept SMB 2.0 or newer"
                    SMB_VERS=1.0
                    smb1_kernel_check
                else
                    die "SMB 1.0 failed too; this kernel may not support it (see the warning above)"
                fi ;;
            *)
                err "$(nas_error_message "$rc")"
                nas_retry_or_die "check the NAS settings in the config file"
                ask_yn use "Enter the NAS details again?" true
                $use || die "stopped at the NAS check"
                ask_nas_share
                ask_nas_login force
                ask_smb_version ;;
        esac
        info "checking again"
    done
}

# ---------------------------------------------------------- backup schedule --
# "2am", "2:30 PM", "14:05", "noon", "midnight" -> HH:MM
parse_time() {
    local t="${1,,}" h m
    t="${t// /}"
    case "$t" in
        noon) t="12:00" ;;
        midnight) t="00:00" ;;
    esac
    if [[ "$t" =~ ^([0-9]{1,2})(:([0-9]{2}))?(am|pm)$ ]]; then
        h=$((10#${BASH_REMATCH[1]}))
        m=$((10#${BASH_REMATCH[3]:-0}))
        ((h >= 1 && h <= 12)) || return 1
        h=$((h % 12))
        [[ "${BASH_REMATCH[4]}" == "pm" ]] && h=$((h + 12))
    elif [[ "$t" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
        h=$((10#${BASH_REMATCH[1]}))
        m=$((10#${BASH_REMATCH[2]}))
        ((h <= 23)) || return 1
    else
        return 1
    fi
    ((m <= 59)) || return 1
    printf '%02d:%02d' "$h" "$m"
}

# "mon, Thursday" / "weekdays" / "weekends" -> "Mon,Thu" (in week order)
parse_days() {
    local input="${1,,}" word d out="" picked=" " words
    read -ra words <<<"${input//,/ }"
    for word in "${words[@]}"; do
        case "$word" in
            weekdays) picked+="Mon Tue Wed Thu Fri " ;;
            weekends|weekend) picked+="Sat Sun " ;;
            mon|monday) picked+="Mon " ;;
            tue|tues|tuesday) picked+="Tue " ;;
            wed|wednesday) picked+="Wed " ;;
            thu|thur|thurs|thursday) picked+="Thu " ;;
            fri|friday) picked+="Fri " ;;
            sat|saturday) picked+="Sat " ;;
            sun|sunday) picked+="Sun " ;;
            *) return 1 ;;
        esac
    done
    for d in Mon Tue Wed Thu Fri Sat Sun; do
        [[ "$picked" == *" $d "* ]] && out+="${out:+,}$d"
    done
    [[ -n "$out" ]] || return 1
    printf '%s' "$out"
}

build_schedule() {
    case "$BACKUP_FREQUENCY" in
        daily)   printf '*-*-* %s:00' "$BACKUP_TIME" ;;
        hourly)  printf '*-*-* 00/%s:00:00' "$BACKUP_EVERY_HOURS" ;;
        weekly)  printf '%s *-*-* %s:00' "$BACKUP_DAYS" "$BACKUP_TIME" ;;
        monthly) printf '*-*-%02d %s:00' "$((10#$BACKUP_MONTHDAY))" "$BACKUP_TIME" ;;
        custom)  printf '%s' "$BACKUP_SCHEDULE" ;;
    esac
}

describe_schedule() {
    case "$BACKUP_FREQUENCY" in
        daily)   printf 'daily at %s' "$BACKUP_TIME" ;;
        hourly)
            if [[ "$BACKUP_EVERY_HOURS" == 1 ]]; then
                printf 'every hour'
            else
                local h out=""
                for ((h = 0; h < 24; h += BACKUP_EVERY_HOURS)); do
                    out+="${out:+, }$(printf '%02d:00' "$h")"
                done
                printf 'every %s hours (%s)' "$BACKUP_EVERY_HOURS" "$out"
            fi ;;
        weekly)  printf 'weekly on %s at %s' "${BACKUP_DAYS//,/, }" "$BACKUP_TIME" ;;
        monthly) printf 'monthly on day %s at %s' "$((10#$BACKUP_MONTHDAY))" "$BACKUP_TIME" ;;
        *)       printf "on the schedule '%s'" "$BACKUP_SCHEDULE" ;;
    esac
}

show_next_runs() {
    have systemd-analyze || return 0
    local runs
    runs="$(systemd-analyze calendar --iterations=3 "$BACKUP_SCHEDULE" 2>/dev/null \
        | sed -n 's/^ *\(Next elapse\|Iter\. #[0-9]*\): *//p')" || return 0
    [[ -n "$runs" ]] || return 0
    echo "  Next runs (each may start up to 5 minutes later):" >&2
    printf '    %s\n' "${runs//$'\n'/$'\n'    }" >&2
}

ask_backup_time() {
    ask BACKUP_TIME "At what time? (e.g. 02:00 or 2am)" "${BACKUP_TIME:-02:00}" v_time
    BACKUP_TIME="$(parse_time "$BACKUP_TIME")"
}

ask_schedule() {
    # A config from before the menu existed only has BACKUP_SCHEDULE.
    if [[ -z "${BACKUP_FREQUENCY:-}" && -n "${BACKUP_SCHEDULE:-}" ]]; then
        if [[ "$BACKUP_SCHEDULE" =~ ^\*-\*-\*\ ([0-9]{2}:[0-9]{2}):00$ ]]; then
            BACKUP_FREQUENCY=daily
            BACKUP_TIME="${BASH_REMATCH[1]}"
        else
            BACKUP_FREQUENCY=custom
        fi
    fi

    local use
    while true; do
        ask_menu BACKUP_FREQUENCY "How often should the backup run?" "${BACKUP_FREQUENCY:-daily}" \
            "daily:Daily" \
            "hourly:Every few hours" \
            "weekly:Weekly" \
            "monthly:Monthly" \
            "custom:Custom (systemd OnCalendar, for advanced users)"
        case "$BACKUP_FREQUENCY" in
            daily)
                ask_backup_time ;;
            hourly)
                ask_choice BACKUP_EVERY_HOURS "Run every how many hours" "${BACKUP_EVERY_HOURS:-6}" 1 2 3 4 6 8 12 ;;
            weekly)
                ask BACKUP_DAYS "On which day(s)? (e.g. sun, mon,thu or weekdays)" "${BACKUP_DAYS:-Sun}" v_days
                BACKUP_DAYS="$(parse_days "$BACKUP_DAYS")"
                ask_backup_time ;;
            monthly)
                ask BACKUP_MONTHDAY "On which day of the month? (1-28)" "${BACKUP_MONTHDAY:-1}" v_monthday
                BACKUP_MONTHDAY="$((10#$BACKUP_MONTHDAY))"
                ask_backup_time ;;
            custom)
                echo "See 'man systemd.time' (CALENDAR EVENTS) for the syntax." >&2
                ask BACKUP_SCHEDULE "OnCalendar expression" "${BACKUP_SCHEDULE:-*-*-* 02:00:00}" v_calendar ;;
        esac
        BACKUP_SCHEDULE="$(build_schedule)"

        info "backup will run $(describe_schedule)"
        show_next_runs
        if [[ "$BACKUP_FREQUENCY" == hourly ]] && ((BACKUP_EVERY_HOURS < 6)); then
            warn "each backup exports and checksums all of MFS, which is slow for large collections"
        fi
        $INTERACTIVE || return 0
        ask_yn use "Use this schedule?" true
        $use && return 0
    done
}

show_summary() {
    section "Summary"
    local announce="(none)"
    [[ -n "$ANNOUNCE_HOST" ]] && announce="$(announce_addrs | tr -d '[]"' | tr ',' ' ')"
    cat >&2 <<EOF
  NAS share ............ $NAS_SHARE -> $NAS_MOUNT (SMB $SMB_VERS, user $NAS_USER${NAS_DOMAIN:+, domain $NAS_DOMAIN})
  Kubo image ........... ipfs/kubo:$KUBO_TAG (restart: $RESTART_POLICY, host networking)
  Repo location ........ $DATA_DIR
  Allowed origins ...... $CORS_ORIGINS
  Allowed methods ...... $CORS_METHODS
  CID version .......... $CID_VERSION
  Chunk size ........... $(describe_chunker "$IMPORT_CHUNKER")
  Announced addresses .. $announce
  Firewall ............. $SWARM_PORT/tcp+udp from anywhere; $API_PORT, $GATEWAY_PORT from $LAN_CIDR
  Backup ............... $NAS_MOUNT/$BACKUP_SUBDIR, $(describe_schedule), mirror deletes: $MIRROR_DELETES
  Node config backup ... $BACKUP_NODE_CONFIG
  Import ............... hidden files: $IMPORT_HIDDEN, on conflict: $IMPORT_CONFLICT
EOF
    $DRY_RUN && warn "dry run: nothing will be changed"
    local go
    ask_yn go "Apply these settings?" true
    $go || die "aborted; nothing was changed"
}

# ---------------------------------------------------------------- packages --
install_packages() {
    section "Packages"
    local pkgs=(ca-certificates curl cifs-utils rsync util-linux)
    systemctl is-active --quiet firewalld 2>/dev/null || pkgs+=(ufw)
    local missing=() p
    for p in "${pkgs[@]}"; do
        # No "| grep -q" here or below: with pipefail, grep exiting early can
        # make the pipeline fail even when it matched.
        [[ "$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null)" == *"install ok installed"* ]] || missing+=("$p")
    done
    if ((${#missing[@]})); then
        info "installing: ${missing[*]}"
        run apt-get update -q
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}"
    fi
    ok "packages ready"
}

install_docker() {
    section "Docker"
    if have docker && docker compose version >/dev/null 2>&1; then
        ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') with compose is already installed"
        run systemctl enable --now docker
        return 0
    fi

    if have docker; then
        info "Docker is installed but the compose plugin is missing"
        run apt-get update -q
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker-compose-plugin \
            || run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker-compose-v2 \
            || die "could not install the Docker compose plugin"
        return 0
    fi

    # Docker's official apt repository: https://docs.docker.com/engine/install/
    local repo codename arch
    if [[ " $OS_ID $OS_LIKE " == *" ubuntu "* ]]; then
        repo="ubuntu"
        codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    else
        # Debian and Raspberry Pi OS (32-bit raspbian uses Debian's armhf builds).
        repo="debian"
        codename="${DEBIAN_CODENAME:-${VERSION_CODENAME:-}}"
    fi
    [[ -n "$codename" ]] || die "cannot tell the release codename for the Docker repository"
    arch="$(dpkg --print-architecture)"

    info "installing Docker from download.docker.com ($repo $codename, $arch)"
    run install -m 0755 -d /etc/apt/keyrings
    run curl -fsSL "https://download.docker.com/linux/$repo/gpg" -o /etc/apt/keyrings/docker.asc
    run chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$repo $codename stable" \
        | write_file /etc/apt/sources.list.d/docker.list 0644
    run apt-get update -q
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    run systemctl enable --now docker
    ok "Docker installed"
}

# --------------------------------------------------------------------- NAS --
smb1_kernel_check() {
    local cfg="" setting=""
    if [[ -r "/boot/config-$(uname -r)" ]]; then
        cfg="/boot/config-$(uname -r)"
        setting="$(grep '^CONFIG_CIFS_ALLOW_INSECURE_LEGACY=' "$cfg" || true)"
    elif [[ -r /proc/config.gz ]]; then
        setting="$(zcat /proc/config.gz | grep '^CONFIG_CIFS_ALLOW_INSECURE_LEGACY=' || true)"
        cfg="/proc/config.gz"
    fi
    if [[ -z "$cfg" ]]; then
        info "cannot read the kernel config; SMB 1.0 support will be checked by a test mount"
    elif [[ "$setting" == *"=y" ]]; then
        ok "kernel allows SMB 1.0"
    else
        warn "this kernel appears to be built without SMB 1.0 support (CONFIG_CIFS_ALLOW_INSECURE_LEGACY)"
    fi
}

#   cifs_opts [credentials file] [smb version]
cifs_opts() {
    printf 'credentials=%s,vers=%s,uid=0,gid=0,file_mode=0664,dir_mode=0775,iocharset=utf8' \
        "${1:-$CRED_FILE}" "${2:-$SMB_VERS}"
}

nas_mounted() {
    # Accessing the path triggers the automount; autofs itself also shows up
    # as a mount, so check for a real CIFS mount specifically.
    ls "$NAS_MOUNT" >/dev/null 2>&1 || true
    findmnt -rn -t cifs,smb3 -M "$NAS_MOUNT" >/dev/null 2>&1
}

credentials() {
    printf 'username=%s\npassword=%s\n' "$NAS_USER" "$1"
    if [[ -n "$NAS_DOMAIN" ]]; then
        printf 'domain=%s\n' "$NAS_DOMAIN"
    fi
}

configure_nas() {
    section "NAS mount"

    if [[ -n "$NAS_PASS" ]]; then
        credentials "$NAS_PASS" | write_file "$CRED_FILE" 0600 secret
        $DRY_RUN || ok "credentials saved to $CRED_FILE (mode 600)"
    elif ! $DRY_RUN; then
        die "no NAS password given (set NAS_PASSWORD or run interactively)"
    fi

    run mkdir -p "$NAS_MOUNT"

    # The login was checked while asking the questions; this is a last check
    # with the final settings before they go into /etc/fstab.
    if $DRY_RUN; then
        info "would test-mount $NAS_SHARE with SMB $SMB_VERS"
    else
        local rc=0
        nas_login_check "$SMB_VERS" || rc=$?
        if ((rc != 0 && rc != NAS_E_CANT_TEST)); then
            die "$(nas_error_message "$rc" "$SMB_VERS")"
        fi
        ok "test mount of $NAS_SHARE succeeded and is writable"
    fi

    write_fstab

    local unit m
    m="${NAS_MOUNT#/}"
    unit="$(systemd-escape -p --suffix=automount "$NAS_MOUNT" 2>/dev/null || echo "${m//\//-}.automount")"
    run systemctl daemon-reload
    if ! $DRY_RUN && findmnt -rn -t cifs,smb3 -M "$NAS_MOUNT" >/dev/null 2>&1; then
        umount "$NAS_MOUNT" 2>/dev/null || warn "could not unmount the old mount at $NAS_MOUNT (busy); a reboot will apply the new options"
    fi
    run systemctl restart "$unit"
    if ! $DRY_RUN; then
        nas_mounted || die "$NAS_MOUNT did not mount from /etc/fstab; check 'systemctl status $unit'"
        ok "$NAS_SHARE is mounted at $NAS_MOUNT (automount, survives reboots)"
    fi
}

write_fstab() {
    local share_esc entry new
    share_esc="${NAS_SHARE// /\\040}"
    entry="$share_esc $NAS_MOUNT cifs $(cifs_opts),_netdev,nofail,x-systemd.automount,x-systemd.mount-timeout=30 0 0"

    # Drop our old block and comment out any other entry for the same mount
    # point (e.g. from an earlier manual setup).
    new="$(awk -v b="$FSTAB_BEGIN" -v e="$FSTAB_END" -v mp="$NAS_MOUNT" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        skip { next }
        $0 !~ /^[[:space:]]*#/ && $2 == mp { print "# disabled by ipfs-setup: " $0; next }
        { print }' /etc/fstab)"
    new+=$'\n'"$FSTAB_BEGIN"$'\n'"$entry"$'\n'"$FSTAB_END"

    if [[ "$new" != "$(cat /etc/fstab)" ]] && ! $DRY_RUN; then
        cp -p /etc/fstab "/etc/fstab.ipfs-setup.$(date +%Y%m%d%H%M%S).bak"
    fi
    printf '%s\n' "$new" | write_file /etc/fstab 0644
}

# -------------------------------------------------------------- IPFS node --
announce_addrs() {
    if [[ -z "$ANNOUNCE_HOST" ]]; then
        printf '[]'
        return
    fi
    local proto="dns4"
    [[ "$ANNOUNCE_HOST" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && proto="ip4"
    printf '["/%s/%s/tcp/%s","/%s/%s/udp/%s/quic-v1"]' \
        "$proto" "$ANNOUNCE_HOST" "$SWARM_PORT" "$proto" "$ANNOUNCE_HOST" "$SWARM_PORT"
}

write_compose() {
    write_file "$COMPOSE_FILE" 0644 <<EOF
# Managed by setup.sh - re-run the setup to change these settings.
services:
  ipfs:
    image: ipfs/kubo:$KUBO_TAG
    container_name: $CONTAINER_NAME
    restart: $RESTART_POLICY
    # Host networking: the firewall on this machine applies to every port, and
    # Kubo sees the real network (LAN discovery via mDNS, UPnP port mapping).
    network_mode: host
    volumes:
      - $DATA_DIR:/data/ipfs
      - $INIT_DIR:/container-init.d:ro
      - $IMPORT_DIR:/import:ro
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
}

# The Kubo image sources /container-init.d/*.sh on every start, before the
# daemon runs, so these settings are re-applied each time the container starts.
write_init_script() {
    write_file "$INIT_SCRIPT" 0755 <<EOF
#!/bin/sh
# Managed by setup.sh - re-run the setup to change these settings.
# Sourced by the Kubo container before the daemon starts.

ipfs config Addresses.API /ip4/0.0.0.0/tcp/$API_PORT
ipfs config Addresses.Gateway /ip4/0.0.0.0/tcp/$GATEWAY_PORT

ipfs config --json API.HTTPHeaders.Access-Control-Allow-Origin '$(to_json_array "$CORS_ORIGINS")'
ipfs config --json API.HTTPHeaders.Access-Control-Allow-Methods '$(to_json_array "$CORS_METHODS")'

ipfs config --json Import.CidVersion $CID_VERSION

# Chunk size for content added without its own (files up to it stay one block).
$(if [[ -n "$IMPORT_CHUNKER" ]]; then
    echo "ipfs config Import.UnixFSChunker $IMPORT_CHUNKER"
else
    echo "ipfs config --json Import.UnixFSChunker null"
fi)

# Reachability from outside the home network: announce the router's public
# name, keep UPnP port mapping on, and allow relays and hole punching.
ipfs config --json Addresses.AppendAnnounce '$(announce_addrs)'
ipfs config --json Swarm.DisableNatPortMap false
ipfs config --json Swarm.RelayClient.Enabled true
ipfs config --json Swarm.EnableHolePunching true
ipfs config --json Discovery.MDNS.Enabled true
EOF
}

check_existing_container() {
    have docker || return 0
    docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 || return 0
    local cfg
    cfg="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$CONTAINER_NAME" 2>/dev/null || true)"
    [[ "$cfg" == "$COMPOSE_FILE" ]] && return 0

    warn "a container named '$CONTAINER_NAME' already exists and was not created from $COMPOSE_FILE"
    warn "(its data folders are not touched; only the container is removed)"
    local remove
    ask_yn remove "Remove that container so the new one can take its place?" false
    $remove || die "aborted; remove or rename the existing '$CONTAINER_NAME' container first"
    run docker rm -f "$CONTAINER_NAME"
}

wait_for_node() {
    $DRY_RUN && return 0
    info "waiting for the IPFS daemon to start"
    local i
    for ((i = 0; i < 90; i++)); do
        if ipfs_exec id -f '<id>' >/dev/null 2>&1; then
            ok "IPFS daemon is up"
            return 0
        fi
        sleep 2
    done
    docker logs --tail 30 "$CONTAINER_NAME" >&2 || true
    die "the IPFS daemon did not start within 3 minutes (logs above)"
}

deploy_node() {
    section "IPFS node"
    check_existing_container
    run mkdir -p "$DATA_DIR" "$INIT_DIR" "$IMPORT_DIR"

    NODE_FILES_CHANGED=false
    write_compose;     $FILE_CHANGED && NODE_FILES_CHANGED=true
    write_init_script; $FILE_CHANGED && NODE_FILES_CHANGED=true

    local compose=(docker compose -p ipfs -f "$COMPOSE_FILE")
    run "${compose[@]}" pull
    if $NODE_FILES_CHANGED; then
        run "${compose[@]}" up -d --force-recreate
    else
        run "${compose[@]}" up -d
    fi
    wait_for_node
}

# --------------------------------------------------------------- firewall --
ssh_port() {
    local p
    p="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)"
    printf '%s' "${p:-22}"
}

configure_firewall() {
    section "Firewall"
    local ssh
    ssh="$(ssh_port)"

    if systemctl is-active --quiet firewalld 2>/dev/null; then
        info "firewalld is active; adding rules there"
        run firewall-cmd --permanent --add-service=ssh
        run firewall-cmd --permanent --add-port="$SWARM_PORT/tcp" --add-port="$SWARM_PORT/udp"
        local port proto
        for port in "$API_PORT/tcp" "$GATEWAY_PORT/tcp" "5353/udp"; do
            proto=${port#*/}
            run firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$LAN_CIDR port port=${port%/*} protocol=$proto accept"
        done
        run firewall-cmd --reload
        ok "firewalld rules added"
        return 0
    fi

    local was_active=false
    [[ "$(ufw status 2>/dev/null)" =~ (^|$'\n')"Status: active" ]] && was_active=true

    # SSH first, so enabling the firewall cannot lock you out.
    run ufw allow "$ssh/tcp" comment 'SSH'
    if ! $was_active; then
        run ufw default deny incoming
        run ufw default allow outgoing
    fi
    run ufw allow "$SWARM_PORT/tcp" comment 'IPFS swarm'
    run ufw allow "$SWARM_PORT/udp" comment 'IPFS swarm (QUIC)'
    run ufw allow from "$LAN_CIDR" to any port "$API_PORT" proto tcp comment 'IPFS API (LAN only)'
    run ufw allow from "$LAN_CIDR" to any port "$GATEWAY_PORT" proto tcp comment 'IPFS gateway (LAN only)'
    run ufw allow from "$LAN_CIDR" to any port 5353 proto udp comment 'mDNS (LAN discovery)'
    run ufw --force enable
    ok "ufw: SSH ($ssh) and $SWARM_PORT open; $API_PORT and $GATEWAY_PORT limited to $LAN_CIDR"
}

# ----------------------------------------------------------------- import --
# Imports the NAS backup folder into MFS. The backup holds the *contents* of
# the MFS root, so each top-level item becomes /<name> in MFS, and is pinned.
import_backup() {
    section "Import existing backup"
    local src="$NAS_MOUNT/$BACKUP_SUBDIR"

    if $DRY_RUN && ! nas_mounted; then
        info "would offer to import $src (the NAS is not mounted during a dry run)"
        return 0
    fi
    nas_mounted || die "$NAS_MOUNT is not mounted"
    if [[ ! -d "$src" ]] || [[ -z "$(ls -A "$src" 2>/dev/null)" ]]; then
        info "no existing backup in $src; nothing to import"
        IMPORT_SUMMARY="nothing to import"
        return 0
    fi
    if ! $DRY_RUN; then
        container_running || die "the '$CONTAINER_NAME' container is not running"
    fi

    info "scanning $src"
    local total visible size hidden=0
    total="$(find "$src" -type f | wc -l)"
    if $IMPORT_HIDDEN; then
        visible=$total
        size="$(find "$src" -type f -printf '%s\n' | awk '{ s += $1 } END { print s + 0 }')"
    else
        visible="$(find "$src" -mindepth 1 -name '.*' -prune -o -type f -print | wc -l)"
        size="$(find "$src" -mindepth 1 -name '.*' -prune -o -type f -printf '%s\n' | awk '{ s += $1 } END { print s + 0 }')"
        hidden=$((total - visible))
    fi
    echo "  $visible files, $(human_size "$size")$( ((hidden)) && echo ", $hidden hidden files will be skipped")" >&2

    local mfs_empty=true default_go
    if container_running && [[ -n "$(ipfs_exec files ls / 2>/dev/null)" ]]; then
        mfs_empty=false
        info "MFS already has content; existing items are handled with: $IMPORT_CONFLICT"
    fi
    default_go=$mfs_empty
    $IMPORT_ONLY && default_go=true
    local go
    ask_yn go "Import these files into MFS and pin them?" "$default_go"
    if ! $go; then
        IMPORT_SUMMARY="skipped"
        return 0
    fi

    # Staging copy on local disk + the blocks in the repo: about twice the size.
    local avail need
    avail="$(df -B1 --output=avail "$IPFS_DIR" | tail -n1 | tr -d ' ')"
    need=$((size * 2 + 1024 * 1024 * 1024))
    if ((avail < need)); then
        warn "low disk space: about $(human_size "$need") is needed, $(human_size "$avail") is free on $IPFS_DIR"
        local anyway
        ask_yn anyway "Import anyway?" false
        $anyway || { IMPORT_SUMMARY="skipped (low disk space)"; return 0; }
    fi

    if $DRY_RUN; then
        info "would copy $src to $IMPORT_DIR, add each item to IPFS, pin it and copy it into MFS"
        return 0
    fi

    # Reading the SMB share from inside the container is unreliable with
    # automount, so stage a local copy that the container sees as /import.
    info "copying the backup to a local staging folder"
    local rsync_args=(-rt --delete "--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r")
    $IMPORT_HIDDEN || rsync_args+=(--exclude='.*')
    rsync "${rsync_args[@]}" "$src/" "$IMPORT_DIR/"

    local add_args=(add -r -Q --pin=false --progress=false "--cid-version=$CID_VERSION")
    $IMPORT_HIDDEN && add_args+=(--hidden)

    local path name dest cid imported=0 skipped=0 failed=0 stamp
    stamp="$(date +%Y%m%d%H%M%S)"
    while IFS= read -r -d '' path; do
        name="${path##*/}"
        dest="/$name"
        if ipfs_exec files stat --hash "$dest" >/dev/null 2>&1; then
            case "$IMPORT_CONFLICT" in
                skip)
                    info "skip $dest (already in MFS)"
                    skipped=$((skipped + 1)); continue ;;
                replace)
                    ipfs_exec files rm -r "$dest" \
                        || { err "could not remove $dest"; failed=$((failed + 1)); continue; } ;;
                rename)
                    dest="/$name.imported-$stamp" ;;
            esac
        fi

        info "adding $dest"
        if ! cid="$(ipfs_exec "${add_args[@]}" "/import/$name")" || [[ -z "$cid" ]]; then
            err "failed to add $name"
            failed=$((failed + 1)); continue
        fi
        cid="$(tail -n1 <<<"$cid")"
        if ! ipfs_exec pin add --progress=false --name="$dest" "$cid" >/dev/null 2>&1 \
            && ! ipfs_exec pin add --progress=false "$cid" >/dev/null; then
            err "failed to pin $name ($cid)"
            failed=$((failed + 1)); continue
        fi
        if ! ipfs_exec files cp "/ipfs/$cid" "$dest"; then
            err "failed to copy $cid to $dest in MFS"
            failed=$((failed + 1)); continue
        fi

        # The MFS entry must point at exactly the content that was added and pinned.
        if [[ "$(ipfs_exec files stat --hash "$dest")" == "$cid" ]] \
            && ipfs_exec pin ls --type=recursive "$cid" >/dev/null 2>&1; then
            ok "$dest -> $cid (pinned)"
            imported=$((imported + 1))
        else
            err "verification failed for $dest"
            failed=$((failed + 1))
        fi
    done < <(find "$IMPORT_DIR" -mindepth 1 -maxdepth 1 -print0 | sort -z)

    find "$IMPORT_DIR" -mindepth 1 -delete

    IMPORT_SUMMARY="$imported imported and pinned, $skipped skipped, $failed failed"
    ((hidden)) && IMPORT_SUMMARY+=", $hidden hidden files not imported"
    if ((failed)); then
        warn "import: $IMPORT_SUMMARY"
    else
        ok "import: $IMPORT_SUMMARY"
    fi
    info "note: files keep their original CIDs only if chunk size ($(describe_chunker "${IMPORT_CHUNKER:-}")), CID version"
    info "and raw leaves match how they were first added; otherwise they get new CIDs"
}

# ----------------------------------------------------------------- backup --
pause_backup_timer() {
    if [[ -f "$BACKUP_TIMER" ]]; then
        run systemctl stop ipfs-mfs-backup.timer || true
        # Wait for a backup that is already running to finish.
        $DRY_RUN || flock /var/lock/ipfs_mfs_backup.lock true 2>/dev/null || true
    fi
}

install_backup() {
    section "Scheduled backup"
    write_backup_script

    write_file "$BACKUP_ENV_FILE" 0644 <<EOF
# Managed by setup.sh - read by ipfs-mfs-backup.service.
CONTAINER_NAME=$CONTAINER_NAME
SHARED_DIR=$NAS_MOUNT
BACKUP_DIR=$NAS_MOUNT/$BACKUP_SUBDIR
MIRROR_DELETES=$MIRROR_DELETES
BACKUP_NODE_CONFIG=$BACKUP_NODE_CONFIG
IPFS_DATA_DIR=$DATA_DIR
EOF

    write_file "$BACKUP_SERVICE" 0644 <<EOF
# Managed by setup.sh
[Unit]
Description=Back up IPFS MFS to the NAS
Wants=network-online.target
After=network-online.target docker.service
RequiresMountsFor=$NAS_MOUNT

[Service]
Type=oneshot
EnvironmentFile=$BACKUP_ENV_FILE
ExecStart=$BACKUP_SCRIPT
Nice=10
IOSchedulingClass=idle
EOF

    write_file "$BACKUP_TIMER" 0644 <<EOF
# Managed by setup.sh
[Unit]
Description=Scheduled IPFS MFS backup

[Timer]
OnCalendar=$BACKUP_SCHEDULE
Persistent=true
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
EOF

    write_file "$LOGROTATE_FILE" 0644 <<'EOF'
/var/log/ipfs_mfs_backup.log {
    weekly
    maxsize 50M
    rotate 8
    compress
    delaycompress
    dateext
    missingok
    notifempty
    create 0640 root root
}
EOF

    run systemctl daemon-reload
    run systemctl enable --now ipfs-mfs-backup.timer
    ok "backup scheduled $(describe_schedule); log: /var/log/ipfs_mfs_backup.log"
}

write_backup_script() {
    write_file "$BACKUP_SCRIPT" 0755 <<'BACKUP_EOF'
#!/usr/bin/env bash
#
# ipfs_mfs_backup.sh (installed by setup.sh)
# Backs up the IPFS MFS (Mutable File System) from a Docker container to a
# shared directory using rsync.
#
# Settings come from /etc/ipfs-setup/backup.env via ipfs-mfs-backup.service
# and can be overridden via environment variables, e.g.:
#   MIRROR_DELETES=true ipfs_mfs_backup.sh

set -Eeuo pipefail

# ---------------------------------------------------------------- settings --
CONTAINER_NAME="${CONTAINER_NAME:-ipfs}"
SHARED_DIR="${SHARED_DIR:-/mnt/ipfs}"
BACKUP_DIR="${BACKUP_DIR:-$SHARED_DIR/backup}"
LOG_FILE="${LOG_FILE:-/var/log/ipfs_mfs_backup.log}"
LOCK_FILE="${LOCK_FILE:-/var/lock/ipfs_mfs_backup.lock}"

# If true, files removed from MFS are also removed from the backup (mirror).
# If false, the backup only grows (safer: protects against an accidental
# deletion in MFS propagating to the backup).
MIRROR_DELETES="${MIRROR_DELETES:-false}"

# If true, refuse to run unless SHARED_DIR is a mounted SMB share, so a missing
# NAS never results in the backup silently filling the local disk.
REQUIRE_MOUNT="${REQUIRE_MOUNT:-true}"

# If true, also copy the node's config and keystore (contains the private
# identity key) to NODE_CONFIG_DIR.
BACKUP_NODE_CONFIG="${BACKUP_NODE_CONFIG:-false}"
IPFS_DATA_DIR="${IPFS_DATA_DIR:-/opt/ipfs/data}"
NODE_CONFIG_DIR="${NODE_CONFIG_DIR:-$SHARED_DIR/node-config}"

# cron/systemd run with a minimal PATH, so set one explicitly.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ----------------------------------------------------------------- helpers --
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

STAGING_ROOT=""
REMOTE_TMP="/tmp/mfs_export_$$"

cleanup() {
    local rc=$?
    [[ -n "$STAGING_ROOT" ]] && rm -rf "$STAGING_ROOT"
    docker exec "$CONTAINER_NAME" rm -rf "$REMOTE_TMP" >/dev/null 2>&1 || true
    if (( rc != 0 )); then
        log "ERROR: backup failed (exit code $rc)."
    fi
}
trap cleanup EXIT
trap 'log "ERROR: command failed at line $LINENO: $BASH_COMMAND"' ERR

# ------------------------------------------------------------------- setup --
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Prevent overlapping runs (e.g. a slow backup still going at the next tick).
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "Another backup is already running; skipping this run."
    trap - EXIT ERR
    exit 0
fi

SECONDS=0
log "Starting IPFS MFS backup..."

# Make sure the NAS is really mounted (accessing the path triggers automount;
# autofs itself also counts as a mount, so look for an SMB mount).
if [[ "$REQUIRE_MOUNT" == "true" ]]; then
    ls "$SHARED_DIR" >/dev/null 2>&1 || true
    if ! findmnt -rn -t cifs,smb3 -M "$SHARED_DIR" >/dev/null 2>&1; then
        log "ERROR: $SHARED_DIR is not a mounted SMB share; refusing to back up to local disk."
        exit 1
    fi
fi
mkdir -p "$BACKUP_DIR"

# Make sure the container is up.
if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>>"$LOG_FILE")" != "true" ]]; then
    log "ERROR: container '$CONTAINER_NAME' is not running."
    exit 1
fi

# ------------------------------------------------- 1. get current MFS root --
MFS_CID="$(docker exec "$CONTAINER_NAME" ipfs files stat --hash / 2>>"$LOG_FILE")"
if [[ -z "$MFS_CID" ]]; then
    log "ERROR: failed to retrieve MFS root CID."
    exit 1
fi
log "MFS root CID: $MFS_CID"

# ----------------------------------------- 2. export to a host staging dir --
STAGING_ROOT="$(mktemp -d /tmp/ipfs_mfs_staging.XXXXXX)"
STAGING_DIR="$STAGING_ROOT/export"
mkdir -p "$STAGING_DIR"

# shellcheck disable=SC2129
docker exec "$CONTAINER_NAME" ipfs get --progress=false "$MFS_CID" -o "$REMOTE_TMP" >>"$LOG_FILE" 2>&1
# The trailing "/." copies the directory's *contents* into the existing dir.
docker cp "$CONTAINER_NAME:$REMOTE_TMP/." "$STAGING_DIR/" >>"$LOG_FILE" 2>&1
docker exec "$CONTAINER_NAME" rm -rf "$REMOTE_TMP" >>"$LOG_FILE" 2>&1

# Safety check: never sync (and especially never --delete) from an empty export.
if [[ -z "$(ls -A "$STAGING_DIR")" ]]; then
    log "ERROR: exported MFS is empty; aborting to protect the existing backup."
    exit 1
fi

# --------------------------------------------------- 3. sync to shared dir --
# -r  recurse
# -t  preserve modification times
# -p  preserve permissions (applies --chmod to existing items too; this is
#     what lets other users delete/modify files)
# --checksum  compare file contents instead of mtime/size, because
#     `ipfs get` doesn't preserve original mtimes, so every file would
#     otherwise look "changed" on every run. If your MFS is very large and
#     this is too slow, try --size-only instead (less safe).
RSYNC_ARGS=(
    -rtp
    --no-owner --no-group
    --chmod=ugo=rwX
    --checksum
    --itemize-changes
)
if [[ "$MIRROR_DELETES" == "true" ]]; then
    RSYNC_ARGS+=(--delete)
fi

rsync "${RSYNC_ARGS[@]}" "$STAGING_DIR/" "$BACKUP_DIR/" >>"$LOG_FILE" 2>&1

# ------------------------------------------- 4. node config (optional) --
if [[ "$BACKUP_NODE_CONFIG" == "true" ]]; then
    mkdir -p "$NODE_CONFIG_DIR"
    cp "$IPFS_DATA_DIR/config" "$NODE_CONFIG_DIR/config"
    if [[ -d "$IPFS_DATA_DIR/keystore" ]]; then
        rsync -rt --delete "$IPFS_DATA_DIR/keystore/" "$NODE_CONFIG_DIR/keystore/" >>"$LOG_FILE" 2>&1
    fi
    log "Node config and keystore copied to $NODE_CONFIG_DIR."
fi

log "Backup completed successfully to $BACKUP_DIR in ${SECONDS}s (mirror deletes: $MIRROR_DELETES)."
BACKUP_EOF
}

# ----------------------------------------------------------------- report --
final_report() {
    section "Done"
    if $DRY_RUN; then
        ok "dry run finished; nothing was changed"
        return 0
    fi
    local peer addrs
    peer="$(ipfs_exec id -f '<id>' 2>/dev/null || echo '?')"
    addrs="$(ipfs_exec id -f '<addrs>' 2>/dev/null | sed 's/^/    /' || true)"
    cat >&2 <<EOF
  Peer ID ......... $peer
  WebUI ........... http://${LAN_IP:-<this-host>}:$API_PORT/webui
  Gateway ......... http://${LAN_IP:-<this-host>}:$GATEWAY_PORT/ipfs/<cid>
  NAS ............. $NAS_SHARE mounted at $NAS_MOUNT
  Import .......... $IMPORT_SUMMARY
  Backup .......... $(systemctl list-timers ipfs-mfs-backup.timer --no-legend 2>/dev/null | awk '{print "next run " $1, $2, $3}' || echo "scheduled")
  Answers saved ... $CONF_FILE (re-run the setup to change them)

  Addresses the node listens on / announces:
$addrs

${C_BOLD}Next step:${C_RESET} on your router, forward port $SWARM_PORT (TCP and UDP) to ${LAN_IP:-this machine}
so peers outside your network can connect. Never forward $API_PORT or $GATEWAY_PORT.
EOF
}

# ------------------------------------------------------------------- main --
main() {
    parse_args "$@"
    trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
    trap cleanup_tmp EXIT
    printf '%sIPFS node setup %s%s\n' "$C_BOLD" "$SCRIPT_VERSION" "$C_RESET" >&2

    preflight
    setup_tty
    load_conf

    if $IMPORT_ONLY; then
        [[ -n "${NAS_MOUNT:-}" && -n "${BACKUP_SUBDIR:-}" ]] \
            || die "no saved setup found in $CONF_FILE; run the full setup first"
        : "${IMPORT_HIDDEN:=false}" "${IMPORT_CONFLICT:=skip}" "${CID_VERSION:=1}"
        pause_backup_timer
        import_backup
        [[ -f "$BACKUP_TIMER" ]] && run systemctl start ipfs-mfs-backup.timer
        return 0
    fi

    $INTERACTIVE || [[ -n "$CONFIG_FILE" ]] \
        || die "no terminal for questions; run interactively or pass --config <file>"

    collect_answers
    show_summary
    save_conf

    install_packages
    install_docker
    configure_nas
    deploy_node
    configure_firewall
    pause_backup_timer
    import_backup
    install_backup
    final_report
}

main "$@"
