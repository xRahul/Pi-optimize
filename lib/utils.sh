#!/bin/bash

# --- Colors ---
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export MAGENTA='\033[0;35m'
export NC='\033[0m'

# --- Logging Functions ---
# Usage: log_info "Message"
# Dependencies: LOG_FILE (optional)

_log() {
    # level is unused but kept for interface consistency/future use
    # shellcheck disable=SC2034
    local level="$1"
    local color="$2"
    local icon="$3"
    local message="$4"
    local log_entry="${color}${icon}${NC} ${message}"

    if [[ -n "${LOG_FILE:-}" ]]; then
        echo -e "$log_entry" | tee -a "$LOG_FILE"
    else
        echo -e "$log_entry"
    fi
}

log_info() {
    _log "INFO" "${BLUE}" "[INFO]" "$1"
}

log_pass() {
    _log "PASS" "${GREEN}" "[✓]" "$1"
    # Increment counters if they exist
    # shellcheck disable=SC2015
    [[ -v CHECKS_PASSED ]] && ((CHECKS_PASSED++)) || true
    # shellcheck disable=SC2015
    [[ -v OPTIMIZATIONS_APPLIED ]] && ((OPTIMIZATIONS_APPLIED++)) || true
}

log_fail() {
    _log "FAIL" "${RED}" "[✗]" "$1"
    # shellcheck disable=SC2015
    [[ -v CHECKS_FAILED ]] && ((CHECKS_FAILED++)) || true
    # shellcheck disable=SC2015
    [[ -v ERRORS ]] && ((ERRORS++)) || true
}

log_warn() {
    _log "WARN" "${YELLOW}" "[!]" "$1"
    # shellcheck disable=SC2015
    [[ -v WARNINGS ]] && ((WARNINGS++)) || true
}

log_skip() {
    _log "SKIP" "${YELLOW}" "[⊘]" "$1"
    # shellcheck disable=SC2015
    [[ -v OPTIMIZATIONS_SKIPPED ]] && ((OPTIMIZATIONS_SKIPPED++)) || true
}

log_section() {
    local message="\n${CYAN}=== $1 ===${NC}"
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo -e "$message" | tee -a "$LOG_FILE"
    else
        echo -e "$message"
    fi
}

log_error() {
    log_fail "$1"
    exit 1
}

log_success() {
    local message="\n${GREEN}$1${NC}"
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo -e "$message" | tee -a "$LOG_FILE"
    else
        echo -e "$message"
    fi
}

# --- Common Utilities ---

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (sudo)"
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

confirm_action() {
    local prompt="$1"
    local response

    # Non-interactive check
    if [[ ! -t 0 ]]; then
        return 1
    fi

    while true; do
        read -r -p "$(echo -e "${CYAN}${prompt}${NC} [y/N]: ")" response
        case "$response" in
            [yY]*) return 0 ;;
            [nN]*|"") return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

# Compares two files. Returns 0 if they differ (need update), 1 if they are same.
files_differ() {
    local file1="$1"
    local file2="$2"
    if [[ ! -f "$file1" ]]; then return 0; fi # If target doesn't exist, they differ
    if cmp -s "$file1" "$file2"; then
        return 1 # They are the same
    else
        return 0 # They differ
    fi
}

backup_file() {
    local file="$1"
    local backup_dir="${BACKUP_DIR:-/var/backups/rpi-optimize}"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)

    if [[ -f "$file" ]]; then
        mkdir -p "$backup_dir"
        local bkp
        bkp="${backup_dir}/$(basename "$file").${timestamp}"
        cp "$file" "$bkp"
        log_info "Backup created: $bkp"
    fi
}
