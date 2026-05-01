#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Management & Setup for visionBackup
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/visionBackup.log"
BACKUP_SCRIPT="${SCRIPT_DIR}/visionBackup.sh"
CRON_TAG="visionBackup-auto"

# ── Terminal Capabilities ────────────────────────────────────────────────────
HAS_TPUT=false
command -v tput &>/dev/null && HAS_TPUT=true

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ── Helpers ──────────────────────────────────────────────────────────────────
print_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║         visionBackup · Deploy Manager        ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_msg()  { echo -e "  ${GREEN}✔${NC} $1"; }
print_warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
print_err()  { echo -e "  ${RED}✖${NC} $1"; }
print_info() { echo -e "  ${BLUE}ℹ${NC} $1"; }
separator()  { echo -e "  ${DIM}──────────────────────────────────────────────${NC}"; }

log_event() {
    local status="$1" desc="$2" message="$3"
    mkdir -p "$LOG_DIR"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${status}] [${desc}] ${message}" >> "$LOG_FILE"
}

press_enter() {
    echo ""
    read -rp "  Press Enter to continue..." _
}

# ── Dependency Check ─────────────────────────────────────────────────────────
check_requirements() {
    local missing=() pkgs=()

    for cmd in mysql mysqldump; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd"); pkgs+=("mariadb-client")
        fi
    done
    for cmd in tar grep sed awk; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if ! command -v tput &>/dev/null; then
        missing+=("tput"); pkgs+=("ncurses-bin")
    fi
    if ! command -v timeout &>/dev/null; then
        missing+=("timeout"); pkgs+=("coreutils")
    fi
    if ! command -v crontab &>/dev/null; then
        missing+=("crontab"); pkgs+=("cron")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo ""
        echo -e "  ${RED}${BOLD}Missing Dependencies${NC}"
        separator
        for cmd in "${missing[@]}"; do
            echo -e "  ${RED}✖${NC} ${cmd}"
        done
        # Deduplicate package suggestions
        local unique_pkgs
        unique_pkgs=$(printf '%s\n' "${pkgs[@]}" | sort -u | tr '\n' ' ')
        if [[ -n "${unique_pkgs// /}" ]]; then
            echo ""
            echo -e "  ${YELLOW}Suggested install command:${NC}"
            echo -e "  ${BOLD}sudo apt install -y ${unique_pkgs}${NC}"
        fi
        echo ""
        read -rp "  Continue anyway? (y/N): " cont
        if [[ "$cont" != "y" && "$cont" != "Y" ]]; then
            exit 1
        fi
    fi
}

# ── ENV Management ───────────────────────────────────────────────────────────
init_env() {
    mkdir -p "$LOG_DIR"
    if [[ ! -f "$ENV_FILE" ]]; then
        cat > "$ENV_FILE" <<'EOF'
SOURCE_DBS=""
TARGET_PATH=""
EOF
        log_event "INFO" "system" "Initialized new .env configuration"
    fi
}

load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$ENV_FILE"
    fi
    SOURCE_DBS="${SOURCE_DBS:-}"
    TARGET_PATH="${TARGET_PATH:-}"
}

save_env() {
    cat > "$ENV_FILE" <<EOF
SOURCE_DBS="${SOURCE_DBS}"
TARGET_PATH="${TARGET_PATH}"
EOF
}

# ── Source Parsing ───────────────────────────────────────────────────────────
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

get_source_count() {
    [[ -z "$SOURCE_DBS" ]] && echo 0 && return
    local IFS=','
    local arr=($SOURCE_DBS)
    echo "${#arr[@]}"
}

# ── Add Source ───────────────────────────────────────────────────────────────
add_source() {
    print_header
    echo -e "  ${BOLD}Add New Database Source${NC}"
    separator

    read -rp "  DB Host [localhost]: " host; host="${host:-localhost}"
    read -rp "  DB Port [3306]:     " port; port="${port:-3306}"
    read -rp "  DB User:            " user
    if [[ -z "$user" ]]; then print_err "User is required."; press_enter; return; fi
    read -srp "  DB Password:        " pass; echo ""
    read -rp "  DB Name:            " db
    if [[ -z "$db" ]]; then print_err "Database name is required."; press_enter; return; fi
    read -rp "  Description (no spaces, e.g. prod_main): " desc
    if [[ -z "$desc" ]]; then print_err "Description is required."; press_enter; return; fi
    desc="${desc// /_}"

    # Check for duplicate descriptions
    if [[ -n "$SOURCE_DBS" ]]; then
        IFS=',' read -ra blocks <<< "$SOURCE_DBS"
        for b in "${blocks[@]}"; do
            local existing_desc="${b##*|}"
            if [[ "$existing_desc" == "$desc" ]]; then
                print_err "A source with description '${desc}' already exists."
                press_enter; return
            fi
        done
    fi

    local new_block="${user}:${pass}@${host}:${port}/${db}|${desc}"
    if [[ -z "$SOURCE_DBS" ]]; then
        SOURCE_DBS="$new_block"
    else
        SOURCE_DBS="${SOURCE_DBS},${new_block}"
    fi
    save_env
    log_event "INFO" "$desc" "Source added: ${user}@${host}:${port}/${db}"
    print_msg "Source '${desc}' added successfully."
    press_enter
}

# ── Remove Source ────────────────────────────────────────────────────────────
remove_source() {
    print_header
    echo -e "  ${BOLD}Remove Database Source${NC}"
    separator

    if [[ -z "$SOURCE_DBS" ]]; then
        print_warn "No sources configured."
        press_enter; return
    fi

    IFS=',' read -ra blocks <<< "$SOURCE_DBS"
    local i=1
    for b in "${blocks[@]}"; do
        parse_source "$b"
        echo -e "  ${CYAN}${i})${NC} ${SRC_DESC} ${DIM}(${SRC_USER}@${SRC_HOST}:${SRC_PORT}/${SRC_DB})${NC}"
        i=$((i+1))
    done
    separator
    echo -e "  ${DIM}0) Cancel${NC}"
    echo ""
    read -rp "  Select source to remove: " choice

    if [[ "$choice" == "0" || -z "$choice" ]]; then return; fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#blocks[@]} )); then
        print_err "Invalid selection."
        press_enter; return
    fi

    local removed_desc
    parse_source "${blocks[$((choice-1))]}"
    removed_desc="$SRC_DESC"

    unset 'blocks[choice-1]'
    SOURCE_DBS="$(IFS=','; echo "${blocks[*]}")"
    save_env
    log_event "INFO" "$removed_desc" "Source removed"
    print_msg "Source '${removed_desc}' removed."
    press_enter
}

# ── List Sources ─────────────────────────────────────────────────────────────
list_sources() {
    print_header
    echo -e "  ${BOLD}Configured Database Sources${NC}"
    separator

    if [[ -z "$SOURCE_DBS" ]]; then
        print_warn "No sources configured."
        press_enter; return
    fi

    IFS=',' read -ra blocks <<< "$SOURCE_DBS"
    local i=1
    for b in "${blocks[@]}"; do
        parse_source "$b"

        # Find last successful backup timestamp from log
        local last_backup="Never"
        if [[ -f "$LOG_FILE" ]]; then
            local entry
            entry=$(grep "\[SUCCESS\] \[${SRC_DESC}\]" "$LOG_FILE" | tail -1 || true)
            if [[ -n "$entry" ]]; then
                last_backup=$(echo "$entry" | grep -oP '^\[\K[0-9 :-]+' || echo "Unknown")
            fi
        fi

        echo -e "  ${CYAN}${i})${NC} ${BOLD}${SRC_DESC}${NC}"
        echo -e "     Host: ${SRC_HOST}:${SRC_PORT}  DB: ${SRC_DB}  User: ${SRC_USER}"
        echo -e "     Last backup: ${GREEN}${last_backup}${NC}"
        i=$((i+1))
    done

    separator
    if [[ -n "$TARGET_PATH" ]]; then
        echo -e "  Target: ${MAGENTA}${TARGET_PATH}${NC}"
    else
        echo -e "  Target: ${YELLOW}Not set${NC}"
    fi

    press_enter
}

# ── Target Path Selector (Arrow-Key Navigation) ─────────────────────────────
select_target() {
    local current_dir="${TARGET_PATH:-$HOME}"
    [[ ! -d "$current_dir" ]] && current_dir="$HOME"

    while true; do
        # Read subdirectories into array
        local dirs=()
        while IFS= read -r d; do
            dirs+=("$(basename "$d")")
        done < <(find "$current_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

        local selected=0
        local total=${#dirs[@]}
        local max_visible=15
        local action=""

        while [[ -z "$action" ]]; do
            print_header
            echo -e "  ${BOLD}Select Target Directory${NC}"
            echo -e "  ${MAGENTA}${current_dir}${NC}"
            separator
            echo -e "  ${DIM}↑↓ Navigate   → Enter dir   ← Parent   Enter Select   p Manual   q Cancel${NC}"
            separator

            if [[ $total -eq 0 ]]; then
                echo -e "  ${DIM}(empty directory)${NC}"
            else
                # Calculate visible window
                local offset=0
                if (( selected >= max_visible )); then
                    offset=$((selected - max_visible + 1))
                fi
                local end=$((offset + max_visible))
                (( end > total )) && end=$total

                if (( offset > 0 )); then
                    echo -e "  ${DIM}  ↑ ${offset} more above${NC}"
                fi

                local idx
                for (( idx=offset; idx<end; idx++ )); do
                    if [[ $idx -eq $selected ]]; then
                        echo -e "  ${CYAN}▸${NC} ${BOLD}📁 ${dirs[$idx]}/${NC}"
                    else
                        echo -e "    ${DIM}📁 ${dirs[$idx]}/${NC}"
                    fi
                done

                if (( end < total )); then
                    echo -e "  ${DIM}  ↓ $((total - end)) more below${NC}"
                fi
            fi

            separator

            # Read keypress
            read -rsn1 key
            if [[ "$key" == $'\x1b' ]]; then
                read -rsn2 -t 0.1 key
                case "$key" in
                    '[A') # Up arrow
                        (( selected > 0 )) && selected=$((selected - 1))
                        ;;
                    '[B') # Down arrow
                        (( total > 0 && selected < total - 1 )) && selected=$((selected + 1))
                        ;;
                    '[C') # Right arrow — enter selected directory
                        if (( total > 0 )); then
                            current_dir="${current_dir%/}/${dirs[$selected]}"
                            action="refresh"
                        fi
                        ;;
                    '[D') # Left arrow — go up
                        current_dir="$(dirname "$current_dir")"
                        action="refresh"
                        ;;
                esac
            elif [[ "$key" == '' ]]; then
                # Enter — select current directory as target
                TARGET_PATH="$current_dir"
                save_env
                log_event "INFO" "system" "Target path set: ${TARGET_PATH}"
                print_msg "Target set to: ${TARGET_PATH}"
                press_enter
                return
            elif [[ "$key" == 'q' || "$key" == 'Q' ]]; then
                return
            elif [[ "$key" == 'p' || "$key" == 'P' ]]; then
                echo ""
                read -rp "  Enter full path: " manual_path
                if [[ -d "$manual_path" ]]; then
                    current_dir="$manual_path"
                    action="refresh"
                else
                    print_err "Directory does not exist."
                    sleep 1
                    action="refresh"
                fi
            fi
        done
    done
}

# ── Cron Setup ───────────────────────────────────────────────────────────────
setup_cron() {
    print_header
    echo -e "  ${BOLD}Schedule Daily Cron Job${NC}"
    separator

    # Show existing visionBackup cron entry if any
    local existing
    existing=$(crontab -l 2>/dev/null | grep "$CRON_TAG" || true)
    if [[ -n "$existing" ]]; then
        print_info "Existing schedule found:"
        echo -e "  ${DIM}${existing}${NC}"
        separator
    fi

    read -rp "  Run daily at hour (00-23, or 'r' to remove): " hour

    if [[ "$hour" == "r" ]]; then
        crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab - 2>/dev/null || true
        log_event "INFO" "system" "Cron job removed"
        print_msg "Cron job removed."
        press_enter; return
    fi

    if ! [[ "$hour" =~ ^[0-9]{1,2}$ ]] || (( 10#$hour > 23 )); then
        print_err "Invalid hour. Use 00-23."
        press_enter; return
    fi

    local cron_line="0 ${hour} * * * /usr/bin/env bash ${BACKUP_SCRIPT} --auto # ${CRON_TAG}"

    # Preserve existing cron entries, replace only our tagged line
    local temp_cron
    temp_cron=$(crontab -l 2>/dev/null | grep -v "$CRON_TAG" || true)

    if [[ -n "$temp_cron" ]]; then
        printf '%s\n%s\n' "$temp_cron" "$cron_line" | crontab -
    else
        echo "$cron_line" | crontab -
    fi

    log_event "INFO" "system" "Cron job set: daily at ${hour}:00"
    print_msg "Cron job scheduled: daily at ${hour}:00"
    press_enter
}

# ── Log Viewer (scrollable, filterable) ──────────────────────────────────────
view_log() {
    if [[ ! -f "$LOG_FILE" ]]; then
        print_header
        print_warn "No log file found yet."
        press_enter; return
    fi

    local filter="all" offset=0 page_size=14

    while true; do
        # Load lines based on filter
        local lines=()
        if [[ "$filter" == "errors" ]]; then
            mapfile -t lines < <(grep '\[FAIL\]' "$LOG_FILE" 2>/dev/null)
        elif [[ "$filter" == "success" ]]; then
            mapfile -t lines < <(grep '\[SUCCESS\]' "$LOG_FILE" 2>/dev/null)
        else
            mapfile -t lines < <(cat "$LOG_FILE" 2>/dev/null)
        fi

        local total=${#lines[@]}
        local error_count
        error_count=$(grep -c '\[FAIL\]' "$LOG_FILE" 2>/dev/null || echo 0)
        local success_count
        success_count=$(grep -c '\[SUCCESS\]' "$LOG_FILE" 2>/dev/null || echo 0)

        # Clamp offset
        (( offset < 0 )) && offset=0
        (( total > 0 && offset > total - 1 )) && offset=$((total - 1))

        local end=$((offset + page_size))
        (( end > total )) && end=$total

        print_header
        echo -e "  ${BOLD}Event Log${NC}  ${DIM}│${NC} Total: ${CYAN}${total}${NC}  Errors: ${RED}${error_count}${NC}  Success: ${GREEN}${success_count}${NC}"
        echo -e "  Filter: ${BOLD}${filter}${NC}   Showing: $((offset+1))-${end} of ${total}"
        separator

        if [[ $total -eq 0 ]]; then
            if [[ "$filter" == "errors" ]]; then
                print_msg "No errors recorded. All clear!"
            else
                print_warn "Log is empty."
            fi
        else
            for (( i=offset; i<end; i++ )); do
                local line="${lines[$i]}"
                if [[ "$line" == *"[FAIL]"* ]]; then
                    echo -e "  ${RED}${line}${NC}"
                elif [[ "$line" == *"[SUCCESS]"* ]]; then
                    echo -e "  ${GREEN}${line}${NC}"
                else
                    echo -e "  ${DIM}${line}${NC}"
                fi
            done
        fi

        separator
        echo -e "  ${DIM}↑↓ Scroll  PgUp/PgDn Page  Home/End Jump  e Errors  s Success  a All  c Clear  q Back${NC}"

        read -rsn1 key
        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 -t 0.1 key
            case "$key" in
                '[A') offset=$((offset - 1)) ;;
                '[B') offset=$((offset + 1)) ;;
                '[5') read -rsn1 -t 0.1 _; offset=$((offset - page_size)) ;;
                '[6') read -rsn1 -t 0.1 _; offset=$((offset + page_size)) ;;
                '[H') offset=0 ;;
                '[F') (( total > 0 )) && offset=$((total - page_size)); (( offset < 0 )) && offset=0 ;;
            esac
        elif [[ "$key" == 'e' || "$key" == 'E' ]]; then
            filter="errors"; offset=0
        elif [[ "$key" == 's' || "$key" == 'S' ]]; then
            filter="success"; offset=0
        elif [[ "$key" == 'a' || "$key" == 'A' ]]; then
            filter="all"; offset=0
        elif [[ "$key" == 'c' || "$key" == 'C' ]]; then
            echo ""
            read -rp "  Clear all logs? Type 'YES': " confirm_clear
            if [[ "$confirm_clear" == "YES" ]]; then
                > "$LOG_FILE"
                log_event "INFO" "system" "Logs cleared by user"
                offset=0
            fi
        elif [[ "$key" == 'q' || "$key" == 'Q' || "$key" == '' ]]; then
            return
        fi
    done
}

# ── Factory Reset ────────────────────────────────────────────────────────────
factory_reset() {
    print_header
    echo -e "  ${RED}${BOLD}⚠  Factory Reset${NC}"
    separator
    echo -e "  This will:"
    echo -e "    • Delete all configuration (.env)"
    echo -e "    • Delete all logs"
    echo -e "    • Remove cron job for visionBackup"
    echo -e "    ${DIM}(Existing backup files will NOT be deleted)${NC}"
    separator

    read -rp "  Type 'RESET' to confirm: " confirm
    if [[ "$confirm" != "RESET" ]]; then
        print_info "Reset cancelled."
        press_enter; return
    fi

    crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab - 2>/dev/null || true
    rm -f "$ENV_FILE"
    rm -rf "$LOG_DIR"

    SOURCE_DBS=""
    TARGET_PATH=""
    init_env

    print_msg "Factory reset complete."
    press_enter
}

# ── Main Menu ────────────────────────────────────────────────────────────────
main_menu() {
    check_requirements
    init_env
    load_env

    while true; do
        print_header

        local src_count
        src_count=$(get_source_count)
        local target_display="${TARGET_PATH:-${YELLOW}Not set${NC}}"

        echo -e "  Sources: ${CYAN}${src_count}${NC}   Target: ${MAGENTA}${target_display}${NC}"
        separator
        echo -e "  ${BOLD}Source Management${NC}"
        echo -e "    ${CYAN}1)${NC} Add source"
        echo -e "    ${CYAN}2)${NC} Remove source"
        echo -e "    ${CYAN}3)${NC} List sources"
        separator
        echo -e "  ${BOLD}Configuration${NC}"
        echo -e "    ${CYAN}4)${NC} Set target path"
        echo -e "    ${CYAN}5)${NC} Schedule cron job"
        separator
        echo -e "  ${BOLD}Diagnostics${NC}"
        echo -e "    ${CYAN}6)${NC} View event log"
        echo -e "    ${CYAN}7)${NC} Run backup now"
        separator
        echo -e "    ${RED}8)${NC} Factory reset"
        echo -e "    ${DIM}0)${NC} Exit"
        echo ""
        read -rp "  ▸ " choice

        case "$choice" in
            1) add_source ;;
            2) remove_source ;;
            3) list_sources ;;
            4) select_target ;;
            5) setup_cron ;;
            6) view_log ;;
            7)
                if [[ ! -x "$BACKUP_SCRIPT" ]]; then
                    print_err "visionBackup.sh not found or not executable."
                    press_enter
                else
                    bash "$BACKUP_SCRIPT"
                    press_enter
                fi
                ;;
            8) factory_reset ;;
            0) echo -e "\n  ${DIM}Goodbye.${NC}\n"; exit 0 ;;
            *) print_err "Invalid option."; sleep 0.5 ;;
        esac

        load_env
    done
}

main_menu
