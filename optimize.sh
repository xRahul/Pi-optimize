#!/bin/bash

################################################################################
# Raspberry Pi Home Server Optimization - ULTIMATE EDITION v4.2.0
# Target: Debian Trixie/Bookworm (aarch64)
# Optimizes for: Performance, Stability, Flash Longevity, Security
# License: MIT (Copyright 2025 Rahul)
################################################################################

# --- Strict Mode ---
set -euo pipefail
IFS=$'\n\t'

# --- Source Library ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/utils.sh
if [[ -f "${SCRIPT_DIR}/lib/utils.sh" ]]; then
    source "${SCRIPT_DIR}/lib/utils.sh"
else
    echo "Error: lib/utils.sh not found."
    exit 1
fi

# --- Constants & Environment ---
SCRIPT_VERSION="4.2.1"
CONFIG_FILE="/boot/firmware/config.txt"
BACKUP_DIR="/var/backups/rpi-optimize"
LOG_FILE="/var/log/rpi-optimize.log"
LOCK_FILE="/run/rpi-optimize.lock"

# Counters (Globals used by utils.sh)
OPTIMIZATIONS_APPLIED=0
OPTIMIZATIONS_SKIPPED=0
WARNINGS=0
ERRORS=0

################################################################################
# Utility Functions
################################################################################

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo "  -v, --version Show script version"
}

# shellcheck disable=SC2317
cleanup() {
    rm -f "$LOCK_FILE"
}

# shellcheck disable=SC2317
trap_error() {
    local line=$1
    local msg=$2
    log_error "Error at line $line: $msg"
    cleanup
    exit 1
}

trap 'trap_error ${LINENO} "$BASH_COMMAND"' ERR
trap cleanup EXIT

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log_error "Script is already running (PID: $pid)"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

ensure_dependencies() {
    if ! command_exists jq; then
        log_info "Installing jq for JSON processing..."
        apt-get update >/dev/null 2>&1
        apt-get install -y jq >/dev/null 2>&1 || log_warn "Failed to install jq. Some optimizations may be skipped."
    fi
}

################################################################################
# 1. Hardware & Thermal
################################################################################

optimize_hardware() {
    log_section "HARDWARE & THERMAL"
    
    [[ -f "$CONFIG_FILE" ]] || log_error "$CONFIG_FILE not found"

    backup_file "$CONFIG_FILE"

    # Pi 5 Aggressive Cooling
    if grep -q "^dtparam=fan_temp0" "$CONFIG_FILE"; then
        log_skip "Fan curve already configured"
    else
        log_info "Applying aggressive fan curve (35°C start)..."
        # Ensure newline before appending
        echo "" >> "$CONFIG_FILE"
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

    # USB Autosuspend (Vital for USB Boot/Storage)
    local cmdline_file="/boot/firmware/cmdline.txt"
    if [[ -f "$cmdline_file" ]]; then
        if grep -q "usbcore.autosuspend=-1" "$cmdline_file"; then
            log_skip "USB autosuspend already disabled"
        else
            # Append to the end of the line, keeping it on one line
            sed -i 's/$/ usbcore.autosuspend=-1/' "$cmdline_file"
            log_pass "USB autosuspend disabled (improves USB drive stability)"
        fi
    else
        log_warn "cmdline.txt not found, skipping USB autosuspend optimization"
    fi
}

################################################################################
# 2. CPU & Performance
################################################################################

optimize_cpu() {
    log_section "CPU & PERFORMANCE"
    
    local current_gov=""
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        current_gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
    fi

    if [[ "$current_gov" == "performance" ]]; then
        log_skip "CPU governor already set to performance"
    else
        # Set governor to performance
        if command_exists cpufreq-set; then
            cpufreq-set -g performance || log_warn "Failed to set performance governor"
            log_pass "CPU governor set to performance"
        elif [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
            echo "performance" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1
            log_pass "CPU governor set to performance (sysfs)"
        fi
    fi

    # Persistent Governor via cpufrequtils
    if [[ -f /etc/default/cpufrequtils ]]; then
        if ! grep -q 'GOVERNOR="performance"' /etc/default/cpufrequtils; then
            echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils
            log_pass "Persistent CPU governor: performance"
        else
            log_skip "Persistent CPU governor already configured"
        fi
    fi
}

################################################################################
# 3. Storage & I/O
################################################################################

optimize_storage() {
    log_section "STORAGE & I/O"
    
    backup_file /etc/fstab

    # 1. Root noatime optimization
    if grep -E "^[^#].*\s/\s" /etc/fstab | grep -q "noatime"; then
        log_skip "Root filesystem already has noatime"
    else
        log_info "Adding noatime to root filesystem..."
        # Safely append ,noatime to the options field (4th field) of the root mount
        # Matches: (Start) (device) (mountpoint /) (fs) (options) (dump) (pass)
        sed -i -E 's/^([^#]\S+\s+\/\s+\S+\s+)(\S+)/\1\2,noatime/' /etc/fstab
        log_pass "Root filesystem optimized: noatime"
    fi

    # 2. I/O Scheduler (BFQ for USB/SD)
    log_info "Configuring BFQ scheduler..."
    local devices
    devices=$(lsblk -d -o NAME,TRAN 2>/dev/null | grep -E "usb|sd|mmc" | awk '{print $1}' || echo "")
    if [[ -z "$devices" ]]; then
        log_skip "No USB/SD/MMC devices found for I/O scheduler optimization"
    else
        for dev in $devices; do
            if [[ -f "/sys/block/$dev/queue/scheduler" ]]; then
                # Check if BFQ is selected (surrounded by brackets)
                if grep -q "\[bfq\]" "/sys/block/$dev/queue/scheduler"; then
                    log_skip "BFQ already active for $dev"
                elif grep -q "bfq" "/sys/block/$dev/queue/scheduler"; then
                    # shellcheck disable=SC2015
                    echo "bfq" > "/sys/block/$dev/queue/scheduler" 2>/dev/null && log_pass "BFQ set for $dev" || log_warn "Failed to set BFQ for $dev"
                else
                    log_skip "BFQ not available for $dev"
                fi
            fi
        done
    fi

    # 3. fstrim for SSDs (if applicable)
    if systemctl list-unit-files | grep -q fstrim.timer; then
        if systemctl is-active --quiet fstrim.timer; then
            log_skip "Fstrim timer already active"
        else
            systemctl enable --now fstrim.timer >/dev/null 2>&1
            log_pass "Fstrim timer enabled"
        fi
    fi
}

################################################################################
# 4. Kernel Tuning (Sysctl)
################################################################################

optimize_kernel() {
    log_section "KERNEL TUNING"
    
    local sysctl_conf="/etc/sysctl.d/99-server-optimize.conf"
    local tmp_conf="/tmp/99-server-optimize.conf.tmp"
    
    cat > "$tmp_conf" << 'EOF'
# Memory Management
vm.swappiness=1
vm.dirty_ratio=15
vm.dirty_background_ratio=5
vm.vfs_cache_pressure=50
vm.overcommit_memory=1
vm.min_free_kbytes=65536

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

    if files_differ "$sysctl_conf" "$tmp_conf"; then
        backup_file "$sysctl_conf"
        mv "$tmp_conf" "$sysctl_conf"
        sysctl -p "$sysctl_conf" >/dev/null 2>&1 || log_warn "Some sysctl parameters failed to apply"
        log_pass "Kernel parameters optimized (including BBR & Security)"
    else
        rm "$tmp_conf"
        log_skip "Kernel parameters already optimized"
    fi
}

################################################################################
# 5. USB Auto-Mount Configuration
################################################################################

setup_usb_automount() {
    log_section "USB AUTO-MOUNT"
    
    local mount_path="/mnt/usb"
    local fstab_file="/etc/fstab"
    
    # Create mount directory if it doesn't exist
    if [[ ! -d "$mount_path" ]]; then
        mkdir -p "$mount_path"
        log_pass "Mount directory created: $mount_path"
    else
        log_skip "Mount directory already exists: $mount_path"
    fi
    
    # Check if USB device needs to be added to fstab
    
    # Identify root device to exclude it
    local root_dev
    root_dev=$(findmnt -n -o SOURCE /)
    local root_disk
    root_disk=$(lsblk -no PKNAME "$root_dev" 2>/dev/null || echo "$root_dev")
    # Clean up root_disk (remove /dev/ prefix if present)
    root_disk=$(basename "$root_disk")

    # Look for USB/SD/MMC PARTITIONS, excluding root disk
    # We want partitions (TYPE="part") on specific transports (TRAN="usb" etc)
    local usb_device
    usb_device=$(lsblk -nr -o NAME,TRAN,TYPE,PKNAME 2>/dev/null | \
        grep -E "usb|sd|mmc" | \
        grep "part" | \
        grep -v "$root_disk" | \
        awk '{print $1}' | head -1)
    
    if [[ -z "$usb_device" ]]; then
        log_warn "No USB device detected. Manual fstab configuration may be required."
        return
    fi
    
    # Get UUID of the USB device
    local usb_dev_path="/dev/$usb_device"
    if [[ ! -b "$usb_dev_path" ]]; then
        log_warn "USB device $usb_dev_path not found"
        return
    fi
    
    local usb_uuid
    usb_uuid=$(blkid -s UUID -o value "$usb_dev_path" 2>/dev/null)
    if [[ -z "$usb_uuid" ]]; then
        log_warn "Could not determine UUID for $usb_dev_path. Manual configuration required."
        return
    fi
    
    # Check if already in fstab by UUID or Mount Point
    if grep -q "UUID=$usb_uuid" "$fstab_file"; then
        log_skip "USB mount already configured in fstab (UUID: $usb_uuid)"
    elif grep -q "[[:space:]]${mount_path}[[:space:]]" "$fstab_file"; then
        log_warn "Mount point $mount_path already exists in fstab with a different UUID. Skipping to avoid conflicts."
    else
        backup_file "$fstab_file"
        
        # Detect filesystem type
        local fs_type
        fs_type=$(blkid -s TYPE -o value "$usb_dev_path" 2>/dev/null || echo "ext4")
        
        # Add appropriate mount options based on filesystem
        local mount_opts="defaults,nofail,noatime"
        if [[ "$fs_type" == "ext4" ]]; then
            # Optimization for flash storage: commit=60 reduces write frequency
            mount_opts="defaults,nofail,noatime,commit=60"
        elif [[ "$fs_type" == "vfat" || "$fs_type" == "exfat" ]]; then
            mount_opts="defaults,nofail,noatime,uid=1000,gid=1000,umask=002,utf8"
        fi
        
        echo "UUID=$usb_uuid  $mount_path  $fs_type  $mount_opts  0  2" >> "$fstab_file"
        log_pass "USB mount added to fstab (UUID: $usb_uuid, Type: $fs_type)"
        
        # Attempt to mount immediately so subsequent checks pass
        mount "$mount_path" 2>/dev/null || true
    fi
    
    # Create systemd mount override to ensure Docker waits
    mkdir -p /etc/systemd/system/docker.service.d
    if [[ ! -f /etc/systemd/system/docker.service.d/usb-mount.conf ]]; then
        cat > /etc/systemd/system/docker.service.d/usb-mount.conf << 'EOF'
[Unit]
RequiresMountsFor=/mnt/usb
EOF
        log_pass "Docker USB mount dependency configured"
    else
        log_skip "Docker USB mount dependency already configured"
    fi
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

    # Base configuration to apply
    local base_config='{
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
    local final_config="$base_config"
    if mountpoint -q /mnt/usb; then
        # Check filesystem type compatibility
        local fs_type
        fs_type=$(stat -f -c %T /mnt/usb 2>/dev/null || echo "unknown")
        if [[ "$fs_type" == "msdos" || "$fs_type" == "vfat" || "$fs_type" == "exfat" || "$fs_type" == "fuseblk" ]]; then
             log_warn "USB mount /mnt/usb is $fs_type (incompatible with Docker data-root). Skipping data-root optimization."
        else
            if [[ -d "/mnt/usb/docker" ]]; then
                if command_exists jq; then
                    final_config=$(echo "$final_config" | jq '. + {"data-root": "/mnt/usb/docker"}')
                fi
                log_info "Configuring Docker to use existing /mnt/usb/docker"
            else
                log_skip "Directory /mnt/usb/docker not found. Skipping data-root move to prevent data modification."
            fi
        fi
    fi

    # Merge or Write
    if [[ -f "$docker_config" ]]; then
        if command_exists jq; then
            # Idempotency Check: Compare existing vs new (merged)
            local current_json
            current_json=$(jq -S . "$docker_config")
            local new_json
            new_json=$(jq -s '.[0] * .[1]' "$docker_config" <(echo "$final_config") | jq -S .)
            
            if [[ "$current_json" == "$new_json" ]]; then
                log_skip "Docker daemon.json already optimized"
            else
                log_info "Merging with existing daemon.json..."
                echo "$new_json" > "$docker_config"
                log_pass "Docker daemon.json optimized (merged)"
                
                systemctl daemon-reload
                # shellcheck disable=SC2015
                systemctl is-active --quiet docker && systemctl restart docker || log_warn "Failed to restart Docker (may not be running yet)"
            fi
        else
            log_warn "jq not found. Skipping Docker config merge to prevent data loss."
        fi
    else
        echo "$final_config" > "$docker_config"
        log_pass "Docker daemon.json optimized (created)"
        
        systemctl daemon-reload
        # shellcheck disable=SC2015
        systemctl is-active --quiet docker && systemctl restart docker || log_warn "Failed to restart Docker (may not be running yet)"
    fi
}

################################################################################
# 5b. Docker Compose Auto-Restart
################################################################################

setup_docker_compose_restart() {
    log_section "DOCKER COMPOSE AUTO-RESTART"

    if ! command_exists docker; then
        log_skip "Docker not installed"
        return
    fi

    # Determine real user and home
    local target_user="${SUDO_USER:-$USER}"
    # If root, try to find 'rahul' or assume root
    if [[ "$target_user" == "root" ]] && [[ -d "/home/rahul" ]]; then
        target_user="rahul"
    fi
    
    local target_home
    if command_exists getent; then
        target_home=$(getent passwd "$target_user" | cut -d: -f6)
    else
        target_home="/home/$target_user"
    fi
    
    local docker_dir="${target_home}/docker"

    if [[ ! -d "$docker_dir" ]]; then
        log_skip "Directory $docker_dir not found. Skipping auto-restart setup."
        return
    fi

    local service_file="/etc/systemd/system/docker-compose-restart.service"
    
    if [[ -f "$service_file" ]]; then
        log_skip "Service docker-compose-restart already exists."
        return
    fi

    # Interactive Prompt
    echo -e "${YELLOW}Do you want to enable automatic 'docker compose down && docker compose up -d' in $docker_dir on boot? [y/N]${NC}"
    local choice
    # Use || true to prevent exit on read failure (e.g., EOF)
    read -r -p "Select (default No): " choice || choice="N"
    choice=${choice:-N}

    if [[ "$choice" =~ ^[Yy]$ ]]; then
        cat > "$service_file" << EOF
[Unit]
Description=Restart Docker Compose services in $docker_dir on boot
Requires=docker.service
After=docker.service network-online.target multi-user.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
WorkingDirectory=$docker_dir
ExecStartPre=/bin/sleep 15
ExecStart=/usr/bin/docker compose down
ExecStart=/usr/bin/docker compose up -d
RemainAfterExit=yes
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        if systemctl enable docker-compose-restart.service 2>/dev/null; then
             log_pass "Docker compose auto-restart enabled for $docker_dir"
        else
             log_warn "Failed to enable docker-compose-restart service"
        fi
    else
        log_skip "User declined docker compose auto-restart"
    fi
}

################################################################################
# 5a. Tailscale Fix
################################################################################

fix_tailscale_race() {
    log_section "TAILSCALE CONNECTIVITY FIX"

    if ! command_exists docker; then
        log_skip "Docker not installed"
        return
    fi

    # Check if tailscale container exists (running or stopped)
    if ! docker ps -a --format '{{.Names}}' | grep -q "^tailscale$"; then
        log_skip "Tailscale container not found. Skipping fix."
        return
    fi

    local service_file="/etc/systemd/system/tailscale-fix.service"
    
    # We create a service that waits for valid internet connection then restarts tailscale
    cat > "$service_file" << 'EOF'
[Unit]
Description=Fix Tailscale Connectivity on Boot
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# Wait for internet connectivity (check default gateway)
ExecStartPre=/bin/bash -c 'gw=$(ip route | grep default | cut -d" " -f3 | head -n1); for i in {1..30}; do ping -c1 -W2 "$gw" >/dev/null 2>&1 && break; sleep 2; done'
ExecStart=/usr/bin/docker restart tailscale
RemainAfterExit=yes
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    if systemctl enable tailscale-fix.service 2>/dev/null; then
        log_pass "Tailscale boot fix enabled"
    else
        log_warn "Failed to enable Tailscale boot fix"
    fi
}

################################################################################
# 6. Memory & Swap (ZRAM)
################################################################################

optimize_memory() {
    log_section "MEMORY & SWAP"

    # 1. Disable Disk-based Swap (Permanent)
    log_info "Configuring swap settings..."
    
    # Disable and purge dphys-swapfile (Raspberry Pi default)
    if command_exists dphys-swapfile; then
        log_info "Removing dphys-swapfile..."
        dphys-swapfile swapoff 2>/dev/null || true
        dphys-swapfile uninstall 2>/dev/null || true
        systemctl stop dphys-swapfile 2>/dev/null || true
        systemctl disable dphys-swapfile 2>/dev/null || true
        # Remove the swap file itself if it still exists
        rm -f /var/swap
        log_pass "dphys-swapfile service disabled and swap file removed"
    fi

    # Check for and disable systemd-swap if present
    if systemctl list-unit-files | grep -q systemd-swap; then
        systemctl stop systemd-swap 2>/dev/null || true
        systemctl disable systemd-swap 2>/dev/null || true
        log_pass "systemd-swap service disabled"
    fi

    # Disable runtime disk swap
    local other_swaps
    other_swaps=$(swapon --show --noheadings | grep -v "zram" | awk '{print $1}')
    if [[ -n "$other_swaps" ]]; then
        for s in $other_swaps; do
            swapoff "$s" 2>/dev/null || true
        done
        log_pass "Active disk swap(s) disabled"
    fi

    # Disable fstab swap entries
    if grep -E "^[^#].*\sswap\s" /etc/fstab >/dev/null; then
        sed -i '/\sswap\s/ s/^/#/' /etc/fstab
        log_pass "Swap entries in fstab disabled"
    fi

    # 2. ZRAM Setup (if available)
    if [[ -f /etc/default/zramswap ]]; then
        if grep -q "ALGO=zstd" /etc/default/zramswap && grep -q "PERCENT=60" /etc/default/zramswap; then
            log_skip "ZRAM already configured (zstd, 60%)"
        else
            sed -i 's/ALGO=.*/ALGO=zstd/' /etc/default/zramswap
            sed -i 's/PERCENT=.*/PERCENT=60/' /etc/default/zramswap
            systemctl restart zramswap 2>/dev/null || true
            log_pass "ZRAM tuned: zstd, 60%"
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
    local journal_conf="${journal_conf_dir}/optimize.conf"
    local tmp_conf="/tmp/journald-optimize.conf.tmp"
    
    mkdir -p "$journal_conf_dir"
    cat > "$tmp_conf" << 'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=64M
RuntimeMaxFileSize=8M
Compress=yes
EOF

    if files_differ "$journal_conf" "$tmp_conf"; then
        mv "$tmp_conf" "$journal_conf"
        systemctl restart systemd-journald
        log_pass "Journald optimized for volatile storage"
    else
        rm "$tmp_conf"
        log_skip "Journald already optimized"
    fi

    # Log2Ram (if installed)
    if [[ -f /etc/log2ram.conf ]]; then
        sed -i 's/SIZE=.*/SIZE=128M/' /etc/log2ram.conf
        log_pass "Log2Ram size increased to 128M"
    fi
}

################################################################################
# 7b. Ollama Service
################################################################################

prompt_update() {
    confirm_action "$1"
}

optimize_ollama_service() {
    log_section "OLLAMA SERVICE"
    if command_exists ollama; then
        # Ensure enabled
        if ! systemctl is-enabled --quiet ollama; then
            systemctl enable ollama
            log_pass "Ollama service enabled"
        fi

        # --- Update Check ---
        log_info "Checking for Ollama updates..."
        local current_ver
        current_ver=$(ollama --version 2>/dev/null | awk '{print $3}')
        # Use a short timeout for the network call
        local latest_ver
        latest_ver=$(curl -s --max-time 3 https://api.github.com/repos/ollama/ollama/releases/latest | jq -r .tag_name 2>/dev/null | sed 's/^v//' || echo "")

        if [[ -n "$latest_ver" ]] && [[ -n "$current_ver" ]]; then
            if [[ "$current_ver" != "$latest_ver" ]]; then
                echo -e "${YELLOW}Update available: $current_ver -> $latest_ver${NC}"
                if prompt_update "Do you want to update Ollama?"; then
                    log_info "Updating Ollama..."
                    if curl -fsSL https://ollama.com/install.sh | sh; then
                        log_pass "Ollama updated to $latest_ver"
                    else
                        log_warn "Ollama update failed"
                    fi
                else
                    log_skip "Update skipped by user"
                fi
            else
                log_pass "Ollama is up to date ($current_ver)"
            fi
        else
            log_warn "Could not check for Ollama updates (Network/API issue)"
        fi

        # Apply boot-order and permission fixes
        local override_dir="/etc/systemd/system/ollama.service.d"
        local override_file="${override_dir}/override.conf"
        
        # Check if we are using USB storage
        if [ -f "$override_file" ] && grep -q "/mnt/usb" "$override_file"; then
            local models_dir
            models_dir=$(grep "OLLAMA_MODELS=" "$override_file" | cut -d'=' -f2 | tr -d '"' || echo "")
            [ -z "$models_dir" ] && models_dir="/mnt/usb/ollama"
            
            if ! grep -q "RequiresMountsFor" "$override_file" || ! grep -q "OLLAMA_NUM_PARALLEL" "$override_file"; then
                log_info "Applying optimizations & boot-order fix to Ollama..."
                # Extract existing Environment vars, filtering out ones we are about to add/enforce
                local envs
                envs=$(grep "Environment=" "$override_file" | grep -vE "OLLAMA_NUM_PARALLEL|OLLAMA_FLASH_ATTENTION|OLLAMA_KV_CACHE_TYPE|OLLAMA_MAX_LOADED_MODELS")
                
                cat > "$override_file" <<EOF
[Unit]
After=network-online.target
RequiresMountsFor=${models_dir}

[Service]
${envs}
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q4_0"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
EOF
                systemctl daemon-reload
                log_pass "Ollama optimizations & boot-order fix applied"
            fi
            
            # Ensure permissions
            local target_user="${SUDO_USER:-$USER}"
            # Attempt to use detected user
            if [[ -n "$target_user" && "$target_user" != "root" ]]; then
                if ! groups ollama | grep -q "\b${target_user}\b"; then
                    usermod -aG "$target_user" ollama
                    log_pass "Ollama user added to $target_user group for USB access"
                fi
            else
                 # Fallback to 'rahul' if present, as in original script
                 if id "rahul" &>/dev/null; then
                     if ! groups ollama | grep -q "\brahul\b"; then
                        usermod -aG rahul ollama
                        log_pass "Ollama user added to rahul group for USB access"
                     fi
                 fi
            fi
        fi
    else
        log_skip "Ollama not installed"
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
        # Fix for n8n <-> Ollama connection timeout (Allow wg-easy subnet to Ollama)
        ufw allow from 10.8.1.0/24 to any port 11434 proto tcp >/dev/null
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
    # Parse arguments
    while getopts ":hv-:" opt; do
        case ${opt} in
            h)
                usage
                exit 0
                ;;
            v)
                echo "$SCRIPT_VERSION"
                exit 0
                ;;
            -)
                case "${OPTARG}" in
                    help)
                        usage
                        exit 0
                        ;;
                    version)
                        echo "$SCRIPT_VERSION"
                        exit 0
                        ;;
                    *)
                        echo "Invalid option: --${OPTARG}" >&2
                        usage
                        exit 1
                        ;;
                esac
                ;;
            \?)
                echo "Invalid option: -${OPTARG}" >&2
                usage
                exit 1
                ;;
        esac
    done

    require_root
    acquire_lock
    ensure_dependencies
    
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
    setup_usb_automount
    optimize_docker
    fix_tailscale_race
    setup_docker_compose_restart
    optimize_memory
    optimize_logs
    optimize_ollama_service
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