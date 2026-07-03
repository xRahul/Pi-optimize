#!/bin/bash

################################################################################
# Raspberry Pi Home Server Optimization - ULTIMATE EDITION v4.3.0
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
SCRIPT_VERSION="4.4.0"
CONFIG_FILE="/boot/firmware/config.txt"
export BACKUP_DIR="/var/backups/rpi-optimize"
LOG_FILE="/var/log/rpi-optimize.log"
LOCK_FILE="/run/rpi-optimize.lock"
BOOT_TRAN=""

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
        pid=$(< "$LOCK_FILE")
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

add_cmdline_param() {
    local param="$1"
    local cmdline_file="/boot/firmware/cmdline.txt"
    if [[ -f "$cmdline_file" ]]; then
        if grep -q -F "$param" "$cmdline_file"; then
            log_skip "Kernel parameter '$param' already in cmdline.txt"
        else
            # Trim spaces, remove existing trailing spaces, append param on the single line
            sed -i -E "s/[[:space:]]*$/ ${param}/" "$cmdline_file"
            log_pass "Kernel parameter '$param' added to cmdline.txt"
        fi
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
dtparam=fan_temp1_speed=200
EOF
        log_pass "Fan curve optimized"
    fi

    # Pi 5 PCIe Config (Gen 2 for maximum stability/endurance)
    # Remove/comment any pciex1_gen=3 entries to avoid conflicts
    if grep -q "pciex1_gen=3" "$CONFIG_FILE"; then
        sed -i 's/^dtparam=pciex1_gen=3/# dtparam=pciex1_gen=3  # Disabled by optimize.sh for Gen 2/' "$CONFIG_FILE"
    fi

    if grep -q "^dtparam=pciex1$" "$CONFIG_FILE" || grep -q "^dtparam=nvme$" "$CONFIG_FILE"; then
        log_skip "PCIe interface already enabled in config.txt"
    else
        echo "dtparam=pciex1" >> "$CONFIG_FILE"
        log_pass "PCIe interface enabled (Pi 5)"
    fi

    if grep -q "^dtparam=pciex1_gen=2" "$CONFIG_FILE"; then
        log_skip "PCIe Gen 2 already configured in config.txt"
    else
        echo "dtparam=pciex1_gen=2" >> "$CONFIG_FILE"
        log_pass "PCIe Gen 2 configured (Pi 5)"
    fi

    # Reduce GPU Memory (Server mode)
    if grep -q "^gpu_mem=" "$CONFIG_FILE"; then
        sed -i 's/^gpu_mem=.*/gpu_mem=16/' "$CONFIG_FILE"
        log_pass "GPU memory reduced to 16MB"
    else
        echo "gpu_mem=16" >> "$CONFIG_FILE"
        log_pass "GPU memory set to 16MB"
    fi

    # Disable Bluetooth & Audio (Saves power/interrupts)
    if grep -q "^dtoverlay=disable-bt" "$CONFIG_FILE"; then
        log_skip "dtoverlay=disable-bt already set"
    else
        echo "dtoverlay=disable-bt" >> "$CONFIG_FILE"
        log_pass "dtoverlay=disable-bt enabled"
    fi

    if grep -q "^dtparam=audio=off" "$CONFIG_FILE"; then
        log_skip "dtparam=audio=off already set"
    else
        # Comment out any existing audio=on to avoid conflicting entries
        sed -i 's/^dtparam=audio=on/# dtparam=audio=on  # Disabled by optimize.sh/' "$CONFIG_FILE"
        echo "dtparam=audio=off" >> "$CONFIG_FILE"
        log_pass "dtparam=audio=off enabled (existing audio=on commented out)"
    fi

    # Smart Wi-Fi Disablement
    local wifi_active=false
    if command_exists ip; then
        if ip -4 addr show wlan0 2>/dev/null | grep -q "inet "; then
            wifi_active=true
        fi
    fi

    if [[ "$wifi_active" == "false" ]]; then
        local eth_active=false
        if ip -4 addr show eth0 2>/dev/null | grep -q "inet " || ip -4 addr show end0 2>/dev/null | grep -q "inet "; then
            eth_active=true
        fi

        if [[ "$eth_active" == "true" ]]; then
            if grep -q "^dtoverlay=disable-wifi" "$CONFIG_FILE"; then
                log_skip "dtoverlay=disable-wifi already set"
            else
                echo "dtoverlay=disable-wifi" >> "$CONFIG_FILE"
                log_pass "Ethernet active & Wi-Fi unused: disabled Wi-Fi to reduce heat/power"
            fi
        else
            log_skip "Neither Wi-Fi nor Ethernet active or detected. Keeping Wi-Fi enabled for safety."
        fi
    else
        log_skip "Wi-Fi is currently in use (active IP detected). Keeping Wi-Fi enabled."
    fi

    # Ensure overclock parameters are commented out for system endurance
    if grep -qE "^(arm_freq|gpu_freq|over_voltage_delta)" "$CONFIG_FILE"; then
        sed -i -E 's/^(arm_freq|gpu_freq|over_voltage_delta)/# \1  # Disabled by optimize.sh for endurance/' "$CONFIG_FILE"
        log_pass "Overclock parameters disabled/removed for stability"
    fi

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
    add_cmdline_param "usbcore.autosuspend=-1"
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
        # Set governor to performance immediately (runtime)
        if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
            echo "performance" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null 2>&1
            log_pass "CPU governor set to performance (runtime)"
        fi
    fi

    # Persist governor across reboots via systemd service
    # NOTE: /etc/default/cpufrequtils is NOT used here because the cpufrequtils
    # init.d service does not exist on modern Debian Trixie with the cpufreq-dt driver.
    local gov_service="/etc/systemd/system/cpu-governor.service"
    if [[ -f "$gov_service" ]] && grep -q "performance" "$gov_service"; then
        log_skip "CPU governor persistence already configured"
    else
        cat > "$gov_service" << 'EOF'
[Unit]
Description=Set CPU Governor to Performance Mode
After=sysinit.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        # shellcheck disable=SC2015
        systemctl enable --now cpu-governor.service > /dev/null 2>&1 \
            && log_pass "CPU governor persistence configured (cpu-governor.service)" \
            || log_warn "Failed to enable cpu-governor.service"
    fi
}

################################################################################
# 3. Storage & I/O
################################################################################

optimize_storage() {
    log_section "STORAGE & I/O"
    
    local fstab_file="${FSTAB_FILE:-/etc/fstab}"
    backup_file "$fstab_file"

    # 1. Root noatime optimization & commit=60,lazytime for ext4 flash wear protection
    if grep -qE "^[^#].*\s/\s.*noatime" "$fstab_file"; then
        log_skip "Root filesystem already has noatime"
    else
        log_info "Adding noatime to root filesystem..."
        # Safely append ,noatime to the options field (4th field) of the root mount
        # Matches: (Start) (device) (mountpoint /) (fs) (options) (dump) (pass)
        sed -i -E 's/^([^#]\S+\s+\/\s+\S+\s+)(\S+)/\1\2,noatime/' "$fstab_file"
        log_pass "Root filesystem optimized: noatime"
    fi

    # 1b. Root commit option for ext4 to reduce writeback latency (if root is ext4)
    # Check if root filesystem is ext4 in fstab
    if grep -qE "^[^#].*\s/\s+ext4" "$fstab_file"; then
        if grep -qE "^[^#].*\s/\s+ext4\s+\S*commit=60" "$fstab_file" && grep -qE "^[^#].*\s/\s+ext4\s+\S*lazytime" "$fstab_file"; then
            log_skip "Root filesystem already has commit=60 and lazytime"
        else
            log_info "Adding commit=60,lazytime to root filesystem..."
            # Check if any commit option exists, modify it.
            if grep -qE "^[^#].*\s/\s+ext4\s+\S*commit=" "$fstab_file"; then
                sed -i -E 's/commit=[0-9]+/commit=60/' "$fstab_file"
            else
                sed -i -E 's/^([^#]\S+\s+\/\s+ext4\s+)(\S+)/\1\2,commit=60/' "$fstab_file"
            fi
            # Check if lazytime exists, if not, append it
            if ! grep -qE "^[^#].*\s/\s+ext4\s+\S*lazytime" "$fstab_file"; then
                sed -i -E 's/^([^#]\S+\s+\/\s+ext4\s+)(\S+)/\1\2,lazytime/' "$fstab_file"
            fi
            log_pass "Root filesystem optimized: commit=60,lazytime"
        fi
    fi

    # 2. I/O Scheduler (BFQ for USB/SD)
    log_info "Configuring BFQ scheduler..."
    local devices
    devices=$(lsblk -d -n -o NAME,TRAN 2>/dev/null | awk '/usb|sd|mmc/ {print $1}' || echo "")
    if [[ -z "$devices" ]]; then
        log_skip "No USB/SD/MMC devices found for I/O scheduler optimization"
    else
        local sys_block_dir="${SYS_BLOCK_DIR:-/sys/block}"
        for dev in $devices; do
            local sched_file="$sys_block_dir/$dev/queue/scheduler"
            if [[ -f "$sched_file" ]]; then
                local sched_content
                sched_content=$(<"$sched_file")

                # Check if BFQ is selected (surrounded by brackets)
                if [[ "$sched_content" == *"[bfq]"* ]]; then
                    log_skip "BFQ already active for $dev"
                elif [[ "$sched_content" == *"bfq"* ]]; then
                    # shellcheck disable=SC2015
                    echo "bfq" > "$sched_file" 2>/dev/null && log_pass "BFQ set for $dev" || log_warn "Failed to set BFQ for $dev"
                else
                    log_skip "BFQ not available for $dev"
                fi
            fi
        done
    fi

    # 2b. I/O Scheduler (none for NVMe)
    log_info "Configuring NVMe scheduler..."
    local nvme_devices
    nvme_devices=$(lsblk -d -n -o NAME 2>/dev/null | grep nvme || echo "")
    if [[ -z "$nvme_devices" ]]; then
        log_skip "No NVMe devices found for I/O scheduler optimization"
    else
        local sys_block_dir="${SYS_BLOCK_DIR:-/sys/block}"
        for dev in $nvme_devices; do
            local sched_file="$sys_block_dir/$dev/queue/scheduler"
            if [[ -f "$sched_file" ]]; then
                local sched_content
                sched_content=$(<"$sched_file")

                # Check if none is active
                if [[ "$sched_content" == *"[none]"* ]]; then
                    log_skip "none scheduler already active for $dev"
                elif [[ "$sched_content" == *"none"* ]]; then
                    # shellcheck disable=SC2015
                    echo "none" > "$sched_file" 2>/dev/null && log_pass "none scheduler set for $dev" || log_warn "Failed to set none scheduler for $dev"
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

    # 4. Tmpfs for temporary files
    if grep -qE "\s/tmp\s+tmpfs" "$fstab_file"; then
        log_skip "/tmp already in tmpfs"
    else
        echo "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,size=512M 0 0" >> "$fstab_file"
        log_pass "/tmp moved to tmpfs"
    fi

    if grep -qE "\s/var/tmp\s+tmpfs" "$fstab_file"; then
        log_skip "/var/tmp already in tmpfs"
    else
        echo "tmpfs /var/tmp tmpfs defaults,noatime,nosuid,nodev,size=256M 0 0" >> "$fstab_file"
        log_pass "/var/tmp moved to tmpfs"
    fi
}

################################################################################
# 4. Kernel Tuning (Sysctl)
################################################################################

optimize_kernel() {
    log_section "KERNEL TUNING"
    
    local sysctl_conf="/etc/sysctl.d/99-server-optimize.conf"
    local tmp_conf
    tmp_conf=$(mktemp)
    
    cat > "$tmp_conf" << 'EOF'
# Memory Management (Tuned for 16k pages & ZRAM)
vm.dirty_ratio=15
vm.dirty_background_ratio=5
vm.vfs_cache_pressure=50
vm.overcommit_memory=1
vm.min_free_kbytes=131072
vm.dirty_writeback_centisecs=1000
vm.dirty_expire_centisecs=6000

# Network Stack Optimizations
net.core.somaxconn=1024
net.core.netdev_max_backlog=5000
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 87380 16777216
net.ipv4.tcp_max_syn_backlog=4096
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.ip_forward=1

# Docker Networking
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1

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
        mv -f "$tmp_conf" "$sysctl_conf"
        sysctl -p "$sysctl_conf" >/dev/null 2>&1 || log_warn "Some sysctl parameters failed to apply"
        log_pass "Kernel parameters optimized (including BBR & Security)"
    else
        rm "$tmp_conf"
        log_skip "Kernel parameters already optimized"
    fi

    # MGLRU Optimization (if enabled in kernel)
    if [[ -f /sys/kernel/mm/lru_gen/enabled ]]; then
        echo 1000 > /sys/kernel/mm/lru_gen/min_ttl_ms 2>/dev/null || true
        log_pass "MGLRU thrashing threshold optimized"
        
        # Persist MGLRU min_ttl_ms via tmpfiles.d
        local tmpfiles_conf="/etc/tmpfiles.d/sysfs-tuning.conf"
        mkdir -p /etc/tmpfiles.d
        if [[ ! -f "$tmpfiles_conf" ]] || ! grep -q "lru_gen/min_ttl_ms" "$tmpfiles_conf"; then
            echo "w /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 1000" >> "$tmpfiles_conf"
            log_pass "MGLRU thrashing threshold persistence configured"
        fi
    fi

    # Ensure br_netfilter loads at boot (required for Docker bridge sysctl settings)
    # Without this, net.bridge.bridge-nf-call-iptables silently fails on fresh boot
    local netfilter_conf="/etc/modules-load.d/docker-netfilter.conf"
    if [[ ! -f "$netfilter_conf" ]]; then
        echo "br_netfilter" > "$netfilter_conf"
        modprobe br_netfilter 2>/dev/null || true
        log_pass "br_netfilter configured to load at boot (Docker bridge networking)"
    else
        log_skip "br_netfilter already configured"
    fi

    # Apply all sysctl configs
    sysctl --system > /dev/null 2>&1

    # PCIe ASPM & APST Sleep Workarounds to prevent NVMe drive lockups/disconnects
    add_cmdline_param "pcie_aspm=off"
    add_cmdline_param "nvme_core.default_ps_max_latency_us=0"
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
        awk -v root="$root_disk" '/usb|sd|mmc/ && /part/ && !index($0, root) { print $1; exit }')
    
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
      "exec-opts": ["native.cgroupdriver=systemd"],
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
            new_json=$(jq -S -s '.[0] * .[1]' "$docker_config" <(echo "$final_config"))
            
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
    if [[ -z "$(docker ps -a -q -f name='^tailscale$')" ]]; then
        log_skip "Tailscale container not found. Skipping fix."
        return
    fi

    local service_file="/etc/systemd/system/tailscale-fix.service"
    local tmp_service
    tmp_service=$(mktemp)

    # Write desired state to temp file first, then compare for idempotency
    cat > "$tmp_service" << 'EOF'
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

    if files_differ "$service_file" "$tmp_service"; then
        mv -f "$tmp_service" "$service_file"
        systemctl daemon-reload
        log_pass "Tailscale boot fix service updated"
    else
        rm "$tmp_service"
        log_skip "Tailscale boot fix already configured"
    fi

    # Ensure it's enabled regardless (idempotent)
    # shellcheck disable=SC2015
    systemctl enable tailscale-fix.service 2>/dev/null \
        && log_pass "Tailscale boot fix enabled" \
        || log_warn "Failed to enable Tailscale boot fix"
}

################################################################################
# 6. Memory & Swap (ZRAM)
################################################################################

optimize_memory() {
    log_section "MEMORY & SWAP"

    # 1. Disable Disk-based Swap (Permanent for flash, hybrid/overflow for NVMe)
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

    # Explicitly remove any orphaned /var/swap file (may persist even if dphys-swapfile is gone)
    # This reclaims the 2GB the default dphys-swapfile creates on the OS flash drive
    if [[ -f /var/swap ]]; then
        swapoff /var/swap 2>/dev/null || true
        rm -f /var/swap
        log_pass "Orphaned /var/swap file removed (flash space reclaimed)"
    fi

    if [[ "${BOOT_TRAN:-}" == "nvme" ]]; then
        log_info "NVMe boot detected. Configuring 4GB static swapfile for memory overflow..."
        
        # Disable fstab swap entries that are NOT our swapfile
        if grep -E "^[^#].*\sswap\s" /etc/fstab | grep -v "/swapfile" >/dev/null; then
            sed -i '/\/swapfile/! s/\sswap\s/#\0/' /etc/fstab
            log_pass "Non-swapfile fstab entries disabled"
        fi

        # Disable any active non-zram, non-swapfile swaps
        local bad_swaps
        bad_swaps=$(swapon --show --noheadings | grep -v "zram" | grep -v "/swapfile" | awk '{print $1}' || true)
        if [[ -n "$bad_swaps" ]]; then
            echo "$bad_swaps" | xargs -r swapoff 2>/dev/null || true
            log_pass "Active flash/unwanted swap(s) disabled"
        fi

        # Create 4GB swapfile on NVMe if not exists or size is wrong
        local create_swap=false
        if [[ ! -f /swapfile ]]; then
            create_swap=true
        else
            local sf_size
            sf_size=$(du -m /swapfile | cut -f1)
            if [[ $sf_size -lt 4000 ]]; then
                swapoff /swapfile 2>/dev/null || true
                rm -f /swapfile
                create_swap=true
            fi
        fi

        if [[ "$create_swap" == "true" ]]; then
            log_info "Creating 4GB swapfile on NVMe..."
            fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
            chmod 600 /swapfile
            mkswap /swapfile
            log_pass "Swapfile initialized"
        fi

        # Enable swapfile with priority 10
        if swapon --show --noheadings | grep -q "/swapfile"; then
            log_skip "Swapfile already active"
        else
            swapon -p 10 /swapfile 2>/dev/null && log_pass "Swapfile activated (priority 10)" || log_warn "Failed to activate swapfile"
        fi

        # Ensure in fstab
        if grep -q "/swapfile" /etc/fstab; then
            log_skip "Swapfile already configured in fstab"
        else
            echo "/swapfile  none  swap  sw,pri=10,nofail  0  0" >> /etc/fstab
            log_pass "Swapfile configured in fstab"
        fi
    else
        # Disable all disk-based swap for flash media
        local other_swaps
        other_swaps=$(swapon --show --noheadings | grep -v "zram" | awk '{print $1}' || true)
        if [[ -n "$other_swaps" ]]; then
            echo "$other_swaps" | xargs -r swapoff 2>/dev/null || true
            log_pass "Active disk swap(s) disabled"
        fi

        # Disable fstab swap entries
        if grep -E "^[^#].*\sswap\s" /etc/fstab >/dev/null; then
            sed -i '/\sswap\s/ s/^/#/' /etc/fstab
            log_pass "Swap entries in fstab disabled"
        fi
    fi

    # Configure rpi-swap (Raspberry Pi OS Bookworm/Trixie) to use ZRAM only, preventing file writeback
    if [[ -f /etc/rpi/swap.conf ]]; then
        log_info "Configuring rpi-swap to use ZRAM-only mechanism..."
        local rpi_swap_conf="/etc/rpi/swap.conf"
        
        # Disable hybrid swap by switching mechanism to zram
        if grep -q "^Mechanism=zram$" "$rpi_swap_conf"; then
            log_skip "rpi-swap mechanism already configured to zram"
        elif grep -q "^#Mechanism=auto" "$rpi_swap_conf"; then
            sed -i 's/^#Mechanism=auto/Mechanism=zram/' "$rpi_swap_conf"
            log_pass "rpi-swap mechanism configured to zram"
        elif grep -q "^Mechanism=" "$rpi_swap_conf"; then
            sed -i 's/^Mechanism=.*/Mechanism=zram/' "$rpi_swap_conf"
            log_pass "rpi-swap mechanism updated to zram"
        else
            # No Mechanism line exists at all — insert under [Main] section
            sed -i '/^\[Main\]/a Mechanism=zram' "$rpi_swap_conf"
            log_pass "rpi-swap mechanism set to zram under [Main]"
        fi

        # Safely detach loop device if it holds a deleted swap file
        if losetup -a 2>/dev/null | grep -q "/var/swap (deleted)"; then
            log_info "Detaching locked /var/swap (deleted) to reclaim space..."
            
            # 1. Deactivate zram swap (it may have a backing_dev pointing at the loop)
            swapoff /dev/zram0 2>/dev/null || true
            zramctl --reset /dev/zram0 2>/dev/null || true
            
            # 2. Find and detach the specific loop device holding the deleted file
            local loop_dev
            loop_dev=$(losetup -a 2>/dev/null | grep "/var/swap (deleted)" | cut -d: -f1 | head -n1)
            if [[ -n "$loop_dev" ]]; then
                losetup -d "$loop_dev" 2>/dev/null || true
            fi
            
            # 3. Clear any failed state from old units before restarting
            systemctl reset-failed systemd-zram-setup@zram0.service 2>/dev/null || true
            systemctl reset-failed rpi-zram-writeback.timer 2>/dev/null || true
            systemctl reset-failed rpi-setup-loop@var-swap.service 2>/dev/null || true
            
            # 4. Reload generators so they regenerate zram-only config (no loop dependency)
            systemctl daemon-reload
            
            # 5. Start zram device AND activate swap on it
            systemctl start systemd-zram-setup@zram0.service 2>/dev/null || true
            systemctl start dev-zram0.swap 2>/dev/null || true
            
            log_pass "Locked swap file detached, ZRAM restarted, disk space reclaimed"
        fi
    fi

    # 2. ZRAM Setup (systemd-zram-generator)
    log_info "Configuring systemd-zram-generator..."
    
    # Remove zram-tools to avoid conflict
    if command_exists apt-get && dpkg -l | grep -q "zram-tools"; then
        log_info "Removing zram-tools conflict..."
        apt-get purge -y zram-tools >/dev/null 2>&1 || true
    fi

    local zram_conf="/etc/systemd/zram-generator.conf"
    local tmp_zram
    tmp_zram=$(mktemp)

    cat > "$tmp_zram" << 'EOF'
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

    if files_differ "$zram_conf" "$tmp_zram"; then
        mv -f "$tmp_zram" "$zram_conf"
        systemctl daemon-reload
        systemctl start /dev/zram0 2>/dev/null || true
        log_pass "systemd-zram-generator configured (zstd, 50% RAM up to 4G)"
    else
        rm "$tmp_zram"
        log_skip "systemd-zram-generator already configured"
    fi

    # Ensure high swappiness for ZRAM
    local swappiness_file="/etc/sysctl.d/98-zram-swappiness.conf"
    if [[ ! -f "$swappiness_file" ]] || ! grep -q "vm.swappiness=150" "$swappiness_file"; then
        echo "vm.swappiness=150" > "$swappiness_file"
        sysctl -w vm.swappiness=150 >/dev/null 2>&1
        log_pass "Swappiness set to 150 (ZRAM optimization)"
    else
        log_skip "Swappiness already optimized for ZRAM"
    fi

    # 3. Transparent Hugepages (THP) for Valkey/Databases
    # 16k page size systems benefit from 'madvise' to prevent fragmentation
    log_info "Optimizing Transparent Hugepages..."
    if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
        echo "madvise" > /sys/kernel/mm/transparent_hugepage/enabled
        log_pass "THP set to 'madvise' (optimal for Valkey/Redis)"
        
        # Persist THP via tmpfiles.d
        local tmpfiles_conf="/etc/tmpfiles.d/sysfs-tuning.conf"
        mkdir -p /etc/tmpfiles.d
        if [[ ! -f "$tmpfiles_conf" ]] || ! grep -q "transparent_hugepage/enabled" "$tmpfiles_conf"; then
            echo "w /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise" >> "$tmpfiles_conf"
            log_pass "THP persistence configured"
        fi
    fi

    # 4. Continuous Flash Media Protection (Hourly Swap Enforcer)
    local enforcer_script="/usr/local/bin/disk-swap-enforcer"
    local enforcer_service="/etc/systemd/system/disk-swap-enforcer.service"
    local enforcer_timer="/etc/systemd/system/disk-swap-enforcer.timer"

    if [[ "${BOOT_TRAN:-}" == "nvme" ]]; then
        if [[ -f "$enforcer_timer" ]]; then
            log_info "NVMe boot detected. Disabling and removing hourly disk-swap-enforcer..."
            systemctl disable --now disk-swap-enforcer.timer 2>/dev/null || true
            systemctl stop disk-swap-enforcer.service 2>/dev/null || true
            rm -f "$enforcer_script" "$enforcer_service" "$enforcer_timer" 2>/dev/null
            systemctl daemon-reload
            log_pass "Disk-swap-enforcer disabled and removed (unnecessary for NVMe SSD)"
        else
            log_skip "Disk-swap-enforcer is not installed"
        fi
    else
        if [[ ! -f "$enforcer_script" ]]; then
            log_info "Setting up continuous disk swap enforcer..."
            cat > "$enforcer_script" << 'EOF'
#!/bin/bash
# Checks if any disk-based swap has been enabled and turns it off to protect flash media.
# Ignores zram which is RAM-based.
bad_swaps=$(swapon --show --noheadings | grep -v "zram" | awk '{print $1}' || true)
if [[ -n "$bad_swaps" ]]; then
    for s in $bad_swaps; do
        swapoff "$s" 2>/dev/null || true
        logger -p warning -t disk-swap-enforcer "Disabled unauthorized disk swap: $s to protect flash media."
    done
fi
EOF
            chmod +x "$enforcer_script"
        fi

        if [[ ! -f "$enforcer_service" ]]; then
            cat > "$enforcer_service" << 'EOF'
[Unit]
Description=Enforce Flash Media Protection (Disable Disk Swap)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/disk-swap-enforcer
EOF
        fi

        if [[ ! -f "$enforcer_timer" ]]; then
            cat > "$enforcer_timer" << 'EOF'
[Unit]
Description=Run Disk Swap Enforcer Hourly

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF
            systemctl daemon-reload
            if systemctl enable --now disk-swap-enforcer.timer 2>/dev/null; then
                log_pass "Hourly disk swap enforcer configured and activated"
            else
                log_warn "Failed to enable disk-swap-enforcer timer"
            fi
        else
            log_skip "Disk swap enforcer already configured"
        fi
    fi
}

################################################################################
# 7. Log Management
################################################################################

optimize_logs() {
    log_section "LOG MANAGEMENT"

    if [[ "${BOOT_TRAN:-}" == "nvme" ]]; then
        # On NVMe boot, we want persistent journaling and logging
        local journal_conf="/etc/systemd/journald.conf.d/optimize.conf"
        if [[ -f "$journal_conf" ]]; then
            log_info "NVMe boot detected. Restoring persistent journald logging..."
            rm -f "$journal_conf"
            systemctl restart systemd-journald
            log_pass "Journald volatile override removed (logs are now persistent)"
        else
            log_skip "Journald logging is already persistent"
        fi
        
        # If busybox-syslogd is installed, purge it and install rsyslog to restore persistent syslog
        if command_exists dpkg && dpkg -l | grep -q "busybox-syslogd"; then
            log_info "NVMe boot detected. Removing busybox-syslogd and restoring rsyslog for persistent syslog..."
            apt-get purge -y busybox-syslogd >/dev/null 2>&1 || true
            rm -f /etc/syslog.conf 2>/dev/null || true
            apt-get install -y rsyslog >/dev/null 2>&1 || true
            systemctl restart rsyslog 2>/dev/null || true
            log_pass "Syslog restored to persistent rsyslog"
        fi
        return
    fi

    # Journald volatile storage (for non-NVMe boot)
    local journal_conf_dir="/etc/systemd/journald.conf.d"
    local journal_conf="${journal_conf_dir}/optimize.conf"
    local tmp_conf
    tmp_conf=$(mktemp)
    
    mkdir -p "$journal_conf_dir"
    cat > "$tmp_conf" << 'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=64M
RuntimeMaxFileSize=8M
Compress=yes
EOF

    if files_differ "$journal_conf" "$tmp_conf"; then
        mv -f "$tmp_conf" "$journal_conf"
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
            models_dir=$(awk -F'OLLAMA_MODELS=' '/OLLAMA_MODELS=/ {gsub(/"/, "", $2); print $2; exit}' "$override_file")
            [ -z "$models_dir" ] && models_dir="/mnt/usb/ollama"
            
            if ! grep -q "RequiresMountsFor" "$override_file" || ! grep -q "OLLAMA_NUM_PARALLEL" "$override_file"; then
                log_info "Applying optimizations & boot-order fix to Ollama..."
                # Extract existing Environment vars, filtering out ones we are about to add/enforce
                local envs
                envs=$(sed -nE '/Environment=/ { /OLLAMA_NUM_PARALLEL|OLLAMA_FLASH_ATTENTION|OLLAMA_KV_CACHE_TYPE|OLLAMA_MAX_LOADED_MODELS/!p }' "$override_file")
                
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
# 8. SMART Daemon Configuration
################################################################################

optimize_smartd() {
    log_section "SMART DAEMON (smartd)"

    if ! command_exists smartd; then
        log_skip "smartmontools not installed"
        return
    fi

    local smartd_defaults="/etc/default/smartmontools"
    if [[ ! -f "$smartd_defaults" ]]; then
        log_warn "$smartd_defaults not found - skipping smartd configuration"
        return
    fi

    # Use -q never so smartd doesn't exit when no SMART-capable devices are found.
    # USB bridges (e.g. SanDisk USB enclosures) report SCSI rather than ATA SMART,
    # causing smartd to exit with status 17 ("No devices to monitor") which makes
    # the smartmontools.service fail at boot.
    if grep -q "^smartd_opts" "$smartd_defaults"; then
        log_skip "smartd_opts already configured"
    else
        backup_file "$smartd_defaults"
        sed -i 's/^#smartd_opts=.*/smartd_opts="-q never"/' "$smartd_defaults"
        # shellcheck disable=SC2015
        systemctl restart smartmontools 2>/dev/null \
            && log_pass "smartd configured with -q never (survives USB SMART limitations)" \
            || log_warn "smartd restart failed - will apply on next boot"
    fi
}

################################################################################
# 8b. EEPROM Bootloader Configuration
################################################################################

optimize_eeprom() {
    log_section "EEPROM BOOTLOADER CONFIG"
    if ! command_exists rpi-eeprom-config; then
        log_skip "rpi-eeprom-config tool not available"
        return
    fi

    # Check for updates
    log_info "Checking for EEPROM bootloader updates..."
    if rpi-eeprom-update -a >/dev/null 2>&1; then
        log_pass "Bootloader firmware updated/verified"
    else
        log_warn "Bootloader update check skipped or failed"
    fi

    # Modify EEPROM settings
    local current_config
    current_config=$(rpi-eeprom-config)
    local need_update=false
    local new_config_file
    new_config_file=$(mktemp)
    echo "$current_config" > "$new_config_file"

    # Ensure PCIE_PROBE=1
    if ! grep -q "^PCIE_PROBE=" "$new_config_file"; then
        echo "PCIE_PROBE=1" >> "$new_config_file"
        need_update=true
        log_info "Adding PCIE_PROBE=1 to EEPROM config"
    fi

    # Ensure BOOT_ORDER is 0xf416 (prioritizes NVMe boot, bypasses USB checks on fallback)
    if ! grep -q "^BOOT_ORDER=" "$new_config_file"; then
        echo "BOOT_ORDER=0xf416" >> "$new_config_file"
        need_update=true
        log_info "Setting BOOT_ORDER=0xf416 in EEPROM config"
    else
        local current_order
        current_order=$(grep "^BOOT_ORDER=" "$new_config_file" | cut -d= -f2)
        if [[ "$current_order" != "0xf416" ]]; then
            sed -i 's/^BOOT_ORDER=.*/BOOT_ORDER=0xf416/' "$new_config_file"
            need_update=true
            log_info "Updating BOOT_ORDER to 0xf416 to prioritize NVMe boot"
        fi
    fi

    # Ensure POWER_OFF_ON_HALT=1 to minimize idle wattage
    if ! grep -q "^POWER_OFF_ON_HALT=" "$new_config_file"; then
        echo "POWER_OFF_ON_HALT=1" >> "$new_config_file"
        need_update=true
        log_info "Adding POWER_OFF_ON_HALT=1 to EEPROM config"
    else
        local current_poh
        current_poh=$(grep "^POWER_OFF_ON_HALT=" "$new_config_file" | cut -d= -f2)
        if [[ "$current_poh" != "1" ]]; then
            sed -i 's/^POWER_OFF_ON_HALT=.*/POWER_OFF_ON_HALT=1/' "$new_config_file"
            need_update=true
            log_info "Updating POWER_OFF_ON_HALT to 1 in EEPROM config"
        fi
    fi

    # Ensure BOOT_UART=1 to preserve components when halted
    if ! grep -q "^BOOT_UART=" "$new_config_file"; then
        echo "BOOT_UART=1" >> "$new_config_file"
        need_update=true
        log_info "Adding BOOT_UART=1 to EEPROM config"
    else
        local current_bu
        current_bu=$(grep "^BOOT_UART=" "$new_config_file" | cut -d= -f2)
        if [[ "$current_bu" != "1" ]]; then
            sed -i 's/^BOOT_UART=.*/BOOT_UART=1/' "$new_config_file"
            need_update=true
            log_info "Updating BOOT_UART to 1 in EEPROM config"
        fi
    fi

    if [[ "$need_update" == "true" ]]; then
        backup_file "/etc/default/rpi-eeprom-update" 2>/dev/null || true
        if rpi-eeprom-config --apply "$new_config_file" >/dev/null 2>&1; then
            log_pass "EEPROM configuration updated successfully"
        else
            log_warn "Failed to apply EEPROM configuration. Manual check required."
        fi
    else
        log_skip "EEPROM configuration already optimized"
    fi
    rm -f "$new_config_file"
}

################################################################################
# 9. Maintenance & Security
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
        # Disable logging to save flash
        ufw logging off >/dev/null
        echo "y" | ufw enable >/dev/null
        log_pass "Firewall (UFW) configured (logging disabled)"
    fi

    log_info "Removing documentation to save space..."
    rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* 2>/dev/null || true
    log_pass "Documentation cleared"

    # Clean user-level caches that accumulate on the OS flash drive
    local target_user
    target_user="${SUDO_USER:-}"
    [[ -z "$target_user" ]] && target_user=$(id -nu 1000 2>/dev/null || echo "")

    if [[ -n "$target_user" && "$target_user" != "root" ]]; then
        local target_home
        target_home=$(getent passwd "$target_user" | cut -d: -f6)

        # Clean uv cache (Python tool manager for MCP servers)
        local uv_bin="${target_home}/.local/bin/uv"
        if [[ -f "$uv_bin" ]]; then
            log_info "Cleaning uv cache..."
            # shellcheck disable=SC2015
            sudo -u "$target_user" "$uv_bin" cache clean --quiet 2>/dev/null \
                && log_pass "uv cache cleaned" \
                || log_warn "uv cache clean failed"
        fi

        # Clean npm cache (prune stale packages, not full wipe to preserve build speed)
        if command_exists npm; then
            log_info "Cleaning npm cache..."
            # shellcheck disable=SC2015
            sudo -u "$target_user" npm cache verify --quiet 2>/dev/null \
                && log_pass "npm cache verified and pruned" \
                || log_warn "npm cache clean failed"
        fi
    fi
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
    
    # Boot Drive Detection
    local boot_dev
    boot_dev=$(findmnt -n -o SOURCE /)
    local parent_dev
    parent_dev=$(lsblk -nd -o PKNAME -p "$boot_dev" 2>/dev/null)
    [[ -z "$parent_dev" ]] && parent_dev="$boot_dev"
    BOOT_TRAN=$(lsblk -nd -o TRAN "$parent_dev" 2>/dev/null)
    
    echo -e "${MAGENTA}"
    echo "██████╗ ██████╗ ██╗    ██████╗ ██████╗ ████████╗██╗███╗   ███╗██╗███████╗███████╗"
    echo "██╔══██╗██╔══██╗██║    ██╔══██╗██╔══██╗╚══██╔══╝██║████╗ ████║██║╚══███╔╝██╔════╝"
    echo "██████╔╝██████╔╝██║    ██║  ██║██████╔╝   ██║   ██║██╔████╔██║██║  ███╔╝ █████╗  "
    echo "██╔══██╗██╔═══╝ ██║    ██║  ██║██╔═══╝    ██║   ██║██║╚██╔╝██║██║ ███╔╝  ██╔══╝  "
    echo "██║  ██║██║     ██║    ██████╔╝██║        ██║   ██║██║ ╚═╝ ██║██║███████╗███████╗"
    echo "╚═╝  ╚═╝╚═╝     ╚═╝    ╚═════╝ ╚═╝        ╚═╝   ╚═╝╚═╝     ╚═╝╚═╝╚══════╝╚══════╝"
    echo -e "${NC}"
    log_info "RPI SERVER OPTIMIZER v${SCRIPT_VERSION}"
    if [[ "$BOOT_TRAN" == "usb" ]]; then
        log_info "Boot Drive: USB Flash/SSD detected. Applying flash-wear optimizations."
    elif [[ "$BOOT_TRAN" == "nvme" ]]; then
        log_info "Boot Drive: NVMe SSD detected. Keeping persistent logging."
    else
        log_info "Boot Drive: ${BOOT_TRAN:-Unknown}. Applying standard flash-wear optimizations."
    fi
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
    optimize_smartd
    optimize_ollama_service
    optimize_eeprom
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