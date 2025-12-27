#!/bin/bash

################################################################################
# Raspberry Pi Home Server Optimization - ULTIMATE EDITION v4.1.0
# Target: Debian Trixie/Bookworm (aarch64)
# Optimizes for: Performance, Stability, Flash Longevity, Security
# License: MIT (Copyright 2025 Rahul)
################################################################################

# --- Strict Mode ---
set -euo pipefail
IFS=$'\n\t'

# --- Constants & Environment ---
SCRIPT_VERSION="4.1.0"
CONFIG_FILE="/boot/firmware/config.txt"
BACKUP_DIR="/var/backups/rpi-optimize"
LOG_FILE="/var/log/rpi-optimize.log"
LOCK_FILE="/run/rpi-optimize.lock"
BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Counters
OPTIMIZATIONS_APPLIED=0
OPTIMIZATIONS_SKIPPED=0
WARNINGS=0
ERRORS=0

################################################################################
# Utility Functions
################################################################################

log_info() { echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
log_pass() { echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOG_FILE"; ((OPTIMIZATIONS_APPLIED++)); }
log_skip() { echo -e "${YELLOW}[⊘]${NC} $1" | tee -a "$LOG_FILE"; ((OPTIMIZATIONS_SKIPPED++)); }
log_warn() { echo -e "${YELLOW}[!]${NC} $1" | tee -a "$LOG_FILE"; ((WARNINGS++)); }
log_error() { echo -e "${RED}[✗]${NC} $1" | tee -a "$LOG_FILE"; ((ERRORS++)); }
log_section() { echo -e "\n${CYAN}=== $1 ===${NC}" | tee -a "$LOG_FILE"; }
log_success() { echo -e "\n${GREEN}$1${NC}" | tee -a "$LOG_FILE"; }

cleanup() {
    rm -f "$LOCK_FILE"
}

trap_error() {
    local line=$1
    local msg=$2
    log_error "Error at line $line: $msg"
    cleanup
    exit 1
}

trap 'trap_error ${LINENO} "$BASH_COMMAND"' ERR
trap cleanup EXIT

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}ERROR: This script must be run as root (sudo)${NC}"
        exit 1
    fi
}

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log_error "Script is already running (PID: $pid)"
            exit 1
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        mkdir -p "$BACKUP_DIR"
        local bkp="${BACKUP_DIR}/$(basename "$file").${BACKUP_TIMESTAMP}"
        cp "$file" "$bkp"
        log_info "Backup created: $bkp"
    fi
}

################################################################################
# 1. Hardware & Thermal
################################################################################

optimize_hardware() {
    log_section "HARDWARE & THERMAL"
    
    [[ -f "$CONFIG_FILE" ]] || { log_error "$CONFIG_FILE not found"; return; }
    backup_file "$CONFIG_FILE"

    # Pi 5 Aggressive Cooling
    if grep -q "^dtparam=fan_temp0" "$CONFIG_FILE"; then
        log_skip "Fan curve already configured"
    else
        log_info "Applying aggressive fan curve (35°C start)..."
        cat >> "$CONFIG_FILE" << 'EOF'

# Active Cooling for Pi 5
dtparam=fan_temp0=35000
dtparam=fan_temp0_hyst=5000
dtparam=fan_temp0_speed=125
dtparam=fan_temp1=50000
dtparam=fan_temp1_hyst=5000
dtparam=fan_temp1_speed=200
EOF
        log_pass "Fan curve optimized"
    fi

    # Disable Bluetooth & Audio (Saves power/interrupts)
    for opt in "dtoverlay=disable-bt" "dtparam=audio=off"; do
        if grep -q "^$opt" "$CONFIG_FILE"; then
            log_skip "$opt already set"
        else
            echo "$opt" >> "$CONFIG_FILE"
            log_pass "$opt enabled"
        fi
    done

    # Hardware Watchdog
    if grep -q "^dtparam=watchdog=on" "$CONFIG_FILE"; then
        log_skip "Hardware watchdog already enabled"
    else
        echo "dtparam=watchdog=on" >> "$CONFIG_FILE"
        log_pass "Hardware watchdog enabled in config.txt"
    fi
    
    if command_exists systemctl; then
        systemctl enable --now watchdog 2>/dev/null || log_warn "Watchdog service failed to start"
    fi
}

################################################################################
# 2. CPU & Performance
################################################################################

optimize_cpu() {
    log_section "CPU & PERFORMANCE"
    
    # Set governor to performance
    if command_exists cpufreq-set; then
        cpufreq-set -g performance || log_warn "Failed to set performance governor"
        log_pass "CPU governor set to performance"
    elif [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        echo "performance" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1
        log_pass "CPU governor set to performance (sysfs)"
    fi

    # Persistent Governor via cpufrequtils
    if [[ -f /etc/default/cpufrequtils ]]; then
        if ! grep -q 'GOVERNOR="performance"' /etc/default/cpufrequtils; then
            echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils
            log_pass "Persistent CPU governor: performance"
        fi
    fi
}

################################################################################
# 3. Storage & I/O
################################################################################

optimize_storage() {
    log_section "STORAGE & I/O"
    
    backup_file /etc/fstab

    # 1. Root noatime optimization (More robust regex)
    if grep -E "^[^#].*\s/\s.*\bnoatime\b" /etc/fstab >/dev/null; then
        log_skip "Root filesystem already has noatime"
    else
        log_info "Adding noatime to root filesystem..."
        # Target the root mount entry specifically
        sed -i '/[[:space:]]\/[[:space:]]/ s/defaults/defaults,noatime/' /etc/fstab
        log_pass "Root filesystem optimized: noatime"
    fi

    # 2. I/O Scheduler (BFQ for USB/SD)
    log_info "Configuring BFQ scheduler..."
    local devices=$(lsblk -d -o NAME,TRAN | grep -E "usb|sd" | awk '{print $1}' || echo "")
    for dev in $devices; do
        if [[ -f "/sys/block/$dev/queue/scheduler" ]]; then
            if grep -q "bfq" "/sys/block/$dev/queue/scheduler"; then
                echo "bfq" > "/sys/block/$dev/queue/scheduler" 2>/dev/null && log_pass "BFQ set for $dev" || log_warn "Failed to set BFQ for $dev"
            fi
        fi
    done

    # 3. fstrim for SSDs (if applicable)
    if systemctl list-unit-files | grep -q fstrim.timer; then
        systemctl enable --now fstrim.timer >/dev/null 2>&1
        log_pass "Fstrim timer enabled"
    fi
}

################################################################################
# 4. Kernel Tuning (Sysctl)
################################################################################

optimize_kernel() {
    log_section "KERNEL TUNING"
    
    local sysctl_conf="/etc/sysctl.d/99-server-optimize.conf"
    backup_file "$sysctl_conf"

    cat > "$sysctl_conf" << 'EOF'
# Memory Management
vm.swappiness=10
vm.dirty_ratio=15
vm.dirty_background_ratio=5
vim.vfs_cache_pressure=50
vim.overcommit_memory=1

# Network Stack Optimizations
net.core.somaxconn=1024
net.core.netdev_max_backlog=5000
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_max_syn_backlog=4096
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.ip_forward=1

# TCP BBR
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# Security Hardening
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.tcp_syncookies=1
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
EOF

    sysctl -p "$sysctl_conf" >/dev/null 2>&1 || log_warn "Some sysctl parameters failed to apply"
    log_pass "Kernel parameters optimized (including BBR & Security)"
}

################################################################################
# 5. Docker Optimization
################################################################################

optimize_docker() {
    log_section "DOCKER OPTIMIZATION"
    
    if ! command_exists docker; then
        log_skip "Docker not installed"
        return
    fi

    local docker_config="/etc/docker/daemon.json"
    backup_file "$docker_config"

    # Robust JSON generation
    local config_content='{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true,
  "features": { "buildkit": true },
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 64000, "Soft": 64000 }
  }
}'

    # Check for USB mount and add data-root if necessary
    if mountpoint -q /mnt/usb; then
        if [[ -d "/mnt/usb/docker" ]] || mkdir -p /mnt/usb/docker; then
            if command_exists jq; then
                config_content=$(echo "$config_content" | jq '. + {"data-root": "/mnt/usb/docker"}')
            else
                # Fallback simple append if jq missing (less robust but works for fresh install)
                config_content=$(echo "$config_content" | sed 's/}/  ,"data-root": "\/mnt\/usb\/docker"\n}/')
            fi
            log_info "Configuring Docker to use /mnt/usb/docker"
        fi
    fi

    echo "$config_content" > "$docker_config"
    log_pass "Docker daemon.json optimized"

    # Systemd Override
    mkdir -p /etc/systemd/system/docker.service.d
    cat > /etc/systemd/system/docker.service.d/override.conf << 'EOF'
[Unit]
After=mnt-usb.mount
RequiresMountsFor=/mnt/usb

[Service]
ExecStart=
ExecStart=/usr/bin/dockerd --log-level=warn
TasksMax=infinity
LimitNOFILE=infinity
LimitNPROC=infinity
EOF
    systemctl daemon-reload
    log_pass "Docker systemd overrides applied"
    
    systemctl restart docker || log_error "Failed to restart Docker"
}

################################################################################
# 6. Memory & Swap (ZRAM)
################################################################################

optimize_memory() {
    log_section "MEMORY & SWAP"

    # ZRAM setup (Generic via zram-tools if available)
    if [[ -f /etc/default/zramswap ]]; then
        sed -i 's/ALGO=.*/ALGO=zstd/' /etc/default/zramswap
        sed -i 's/PERCENT=.*/PERCENT=60/' /etc/default/zramswap
        systemctl restart zramswap 2>/dev/null || true
        log_pass "ZRAM tuned: zstd, 60%"
    fi

    # Disable traditional swap if ZRAM is active
    if [[ -f /sys/block/zram0/disksize ]]; then
        if swapon --show | grep -qv "zram"; then
            log_info "Disabling disk-based swap..."
            swapoff -a 2>/dev/null || true
            # Comment out swap in fstab
            sed -i '/\sswap\s/ s/^/#/' /etc/fstab
            log_pass "Traditional swap disabled"
        fi
    fi
}

################################################################################
# 7. Log Management
################################################################################

optimize_logs() {
    log_section "LOG MANAGEMENT"

    # Journald volatile storage
    local journal_conf_dir="/etc/systemd/journald.conf.d"
    mkdir -p "$journal_conf_dir"
    cat > "${journal_conf_dir}/optimize.conf" << 'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=64M
RuntimeMaxFileSize=8M
Compress=yes
EOF
    systemctl restart systemd-journald
    log_pass "Journald optimized for volatile storage"

    # Log2Ram (if installed)
    if [[ -f /etc/log2ram.conf ]]; then
        sed -i 's/SIZE=.*/SIZE=128M/' /etc/log2ram.conf
        log_pass "Log2Ram size increased to 128M"
    fi
}

################################################################################
# 8. Maintenance & Security
################################################################################

system_maintenance() {
    log_section "MAINTENANCE & SECURITY"
    
    log_info "Cleaning package cache..."
    apt-get autoremove -y >/dev/null 2>&1
    apt-get autoclean -y >/dev/null 2>&1
    log_pass "Apt cleanup complete"

    # Firewall setup
    if command_exists ufw; then
        ufw allow ssh >/dev/null
        ufw allow 80/tcp >/dev/null
        ufw allow 443/tcp >/dev/null
        # Allow Docker traffic
        ufw allow in on docker0 >/dev/null
        echo "y" | ufw enable >/dev/null
        log_pass "Firewall (UFW) configured and enabled"
    fi

    log_info "Removing documentation to save space..."
    rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* 2>/dev/null || true
    log_pass "Documentation cleared"
}

################################################################################
# Main Execution
################################################################################

main() {
    require_root
    acquire_lock
    
    echo -e "${MAGENTA}"
    echo "██████╗ ██████╗ ██╗    ██████╗ ██████╗ ████████╗██╗███╗   ███╗██╗███████╗███████╗"
    echo "██╔══██╗██╔══██╗██║    ██╔══██╗██╔══██╗╚══██╔══╝██║████╗ ████║██║╚══███╔╝██╔════╝"
    echo "██████╔╝██████╔╝██║    ██║  ██║██████╔╝   ██║   ██║██╔████╔██║██║  ███╔╝ █████╗  "
    echo "██╔══██╗██╔═══╝ ██║    ██║  ██║██╔═══╝    ██║   ██║██║╚██╔╝██║██║ ███╔╝  ██╔══╝  "
    echo "██║  ██║██║     ██║    ██████╔╝██║        ██║   ██║██║ ╚═╝ ██║██║███████╗███████╗"
    echo "╚═╝  ╚═╝╚═╝     ╚═╝    ╚═════╝ ╚═╝        ╚═╝   ╚═╝╚═╝     ╚═╝╚═╝╚══════╝╚══════╝"
    echo -e "${NC}"
    log_info "RPI SERVER OPTIMIZER v${SCRIPT_VERSION}"
    log_info "Started at: $(date)"
    
    # Run modules
    optimize_hardware
    optimize_cpu
    optimize_storage
    optimize_kernel
    optimize_docker
    optimize_memory
    optimize_logs
    system_maintenance
    
    # Summary
    log_section "OPTIMIZATION SUMMARY"
    log_success "Applied: $OPTIMIZATIONS_APPLIED"
    log_info "Skipped: $OPTIMIZATIONS_SKIPPED"
    log_warn "Warnings: $WARNINGS"
    
    if [[ $ERRORS -gt 0 ]]; then
        log_error "Errors: $ERRORS"
    fi

    log_warn "REBOOT IS REQUIRED TO APPLY ALL CHANGES."
    log_info "Log file: $LOG_FILE"
}

main "$@"