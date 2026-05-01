#!/usr/bin/env bash
# =============================================================================
# visionBackup.sh — Database Backup Execution Engine
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/visionBackup.log"

# ── Colors (disabled in auto mode) ──────────────────────────────────────────
setup_colors() {
    if [[ "$MODE" == "auto" ]]; then
        RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''
        BOLD=''; DIM=''; NC=''
    else
        RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
        BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
        BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
    fi
}

# ── Helpers ──────────────────────────────────────────────────────────────────
print_msg()  { [[ "$MODE" != "auto" ]] && echo -e "  ${GREEN}✔${NC} $1"; }
print_warn() { [[ "$MODE" != "auto" ]] && echo -e "  ${YELLOW}⚠${NC} $1"; }
print_err()  { [[ "$MODE" != "auto" ]] && echo -e "  ${RED}✖${NC} $1"; }
print_info() { [[ "$MODE" != "auto" ]] && echo -e "  ${BLUE}ℹ${NC} $1"; }

log_event() {
    local status="$1" desc="$2" message="$3"
    mkdir -p "$LOG_DIR"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${status}] [${desc}] ${message}" >> "$LOG_FILE"
}

separator() {
    [[ "$MODE" != "auto" ]] && echo -e "  ${DIM}──────────────────────────────────────────────${NC}"
}

# ── Source Parser ────────────────────────────────────────────────────────────
parse_source() {
    local block="$1"
    SRC_DESC="${block##*|}"
    local connstr="${block%|*}"
    SRC_USER="${connstr%%:*}"
    local rest="${connstr#*:}"
    local hostportdb="${rest##*@}"
    SRC_PASS="${rest%@*}"
    SRC_HOST="${hostportdb%%:*}"
    local portdb="${hostportdb#*:}"
    SRC_PORT="${portdb%%/*}"
    SRC_DB="${portdb#*/}"
}

# ── Progress Bar ─────────────────────────────────────────────────────────────
show_progress() {
    local pid="$1" desc="$2"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    local elapsed=0

    while kill -0 "$pid" 2>/dev/null; do
        local char="${spin:i%${#spin}:1}"
        printf "\r  ${CYAN}%s${NC} Dumping ${BOLD}%s${NC}... %ds " "$char" "$desc" "$elapsed"
        sleep 0.2
        i=$((i + 1))
        elapsed=$(( i / 5 ))
    done
    printf "\r%80s\r" ""  # Clear the progress line
}

# ── Backup Single Source ─────────────────────────────────────────────────────
backup_source() {
    local block="$1" manual_suffix="$2"
    parse_source "$block"

    local date_stamp
    date_stamp=$(date '+%Y%m%d')
    local backup_dir="${TARGET_PATH}/visionBackup/${SRC_DESC}"
    local filename="${SRC_DESC}_${date_stamp}${manual_suffix}"
    local sql_file="${backup_dir}/${filename}.sql"
    local tar_file="${backup_dir}/${filename}.tar.gz"
    local err_file
    err_file=$(mktemp)

    # Create backup directory
    mkdir -p "$backup_dir"

    # Run mysqldump
    if [[ "$MODE" != "auto" ]]; then
        mysqldump \
            --user="$SRC_USER" \
            --password="$SRC_PASS" \
            --host="$SRC_HOST" \
            --port="$SRC_PORT" \
            --single-transaction \
            --routines \
            --triggers \
            --quick \
            "$SRC_DB" > "$sql_file" 2>"$err_file" &
        local dump_pid=$!
        show_progress "$dump_pid" "$SRC_DESC"
        wait "$dump_pid"
        local dump_exit=$?
    else
        mysqldump \
            --user="$SRC_USER" \
            --password="$SRC_PASS" \
            --host="$SRC_HOST" \
            --port="$SRC_PORT" \
            --single-transaction \
            --routines \
            --triggers \
            --quick \
            "$SRC_DB" > "$sql_file" 2>"$err_file"
        local dump_exit=$?
    fi

    # Validate dump success
    if [[ $dump_exit -ne 0 ]] || [[ ! -s "$sql_file" ]]; then
        local err_msg
        err_msg=$(cat "$err_file" 2>/dev/null || echo "Unknown error")
        rm -f "$sql_file" "$err_file"
        log_event "FAIL" "$SRC_DESC" "mysqldump failed (exit ${dump_exit}): ${err_msg}"
        print_err "${SRC_DESC}: mysqldump failed — ${err_msg}"
        return 1
    fi

    # Compress
    if tar -czf "$tar_file" -C "$backup_dir" "${filename}.sql" 2>>"$err_file"; then
        rm -f "$sql_file"
        local size
        size=$(du -h "$tar_file" | cut -f1)
        log_event "SUCCESS" "$SRC_DESC" "Backup completed: ${tar_file} (${size})"
        print_msg "${SRC_DESC}: ${GREEN}${filename}.tar.gz${NC} (${size})"
    else
        local err_msg
        err_msg=$(cat "$err_file" 2>/dev/null || echo "Compression error")
        log_event "FAIL" "$SRC_DESC" "tar compression failed: ${err_msg}"
        print_err "${SRC_DESC}: compression failed — ${err_msg}"
        rm -f "$err_file"
        return 1
    fi

    rm -f "$err_file"
    return 0
}

# ── Interactive Mode ─────────────────────────────────────────────────────────
run_interactive() {
    echo -e "\n  ${CYAN}${BOLD}visionBackup · Interactive Mode${NC}\n"
    separator

    if [[ -z "$SOURCE_DBS" ]]; then
        print_err "No sources configured. Run deploy.sh first."
        exit 1
    fi
    if [[ -z "$TARGET_PATH" ]]; then
        print_err "TARGET_PATH not set. Run deploy.sh first."
        exit 1
    fi

    IFS=',' read -ra blocks <<< "$SOURCE_DBS"
    local total=${#blocks[@]}

    echo -e "  ${BOLD}Select backup scope:${NC}"
    echo -e "    ${CYAN}1)${NC} Single source"
    echo -e "    ${CYAN}2)${NC} All sources (${total})"
    echo -e "    ${DIM}0)${NC} Cancel"
    echo ""
    read -rp "  ▸ " scope

    case "$scope" in
        1)
            # List sources for selection
            echo ""
            local i=1
            for b in "${blocks[@]}"; do
                parse_source "$b"
                echo -e "  ${CYAN}${i})${NC} ${SRC_DESC} ${DIM}(${SRC_HOST}:${SRC_PORT}/${SRC_DB})${NC}"
                ((i++))
            done
            echo ""
            read -rp "  Select source: " src_choice
            if ! [[ "$src_choice" =~ ^[0-9]+$ ]] || (( src_choice < 1 || src_choice > total )); then
                print_err "Invalid selection."
                exit 1
            fi
            separator
            echo ""
            backup_source "${blocks[$((src_choice-1))]}" "_manual"
            ;;
        2)
            separator
            echo ""
            local success=0 fail=0
            for b in "${blocks[@]}"; do
                if backup_source "$b" "_manual"; then
                    ((success++))
                else
                    ((fail++))
                fi
            done
            separator
            echo -e "\n  ${BOLD}Summary:${NC} ${GREEN}${success} succeeded${NC}, ${RED}${fail} failed${NC}\n"
            ;;
        0)
            echo -e "\n  ${DIM}Cancelled.${NC}\n"
            exit 0
            ;;
        *)
            print_err "Invalid option."
            exit 1
            ;;
    esac
}

# ── Auto Mode ────────────────────────────────────────────────────────────────
run_auto() {
    if [[ -z "$SOURCE_DBS" ]]; then
        log_event "FAIL" "system" "Auto run aborted: no sources configured"
        exit 1
    fi
    if [[ -z "$TARGET_PATH" ]]; then
        log_event "FAIL" "system" "Auto run aborted: TARGET_PATH not set"
        exit 1
    fi

    log_event "INFO" "system" "Auto backup started"

    IFS=',' read -ra blocks <<< "$SOURCE_DBS"
    local success=0 fail=0

    for b in "${blocks[@]}"; do
        if backup_source "$b" ""; then
            ((success++))
        else
            ((fail++))
        fi
    done

    log_event "INFO" "system" "Auto backup finished: ${success} succeeded, ${fail} failed"
}

# ── Dependency Check ─────────────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in mysqldump tar grep sed awk; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Missing dependencies: ${missing[*]}" >&2
        log_event "FAIL" "system" "Missing dependencies: ${missing[*]}"
        exit 1
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
MODE="interactive"
if [[ "${1:-}" == "--auto" ]]; then
    MODE="auto"
fi

setup_colors
check_deps

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: .env not found. Run deploy.sh first." >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"
SOURCE_DBS="${SOURCE_DBS:-}"
TARGET_PATH="${TARGET_PATH:-}"

if [[ "$MODE" == "auto" ]]; then
    run_auto
else
    run_interactive
fi
