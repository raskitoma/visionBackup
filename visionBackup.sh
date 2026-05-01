#!/usr/bin/env bash
# =============================================================================
# visionBackup.sh — Database Backup Execution Engine v2
# =============================================================================
# No set -e: errors are handled manually so one failed source won't stop others
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/visionBackup.log"
CONNECT_TIMEOUT=10
DUMP_TIMEOUT=3600

# ── Terminal Capabilities ───────────────────────────────────────────────────
HAS_TPUT=false
command -v tput &>/dev/null && HAS_TPUT=true

cursor_up()  { if $HAS_TPUT; then tput cuu "$1" 2>/dev/null; else printf '\033[%dA' "$1"; fi; }
clear_eol()  { if $HAS_TPUT; then tput el 2>/dev/null; else printf '\033[K'; fi; }

# ── Colors ──────────────────────────────────────────────────────────────────
setup_colors() {
    if [[ "$MODE" == "auto" ]]; then
        RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
    else
        RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
        BLUE='\033[0;34m' CYAN='\033[0;36m'
        BOLD='\033[1m' DIM='\033[2m' NC='\033[0m'
    fi
}

# ── Helpers ──────────────────────────────────────────────────────────────────
print_msg()  { [[ "$MODE" != "auto" ]] && echo -e "  ${GREEN}✔${NC} $1" || true; }
print_err()  { [[ "$MODE" != "auto" ]] && echo -e "  ${RED}✖${NC} $1" || true; }
print_info() { [[ "$MODE" != "auto" ]] && echo -e "  ${BLUE}ℹ${NC} $1" || true; }

log_event() {
    mkdir -p "$LOG_DIR"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] [$2] $3" >> "$LOG_FILE"
}

separator() { [[ "$MODE" != "auto" ]] && echo -e "  ${DIM}──────────────────────────────────────────────────────${NC}" || true; }

format_time() {
    local s=$1
    if (( s < 60 )); then printf "%ds" "$s"
    elif (( s < 3600 )); then printf "%dm%02ds" $((s/60)) $((s%60))
    else printf "%dh%02dm" $((s/3600)) $(( (s%3600)/60 )); fi
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

# ── Log Rotation (keep last 30 days) ─────────────────────────────────────
rotate_logs() {
    [[ ! -f "$LOG_FILE" ]] && return 0
    local cutoff
    cutoff=$(date -d "30 days ago" '+%Y-%m-%d' 2>/dev/null) || return 0
    local tmp
    tmp=$(mktemp)
    while IFS= read -r line; do
        local d="${line:1:10}"
        [[ "$d" > "$cutoff" || "$d" == "$cutoff" ]] && echo "$line"
    done < "$LOG_FILE" > "$tmp"
    mv "$tmp" "$LOG_FILE"
}

# ── Backup Retention Policy ───────────────────────────────────────────
# 30 daily → 12 monthly (1 per month) → 1 per year
cleanup_retention() {
    [[ -z "${TARGET_PATH:-}" ]] && return 0
    local base_dir="${TARGET_PATH}/visionBackup"
    [[ ! -d "$base_dir" ]] && return 0

    local today_epoch
    today_epoch=$(date +%s)
    local thirty_days=$((30 * 86400))
    local one_year=$((365 * 86400))
    local removed=0

    for desc_dir in "$base_dir"/*/; do
        [[ ! -d "$desc_dir" ]] && continue
        local desc
        desc=$(basename "$desc_dir")

        # Collect backup files sorted newest first
        local files=()
        mapfile -t files < <(find "$desc_dir" -maxdepth 1 -name '*.tar.gz' 2>/dev/null | sort -r)
        [[ ${#files[@]} -eq 0 ]] && continue

        local keep=()
        declare -A monthly_kept yearly_kept

        for file in "${files[@]}"; do
            local bn
            bn=$(basename "$file")
            local ds
            ds=$(echo "$bn" | grep -oE '[0-9]{8}' | head -1) || true
            [[ -z "$ds" ]] && keep+=("$file") && continue

            local file_epoch
            file_epoch=$(date -d "${ds:0:4}-${ds:4:2}-${ds:6:2}" +%s 2>/dev/null) || continue
            local age=$((today_epoch - file_epoch))
            local ym="${ds:0:6}"
            local y="${ds:0:4}"

            if (( age <= thirty_days )); then
                keep+=("$file")
            elif (( age <= one_year )); then
                if [[ -z "${monthly_kept[$ym]+x}" ]]; then
                    keep+=("$file")
                    monthly_kept[$ym]=1
                fi
            else
                if [[ -z "${yearly_kept[$y]+x}" ]]; then
                    keep+=("$file")
                    yearly_kept[$y]=1
                fi
            fi
        done

        # Remove files not in keep list
        for file in "${files[@]}"; do
            local found=false
            for k in "${keep[@]}"; do
                [[ "$file" == "$k" ]] && found=true && break
            done
            if ! $found; then
                rm -f "$file"
                rm -f "${file%.tar.gz}_error.log"
                removed=$((removed + 1))
                log_event "CLEANUP" "$desc" "Removed old backup: $(basename "$file")"
            fi
        done

        # Clean up orphaned error logs older than 30 days
        for errlog in "$desc_dir"*_error.log; do
            [[ ! -f "$errlog" ]] && continue
            local eds
            eds=$(basename "$errlog" | grep -oE '[0-9]{8}' | head -1) || true
            [[ -z "$eds" ]] && continue
            local ee
            ee=$(date -d "${eds:0:4}-${eds:4:2}-${eds:6:2}" +%s 2>/dev/null) || continue
            (( today_epoch - ee > thirty_days )) && rm -f "$errlog"
        done

        unset monthly_kept yearly_kept
    done

    (( removed > 0 )) && log_event "INFO" "system" "Retention cleanup: removed ${removed} old backup(s)"
    [[ "$MODE" != "auto" ]] && (( removed > 0 )) && print_info "Retention cleanup: removed ${removed} old backup(s)" || true
    return 0
}

# ── Single-line Spinner ─────────────────────────────────────────────────────
spin_wait() {
    local pid=$1 msg="$2"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0 start=$SECONDS
    while kill -0 "$pid" 2>/dev/null; do
        local c="${spin:i%${#spin}:1}" e=$(( SECONDS - start ))
        printf "\r$(clear_eol)  ${CYAN}%s${NC} %s  ${DIM}%s${NC}" "$c" "$msg" "$(format_time $e)"
        sleep 0.2; i=$((i+1))
    done
    wait "$pid" 2>/dev/null
    return $?
}

# ── Dump Monitor (2-line controlled area) ────────────────────────────────────
monitor_dump() {
    local pid=$1 sql_file="$2" err_file="$3"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0 start=$SECONDS

    # Reserve 2 display lines
    echo -e "  ${CYAN}⠋${NC} Dumping database..."
    echo -e "    └ Starting mysqldump..."

    while kill -0 "$pid" 2>/dev/null; do
        local c="${spin:i%${#spin}:1}" e=$(( SECONDS - start ))
        local size="..."
        [[ -f "$sql_file" ]] && size=$(du -h "$sql_file" 2>/dev/null | cut -f1) || true
        local last_line="working..."
        if [[ -f "$err_file" && -s "$err_file" ]]; then
            # Show only --verbose progress lines (prefixed with "-- ")
            local verbose_line
            verbose_line=$(grep '^-- ' "$err_file" 2>/dev/null | tail -1 | sed 's/^-- //' | head -c 55) || true
            [[ -n "$verbose_line" ]] && last_line="$verbose_line"
        fi

        cursor_up 2
        printf "\r$(clear_eol)  ${CYAN}%s${NC} Dumping database...   ${BOLD}%s${NC}          ${DIM}%s${NC}\n" \
            "$c" "$size" "$(format_time $e)"
        printf "\r$(clear_eol)    └ ${DIM}%s${NC}\n" "$last_line"
        sleep 0.3; i=$((i+1))
    done

    wait "$pid" 2>/dev/null
    local exit_code=$? final_e=$(( SECONDS - start )) final_size="?"
    [[ -f "$sql_file" ]] && final_size=$(du -h "$sql_file" 2>/dev/null | cut -f1) || true

    cursor_up 2
    if [[ $exit_code -eq 0 ]] && [[ -s "$sql_file" ]]; then
        printf "\r$(clear_eol)  ${GREEN}✔${NC} Database dumped        ${BOLD}%s${NC}          ${DIM}%s${NC}\n" "$final_size" "$(format_time $final_e)"
        printf "\r$(clear_eol)\n"
    else
        # Try filtered first, fall back to unfiltered last lines
        local err_msg
        err_msg=$(grep -v '^-- \|\[Warning\]' "$err_file" 2>/dev/null | tail -5 | tr '\n' ' ' | sed 's/^[[:space:]]*//' | head -c 70) || true
        if [[ -z "${err_msg// /}" ]]; then
            err_msg=$(tail -3 "$err_file" 2>/dev/null | sed 's/^-- //' | tr '\n' ' ' | sed 's/^[[:space:]]*//' | head -c 70) || true
        fi
        [[ -z "${err_msg// /}" ]] && err_msg="Exit code from mysqldump (check credentials/permissions)"
        printf "\r$(clear_eol)  ${RED}✖${NC} Dump FAILED                             ${DIM}%s${NC}\n" "$(format_time $final_e)"
        printf "\r$(clear_eol)    └ ${RED}%s${NC}\n" "$err_msg"
    fi
    return $exit_code
}

# ── Backup Single Source ─────────────────────────────────────────────────────
backup_source() {
    local block="$1" manual_suffix="$2" index="${3:-1}" total="${4:-1}"
    parse_source "$block"

    local date_stamp backup_dir filename sql_file tar_file err_file
    date_stamp=$(date '+%Y%m%d')
    backup_dir="${TARGET_PATH}/visionBackup/${SRC_DESC}"
    filename="${SRC_DESC}_${date_stamp}${manual_suffix}"
    sql_file="${backup_dir}/${filename}.sql"
    tar_file="${backup_dir}/${filename}.tar.gz"
    err_file=$(mktemp)

    # ── Header ──
    if [[ "$MODE" != "auto" ]]; then
        echo ""
        echo -e "  ${BOLD}┌─[${index}/${total}]─ ${SRC_DESC} ${NC}${DIM}── ${SRC_USER}@${SRC_HOST}:${SRC_PORT}/${SRC_DB}${NC}"
        echo -e "  ${DIM}│${NC}"
    fi

    mkdir -p "$backup_dir"

    # ── Phase 1: Connection Test ──
    if [[ "$MODE" != "auto" ]]; then
        timeout "$CONNECT_TIMEOUT" mysql \
            --user="$SRC_USER" --password="$SRC_PASS" \
            --host="$SRC_HOST" --port="$SRC_PORT" \
            --database="$SRC_DB" --connect-timeout="$CONNECT_TIMEOUT" \
            -e "SELECT 1" >/dev/null 2>"$err_file" &
        spin_wait $! "Connecting to ${SRC_HOST}:${SRC_PORT}..."
        local conn_exit=$?
    else
        timeout "$CONNECT_TIMEOUT" mysql \
            --user="$SRC_USER" --password="$SRC_PASS" \
            --host="$SRC_HOST" --port="$SRC_PORT" \
            --database="$SRC_DB" --connect-timeout="$CONNECT_TIMEOUT" \
            -e "SELECT 1" >/dev/null 2>"$err_file"
        local conn_exit=$?
    fi

    if [[ $conn_exit -ne 0 ]]; then
        local conn_err
        conn_err=$(grep -v '\[Warning\]' "$err_file" 2>/dev/null | tail -1 | head -c 60) || true
        [[ -z "${conn_err// /}" ]] && conn_err="Timeout or unreachable"
        log_event "FAIL" "$SRC_DESC" "Connection failed: ${conn_err}"
        if [[ "$MODE" != "auto" ]]; then
            printf "\r$(clear_eol)  ${RED}✖${NC} Connection FAILED\n"
            echo -e "    └ ${RED}${conn_err:-Timeout or unreachable}${NC}"
            echo -e "  ${DIM}│${NC}"
            echo -e "  ${YELLOW}⚠${NC}  Skipping — continuing to next source"
            echo -e "  ${DIM}└──────────────────────────────────────────────────────${NC}"
        fi
        rm -f "$err_file"; return 1
    fi

    if [[ "$MODE" != "auto" ]]; then
        printf "\r$(clear_eol)  ${GREEN}✔${NC} Connected to ${SRC_HOST}:${SRC_PORT}/${SRC_DB}\n"
    fi

    # ── Phase 2: Database Dump ──
    > "$err_file"
    if [[ "$MODE" != "auto" ]]; then
        timeout "$DUMP_TIMEOUT" mysqldump \
            --user="$SRC_USER" --password="$SRC_PASS" \
            --host="$SRC_HOST" --port="$SRC_PORT" \
            --single-transaction --routines --triggers --quick --verbose \
            "$SRC_DB" > "$sql_file" 2>"$err_file" &
        monitor_dump $! "$sql_file" "$err_file"
        local dump_exit=$?
    else
        timeout "$DUMP_TIMEOUT" mysqldump \
            --user="$SRC_USER" --password="$SRC_PASS" \
            --host="$SRC_HOST" --port="$SRC_PORT" \
            --single-transaction --routines --triggers --quick \
            "$SRC_DB" > "$sql_file" 2>"$err_file"
        local dump_exit=$?
    fi

    if [[ $dump_exit -ne 0 ]] || [[ ! -s "$sql_file" ]]; then
        # Try filtered first, fall back to unfiltered with -- prefix stripped
        local err_msg
        err_msg=$(grep -v '^-- \|\[Warning\]' "$err_file" 2>/dev/null | tail -5 | tr '\n' ' ' | sed 's/^[[:space:]]*//' | head -c 120) || true
        if [[ -z "${err_msg// /}" ]]; then
            err_msg=$(tail -5 "$err_file" 2>/dev/null | sed 's/^-- //' | tr '\n' ' ' | sed 's/^[[:space:]]*//' | head -c 120) || true
        fi
        [[ -z "${err_msg// /}" ]] && err_msg="Exit code ${dump_exit} (check ${backup_dir}/${filename}_error.log)"
        # Save full stderr for debugging
        cp "$err_file" "${backup_dir}/${filename}_error.log" 2>/dev/null || true
        log_event "FAIL" "$SRC_DESC" "mysqldump failed (exit ${dump_exit}): ${err_msg}"
        if [[ "$MODE" != "auto" ]]; then
            echo -e "  ${DIM}│${NC}"
            echo -e "  ${YELLOW}⚠${NC}  Skipping — continuing to next source"
            echo -e "  ${DIM}│${NC}  ${DIM}Full stderr saved: ${backup_dir}/${filename}_error.log${NC}"
            echo -e "  ${DIM}└──────────────────────────────────────────────────────${NC}"
        fi
        rm -f "$sql_file" "$err_file"; return 1
    fi

    # ── Phase 3: Compression ──
    > "$err_file"
    if [[ "$MODE" != "auto" ]]; then
        tar -czf "$tar_file" -C "$backup_dir" "${filename}.sql" 2>"$err_file" &
        spin_wait $! "Compressing..."
        local tar_exit=$?
    else
        tar -czf "$tar_file" -C "$backup_dir" "${filename}.sql" 2>"$err_file"
        local tar_exit=$?
    fi

    if [[ $tar_exit -ne 0 ]]; then
        local err_msg
        err_msg=$(cat "$err_file" 2>/dev/null | head -c 70) || true
        log_event "FAIL" "$SRC_DESC" "Compression failed: ${err_msg}"
        if [[ "$MODE" != "auto" ]]; then
            printf "\r$(clear_eol)  ${RED}✖${NC} Compression FAILED\n"
            echo -e "    └ ${RED}${err_msg:-Unknown error}${NC}"
            echo -e "  ${DIM}└──────────────────────────────────────────────────────${NC}"
        fi
        rm -f "$err_file"; return 1
    fi

    rm -f "$sql_file"
    local final_size
    final_size=$(du -h "$tar_file" 2>/dev/null | cut -f1) || true
    log_event "SUCCESS" "$SRC_DESC" "Backup completed: ${tar_file} (${final_size})"

    if [[ "$MODE" != "auto" ]]; then
        printf "\r$(clear_eol)  ${GREEN}✔${NC} Compressed             ${BOLD}%s${NC}\n" "$final_size"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${GREEN}✔${NC}  ${BOLD}${filename}.tar.gz${NC}"
        echo -e "  ${DIM}└──────────────────────────────────────────────────────${NC}"
    fi
    rm -f "$err_file"; return 0
}

# ── Interactive Mode ─────────────────────────────────────────────────────────
run_interactive() {
    echo ""
    echo -e "  ${CYAN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "  ${CYAN}${BOLD}║       visionBackup · Interactive Mode        ║${NC}"
    echo -e "  ${CYAN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    if [[ -z "$SOURCE_DBS" ]]; then print_err "No sources configured. Run deploy.sh first."; exit 1; fi
    if [[ -z "$TARGET_PATH" ]]; then print_err "TARGET_PATH not set. Run deploy.sh first."; exit 1; fi

    print_info "Target: ${BOLD}${TARGET_PATH}${NC}"
    separator

    IFS=',' read -ra blocks <<< "$SOURCE_DBS"
    local total=${#blocks[@]}

    echo -e "  ${BOLD}Select backup scope:${NC}"
    echo -e "    ${CYAN}1)${NC} Single source"
    echo -e "    ${CYAN}2)${NC} All sources (${total})"
    echo -e "    ${DIM}0)${NC} Cancel"
    echo ""
    read -rp "  ▸ " scope

    local success=0 fail=0

    case "$scope" in
        1)
            echo ""
            local i=1
            for b in "${blocks[@]}"; do
                parse_source "$b"
                echo -e "  ${CYAN}${i})${NC} ${SRC_DESC} ${DIM}(${SRC_HOST}:${SRC_PORT}/${SRC_DB})${NC}"
                i=$((i+1))
            done
            echo ""
            read -rp "  Select source: " src_choice
            if ! [[ "$src_choice" =~ ^[0-9]+$ ]] || (( src_choice < 1 || src_choice > total )); then
                print_err "Invalid selection."; exit 1
            fi
            separator
            if backup_source "${blocks[$((src_choice-1))]}" "_manual" 1 1; then
                success=1
            else
                fail=1
            fi
            ;;
        2)
            separator
            local i=1
            for b in "${blocks[@]}"; do
                if backup_source "$b" "_manual" "$i" "$total"; then
                    success=$((success + 1))
                else
                    fail=$((fail + 1))
                fi
                i=$((i + 1))
            done
            ;;
        0) echo -e "\n  ${DIM}Cancelled.${NC}\n"; exit 0 ;;
        *) print_err "Invalid option."; exit 1 ;;
    esac

    echo ""
    separator
    echo -e "  ${BOLD}Backup Complete${NC}"
    echo -e "  ${GREEN}✔ ${success} succeeded${NC}   ${RED}✖ ${fail} failed${NC}"
    separator
    echo ""

    # Run retention cleanup after backups
    cleanup_retention
}

# ── Auto Mode ────────────────────────────────────────────────────────────────
run_auto() {
    if [[ -z "$SOURCE_DBS" ]]; then log_event "FAIL" "system" "Auto aborted: no sources"; exit 1; fi
    if [[ -z "$TARGET_PATH" ]]; then log_event "FAIL" "system" "Auto aborted: no TARGET_PATH"; exit 1; fi

    log_event "INFO" "system" "Auto backup started"
    IFS=',' read -ra blocks <<< "$SOURCE_DBS"
    local success=0 fail=0

    for b in "${blocks[@]}"; do
        if backup_source "$b" ""; then success=$((success + 1)); else fail=$((fail + 1)); fi
    done
    log_event "INFO" "system" "Auto backup finished: ${success} succeeded, ${fail} failed"

    # Run retention cleanup after backups
    cleanup_retention
}

# ── Dependency Check ─────────────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in mysqldump mysql tar grep sed awk timeout; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Missing dependencies: ${missing[*]}" >&2
        echo "Install: sudo apt install -y mariadb-client coreutils" >&2
        log_event "FAIL" "system" "Missing deps: ${missing[*]}"
        exit 1
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
MODE="interactive"
[[ "${1:-}" == "--auto" ]] && MODE="auto"

setup_colors
check_deps

if [[ ! -f "$ENV_FILE" ]]; then echo "Error: .env not found. Run deploy.sh first." >&2; exit 1; fi
# shellcheck disable=SC1090
source "$ENV_FILE"
SOURCE_DBS="${SOURCE_DBS:-}"
TARGET_PATH="${TARGET_PATH:-}"

# Prune old log entries on every run
rotate_logs

if [[ "$MODE" == "auto" ]]; then run_auto; else run_interactive; fi
