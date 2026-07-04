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
SCRIPT_VERSION="4.6.0"
# shellcheck disable=SC2034
USB_MOUNT_PATH="/mnt/usb"
BOOT_TRAN=""
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

# Target user is now resolved via get_target_user in lib/utils.sh

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
    BOOT_TRAN=$(lsblk -nd -o TRAN "$parent_dev" 2>/dev/null)
    
    if [[ "$BOOT_TRAN" == "usb" ]]; then
        log_pass "Boot Drive: USB Flash/SSD detected"
        log_info "Flash wear-level optimizations (RAM logging, delayed writebacks, adjusted commit intervals) will be applied."
    elif [[ "$BOOT_TRAN" == "nvme" ]]; then
        log_pass "Boot Drive: NVMe SSD detected"
        log_info "High-performance SSD boot drive. Standard persistent logging will be configured."
    else
        log_warn "Boot Drive: ${BOOT_TRAN:-Unknown} (Not USB/NVMe). Flash wear-level optimizations will still be configured for media safety."
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

    if command_exists rpi-eeprom-update; then
        log_info "Checking for bootloader EEPROM updates..."
        rpi-eeprom-update -a || log_warn "EEPROM update failed or no update available"
    fi
    
    local packages=(
        "ca-certificates" "curl" "gnupg" "git" "jq" "bc" 
        "usbutils" "util-linux" "watchdog" "e2fsprogs" 
        "smartmontools" "cpufrequtils" "systemd-zram-generator" "fail2ban" "ufw"
        "htop" "vim" "tmux" "net-tools" "lsb-release" "rng-tools5"
        "bats" "network-manager" "ethtool" "zsh"
    )
    if [[ "${BOOT_TRAN:-}" == "nvme" ]]; then
        packages+=("rsyslog" "nvme-cli")
    else
        packages+=("busybox-syslogd")
    fi
    
    # Optimize: Bulk check installed packages
    declare -A installed_map
    # shellcheck disable=SC2034
    while IFS=' ' read -r status name; do
        if [[ "$status" == "ii" ]]; then
            installed_map["$name"]=1
        fi
    done < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null)

    # If booting from NVMe, ensure busybox-syslogd is purged to prevent conflicts
    if [[ "${BOOT_TRAN:-}" == "nvme" ]]; then
        if [[ -n "${installed_map[busybox-syslogd]:-}" ]]; then
            log_info "Removing busybox-syslogd on NVMe boot drive to enable persistent logging..."
            apt-get purge -y busybox-syslogd >/dev/null 2>&1 || true
            rm -f /etc/syslog.conf 2>/dev/null || true
            log_pass "busybox-syslogd removed"
        fi
    fi

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
        log_info "Installing Node.js LTS via NodeSource..."
        # NodeSource manual installation (modern way)
        wait_for_apt_lock
        apt-get update
        apt-get install -y ca-certificates curl gnupg
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
        
        # Node 22 (Jod) is the current LTS as of 2025/2026
        local node_major="22"
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${node_major}.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
        
        apt-get update
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
# 6. Python Tooling (uv)
################################################################################

install_uv_tooling() {
    log_section "PYTHON TOOLING (uv)"

    local target_user
    target_user=$(get_target_user)
    local target_home
    target_home=$(getent passwd "$target_user" | cut -d: -f6)
    local uv_bin="${target_home}/.local/bin/uv"

    if [[ -f "$uv_bin" ]]; then
        local uv_ver
        uv_ver=$(sudo -u "$target_user" "$uv_bin" self version 2>/dev/null || echo "unknown")
        log_skip "uv already installed: ${uv_ver}"
        return
    fi

    if [[ "$target_user" == "root" ]]; then
        log_warn "Running as root without SUDO_USER set — skipping uv install (requires a non-root user home)"
        return
    fi

    log_info "Installing uv Python tool manager for user $target_user..."
    if sudo -u "$target_user" bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'; then
        log_pass "uv installed for $target_user"
        # Add ~/.local/bin to PATH if not already present
        if ! grep -q '.local/bin' "${target_home}/.bashrc"; then
            # shellcheck disable=SC2016
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${target_home}/.bashrc"
            log_pass ".local/bin added to PATH in .bashrc"
        else
            log_skip ".local/bin already in .bashrc PATH"
        fi
    else
        log_warn "uv installation failed — MCP Python servers may not work"
    fi
}

################################################################################
# 6. Zsh & Oh My Zsh Suite
################################################################################

install_zsh_suite() {
    log_section "ZSH & OH MY ZSH SUITE"

    local target_user
    target_user=$(get_target_user)
    local target_home
    target_home=$(getent passwd "$target_user" | cut -d: -f6)

    # 1. Ensure Zsh package is installed
    if ! command_exists zsh; then
        log_info "Installing Zsh..."
        wait_for_apt_lock
        apt-get install -y zsh || log_error "Failed to install Zsh"
    else
        log_skip "Zsh already installed"
    fi

    # 2. Oh My Zsh installation
    local omz_dir="${target_home}/.oh-my-zsh"
    if [[ -d "$omz_dir" ]]; then
        log_skip "Oh My Zsh already installed at $omz_dir"
    else
        log_info "Installing Oh My Zsh for user $target_user..."
        if sudo -u "$target_user" RUNZSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended; then
            log_pass "Oh My Zsh installed successfully"
        else
            log_warn "Oh My Zsh installation failed"
        fi
    fi

    # 3. Custom plugins installation
    local custom_plugin_dir="${omz_dir}/custom/plugins"
    mkdir -p "$custom_plugin_dir"
    chown "$target_user:$target_user" "$custom_plugin_dir"

    # Clone zsh-syntax-highlighting
    if [[ -d "${custom_plugin_dir}/zsh-syntax-highlighting" ]]; then
        log_skip "zsh-syntax-highlighting already installed"
    else
        log_info "Cloning zsh-syntax-highlighting..."
        if sudo -u "$target_user" git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "${custom_plugin_dir}/zsh-syntax-highlighting"; then
            log_pass "zsh-syntax-highlighting cloned"
        else
            log_warn "Failed to clone zsh-syntax-highlighting"
        fi
    fi

    # Clone zsh-autosuggestions
    if [[ -d "${custom_plugin_dir}/zsh-autosuggestions" ]]; then
        log_skip "zsh-autosuggestions already installed"
    else
        log_info "Cloning zsh-autosuggestions..."
        if sudo -u "$target_user" git clone https://github.com/zsh-users/zsh-autosuggestions "${custom_plugin_dir}/zsh-autosuggestions"; then
            log_pass "zsh-autosuggestions cloned"
        else
            log_warn "Failed to clone zsh-autosuggestions"
        fi
    fi

    # 4. Write custom .zshrc
    local zshrc_file="${target_home}/.zshrc"
    if [[ -f "$zshrc_file" ]]; then
        log_info "Backing up existing .zshrc to .zshrc.bak..."
        backup_file "$zshrc_file"
    fi

    log_info "Writing custom .zshrc configuration..."
    cat > "$zshrc_file" << 'EOF'
# Keep lengthy history
HISTSIZE=100000
SAVEHIST=100000
HISTFILE=~/.zsh_history

# Write commands to history immediately and share across sessions
setopt INC_APPEND_HISTORY
setopt SHARE_HISTORY

# Path to your Oh My Zsh installation.
export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="amuse"

# Disable automatic update checks (optimize.sh sets this, setup.sh sets default reminder)
zstyle ':omz:update' mode reminder

# Custom plugins list
plugins=(git node npm sudo colored-man-pages history zsh-autosuggestions zsh-syntax-highlighting)

source $ZSH/oh-my-zsh.sh

# User configuration
export PATH="$HOME/bin:$HOME/.local/bin:$PATH"

# Node global prefix path (added during setup)
export PATH="$HOME/.npm-global/bin:$PATH"

# Environment variables
export NVM_DIR="$HOME/.nvm"
export COLORTERM=truecolor
export TERM=xterm-256color

# Android SDK & Java 21
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
export ANDROID_HOME=$HOME/android-sdk
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$JAVA_HOME/bin
export PATH="$PATH:$HOME/flutter/bin"

# Added by Antigravity CLI installer
export PATH="/home/rahul/.local/bin:$PATH"

alias pbcopy='clip.exe'
alias pbpaste='powershell.exe -Command "Get-Clipboard" | tr -d "\r"'

# Antigravity CLI Verbose & Debug Config
export OPENCODE_ANTIGRAVITY_DEBUG=2
export DEBUG=1
export VERBOSE=1

# bun completions
[ -s "$HOME/.bun/_bun" ] && source "$HOME/.bun/_bun"

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
export SYSTEMD_EDITOR=vim

# >>> tokless path >>>
# Adds tokless tool bin dirs to PATH (rtk, bun, cargo).
for d in "$HOME/.local/bin" "$HOME/.bun/bin" "$HOME/.cargo/bin"; do
  [ -d "$d" ] && case ":$PATH:" in *":$d:"*) ;; *) PATH="$PATH:$d" ;; esac
done
export PATH
# <<< tokless path <<<

export ANTHROPIC_BASE_URL=http://localhost:11434
export ANTHROPIC_AUTH_TOKEN=ollama
export ANTHROPIC_API_KEY=""
EOF

    chown "$target_user:$target_user" "$zshrc_file"
    log_pass ".zshrc successfully written and owned by $target_user"

    # 5. Change default shell to Zsh for target user
    local current_shell
    current_shell=$(getent passwd "$target_user" | cut -d: -f7)
    if [[ "$current_shell" != *"/zsh" ]]; then
        log_info "Changing default shell to Zsh for $target_user..."
        if chsh -s /bin/zsh "$target_user"; then
            log_pass "Default shell changed to /bin/zsh"
        else
            log_warn "Failed to change shell using chsh"
        fi
    else
        log_skip "Zsh is already the default shell"
    fi
}

################################################################################
# 7. USB & Optimization
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

configure_syncthing() {
    log_section "SYNCTHING CONTROL CONFIGURATION"
    local target_user
    target_user=$(get_target_user)
    local target_home
    target_home=$(getent passwd "$target_user" | cut -d: -f6)

    # Disable systemd user service autostart for target_user
    log_info "Disabling Syncthing systemd user service autostart..."
    if command_exists systemctl; then
        # Disable globally for systemd user scope so new/all sessions don't trigger it automatically
        systemctl --global disable syncthing.service 2>/dev/null || true
        # Disable for current target_user specifically
        sudo -u "$target_user" XDG_RUNTIME_DIR="/run/user/$(id -u "$target_user")" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$target_user")/bus" systemctl --user disable syncthing.service 2>/dev/null || true
        log_pass "Syncthing autostart disabled (running instances left active)"
    fi

    # Create start script
    local start_script="${target_home}/start_syncthing.sh"
    log_info "Creating start_syncthing.sh..."
    cat > "$start_script" << 'EOF'
#!/bin/bash
systemctl --user start syncthing.service
if systemctl --user is-active --quiet syncthing.service; then
    echo "Syncthing service started successfully."
else
    echo "Failed to start Syncthing service."
    exit 1
fi
EOF
    chmod +x "$start_script"
    chown "$target_user:$target_user" "$start_script"
    log_pass "Created $start_script"

    # Create stop script
    local stop_script="${target_home}/stop_syncthing.sh"
    log_info "Creating stop_syncthing.sh..."
    cat > "$stop_script" << 'EOF'
#!/bin/bash
systemctl --user stop syncthing.service
if ! systemctl --user is-active --quiet syncthing.service; then
    echo "Syncthing service stopped successfully."
else
    echo "Failed to stop Syncthing service."
    exit 1
fi
EOF
    chmod +x "$stop_script"
    chown "$target_user:$target_user" "$stop_script"
    log_pass "Created $stop_script"
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
    install_uv_tooling
    install_zsh_suite
    usb_optimization
    install_ollama
    configure_syncthing
    
    # Post-setup verification and reload
    if systemctl daemon-reload 2>/dev/null; then
        log_pass "Systemd daemon reloaded"
    fi
    
    # Try to mount all local filesystems from fstab (non-blocking)
    mount -a -t ext4,vfat 2>/dev/null || log_warn "Some mounts failed (may be expected)"
    
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
