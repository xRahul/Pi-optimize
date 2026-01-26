#!/bin/bash

################################################################################
# Raspberry Pi Home Server Setup - ULTIMATE EDITION
# Target: Raspberry Pi OS Debian Trixie (aarch64)
# Features: Docker, Node.js, USB Mounting, Hardening, Optimizations
# License: MIT (Copyright 2025 Rahul)
################################################################################

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

# --- Constants ---
SCRIPT_VERSION="4.2.1"
# shellcheck disable=SC2034
USB_MOUNT_PATH="/mnt/usb"
# CONFIG_FILE="/boot/firmware/config.txt" # Unused in setup.sh directly, used in optimize.sh
# BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S) # Unused in setup.sh

# --- Helper Functions ---

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo "  -v, --version Show script version"
}

wait_for_apt_lock() {
    local locks=("/var/lib/dpkg/lock-frontend" "/var/lib/dpkg/lock" "/var/lib/apt/lists/lock")
    local i=0
    
    for lock in "${locks[@]}"; do
        while fuser "$lock" >/dev/null 2>&1; do
            if [ $i -eq 0 ]; then
                log_info "Waiting for apt lock release..."
            fi
            sleep 1
            ((i++))
            if [ $i -gt 300 ]; then
                log_error "Timed out waiting for apt lock. Is another install running?"
            fi
        done
    done
}

get_target_user() {
    local target_user="${SUDO_USER:-}"
    if [[ -z "$target_user" ]]; then
        target_user=$(id -nu 1000 2>/dev/null || echo "$USER")
        log_warn "SUDO_USER not set. Defaulting to user: $target_user"
    fi
    echo "$target_user"
}

################################################################################
# 1. Pre-flight Checks
################################################################################

preflight_checks() {
    log_section "PRE-FLIGHT CHECKS"
    
    if [[ ! -f /etc/os-release ]]; then
        log_error "OS release unknown"
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    log_info "OS: ${PRETTY_NAME:-Unknown}"
    
    [[ "$(uname -m)" != "aarch64" ]] && log_error "64-bit ARM required"
    log_pass "Architecture: aarch64"
    
    ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 || log_error "Internet required"
    log_pass "Connectivity: OK"

    # Boot Drive Detection
    local boot_dev
    boot_dev=$(findmnt -n -o SOURCE /)
    # Get parent disk if partition, otherwise use device itself. Use -d to suppress children, -p for full path.
    local parent_dev
    parent_dev=$(lsblk -nd -o PKNAME -p "$boot_dev" 2>/dev/null)
    [[ -z "$parent_dev" ]] && parent_dev="$boot_dev"
    local boot_tran
    boot_tran=$(lsblk -nd -o TRAN "$parent_dev" 2>/dev/null)
    
    if [[ "$boot_tran" == "usb" ]]; then
        log_pass "Boot Drive: USB Flash/SSD detected"
    else
        log_warn "Boot Drive: ${boot_tran:-Unknown} (Not USB). Ensure you are booting from your flash drive for best performance."
    fi
}

################################################################################
# 2. System Core
################################################################################

system_core() {
    log_section "SYSTEM CORE"
    
    wait_for_apt_lock
    # shellcheck disable=SC2015
    apt-get update && apt-get full-upgrade -y || log_error "Apt upgrade failed"
    log_pass "System updated"
    
    local packages=(
        "ca-certificates" "curl" "gnupg" "git" "jq" "bc" 
        "usbutils" "util-linux" "watchdog" "e2fsprogs" 
        "smartmontools" "cpufrequtils" "zram-tools" "fail2ban" "ufw"
        "htop" "vim" "tmux" "net-tools" "lsb-release" "rng-tools5"
        "busybox-syslogd"
    )
    
    # Optimize: Bulk check installed packages
    declare -A installed_map
    # shellcheck disable=SC2034
    while IFS=' ' read -r status name; do
        if [[ "$status" == "ii" ]]; then
            installed_map["$name"]=1
        fi
    done < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null)

    for pkg in "${packages[@]}"; do
        if [[ -n "${installed_map[$pkg]:-}" ]]; then
            log_skip "$pkg already installed"
            continue
        fi

        # Specific conflict checks
        if [[ "$pkg" == "busybox-syslogd" ]]; then
             if [[ -n "${installed_map[rsyslog]:-}" ]]; then
                 log_warn "Skipping $pkg: rsyslog detected (conflict)"
                 continue
             fi
        fi

        log_info "Installing $pkg..."
        apt-get install -y "$pkg" || log_warn "Failed: $pkg"
    done
    log_pass "Core dependencies installed"
}

################################################################################
# 3. Docker Suite
################################################################################

docker_suite() {
    log_section "DOCKER SUITE"
    
    if ! command_exists docker; then
        curl -fsSL https://get.docker.com | sh || log_error "Docker install failed"
    fi
    log_pass "Docker installed: $(docker --version)"
    
    systemctl enable --now docker
    
    local target_user
    target_user=$(get_target_user)

    if [[ "$target_user" != "root" ]]; then
        usermod -aG docker "$target_user" && log_pass "User $target_user added to docker group"
    else
         log_skip "Skipping docker group add for root"
    fi
}

################################################################################
# 4. Node.js & Tooling
################################################################################

nodejs_tooling() {
    log_section "NODE.JS & TOOLING"
    
    if ! command_exists node; then
        curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
        apt-get install -y nodejs
    fi
    log_pass "Node.js: $(node -v)"
    
    # Global npm config for non-root
    local target_user
    target_user=$(get_target_user)

    if [[ "$target_user" != "root" ]]; then
        local target_home
        target_home=$(getent passwd "$target_user" | cut -d: -f6)
        local npm_global="$target_home/.npm-global"
        mkdir -p "$npm_global"
        chown -R "$target_user" "$npm_global"
        sudo -u "$target_user" npm config set prefix "$npm_global"
        
        if ! grep -q ".npm-global/bin" "$target_home/.bashrc"; then
            # shellcheck disable=SC2016
            echo 'export PATH=~/.npm-global/bin:$PATH' >> "$target_home/.bashrc"
        fi
        log_pass "npm global prefix configured"
    fi
}

################################################################################
# 5. Ollama (Optional AI)
################################################################################

install_ollama() {
    log_section "OLLAMA AI (OPTIONAL)"

    echo -e "${YELLOW}Ollama allows running Large Language Models (LLMs) locally on your Pi 5.${NC}"
    echo -e "On Raspberry Pi 5, it utilizes the CPU (Cortex-A76) for inference."

    local proceed_config=false

    if command_exists ollama; then
        log_info "Ollama is already installed: $(ollama --version)"
        proceed_config=true
    else
        if confirm_action "Install Ollama Native (Warning: High CPU/RAM usage when active)?"; then
            log_info "Downloading and installing Ollama..."
            if curl -fsSL https://ollama.com/install.sh | sh; then
                log_pass "Ollama installed successfully"
                systemctl enable ollama
                proceed_config=true
            else
                log_warn "Ollama installation failed. Continuing with setup..."
            fi
        else
            log_skip "Skipping Ollama installation"
        fi
    fi

    # --- Optimizations & Configuration ---
    if [ "$proceed_config" = true ]; then
        log_info "Checking Ollama configuration..."
        local override_dir="/etc/systemd/system/ollama.service.d"
        local override_file="${override_dir}/override.conf"
        local models_dir="/usr/share/ollama/.ollama/models" # Default
        local bind_addr="127.0.0.1"
        local optimize_config=false

        # Extract existing values if they exist
        if [ -f "$override_file" ]; then
            models_dir=$(grep "OLLAMA_MODELS=" "$override_file" | cut -d'=' -f2 | tr -d '"' || echo "$models_dir")
            bind_addr=$(grep "OLLAMA_HOST=" "$override_file" | cut -d'=' -f2 | tr -d '"' || echo "$bind_addr")
        fi

        # 1. Storage Optimization (Critical for SD cards)
        if mountpoint -q /mnt/usb; then
            if [[ "$models_dir" == "/mnt/usb"* ]]; then
                log_skip "Ollama storage already configured for USB ($models_dir)"
            else
                echo -e "${GREEN}USB drive detected at /mnt/usb.${NC}"
                if confirm_action "Store Ollama models on USB drive (Highly Recommended)?"; then
                    models_dir="/mnt/usb/ollama"
                    mkdir -p "$models_dir"
                    # Ensure ollama user exists (installer should have created it)
                    chown ollama:ollama "$models_dir" 2>/dev/null || true

                    # Fix: Use detected target user instead of hardcoded 'rahul'
                    local target_user
                    target_user=$(get_target_user)
                    if [[ -n "$target_user" && "$target_user" != "root" ]]; then
                         usermod -aG "$target_user" ollama 2>/dev/null || true
                    fi

                    log_pass "Model storage configured: $models_dir"
                    optimize_config=true
                fi
            fi
        fi

        # 2. Network Optimization
        if [[ "$bind_addr" == "0.0.0.0" ]]; then
             log_skip "Ollama already exposed to network (0.0.0.0)"
        else
            if confirm_action "Expose Ollama to local network (0.0.0.0) for external access/Docker UI?"; then
                bind_addr="0.0.0.0"
                log_pass "Bind address set to 0.0.0.0"
                optimize_config=true
            fi
        fi

        # 3. Performance Optimizations (Idempotency check)
        if ! grep -q "OLLAMA_NUM_PARALLEL" "$override_file" 2>/dev/null; then
            log_info "New performance optimizations pending..."
            optimize_config=true
        fi

        # Apply Systemd Overrides if needed
        if [ "$optimize_config" = true ]; then
            mkdir -p "$override_dir"
            cat > "$override_file" <<EOF
[Unit]
After=network-online.target
RequiresMountsFor=${models_dir}

[Service]
Environment="OLLAMA_MODELS=${models_dir}"
Environment="OLLAMA_HOST=${bind_addr}"
Environment="OLLAMA_KEEP_ALIVE=5m"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q4_0"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
EOF
            log_pass "Systemd override configured"
            systemctl daemon-reload
            systemctl restart ollama
        fi
        
        # Verification
        if systemctl is-active --quiet ollama; then
            log_pass "Ollama service active"
        else
            log_warn "Ollama service failed to restart. Check 'systemctl status ollama'"
        fi
    fi
}

################################################################################
# 6. USB & Optimization
################################################################################

usb_optimization() {
    log_section "USB & OPTIMIZATION"
    
    # Prepare USB mount directory
    local mount_path="${USB_MOUNT_PATH}"
    if [[ ! -d "$mount_path" ]]; then
        mkdir -p "$mount_path"
        log_pass "Mount directory created: $mount_path"
    else
        log_skip "Mount directory already exists: $mount_path"
    fi
    
    # Run optimize.sh for system-wide tuning
    if [[ -f "${SCRIPT_DIR}/optimize.sh" ]]; then
        chmod +x "${SCRIPT_DIR}/optimize.sh"
        log_info "Running optimize.sh..."
        "${SCRIPT_DIR}/optimize.sh" || log_warn "optimize.sh encountered issues but continuing"
        log_pass "Optimizations applied"
    else
        log_error "optimize.sh not found in directory: ${SCRIPT_DIR}"
    fi
    
    # Verify USB mount was configured
    if grep -q "$mount_path" /etc/fstab; then
        log_pass "USB mount verified in fstab"
    else
        log_warn "USB mount not found in fstab - may need manual configuration"
    fi

    # Configure forced mount on startup (runs before Docker)
    local service_file="/etc/systemd/system/startup-mounts.service"
    
    # Check if service exists and has correct content (simple check)
    if [[ -f "$service_file" ]] && grep -q "Before=docker.service" "$service_file"; then
        log_skip "Startup mount service already configured"
    else
        log_info "Configuring startup mount service..."
        cat > "$service_file" << 'EOF'
[Unit]
Description=Force Mount All Filesystems
After=local-fs.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/mount -a
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        log_pass "Startup mount service created"
        systemctl daemon-reload
    fi

    if systemctl is-enabled --quiet startup-mounts.service; then
        log_skip "Startup mount service already enabled"
    else
        if systemctl enable startup-mounts.service 2>/dev/null; then
            log_pass "Startup mount service enabled"
        else
            log_warn "Failed to enable startup-mounts.service"
        fi
    fi
}

################################################################################
# Main
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
    preflight_checks
    system_core
    docker_suite
    nodejs_tooling
    usb_optimization
    install_ollama
    
    # Post-setup verification and reload
    if systemctl daemon-reload 2>/dev/null; then
        log_pass "Systemd daemon reloaded"
    fi
    
    # Try to mount all filesystems from fstab (non-blocking)
    mount -a 2>/dev/null || log_warn "Some mounts failed (may be expected)"
    
    log_section "SETUP COMPLETE"
    echo -e "${GREEN}✓ Raspberry Pi Home Server configured!${NC}"
    log_info "Applied Optimizations:"
    log_info "  • Hardware thermals & performance tuning"
    log_info "  • Docker container runtime with USB storage"
    log_info "  • Node.js development environment"
    log_info "  • System hardening & security"
    log_info "  • Automatic USB mounting on boot"
    log_info "  • Log files: /var/log/rpi-optimize.log"
    echo ""
    log_warn "⚠️  REBOOT IS REQUIRED TO APPLY ALL CHANGES"
    
    if confirm_action "Reboot now?"; then
        log_info "Rebooting in 10 seconds... (Press Ctrl+C to cancel)"
        sleep 10
        reboot
    else
        log_info "Setup complete. Run 'sudo reboot' when ready."
    fi
}

main "$@"
