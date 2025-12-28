#!/bin/bash

################################################################################
# Raspberry Pi Home Server Setup - PRO EDITION
# Target: Raspberry Pi OS Debian Trixie (aarch64)
# Features: Docker, Node.js, USB Mounting, Hardening, Optimizations
# License: MIT (Copyright 2025 Rahul)
################################################################################

set -o pipefail
IFS=$'\n\t'

# --- Constants ---
SCRIPT_VERSION="4.0.0"
USB_MOUNT_PATH="/mnt/usb"
CONFIG_FILE="/boot/firmware/config.txt"
BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
CHECKS_PASSED=0
CHECKS_FAILED=0
WARNINGS=0

# --- Logging ---
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[✓]${NC} $1"; ((CHECKS_PASSED++)); }
log_fail() { echo -e "${RED}[✗]${NC} $1"; ((CHECKS_FAILED++)); }
log_skip() { echo -e "${YELLOW}[⊘]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; ((WARNINGS++)); }
log_section() { echo -e "\n${CYAN}=== $1 ===${NC}"; }
log_error() { echo -e "\n${RED}ERROR: $1${NC}"; exit 1; }

# --- Utilities ---
require_root() { [[ $EUID -ne 0 ]] && log_error "Run as root (sudo)"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
confirm_action() {
    local prompt="$1"
    local response
    while true; do
        read -p "$(echo -e ${CYAN}$prompt${NC} [y/N]: )" -r response
        case "$response" in
            [yY]*) return 0 ;; 
            [nN]*|"") return 1 ;; 
            *) echo "Please answer y or n." ;; 
        esac
    done
}

################################################################################
# 1. Pre-flight Checks
################################################################################

preflight_checks() {
    log_section "PRE-FLIGHT CHECKS"
    
    [[ ! -f /etc/os-release ]] && log_error "OS release unknown"
    source /etc/os-release
    log_info "OS: $PRETTY_NAME"
    
    [[ "$(uname -m)" != "aarch64" ]] && log_error "64-bit ARM required"
    log_pass "Architecture: aarch64"
    
    ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 || log_error "Internet required"
    log_pass "Connectivity: OK"
}

################################################################################
# 2. System Core
################################################################################

system_core() {
    log_section "SYSTEM CORE"
    
    apt update && apt full-upgrade -y || log_error "Apt upgrade failed"
    log_pass "System updated"
    
    local packages=(
        "ca-certificates" "curl" "gnupg" "git" "jq" "bc" 
        "usbutils" "util-linux" "watchdog" "e2fsprogs" 
        "smartmontools" "cpufrequtils" "zram-tools" "fail2ban" "ufw"
        "htop" "vim" "tmux" "net-tools" "lsb-release"
    )
    
    for pkg in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii.*${pkg}"; then
            log_info "Installing $pkg..."
            apt install -y "$pkg" || log_warn "Failed: $pkg"
        fi
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
    
    local target_user="${SUDO_USER:-$USER}"
    [[ "$target_user" != "root" ]] && usermod -aG docker "$target_user" && log_pass "User $target_user added to docker group"
}

################################################################################
# 4. Node.js & Tooling
################################################################################

nodejs_tooling() {
    log_section "NODE.JS & TOOLING"
    
    if ! command_exists node; then
        curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
        apt install -y nodejs
    fi
    log_pass "Node.js: $(node -v)"
    
    # Global npm config for non-root
    local target_user="${SUDO_USER:-$USER}"
    if [[ "$target_user" != "root" ]]; then
        local target_home=$(getent passwd "$target_user" | cut -d: -f6)
        local npm_global="$target_home/.npm-global"
        mkdir -p "$npm_global"
        chown -R "$target_user" "$npm_global"
        sudo -u "$target_user" npm config set prefix "$npm_global"
        
        if ! grep -q ".npm-global/bin" "$target_home/.bashrc"; then
            echo 'export PATH=~/.npm-global/bin:$PATH' >> "$target_home/.bashrc"
        fi
        log_pass "npm global prefix configured"
    fi
}

################################################################################
# 5. USB & Optimization
################################################################################

usb_optimization() {
    log_section "USB & OPTIMIZATION"
    
    # Prepare USB mount directory
    local mount_path="/mnt/usb"
    if [[ ! -d "$mount_path" ]]; then
        mkdir -p "$mount_path"
        log_pass "Mount directory created: $mount_path"
    else
        log_skip "Mount directory already exists: $mount_path"
    fi
    
    # Run optimize.sh for system-wide tuning
    if [[ -f "./optimize.sh" ]]; then
        chmod +x ./optimize.sh
        log_info "Running optimize.sh..."
        ./optimize.sh || log_warn "optimize.sh encountered issues but continuing"
        log_pass "Optimizations applied"
    else
        log_error "optimize.sh not found in current directory"
    fi
    
    # Verify USB mount was configured
    if grep -q "$mount_path" /etc/fstab; then
        log_pass "USB mount verified in fstab"
    else
        log_warn "USB mount not found in fstab - may need manual configuration"
    fi
}

################################################################################
# Main
################################################################################

main() {
    require_root
    preflight_checks
    system_core
    docker_suite
    nodejs_tooling
    usb_optimization
    
    # Post-setup verification and reload
    if systemctl daemon-reload 2>/dev/null; then
        log_pass "Systemd daemon reloaded"
    fi
    
    # Try to mount all filesystems from fstab (non-blocking)
    mount -a 2>/dev/null || log_warn "Some mounts failed (may be expected)"
    
    log_section "SETUP COMPLETE"
    echo -e "${GREEN}✓ Raspberry Pi Home Server configured!${NC}"
    log_info "Applied optimizations:"
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
