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
SCRIPT_VERSION="4.6.0"
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

    # PCIe Link Speed Check (Pi 5 NVMe)
    if command_exists lspci; then
        local nvme_addr
        nvme_addr=$(lspci | grep -i "Non-Volatile memory" | awk '{print $1}' | head -n1 || echo "")
        if [[ -n "$nvme_addr" ]]; then
            local lnksta
            lnksta=$(lspci -s "$nvme_addr" -vv 2>/dev/null | grep "LnkSta:" | head -n1 || echo "")
            if [[ -n "$lnksta" ]]; then
                if [[ "$lnksta" == *"Speed 8GT/s"* ]]; then
                    report_pass "PCIe Link Speed: Gen 3 (8GT/s) active"
                elif [[ "$lnksta" == *"Speed 5GT/s"* ]]; then
                    report_pass "PCIe Link Speed: Gen 2 (5GT/s) active (optimal for endurance)"
                else
                    report_info "PCIe Link Speed: $lnksta"
                fi
                
                # Check link width
                if [[ "$lnksta" == *"Width x1"* ]]; then
                    report_pass "PCIe Link Width: x1 active (optimal for Pi 5)"
                else
                    report_info "PCIe Link Width: $lnksta"
                fi
            fi
        fi
    fi

    # Boot Config verification (/boot/firmware/config.txt)
    local config_file="/boot/firmware/config.txt"
    if [[ -f "$config_file" ]]; then
        local config_content
        config_content=$(cat "$config_file" 2>/dev/null || echo "")
        
        # Check PCIe configs
        if echo "$config_content" | grep -q "^dtparam=pciex1$" || echo "$config_content" | grep -q "^dtparam=nvme$"; then
            report_pass "Boot Config: PCIe interface enabled"
        else
            report_warn "Boot Config: PCIe interface (dtparam=pciex1) not enabled in config.txt" "Run optimize.sh to enable PCIe."
        fi
        
        if echo "$config_content" | grep -q "^dtparam=pciex1_gen=2"; then
            report_pass "Boot Config: PCIe speed set to Gen 2"
        elif echo "$config_content" | grep -q "^dtparam=pciex1_gen=3"; then
            report_warn "Boot Config: PCIe speed set to Gen 3" "Consider Gen 2 for lower power/heat and maximum endurance."
        else
            report_info "Boot Config: PCIe speed defaults to Gen 2"
        fi
        
        # Check Overclock
        if echo "$config_content" | grep -qE "^(arm_freq|gpu_freq|over_voltage_delta)"; then
            local active_overclocks
            active_overclocks=$(echo "$config_content" | grep -E "^(arm_freq|gpu_freq|over_voltage_delta)" | xargs || echo "")
            report_warn "Boot Config: Overclock active ($active_overclocks)" "For maximum endurance, run stock clocks."
        else
            report_pass "Boot Config: No overclock active (stock clocks)"
        fi
        
        # Check GPU Memory
        if echo "$config_content" | grep -q "^gpu_mem="; then
            local gmem
            gmem=$(echo "$config_content" | grep "^gpu_mem=" | cut -d= -f2 || echo "")
            if [[ "$gmem" -le 16 ]]; then
                report_pass "Boot Config: GPU Memory split optimized ($gmem MB)"
            else
                report_warn "Boot Config: GPU Memory split is $gmem MB" "Run optimize.sh to reduce to 16MB for headless server."
            fi
        fi
    fi

    # Kernel Cmdline verification (/boot/firmware/cmdline.txt)
    local cmdline_file="/boot/firmware/cmdline.txt"
    if [[ -f "$cmdline_file" ]]; then
        local cmdline_content
        cmdline_content=$(cat "$cmdline_file" 2>/dev/null || echo "")
        
        local has_aspm=0
        local has_apst=0
        if echo "$cmdline_content" | grep -q "pcie_aspm=off"; then
            has_aspm=1
        fi
        if echo "$cmdline_content" | grep -q "nvme_core.default_ps_max_latency_us=0"; then
            has_apst=1
        fi

        if [[ $has_aspm -eq 1 && $has_apst -eq 1 ]]; then
            report_pass "Kernel Cmdline: PCIe ASPM & APST sleep workarounds active"
        else
            if [[ $has_aspm -eq 0 ]]; then
                report_warn "Kernel Cmdline: pcie_aspm=off is missing" "Run optimize.sh to prevent NVMe PCIe disconnects."
            fi
            if [[ $has_apst -eq 0 ]]; then
                report_warn "Kernel Cmdline: nvme_core.default_ps_max_latency_us=0 is missing" "Run optimize.sh to prevent NVMe APST dropouts."
            fi
        fi
    fi

    # EEPROM Config verification
    if command_exists rpi-eeprom-config; then
        local eeprom_conf
        eeprom_conf=$(rpi-eeprom-config 2>/dev/null || echo "")
        if [[ -n "$eeprom_conf" ]]; then
            local boot_order
            boot_order=$(echo "$eeprom_conf" | grep "^BOOT_ORDER=" | cut -d= -f2 || echo "")
            if [[ "$boot_order" == "0xf416" ]]; then
                report_pass "EEPROM Config: Boot order is optimal ($boot_order)"
            else
                report_warn "EEPROM Config: Boot order ($boot_order) is not optimal" "Run optimize.sh to set BOOT_ORDER=0xf416 (NVMe priority with clean USB fallback)."
            fi
            
            if echo "$eeprom_conf" | grep -q "^PCIE_PROBE=1"; then
                report_pass "EEPROM Config: PCIE_PROBE=1 is configured"
            else
                report_warn "EEPROM Config: PCIE_PROBE=1 is missing" "Run optimize.sh to force PCIe probing."
            fi

            if echo "$eeprom_conf" | grep -q "^POWER_OFF_ON_HALT=1"; then
                report_pass "EEPROM Config: POWER_OFF_ON_HALT=1 is configured"
            else
                report_warn "EEPROM Config: POWER_OFF_ON_HALT=1 is missing" "Run optimize.sh to minimize idle power consumption."
            fi

            if echo "$eeprom_conf" | grep -q "^BOOT_UART=1"; then
                report_pass "EEPROM Config: BOOT_UART=1 is configured"
            else
                report_warn "EEPROM Config: BOOT_UART=1 is missing" "Run optimize.sh to reduce halt power draw."
            fi
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
    # Check both runtime state and rpi-swap config intent
    local zram_configured=0
    if grep -q "/dev/zram" /proc/swaps; then
        zram_configured=1
    elif [[ -f /etc/rpi/swap.conf ]] && grep -q "^Mechanism=zram" /etc/rpi/swap.conf; then
        zram_configured=1
    fi
    if [[ $zram_configured -eq 1 ]]; then
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

    # Flash writeback dirty page configurations
    local dirty_writeback dirty_expire
    dirty_writeback=$(sysctl -n vm.dirty_writeback_centisecs 2>/dev/null || echo "500")
    dirty_expire=$(sysctl -n vm.dirty_expire_centisecs 2>/dev/null || echo "3000")
    if [ "$dirty_writeback" -ge 1000 ]; then
        report_pass "vm.dirty_writeback_centisecs: $dirty_writeback (Optimal for Flash write delay)"
    else
        report_warn "vm.dirty_writeback_centisecs: $dirty_writeback is default (5s)" "Run optimize.sh to increase dirty writeback delay."
    fi
    if [ "$dirty_expire" -ge 6000 ]; then
        report_pass "vm.dirty_expire_centisecs: $dirty_expire (Optimal for Flash write expiration)"
    else
        report_warn "vm.dirty_expire_centisecs: $dirty_expire is default (30s)" "Run optimize.sh to increase dirty expire delay."
    fi

    # Swap / ZRAM & Swapfile
    local zram_active=0
    local swapfile_active=0
    local boot_is_nvme=0
    
    # Check if boot is NVMe
    local boot_dev
    boot_dev=$(findmnt -n -o SOURCE / 2>/dev/null)
    local boot_disk
    boot_disk=$(lsblk -nd -o PKNAME -p "$boot_dev" 2>/dev/null || echo "$boot_dev")
    [[ -z "$boot_disk" ]] && boot_disk="$boot_dev"
    [[ "$boot_disk" != /dev/* ]] && boot_disk="/dev/$boot_disk"
    local boot_tran
    boot_tran=$(lsblk -nd -o TRAN "$boot_disk" 2>/dev/null)
    [[ "$boot_tran" == "nvme" ]] && boot_is_nvme=1

    if grep -q "/dev/zram" /proc/swaps; then
        zram_active=1
        report_pass "ZRAM Swap: Active"
        if [[ -f /etc/systemd/zram-generator.conf ]]; then
             report_pass "ZRAM Config: systemd-zram-generator detected"
        fi
        if command_exists zramctl; then
            local z_orig z_comp
            z_orig=$(zramctl --noheadings --output DATA | awk '{sum+=$1} END {print sum/1024/1024}')
            z_comp=$(zramctl --noheadings --output COMPR | awk '{sum+=$1} END {print sum/1024/1024}')
            report_info "ZRAM Stats: $(printf "%.1f" "$z_orig")MB compressed to $(printf "%.1f" "$z_comp")MB"
        fi
    fi

    if grep -q "/swapfile" /proc/swaps; then
        swapfile_active=1
        local sf_priority
        sf_priority=$(awk '/\/swapfile/ {print $5}' /proc/swaps)
        if [[ $boot_is_nvme -eq 1 ]]; then
            report_pass "NVMe Swapfile: Active (Priority: $sf_priority)"
        else
            report_warn "Swapfile: Active on non-NVMe storage (Priority: $sf_priority)" "Disable disk swap on flash media to prevent wear."
        fi
    fi

    # Overall swap assessment
    if [[ $zram_active -eq 0 && $swapfile_active -eq 0 ]]; then
        if grep -q "partition" /proc/swaps || grep -q "file" /proc/swaps; then
            report_warn "Swap: Non-standard disk-based swap active" "Run optimize.sh to configure ZRAM."
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

    # Multi-Gen LRU (MGLRU)
    if [[ -f /sys/kernel/mm/lru_gen/enabled ]]; then
        if [[ -f /sys/kernel/mm/lru_gen/min_ttl_ms ]]; then
            local ttl
            ttl=$(cat /sys/kernel/mm/lru_gen/min_ttl_ms 2>/dev/null || echo "0")
            if [[ "$ttl" -eq 1000 ]]; then
                report_pass "MGLRU: thrashing threshold set to 1000ms (Optimal)"
            else
                report_warn "MGLRU: thrashing threshold set to ${ttl}ms" "Run optimize.sh to set to 1000ms for stable database caching."
            fi
        fi
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

    # Orphaned /var/swap and locked loop devices
    local has_orphaned_file=0
    local has_locked_loop=0
    local swap_size=""
    
    if [[ -f /var/swap ]]; then
        has_orphaned_file=1
        swap_size=$(du -sh /var/swap 2>/dev/null | cut -f1)
    fi
    
    if losetup -a 2>/dev/null | grep -q "/var/swap (deleted)"; then
        has_locked_loop=1
    fi
    
    if [[ $has_orphaned_file -eq 1 && $has_locked_loop -eq 1 ]]; then
        report_warn "Orphaned /var/swap ($swap_size) on flash and locked by loop device" "Run optimize.sh to fully remove and detach it."
    elif [[ $has_orphaned_file -eq 1 ]]; then
        report_warn "Orphaned /var/swap ($swap_size) on flash" "Run optimize.sh to remove it."
    elif [[ $has_locked_loop -eq 1 ]]; then
        report_warn "Deleted /var/swap is locked in RAM (loop device active)" "Run optimize.sh to detach it and reclaim disk space."
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

    # Root mount options checks (noatime, commit)
    local root_fs_type root_fs_opts
    read -r root_fs_type root_fs_opts <<< "$(findmnt -n -o FSTYPE,OPTIONS -T /)"
    if [[ "$root_fs_opts" == *"noatime"* ]]; then
        report_pass "Root Mount Option: noatime active"
    else
        report_warn "Root Mount Option: noatime MISSING" "Run optimize.sh to optimize root partition."
    fi
    if [[ "$root_fs_type" == "ext4" ]]; then
        if [[ "$root_fs_opts" == *"commit=60"* && "$root_fs_opts" == *"lazytime"* ]]; then
            report_pass "Root Mount Option: commit=60 and lazytime active ($root_fs_opts)"
        else
            report_warn "Root Mount Option: commit/lazytime not optimal" "Run optimize.sh to set commit=60,lazytime."
        fi
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
        # Identify boot disk and USB disk
        local boot_dev
        boot_dev=$(findmnt -n -o SOURCE / 2>/dev/null)
        local boot_disk
        boot_disk=$(lsblk -nd -o PKNAME "$boot_dev" 2>/dev/null || echo "$boot_dev")
        [[ -z "$boot_disk" ]] && boot_disk="$boot_dev"
        boot_disk=$(basename "$boot_disk")
        [[ "$boot_disk" != /dev/* ]] && boot_disk="/dev/$boot_disk"

        local usb_dev
        usb_dev=$(findmnt -n -o SOURCE -T "$USB_MOUNT_POINT" 2>/dev/null)
        local usb_disk
        usb_disk=$(lsblk -nd -o PKNAME "$usb_dev" 2>/dev/null || echo "$usb_dev")
        [[ -z "$usb_disk" ]] && usb_disk="$usb_dev"
        usb_disk=$(basename "$usb_disk")
        [[ "$usb_disk" != /dev/* ]] && usb_disk="/dev/$usb_disk"

        # Unique list of disks to check
        local disks_to_check=()
        [[ -b "$boot_disk" ]] && disks_to_check+=("$boot_disk")
        if [[ -b "$usb_disk" && "$usb_disk" != "$boot_disk" ]]; then
            disks_to_check+=("$usb_disk")
        fi

        for disk_dev in "${disks_to_check[@]}"; do
            local smart_status=""
            local dtypes=("" "sat" "scsi")
            if [[ "$disk_dev" == *nvme* ]]; then
                dtypes=("nvme" "${dtypes[@]}")
            fi
            for dtype in "${dtypes[@]}"; do
                local dflag=""
                [[ -n "$dtype" ]] && dflag="-d $dtype"
                smart_status=$(smartctl $dflag -H "$disk_dev" 2>/dev/null | \
                    grep -iE "test result|Health Status|overall-health" | head -1 | \
                    grep -ioE "(PASSED|FAILED|OK)")
                [[ -n "$smart_status" ]] && break
            done
            
            local disk_label="Boot Drive"
            if [[ "$disk_dev" == "$usb_disk" ]]; then
                disk_label="USB Storage"
            fi

            if [[ "$smart_status" == "PASSED" || "$smart_status" == "OK" ]]; then
                report_pass "SMART Health: $smart_status ($disk_label: $disk_dev)"
            elif [[ -z "$smart_status" ]]; then
                report_info "SMART Health: Unsupported on $disk_label ($disk_dev)"
            else
                report_fail "SMART Health: $smart_status ($disk_label: $disk_dev)" "Drive may be failing!"
            fi

            # Rich NVMe metrics if nvme-cli is installed and this is an NVMe disk
            if [[ "$disk_dev" == *nvme* ]] && command_exists nvme; then
                local nvme_log
                nvme_log=$(nvme smart-log "$disk_dev" 2>/dev/null || true)
                if [[ -n "$nvme_log" ]]; then
                    local temp wear spare errors
                    temp=$(echo "$nvme_log" | awk -F: '/temperature/ { if (match($0, /[0-9]+[ ]*C/)) { val = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", val); print val } else { match($0, /[0-9]+/); val = substr($0, RSTART, RLENGTH); if (val > 150) print val - 273; else print val } }')
                    wear=$(echo "$nvme_log" | awk -F: '/percentage_used/ {gsub(/[^0-9]/,"",$2); print $2}')
                    spare=$(echo "$nvme_log" | awk -F: '/available_spare/ {if(!/threshold/) {gsub(/[^0-9]/,"",$2); print $2}}')
                    errors=$(echo "$nvme_log" | awk -F: '/media_errors/ {gsub(/[^0-9]/,"",$2); print $2}')
                    
                    local metrics=""
                    [[ -n "$temp" ]] && metrics+="Temp: ${temp}°C, "
                    [[ -n "$wear" ]] && metrics+="Wear: ${wear}%, "
                    [[ -n "$spare" ]] && metrics+="Spare: ${spare}%, "
                    [[ -n "$errors" ]] && metrics+="Media Errors: ${errors}"
                    
                    if [[ -n "$metrics" ]]; then
                        report_info "NVMe Metrics: $metrics"
                    fi
                fi
            fi
        done
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

    # Wi-Fi Auto-Toggle Dispatcher
    local dispatcher_script="/etc/NetworkManager/dispatcher.d/99-wifi-auto-toggle.sh"
    if [[ -f "$dispatcher_script" ]]; then
        if [[ -x "$dispatcher_script" ]]; then
            report_pass "Wi-Fi Auto-Toggle: Script installed and executable"
            
            # Verify correctness of current state
            # Determine if ethernet has internet
            local eth_active=false
            local eth_devices
            if command_exists nmcli; then
                eth_devices=$(nmcli -t -f DEVICE,TYPE,STATE device | grep -E '^[^:]+:ethernet:connected' | cut -d: -f1 || true)
                for dev in $eth_devices; do
                    if ping -c 1 -W 2 -I "$dev" 1.1.1.1 >/dev/null 2>&1; then
                        eth_active=true
                        break
                    fi
                done
                
                local wifi_state
                wifi_state=$(nmcli radio wifi)
                if [[ "$eth_active" == "true" ]]; then
                    if [[ "$wifi_state" == "disabled" ]]; then
                        report_pass "Wi-Fi Auto-Toggle Status: Correctly disabled (Ethernet internet active)"
                    else
                        report_warn "Wi-Fi Auto-Toggle Status: Wi-Fi is enabled but Ethernet internet is active" "Check dispatcher script logs or run optimize.sh to apply."
                    fi
                else
                    if [[ "$wifi_state" == "enabled" ]]; then
                        report_pass "Wi-Fi Auto-Toggle Status: Correctly enabled (No Ethernet internet)"
                    else
                        report_warn "Wi-Fi Auto-Toggle Status: Wi-Fi is disabled but no active Ethernet internet detected" "Check dispatcher script logs."
                    fi
                fi
            else
                report_warn "Wi-Fi Auto-Toggle: nmcli command missing" "Cannot verify radio state."
            fi
        else
            report_fail "Wi-Fi Auto-Toggle: Script exists but is NOT executable" "Run chmod +x $dispatcher_script"
        fi
    else
        report_info "Wi-Fi Auto-Toggle: Dynamic toggle script not configured"
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

    # Kernel Network Buffer and Congestion Control Optimizations
    local rmem wmem cc
    rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "0")
    wmem=$(sysctl -n net.core.wmem_max 2>/dev/null || echo "0")
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "cubic")
    
    if [ "$rmem" -ge 16777216 ] && [ "$wmem" -ge 16777216 ]; then
        report_pass "Kernel Network Buffers: Optimized (rmem/wmem >= 16MB)"
    else
        report_warn "Kernel Network Buffers: Default sizes (rmem: $rmem, wmem: $wmem)" "Run optimize.sh to increase socket buffers for WireGuard/Tailscale throughput."
    fi
    
    if [ "$cc" == "bbr" ]; then
        report_pass "TCP Congestion Control: BBR (Optimal)"
    else
        report_warn "TCP Congestion Control: $cc" "Run optimize.sh to enable BBR congestion control."
    fi

    # UDP GRO Forwarding (Host)
    if command_exists ethtool; then
        local gro_ok=true
        local checked_ifaces=()
        for iface in eth0 wlan0; do
            if [[ -d "/sys/class/net/$iface" ]]; then
                checked_ifaces+=("$iface")
                if ! ethtool -k "$iface" 2>/dev/null | grep -q "rx-udp-gro-forwarding: on"; then
                    gro_ok=false
                fi
            fi
        done
        
        if [[ ${#checked_ifaces[@]} -eq 0 ]]; then
            report_info "UDP GRO Forwarding: No eth0/wlan0 interfaces found to check"
        elif [[ "$gro_ok" == "true" ]]; then
            report_pass "Host UDP GRO Forwarding: Enabled on ${checked_ifaces[*]}"
        else
            report_warn "Host UDP GRO Forwarding: Disabled or suboptimal" "Run optimize.sh to optimize host interfaces for Tailscale throughput."
        fi
    else
        report_warn "Host UDP GRO: ethtool missing" "Install ethtool using setup.sh."
    fi

    # UDP GRO Forwarding (Tailscale Container)
    if command_exists docker && [[ -n "$(docker ps -q -f 'name=^tailscale$')" ]]; then
        if docker exec tailscale ethtool -k eth0 2>/dev/null | grep -q "rx-udp-gro-forwarding: on"; then
            report_pass "Tailscale UDP GRO Forwarding: Enabled inside container namespace"
        else
            report_fail "Tailscale UDP GRO Forwarding: Disabled or suboptimal inside container namespace" "Check entrypoint configuration in docker-compose.yml."
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
    if pgrep syslogd >/dev/null || pgrep rsyslogd >/dev/null; then
        if pgrep rsyslogd >/dev/null; then
            report_pass "Logging: Persistent rsyslog active"
        elif command_exists logread; then
            report_pass "Logging: Busybox RAM-based syslog active"
        else
            report_pass "Logging: Syslogd active"
        fi
    else
        report_warn "Logging: System logger (syslogd/rsyslogd) NOT FOUND" "Ensure busybox-syslogd or rsyslog is installed."
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

check_zsh_suite() {
    log_section_diag "ZSH & OH MY ZSH SUITE"

    local target_user
    target_user=$(get_target_user)

    if [[ -z "$target_user" ]]; then
        report_warn "Zsh Suite: Target user could not be determined"
        return
    fi

    local target_home
    target_home=$(getent passwd "$target_user" | cut -d: -f6)

    # 1. Zsh installation
    if command_exists zsh; then
        local zsh_ver
        zsh_ver=$(zsh --version | awk '{print $2}')
        report_pass "Zsh: Installed ($zsh_ver)"
    else
        report_fail "Zsh: NOT INSTALLED" "Run setup.sh to install Zsh."
        return
    fi

    # 2. Target user's default shell
    local user_shell
    user_shell=$(getent passwd "$target_user" | cut -d: -f7)
    if [[ "$user_shell" == *"/zsh" ]]; then
        report_pass "Shell: Zsh is default shell for $target_user ($user_shell)"
    else
        report_warn "Shell: Zsh is NOT default shell for $target_user (currently $user_shell)" "Run chsh -s /bin/zsh $target_user."
    fi

    # 3. Oh My Zsh
    local omz_dir="${target_home}/.oh-my-zsh"
    if [[ -d "$omz_dir" ]]; then
        report_pass "Oh My Zsh: Installed at $omz_dir"
    else
        report_warn "Oh My Zsh: NOT INSTALLED" "Run setup.sh to install Oh My Zsh."
    fi

    # 4. .zshrc configuration
    local zshrc="${target_home}/.zshrc"
    if [[ -f "$zshrc" ]]; then
        report_pass ".zshrc: Found for user $target_user"
        
        # Verify custom plugins
        local missing_plugins=()
        local plugins=(
            "zsh-autosuggestions"
            "zsh-syntax-highlighting"
        )
        for plugin in "${plugins[@]}"; do
            if [[ ! -d "${omz_dir}/custom/plugins/${plugin}" ]]; then
                missing_plugins+=("$plugin")
            fi
        done

        if [ ${#missing_plugins[@]} -eq 0 ]; then
            report_pass "Plugins: Custom plugins installed (syntax-highlighting, autosuggestions)"
        else
            report_warn "Plugins: Missing custom plugins (${missing_plugins[*]})" "Run setup.sh to download missing custom plugins."
        fi
        
        # Check if compiled .zshrc.zwc exists
        if [[ -f "${zshrc}.zwc" ]]; then
            report_pass "Optimization: .zshrc is compiled (.zshrc.zwc)"
        else
            report_warn "Optimization: .zshrc is NOT compiled" "Run optimize.sh to compile Zsh files."
        fi
    else
        report_warn ".zshrc: Missing for user $target_user" "Run setup.sh to provision .zshrc."
    fi

    # 5. Measure Shell Startup Time
    report_info "Measuring Zsh startup speed..."
    
    local start_time
    start_time=$(date +%s%N)
    # Run zsh in interactive login mode and exit
    sudo -u "$target_user" zsh -i -c exit >/dev/null 2>&1
    local end_time
    end_time=$(date +%s%N)
    
    # Calculate difference
    local diff=$((end_time - start_time))
    local diff_ms=$((diff / 1000000))
    
    if [ "$diff_ms" -lt 300 ]; then
        report_pass "Zsh Speed: Startup time is ${diff_ms}ms (excellent)"
    elif [ "$diff_ms" -lt 700 ]; then
        report_pass "Zsh Speed: Startup time is ${diff_ms}ms (acceptable)"
    else
        report_warn "Zsh Speed: Startup time is ${diff_ms}ms (slow)" "Profile .zshrc or check plugin load delays."
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
    check_zsh_suite

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