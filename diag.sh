#!/bin/bash

################################################################################
# Raspberry Pi 5 Diagnostic Tool - ULTIMATE EDITION v4.2.0
# Target: Debian Trixie/Bookworm (aarch64) on Raspberry Pi 5
# Features: Pi 5 Hardware, Docker, USB Storage, System Health
# License: MIT (Copyright 2025 Rahul)
################################################################################

# --- Strict Mode ---
set -u
# We don't use 'set -e' to allow the script to continue after a failed check

# --- Constants ---
SCRIPT_VERSION="4.2.0"
LOG_FILE="/var/log/rpi-diag.log"
USB_MOUNT_POINT="/mnt/usb"
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
GREY='\033[0;90m'
NC='\033[0m'

# State Tracking
ERRORS=0
WARNINGS=0
CHECKS_PASSED=0
WARN_LIST=()
ERROR_LIST=()

################################################################################
# Utility Functions
################################################################################

print_header() {
    clear
    echo -e "${MAGENTA}"
    echo "██████╗ ██╗ █████╗  ██████╗ "
    echo "██╔══██╗██║██╔══██╗██╔════╝ "
    echo "██║  ██║██║███████║██║  ███╗"
    echo "██║  ██║██║██╔══██║██║   ██║"
    echo "██████╔╝██║██║  ██║╚██████╔╝"
    echo "╚═════╝ ╚═╝╚═╝  ╚═╝ ╚═════╝ "
    echo -e "${NC}"
    echo -e "${CYAN}Raspberry Pi Diagnostic Tool v${SCRIPT_VERSION}${NC}"
    echo -e "${GREY}Timestamp: $(date)${NC}\n"
}

log_section() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
    echo -e "${GREY}$(printf '%*s' "$TERM_WIDTH" '' | tr ' ' '-')"${NC}
}

report_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((CHECKS_PASSED++))
}

report_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    local sol="${2:-}"
    [ -n "$sol" ] && echo -e "${GREY}       ↳ Solution: $sol${NC}"
    WARN_LIST+=("$1|$sol")
    ((WARNINGS++))
}

report_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    local sol="${2:-}"
    [ -n "$sol" ] && echo -e "${GREY}       ↳ Solution: $sol${NC}"
    ERROR_LIST+=("$1|$sol")
    ((ERRORS++))
}

report_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Floating point comparison using awk
is_greater() { awk -v n1="$1" -v n2="$2" 'BEGIN {if (n1>n2) exit 0; exit 1}'; }
is_less() { awk -v n1="$1" -v n2="$2" 'BEGIN {if (n1<n2) exit 0; exit 1}'; }

################################################################################
# 1. Hardware Health (Pi 5 Specific)
################################################################################

check_hardware() {
    log_section "HARDWARE HEALTH (Raspberry Pi 5)"

    # Board Info
    if [ -f /proc/device-tree/model ]; then
        local model=$(tr -d '\0' < /proc/device-tree/model)
        report_info "Model: $model"
    fi
    report_info "Kernel: $(uname -r)"

    # Firmware
    if command_exists vcgencmd; then
        local fw_version=$(vcgencmd version | head -n 1)
        report_info "Firmware: $fw_version"
    fi

    # Temperature
    local temp_raw=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
    if [ -n "$temp_raw" ]; then
        local temp_c=$(awk "BEGIN {printf \"%.1f\", $temp_raw/1000}")
        if is_less "$temp_c" "60"; then
            report_pass "Temperature: ${temp_c}°C (Optimal)"
        elif is_less "$temp_c" "80"; then
            report_warn "Temperature: ${temp_c}°C (High)" "Check cooling/fan functionality."
        else
            report_fail "Temperature: ${temp_c}°C (CRITICAL)" "Immediate cooling required. Check fan connection."
        fi
    else
        report_warn "Temperature sensor not read."
    fi

    # Throttling & Power
    if command_exists vcgencmd; then
        local throttled=$(vcgencmd get_throttled | cut -d= -f2)
        if [ "$throttled" == "0x0" ]; then
            report_pass "Power/Throttling: Status OK (0x0)"
        else
            report_fail "Throttling Detected: Code $throttled" "Check power supply (need 5V/5A for Pi 5) or cooling."
            # Decode common bits
            # Bit 0: Under-voltage detected
            # Bit 1: Arm frequency capped
            # Bit 2: Currently throttled
            # Bit 3: Soft temperature limit active
            # Bit 16: Under-voltage has occurred
            # Bit 17: Arm frequency capped has occurred
            # Bit 18: Throttling has occurred
            # Bit 19: Soft temperature limit has occurred
        fi

        # Voltage (Core)
        local volts=$(vcgencmd measure_volts core | cut -d= -f2)
        report_info "Core Voltage: $volts"
    fi

    # PMIC (Pi 5 Specific)
    if command_exists vcgencmd; then
        # Just check if pmic_read_adc exists/works by trying one value
        if vcgencmd pmic_read_adc >/dev/null 2>&1; then
             report_info "PMIC: Power Management IC accessible"
        fi
    fi
}

################################################################################
# 2. System Resources
################################################################################

check_resources() {
    log_section "SYSTEM RESOURCES"

    # CPU Load
    local load_1m=$(uptime | awk -F'load average:' '{print $2}' | cut -d, -f1 | xargs)
    # Pi 5 has 4 cores. Load > 4 is heavy.
    if is_less "$load_1m" "3.0"; then
        report_pass "Load Average (1m): $load_1m"
    elif is_less "$load_1m" "5.0"; then
        report_warn "Load Average (1m): $load_1m (High)" "Check background processes."
    else
        report_fail "Load Average (1m): $load_1m (Overloaded)" "System is saturated."
    fi

    # Memory
    local mem_total=$(free -m | awk '/^Mem:/{print $2}')
    local mem_avail=$(free -m | awk '/^Mem:/{print $7}')
    local mem_used_perc=$(awk "BEGIN {printf \"%.1f\", 100-($mem_avail/$mem_total*100)}")
    
    if is_less "$mem_used_perc" "85"; then
        report_pass "Memory Usage: $mem_used_perc% ($mem_avail MB available)"
    else
        report_warn "Memory Usage: $mem_used_perc% (Low Memory)" "Check memory-hungry containers."
    fi

    # Swap / ZRAM
    if grep -q "/dev/zram" /proc/swaps; then
        report_pass "ZRAM Swap: Active"
    else
        if grep -q "partition" /proc/swaps || grep -q "file" /proc/swaps; then
            report_warn "Swap: Disk-based swap detected" "Run optimize.sh to switch to ZRAM (better for flash longevity)."
        else
            report_warn "Swap: No swap active" "ZRAM is recommended for stability."
        fi
    fi
}

################################################################################
# 3. Storage & Filesystems
################################################################################

check_storage() {
    log_section "STORAGE & FILESYSTEMS"

    # Root Filesystem
    local root_usage=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
    if [ "$root_usage" -lt 85 ]; then
        report_pass "Root Partition: ${root_usage}% used"
    else
        report_fail "Root Partition: ${root_usage}% used (Critical)" "Clean up logs or docker images."
    fi

    # USB Mount Check
    if mountpoint -q "$USB_MOUNT_POINT"; then
        report_pass "Mount: $USB_MOUNT_POINT is mounted"
        
        # Check Filesystem Type
        local fs_type=$(findmnt -n -o FSTYPE -T "$USB_MOUNT_POINT")
        report_info "Filesystem: $fs_type"

        # Check Options (noatime, commit)
        local fs_opts=$(findmnt -n -o OPTIONS -T "$USB_MOUNT_POINT")
        if [[ "$fs_opts" == *"noatime"* ]]; then
            report_pass "Mount Option: noatime active"
        else
            report_warn "Mount Option: noatime MISSING" "Run optimize.sh to fix."
        fi
        
        if [[ "$fs_type" == "ext4" ]]; then
             if [[ "$fs_opts" == *"commit="* ]]; then
                 report_pass "Mount Option: commit adjusted"
             else
                 report_info "Mount Option: Default commit interval"
             fi
        elif [[ "$fs_type" == "vfat" || "$fs_type" == "exfat" ]]; then
             report_warn "Filesystem: VFAT/ExFAT detected" "Not recommended for Docker. Consider formatting to EXT4 for reliability."
        fi

        # Write Test (Non-destructive check if writable)
        if touch "$USB_MOUNT_POINT/.diag_test" 2>/dev/null; then
            rm "$USB_MOUNT_POINT/.diag_test"
            report_pass "Write Access: OK"
        else
            report_fail "Write Access: FAILED" "Drive might be read-only or permissions wrong."
        fi

    else
        report_fail "Mount: $USB_MOUNT_POINT NOT MOUNTED" "Check physical connection or fstab."
    fi

    # Kernel Errors (I/O)
    local io_errors=$(dmesg | grep -iE "I/O error|EXT4-fs error|corruption" | tail -n 5)
    if [ -z "$io_errors" ]; then
        report_pass "Kernel Logs: No recent disk errors"
    else
        report_fail "Kernel Logs: Disk errors detected!" "Check 'dmesg' output immediately."
        echo -e "${RED}$io_errors${NC}"
    fi

    # SMART Health Check
    if command_exists smartctl; then
        local disk_dev=$(findmnt -n -o SOURCE -T "$USB_MOUNT_POINT" 2>/dev/null | sed 's/[0-9]*$//')
        if [ -b "$disk_dev" ]; then
            local smart_status=$(smartctl -H "$disk_dev" 2>/dev/null | grep -i "test result" | cut -d: -f2 | xargs)
            if [[ "$smart_status" == "PASSED" ]]; then
                report_pass "SMART Health: PASSED ($disk_dev)"
            elif [[ -z "$smart_status" ]]; then
                 report_info "SMART Health: Unavailable/Unsupported for $disk_dev"
            else
                report_fail "SMART Health: $smart_status ($disk_dev)" "Drive may be failing!"
            fi
        fi
    fi
}

################################################################################
# 4. Docker Health
################################################################################

check_docker() {
    log_section "DOCKER HEALTH"

    if ! command_exists docker; then
        report_fail "Docker: Not installed"
        return
    fi

    if ! systemctl is-active --quiet docker; then
        report_fail "Docker Service: Inactive/Dead" "sudo systemctl start docker"
        return
    fi

    report_pass "Docker Service: Running"

    # Data Root
    local data_root=$(docker info --format '{{.DockerRootDir}}')
    report_info "Data Root: $data_root"
    
    # Check backing device transport
    local backing_dev=$(findmnt -n -o SOURCE --target "$data_root")
    local parent_dev=$(lsblk -nd -o PKNAME -p "$backing_dev" 2>/dev/null)
    [[ -z "$parent_dev" ]] && parent_dev="$backing_dev"
    local transport=$(lsblk -nd -o TRAN "$parent_dev" 2>/dev/null)

    if [[ "$transport" == "usb" || "$transport" == "nvme" ]]; then
        report_pass "Storage Medium: $transport (Safe)"
    elif [[ "$data_root" == *"$USB_MOUNT_POINT"* ]]; then
        # Fallback if transport detection fails but path is explicit
        report_pass "Storage: Using USB Mount"
    else
        report_warn "Storage: Potential SD Card ($transport)" "If booting from SD, move Docker to USB/NVMe to prevent wear."
    fi

    # Logging Driver
    local log_driver=$(docker info --format '{{.LoggingDriver}}')
    if [[ "$log_driver" == "json-file" ]]; then
        report_pass "Log Driver: json-file"
    else
        report_warn "Log Driver: $log_driver" "Run optimize.sh to set json-file with rotation."
    fi

    # Container States
    local running=$(docker ps -q | wc -l)
    local total=$(docker ps -aq | wc -l)
    local exited=$(docker ps -aq -f status=exited | wc -l)
    local restarting=$(docker ps -aq -f status=restarting | wc -l)

    report_info "Containers: $running Running / $total Total"
    
    if [ "$restarting" -gt 0 ]; then
        report_fail "Containers: $restarting in restart loop" "Check 'docker ps' and container logs."
    elif [ "$exited" -gt 0 ]; then
        report_warn "Containers: $exited stopped"
    else
        report_pass "Containers: All healthy"
    fi

    # Docker Compose Auto-Restart Service Check
    if [ -f "/etc/systemd/system/docker-compose-restart.service" ]; then
        if systemctl is-enabled --quiet docker-compose-restart.service 2>/dev/null; then
             report_pass "Compose Auto-Restart: Enabled"
        else
             report_warn "Compose Auto-Restart: Disabled" "Service exists but is not enabled."
        fi
    fi
}

################################################################################
# 5. Network & Security
################################################################################

check_network() {
    log_section "NETWORK & SECURITY"

    # Internet
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        report_pass "Internet: Connected"
    else
        report_fail "Internet: Disconnected" "Check ethernet cable or router."
    fi

    # DNS
    if command_exists nslookup; then
        if nslookup google.com >/dev/null 2>&1; then
            report_pass "DNS: Working"
        else
            report_fail "DNS: Resolution failed" "Check /etc/resolv.conf"
        fi
    fi

    # Firewall
    if command_exists ufw; then
        local ufw_status=$(ufw status | grep "Status" | awk '{print $2}')
        if [ "$ufw_status" == "active" ]; then
            report_pass "Firewall (UFW): Active"
        else
            report_warn "Firewall (UFW): Inactive" "Enable UFW for security."
        fi
    fi

    # SSH
    if systemctl is-active --quiet ssh; then
        report_pass "SSH Service: Active"
    else
        report_warn "SSH Service: Inactive"
    fi
    
    # Fail2Ban
    if command_exists fail2ban-client; then
        if systemctl is-active --quiet fail2ban; then
            report_pass "Fail2Ban: Running"
        else
            report_warn "Fail2Ban: Inactive" "Recommended for SSH security."
        fi
    fi

    # Ollama (if installed)
    if command_exists ollama; then
        if systemctl is-active --quiet ollama; then
            report_pass "Ollama Service: Active"
            if command_exists curl; then
                 # Ollama root endpoint returns "Ollama is running"
                 if curl -s --max-time 2 http://127.0.0.1:11434 >/dev/null; then
                     report_pass "Ollama API: Responding (Port 11434)"
                 else
                     report_warn "Ollama API: Not responding" "Check logs: journalctl -u ollama"
                 fi
            fi
        else
            report_warn "Ollama Service: Inactive" "System has Ollama installed but service is down."
        fi
    fi
}

################################################################################
# Main
################################################################################

main() {
    print_header
    
    check_hardware
    check_resources
    check_storage
    check_docker
    check_network

    log_section "DIAGNOSTIC SUMMARY"
    echo -e "Checks Passed: ${GREEN}$CHECKS_PASSED${NC}"
    echo -e "Warnings:      ${YELLOW}$WARNINGS${NC}"
    echo -e "Errors:        ${RED}$ERRORS${NC}"

    if [ $ERRORS -gt 0 ]; then
        echo -e "\n${RED}=== CRITICAL ISSUES ===${NC}"
        for item in "${ERROR_LIST[@]}"; do
             msg="${item%%|*}"
             sol="${item##*|}"
             echo -e "${RED}[✗] $msg${NC}"
             [ -n "$sol" ] && echo -e "    ↳ Solution: $sol"
        done
    fi

    if [ $WARNINGS -gt 0 ]; then
        echo -e "\n${YELLOW}=== WARNINGS ===${NC}"
        for item in "${WARN_LIST[@]}"; do
             msg="${item%%|*}"
             sol="${item##*|}"
             echo -e "${YELLOW}[!] $msg${NC}"
             [ -n "$sol" ] && echo -e "    ↳ Solution: $sol"
        done
    fi

    if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
        echo -e "\n${GREEN}SYSTEM IS HEALTHY!${NC}"
    elif [ $ERRORS -gt 0 ]; then
        echo -e "\n${RED}SYSTEM REQUIRES ATTENTION.${NC} Review failures above."
    else
        echo -e "\n${YELLOW}SYSTEM FUNCTIONAL BUT OPTIMIZABLE.${NC}"
    fi
    
    echo -e "Log saved to: $LOG_FILE"
}

# Redirect output to log file while showing on screen
main 2>&1 | tee "$LOG_FILE"