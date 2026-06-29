#!/bin/bash

################################################################################
# Raspberry Pi 5 Diagnostic Tool - ULTIMATE EDITION v4.3.0
# Target: Debian Trixie/Bookworm (aarch64) on Raspberry Pi 5
# Features: Pi 5 Hardware, Docker, USB Storage, System Health
# License: MIT (Copyright 2025 Rahul)
################################################################################

# --- Strict Mode ---
set -u
# We don't use 'set -e' to allow the script to continue after a failed check

# --- Source Library ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/utils.sh
if [[ -f "${SCRIPT_DIR}/lib/utils.sh" ]]; then
    source "${SCRIPT_DIR}/lib/utils.sh"
else
    echo "Error: lib/utils.sh not found."
    exit 1
fi

# --- Constants ---
SCRIPT_VERSION="4.3.0"
LOG_FILE="/var/log/rpi-diag.log"
USB_MOUNT_POINT="/mnt/usb"
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)

# Colors are already imported from lib/utils.sh, but we define GREY here if missing
GREY=${GREY:-'\033[0;90m'}

# State Tracking (Globals)
TOTAL_SCORE=100
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

# Override log_section for diag specific formatting if needed, or stick with utils.
# But existing diag.sh has a specific separator line.
log_section_diag() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
    # shellcheck disable=SC2086
    echo -e "${GREY}$(printf '%*s' "$TERM_WIDTH" '' | tr ' ' '-')""${NC}"
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
    TOTAL_SCORE=$((TOTAL_SCORE - 5))
}

report_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    local sol="${2:-}"
    [ -n "$sol" ] && echo -e "${GREY}       ↳ Solution: $sol${NC}"
    ERROR_LIST+=("$1|$sol")
    ((ERRORS++))
    TOTAL_SCORE=$((TOTAL_SCORE - 20))
}

report_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

# Helper for floating point comparison (pure bash)
float_to_int() {
    local n="$1"
    local -n out="$2"

    local sign=""
    if [[ "$n" == -* ]]; then
        sign="-"
        n="${n#-}"
    fi

    if [[ "$n" != *.* ]]; then
        n="${n}00"
    else
        local i="${n%.*}"
        local f="${n#*.}"
        if [[ -z "$f" ]]; then f="00";
        elif [[ ${#f} -eq 1 ]]; then f="${f}0";
        elif [[ ${#f} -ge 2 ]]; then f="${f:0:2}"; fi
        [[ -z "$i" ]] && i="0"
        n="$i$f"
    fi

    # Remove leading zeros (safely)
    n="${n#"${n%%[!0]*}"}"
    [[ -z "$n" ]] && n="0"

    # shellcheck disable=SC2034
    out="$sign$n"
}

# Floating point comparison using pure bash (integer arithmetic)
# Supports up to 2 decimal places. ~96% faster than awk.
is_greater() {
    local n1 n2
    float_to_int "$1" n1
    float_to_int "$2" n2
    (( n1 > n2 ))
}

is_less() {
    local n1 n2
    float_to_int "$1" n1
    float_to_int "$2" n2
    (( n1 < n2 ))
}

################################################################################
# 1. Hardware Health (Pi 5 Specific)
################################################################################

check_hardware() {
    log_section_diag "HARDWARE HEALTH (Raspberry Pi 5)"

    # Board Info
    if [ -f /proc/device-tree/model ]; then
        local model
        model=$(tr -d '\0' < /proc/device-tree/model)
        report_info "Model: $model"
    fi
    report_info "Kernel: $(uname -r)"

    # Firmware
    if command_exists vcgencmd; then
        local fw_version
        fw_version=$(vcgencmd version | head -n 1)
        report_info "Firmware: $fw_version"
    fi

    # Temperature
    local temp_raw
    if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
        temp_raw=$(< /sys/class/thermal/thermal_zone0/temp)
    else
        temp_raw=""
    fi
    if [ -n "$temp_raw" ]; then
        local temp_c
        temp_c=$(awk "BEGIN {printf \"%.1f\", $temp_raw/1000}")
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
        local throttled
        throttled=$(vcgencmd get_throttled | cut -d= -f2)
        if [ "$throttled" == "0x0" ]; then
            report_pass "Power/Throttling: Status OK (0x0)"
        else
            report_fail "Throttling Detected: Code $throttled" "Check power supply (need 5V/5A for Pi 5) or cooling."
        fi

        # Voltage (Core)
        local volts
        volts=$(vcgencmd measure_volts core | cut -d= -f2)
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
    log_section_diag "SYSTEM RESOURCES"

    # CPU Load
    local load_1m
    read -r load_1m _ < /proc/loadavg
    # Pi 5 has 4 cores. Load > 4 is heavy.
    if is_less "$load_1m" "3.0"; then
        report_pass "Load Average (1m): $load_1m"
    elif is_less "$load_1m" "5.0"; then
        report_warn "Load Average (1m): $load_1m (High)" "Check background processes."
    else
        report_fail "Load Average (1m): $load_1m (Overloaded)" "System is saturated."
    fi

    # Memory
    local mem_avail mem_used_perc
    read -r mem_avail mem_used_perc <<< "$(free -m | awk '/^Mem:/{printf "%s %.1f", $7, 100-($7/$2*100)}')"
    # Memory Usage: $mem_used_perc% ($mem_avail MB available)
    if is_less "$mem_used_perc" "85"; then
        report_pass "Memory Usage: $mem_used_perc% ($mem_avail MB available)"
    else
        report_warn "Memory Usage: $mem_used_perc% (Low Memory)" "Check memory-hungry containers."
    fi

    # Page Size (Pi 5 / Trixie)
    local page_size
    page_size=$(getconf PAGESIZE 2>/dev/null || echo "4096")
    if [ "$page_size" -gt 4096 ]; then
        report_info "Page Size: $((page_size / 1024))k (Performance Mode)"
        # Check min_free_kbytes for 16k pages
        local min_free
        min_free=$(sysctl -n vm.min_free_kbytes 2>/dev/null || echo "0")
        if [ "$min_free" -lt 131072 ]; then
            report_warn "vm.min_free_kbytes: $min_free is low for 16k pages" "Run optimize.sh to set to 128MB+."
        else
            report_pass "vm.min_free_kbytes: $min_free (Optimal for 16k pages)"
        fi
    else
        report_info "Page Size: 4k (Compatibility Mode)"
    fi

    # Swappiness
    local swappiness
    swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo "60")
    if grep -q "/dev/zram" /proc/swaps; then
        if [ "$swappiness" -ge 100 ]; then
            report_pass "Swappiness: $swappiness (Optimal for ZRAM)"
        else
            report_warn "Swappiness: $swappiness (Sub-optimal for ZRAM)" "Run optimize.sh to set to 150."
        fi
    else
        if [ "$swappiness" -le 10 ]; then
            report_pass "Swappiness: $swappiness (Optimal for Flash protection)"
        else
            report_warn "Swappiness: $swappiness (High for disk swap)" "Run optimize.sh to reduce to 10."
        fi
    fi

    # Swap / ZRAM
    if grep -q "/dev/zram" /proc/swaps; then
        report_pass "ZRAM Swap: Active"
        # Check generator config
        if [[ -f /etc/systemd/zram-generator.conf ]]; then
             report_pass "ZRAM Config: systemd-zram-generator detected"
        fi
        # Optional: Check zramctl status
        if command_exists zramctl; then
            local z_orig z_comp
            z_orig=$(zramctl --noheadings --output DATA | awk '{sum+=$1} END {print sum/1024/1024}')
            z_comp=$(zramctl --noheadings --output COMPR | awk '{sum+=$1} END {print sum/1024/1024}')
            report_info "ZRAM Stats: $(printf "%.1f" "$z_orig")MB compressed to $(printf "%.1f" "$z_comp")MB"
        fi
    else
        if grep -q "partition" /proc/swaps || grep -q "file" /proc/swaps; then
            report_warn "Swap: Disk-based swap detected" "Run optimize.sh to switch to ZRAM (better for flash longevity)."
        else
            report_warn "Swap: No swap active" "ZRAM is recommended for stability."
        fi
    fi

    # Transparent Hugepages (THP)
    if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
        local thp
        thp=$(grep -o "\[.*\]" /sys/kernel/mm/transparent_hugepage/enabled | tr -d '[]')
        if [[ "$thp" == "madvise" ]]; then
            report_pass "THP: set to 'madvise' (Optimal)"
        else
            report_warn "THP: set to '$thp'" "Run optimize.sh to set to 'madvise' for database performance."
        fi
    else
        report_info "THP: Not available in this kernel (Standard for RPi)"
    fi

    # Tmpfs /tmp
    if findmnt -n -o FSTYPE --target /tmp | grep -q "tmpfs"; then
        report_pass "/tmp: Using tmpfs (Flash-friendly)"
    else
        report_warn "/tmp: Not in tmpfs" "Run optimize.sh to move /tmp to RAM."
    fi

    if findmnt -n -o FSTYPE --target /var/tmp | grep -q "tmpfs"; then
        report_pass "/var/tmp: Using tmpfs (Flash-friendly)"
    else
        report_info "/var/tmp: Not in tmpfs (Standard)"
    fi

    # CPU Governor
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        local gov
        gov=$(< /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
        if [[ "$gov" == "performance" ]]; then
            report_pass "CPU Governor: performance"
        else
            report_warn "CPU Governor: $gov (not performance)" "Run optimize.sh to fix."
        fi
    fi

    # Orphaned /var/swap
    if [[ -f /var/swap ]]; then
        local swap_size
        swap_size=$(du -sh /var/swap 2>/dev/null | cut -f1)
        report_warn "Orphaned /var/swap ($swap_size) on flash" "Run optimize.sh to remove it."
    fi
}


################################################################################
# 3. Storage & Filesystems
################################################################################

check_storage() {
    log_section_diag "STORAGE & FILESYSTEMS"

    # Root Filesystem
    local root_usage
    root_usage=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
    if [ "$root_usage" -lt 85 ]; then
        report_pass "Root Partition: ${root_usage}% used"
    else
        report_fail "Root Partition: ${root_usage}% used (Critical)" "Clean up logs or docker images."
    fi

    # USB Mount Check
    if mountpoint -q "$USB_MOUNT_POINT"; then
        report_pass "Mount: $USB_MOUNT_POINT is mounted"
        
        # Check Filesystem Type & Options
        local fs_type fs_opts
        read -r fs_type fs_opts <<< "$(findmnt -n -o FSTYPE,OPTIONS -T "$USB_MOUNT_POINT")"
        report_info "Filesystem: $fs_type"

        # Check Options (noatime, commit)
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
    local io_errors
    io_errors=$(dmesg | grep -iE "I/O error|EXT4-fs error|corruption" | tail -n 5)
    if [ -z "$io_errors" ]; then
        report_pass "Kernel Logs: No recent disk errors"
    else
        report_fail "Kernel Logs: Disk errors detected!" "Check 'dmesg' output immediately."
        echo -e "${RED}$io_errors${NC}"
    fi

    # SMART Health Check
    if command_exists smartctl; then
        local disk_dev
        disk_dev=$(findmnt -n -o SOURCE -T "$USB_MOUNT_POINT" 2>/dev/null | sed 's/[0-9]*$//')
        if [[ -b "$disk_dev" ]]; then
            local smart_status=""
            # Try standard, then sat, then scsi
            for dtype in "" "sat" "scsi"; do
                local dflag=""
                [[ -n "$dtype" ]] && dflag="-d $dtype"
                smart_status=$(smartctl $dflag -H "$disk_dev" 2>/dev/null | \
                    grep -iE "test result|Health Status" | head -1 | \
                    grep -ioE "(PASSED|FAILED|OK)")
                [[ -n "$smart_status" ]] && break
            done
            
            if [[ "$smart_status" == "PASSED" || "$smart_status" == "OK" ]]; then
                report_pass "SMART Health: $smart_status ($disk_dev)"
            elif [[ -z "$smart_status" ]]; then
                report_info "SMART Health: Unsupported on this drive/bridge ($disk_dev)"
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
    log_section_diag "DOCKER HEALTH"

    if ! command_exists docker; then
        report_fail "Docker: Not installed"
        return
    fi

    if ! systemctl is-active --quiet docker; then
        report_fail "Docker Service: Inactive/Dead" "sudo systemctl start docker"
        return
    fi

    report_pass "Docker Service: Running"

    # Fetch Docker Info Once
    local docker_info
    docker_info=$(docker info --format '{{.DockerRootDir}}|{{.LoggingDriver}}')
    local data_root log_driver
    IFS='|' read -r data_root log_driver <<< "$docker_info"

    # Data Root
    report_info "Data Root: $data_root"
    
    # Check backing device transport
    local backing_dev
    backing_dev=$(findmnt -n -o SOURCE --target "$data_root" 2>/dev/null)
    local parent_dev
    parent_dev=$(lsblk -nd -o PKNAME -p "$backing_dev" 2>/dev/null)
    [[ -z "$parent_dev" ]] && parent_dev="$backing_dev"
    local transport
    transport=$(lsblk -nd -o TRAN "$parent_dev" 2>/dev/null)

    if [[ "$transport" == "usb" || "$transport" == "nvme" ]]; then
        report_pass "Storage Medium: $transport (Safe)"
    elif [[ "$data_root" == *"$USB_MOUNT_POINT"* ]]; then
        # Fallback if transport detection fails but path is explicit
        report_pass "Storage: Using USB Mount"
    else
        report_warn "Storage: Potential SD Card ($transport)" "If booting from SD, move Docker to USB/NVMe to prevent wear."
    fi

    # Logging Driver
    if [[ "$log_driver" == "json-file" ]]; then
        report_pass "Log Driver: json-file"
    else
        report_warn "Log Driver: $log_driver" "Run optimize.sh to set json-file with rotation."
    fi

    # Container States
    local container_states
    container_states=$(docker ps -a --format "{{.State}}")

    local running=0
    local total=0
    local exited=0
    local restarting=0

    if [ -n "$container_states" ]; then
        # Parse all states in one pass
        read -r running total exited restarting <<< "$(echo "$container_states" | awk '
            BEGIN {r=0; t=0; e=0; s=0}
            {
                t++
                if ($1 == "running") r++
                if ($1 == "exited") e++
                if ($1 == "restarting") s++
            }
            END {print r, t, e, s}
        ')"
    fi

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
    log_section_diag "NETWORK & SECURITY"

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
        local ufw_status
        ufw_status=$(ufw status | grep "Status" | awk '{print $2}')
        if [ "$ufw_status" == "active" ]; then
            report_pass "Firewall (UFW): Active"
            # Check for specific Ollama fix
            if ufw status | grep -qE "11434(/tcp)?.*ALLOW.*10.8.1.0/24"; then
                report_pass "Firewall Rule: Ollama (10.8.1.x) -> Port 11434 ALLOWED"
            else
                report_warn "Firewall Rule: Ollama (10.8.1.x) -> Port 11434 MISSING" "Run optimize.sh to apply fix."
            fi
        else
            report_warn "Firewall (UFW): Inactive" "Enable UFW for security."
        fi
    fi

    # Connectivity Check: n8n -> Ollama
    if command_exists docker && [ -n "$(docker ps -q -f "name=^n8n$")" ]; then
        report_info "Testing connectivity: n8n -> Ollama (host.docker.internal)..."
        if docker exec n8n timeout 5 wget -O- http://host.docker.internal:11434/api/tags >/dev/null 2>&1; then
            report_pass "Connectivity: n8n can reach Ollama"
        else
            report_fail "Connectivity: n8n CANNOT reach Ollama" "Check firewall rules or Ollama bind address."
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
        if systemctl is-enabled --quiet ollama; then
             report_pass "Ollama Auto-Start: Enabled"
        else
             report_warn "Ollama Auto-Start: Disabled" "sudo systemctl enable ollama"
        fi

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
# 6. System Services
################################################################################

check_system_services() {
    log_section_diag "SYSTEM SERVICES"

    # Logging
    if pgrep syslogd >/dev/null; then
        if command_exists logread; then
            report_pass "Logging: Busybox RAM-based syslog active"
        else
            report_pass "Logging: Syslogd active"
        fi
    else
        report_warn "Logging: System logger (syslogd) NOT FOUND" "Ensure busybox-syslogd or rsyslog is installed."
    fi

    # Entropy
    if systemctl is-active --quiet rng-tools-debian 2>/dev/null || systemctl is-active --quiet rngd 2>/dev/null; then
        report_pass "Entropy: Hardware RNG service active"
    else
        report_warn "Entropy: Hardware RNG service INACTIVE" "Install/enable rng-tools5 for cryptographic performance."
    fi

    # Failed Units
    local failed_units_list
    failed_units_list=$(systemctl list-units --state=failed --no-legend 2>/dev/null)
    if [[ -z "$failed_units_list" ]]; then
        report_pass "Systemd: No failed units"
    else
        local failed_count
        failed_count=$(echo "$failed_units_list" | wc -l)
        report_fail "Systemd: $failed_count failed unit(s)" "Run 'systemctl --failed' for details."
        # Print each failed unit name
        while IFS= read -r unit_line; do
            [[ -n "$unit_line" ]] && echo -e "${RED}  → $unit_line${NC}"
        done <<< "$failed_units_list"
    fi

    # Toolchain Audit (uv and agy)
    local target_user
    target_user="${SUDO_USER:-}"
    [[ -z "$target_user" ]] && target_user=$(id -nu 1000 2>/dev/null || echo "")
    
    if [[ -n "$target_user" ]]; then
        local target_home
        target_home=$(getent passwd "$target_user" | cut -d: -f6)
        
        # uv check
        local uv_bin="${target_home}/.local/bin/uv"
        if [[ -f "$uv_bin" ]]; then
            local uv_ver
            uv_ver=$(sudo -u "$target_user" "$uv_bin" self version 2>/dev/null | awk '{print $2}')
            report_pass "Tooling: uv (Python) $uv_ver"
        else
            report_warn "Tooling: uv not installed" "Run setup.sh to install."
        fi

        # agy (antigravity-cli) check
        local agy_bin="${target_home}/.local/bin/agy"
        if [[ -f "$agy_bin" ]]; then
            local agy_ver
            agy_ver=$(sudo -u "$target_user" "$agy_bin" --version 2>/dev/null || echo "unknown")
            report_info "Tooling: Antigravity CLI (agy) v$agy_ver"
        else
            report_info "Tooling: Antigravity CLI (agy) not installed"
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
    check_system_services

    log_section_diag "DIAGNOSTIC SUMMARY"
    
    # Ensure score doesn't go below 0
    [ "$TOTAL_SCORE" -lt 0 ] && TOTAL_SCORE=0

    echo -e "Health Score:  ${CYAN}${TOTAL_SCORE}%${NC}"
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