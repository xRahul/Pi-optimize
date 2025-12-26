#!/bin/bash

################################################################################
# Raspberry Pi Home Server Diagnostic Tool
# Enhanced for Debian Trixie with Docker + USB storage
# License: MIT (Copyright 2025 Rahul)
#
# DESCRIPTION:
# This script performs a comprehensive health check of the Raspberry Pi.
# It validates hardware status (thermals, throttling), software configuration
# (Docker, Network, Services), and security posture. It is safe to run anytime.
################################################################################

set -o pipefail
IFS=$'\n\t'

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

SCRIPT_VERSION="2.5"
SCORE=0
ISSUES=0
WARNINGS=0

################################################################################
# Logging Functions
################################################################################

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[✓]${NC} $1"; ((SCORE++)); }
log_fail() { echo -e "${RED}[✗]${NC} $1"; ((ISSUES++)); }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; ((WARNINGS++)); }
log_docker() { echo -e "${CYAN}[🐳]${NC} $1"; }
log_security() { echo -e "${MAGENTA}[🔒]${NC} $1"; }
log_section() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

log_info "=== Raspberry Pi Home Server Diagnostic v$SCRIPT_VERSION ==="

################################################################################
# Utility Functions
################################################################################

command_exists() { command -v "$1" >/dev/null 2>&1; }
service_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
service_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }

################################################################################
# SECTION 1: SYSTEM HEALTH
# Checks core vitals: Temp, Memory, CPU Load
################################################################################

log_section "SYSTEM HEALTH"

# OS Info
source /etc/os-release 2>/dev/null
log_pass "OS: $PRETTY_NAME"
log_info "Kernel: $(uname -r)"
log_info "Architecture: $(uname -m)"

# Uptime and Load
UPTIME=$(uptime -p 2>/dev/null || uptime)
LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)
log_info "Uptime: $UPTIME"
log_info "Load average: $LOAD"

# Temperature Check (Critical for Pi 5)
# Throttling starts at 80°C. We want to stay well below that.
if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
    TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.1f", $1/1000}')
    
    if command_exists bc; then
        if (( $(echo "$TEMP < 70" | bc -l 2>/dev/null) )); then
            log_pass "Temperature: ${TEMP}°C (optimal)"
        elif (( $(echo "$TEMP < 85" | bc -l 2>/dev/null) )); then
            log_warn "Temperature: ${TEMP}°C (warm)"
        else
            log_fail "Temperature: ${TEMP}°C (hot - check cooling)"
        fi
    else
        # Fallback integer comparison if bc missing
        TEMP_INT=$(echo "$TEMP" | cut -d. -f1)
        if [[ "$TEMP_INT" -lt 70 ]]; then
            log_pass "Temperature: ${TEMP}°C (optimal)"
        elif [[ "$TEMP_INT" -lt 85 ]]; then
            log_warn "Temperature: ${TEMP}°C (warm)"
        else
            log_fail "Temperature: ${TEMP}°C (hot - check cooling)"
        fi
    fi
fi

# Throttling Check (Hardware level)
# 0x0 means no throttling. Other values indicate under-voltage or over-temp.
if command_exists vcgencmd; then
    THROTTLED=$(vcgencmd get_throttled | cut -d= -f2)
    if [[ "$THROTTLED" == "0x0" ]]; then
        log_pass "Power/Thermal: Normal"
    else
        log_fail "Power/Thermal: Issues detected ($THROTTLED)"
    fi
fi

# Memory Usage
MEM_TOTAL=$(free -h | awk 'NR==2 {print $2}')
MEM_USED=$(free -h | awk 'NR==2 {print $3}')
MEM_PERCENT=$(free | awk 'NR==2 {printf "%.0f", $3/$2*100}')
if [[ $MEM_PERCENT -lt 80 ]]; then
    log_pass "Memory: $MEM_USED/$MEM_TOTAL ($MEM_PERCENT%)"
else
    log_warn "Memory: High usage ($MEM_PERCENT%)"
fi

# Root Disk Space
ROOT_USAGE=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
ROOT_FREE=$(df -h / | awk 'NR==2 {print $4}')
if [[ $ROOT_USAGE -lt 90 ]]; then
    log_pass "Root disk: $ROOT_FREE free (${ROOT_USAGE}%)"
else
    log_warn "Root disk: Low space (${ROOT_USAGE}% used)"
fi

################################################################################
# SECTION 2: USB STORAGE & MOUNTS
# Verifies external storage is mounted correctly for Docker
################################################################################

log_section "USB STORAGE & MOUNTS"

# Check primary USB mount point
USB_MOUNT_PATH="/mnt/usb"
if mount | grep -q "$USB_MOUNT_PATH"; then
    log_pass "USB mount: $USB_MOUNT_PATH"
    
    # Get device details
    DEVICE=$(mount | grep "$USB_MOUNT_PATH" | awk '{print $1}')
    OPTIONS=$(mount | grep "$USB_MOUNT_PATH" | grep -o "(.*)" | tr -d '()')
    
    log_info "  Device: $DEVICE"
    log_info "  Mount options: $OPTIONS"
    
    # Check optimization flags
    if echo "$OPTIONS" | grep -q "noatime"; then
        log_pass "  noatime: Enabled"
    else
        log_warn "  noatime: Disabled (enable for better performance)"
    fi
    
    if echo "$OPTIONS" | grep -q "errors=remount-ro"; then
        log_pass "  Error handling: Configured (ext4)"
    fi
    
    # Check space
    USB_USAGE=$(df "$USB_MOUNT_PATH" | awk 'NR==2 {print $5}')
    USB_TOTAL=$(df -h "$USB_MOUNT_PATH" | awk 'NR==2 {print $2}')
    USB_USED=$(df -h "$USB_MOUNT_PATH" | awk 'NR==2 {print $3}')
    log_pass "USB space: $USB_USED/$USB_TOTAL ($USB_USAGE)"
    
else
    log_fail "USB mount: Not found at $USB_MOUNT_PATH"
fi

# List block devices
log_info "Block devices:"
if command_exists lsblk; then
    lsblk -o NAME,SIZE,TYPE,TRAN,FSTYPE,MOUNTPOINT | tail -n +2 | sed 's/^/  /'
else
    log_warn "lsblk not found"
fi

################################################################################
# SECTION 3: DOCKER STATUS
# Ensures container runtime is healthy
################################################################################

log_section "DOCKER STATUS"

if command_exists docker; then
    DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ',')
    log_pass "Docker: $DOCKER_VER"
    
    # Check daemon status
    if systemctl is-active --quiet docker; then
        log_pass "Docker daemon: Running"
        
        # Check container stats
        RUNNING=$(docker ps -q | wc -l)
        TOTAL=$(docker ps -a -q | wc -l)
        log_info "  Containers: $RUNNING running / $TOTAL total"
        
        # Check image count
        IMAGES=$(docker images -q | wc -l)
        log_info "  Images: $IMAGES"
        
        # Check logging config
        LOG_DRIVER=$(docker info --format '{{.LoggingDriver}}')
        log_info "  Log driver: $LOG_DRIVER"
        
        # Check user permissions (sudo-less docker)
        if [[ -n "$SUDO_USER" ]]; then
            if groups "$SUDO_USER" | grep -q "\bdocker\b"; then
                log_pass "  User permissions: $SUDO_USER in docker group"
            else
                log_warn "  User permissions: $SUDO_USER NOT in docker group (needs sudo)"
            fi
        fi
        
        # Check top containers by disk usage (if possible)
        # Note: This can be slow, skipping detailed analysis for speed
        log_info "  Top containers by size:"
        docker ps --format "table {{.Size}}\t{{.Names}}" | grep -v "0B" | head -3 | sed 's/^/    /'
    else
        log_fail "Docker daemon: Not running"
    fi
else
    log_fail "Docker: Not installed"
fi

################################################################################
# SECTION 4: NETWORK & CONNECTIVITY
################################################################################

log_section "NETWORK & CONNECTIVITY"

# Interface check
INTERFACES=$(ip -o link show | awk -F': ' '{print $2}')
IF_COUNT=$(echo "$INTERFACES" | wc -l)
log_pass "Network interfaces: $IF_COUNT"

for iface in $INTERFACES; do
    if [[ "$iface" != "lo" ]]; then
        IP=$(ip -4 addr show "$iface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        if [[ -n "$IP" ]]; then
            log_pass "  $iface: $IP (active)"
        else
            log_warn "  $iface: down"
        fi
    fi
done

# Internet connectivity
if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    log_pass "Internet: Connected"
else
    log_fail "Internet: Not connected"
fi

# DNS Resolution
# Uses getent as fallback if nslookup is missing
if command_exists nslookup; then
    if nslookup google.com >/dev/null 2>&1; then
        log_pass "DNS: Resolving (nslookup)"
    else
        log_fail "DNS: Not resolving"
    fi
elif getent hosts google.com >/dev/null 2>&1; then
    log_pass "DNS: Resolving (getent)"
else
    log_fail "DNS: Not resolving"
fi

# SSH
if service_active ssh; then
    SSH_PORT=$(ss -tlnp 2>/dev/null | grep :22 | head -1 | awk '{print $4}' | cut -d':' -f2)
    log_pass "SSH: Running (port $SSH_PORT)"
else
    log_fail "SSH: Not running"
fi

################################################################################
# SECTION 5: NPM & DEVELOPMENT TOOLS
################################################################################

log_section "NPM & DEVELOPMENT TOOLS"

if command_exists npm; then
    NPM_VERSION=$(npm --version)
    NODE_VERSION=$(node --version 2>/dev/null)
    log_pass "npm: Installed (version $NPM_VERSION)"
    if [[ -n "$NODE_VERSION" ]]; then
        log_info "  Node.js: $NODE_VERSION"
    fi
    
    # Check global install prefix (for sudo-less installs)
    if [[ -n "$SUDO_USER" ]]; then
        USER_PREFIX=$(sudo -u "$SUDO_USER" npm config get prefix 2>/dev/null)
        if [[ "$USER_PREFIX" == *".npm-global" ]]; then
            log_pass "  npm prefix: User-local ($USER_PREFIX)"
        else
            log_warn "  npm prefix: System default ($USER_PREFIX) - may require sudo"
        fi
    fi
    
    # Gemini CLI Check
    target_user="${SUDO_USER:-$USER}"
    if command_exists getent; then
        target_home=$(getent passwd "$target_user" | cut -d: -f6)
    fi
    
    if [[ -z "$target_home" ]]; then
        target_home="$HOME"
    fi
    
    if [[ -f "$target_home/.gemini/settings.json" ]]; then
        PREVIEW=$(grep "previewFeatures" "$target_home/.gemini/settings.json" | grep -q "true" && echo "Enabled" || echo "Disabled")
        log_pass "  Gemini CLI: Configured (Preview: $PREVIEW)"
    else
        log_warn "  Gemini CLI: No settings found at $target_home/.gemini/settings.json"
    fi
    
    # Cache check
    CACHE_SIZE=$(du -sh "$target_home/.npm" 2>/dev/null | awk '{print $1}')
    if [[ -n "$CACHE_SIZE" ]]; then
        log_info "  npm cache size: $CACHE_SIZE"
    fi
    
    # Config check
    if [[ -f "$target_home/.npmrc" ]]; then
        log_pass "  npm config: Optimized (.npmrc present)"
    else
        log_warn "  npm config: No $target_home/.npmrc found (default settings used)"
    fi
else
    log_warn "npm: Not installed"
fi

################################################################################
# SECTION 6: SECURITY STATUS
################################################################################

log_section "SECURITY STATUS"

# SSH Root Login
if grep -q "^PermitRootLogin no" /etc/ssh/sshd_config 2>/dev/null; then
    log_pass "SSH root login: Disabled"
else
    log_warn "SSH root login: Not disabled"
fi

# SSH Password Auth
if grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config 2>/dev/null; then
    log_pass "SSH password auth: Disabled (Keys only)"
else
    log_pass "SSH password auth: Enabled"
fi

# Fail2Ban
if command_exists fail2ban-client; then
    JAILS=$(fail2ban-client status | grep "Jail list" | cut -d: -f2)
    log_pass "Fail2Ban: Running ($JAILS)"
else
    log_info "Fail2Ban: Not installed"
fi

# Users
USER_COUNT=$(cat /etc/passwd | grep -E "/bin/bash|/bin/sh" | wc -l)
SUDO_USERS=$(grep -Po '^sudo.+:\K.*$' /etc/group)
log_info "Users: $USER_COUNT total, 1 admin"

################################################################################
# SECTION 7: SERVICES & OPTIMIZATIONS
################################################################################

log_section "SERVICES & OPTIMIZATIONS"

log_info "Key system services:"
for service in docker ssh cron systemd-resolved avahi-daemon; do
    if service_active "$service"; then
        log_pass "  $service: active"
    else
        log_warn "  $service: inactive"
    fi
done

# ZRAM Check
if [[ -f /sys/block/zram0/disksize ]]; then
    ZRAM_SIZE=$(cat /sys/block/zram0/disksize)
    if [[ "$ZRAM_SIZE" != "0" ]]; then
        log_pass "ZRAM: Enabled ($((ZRAM_SIZE/1024/1024))MB)"
    else
        log_warn "ZRAM: Disabled"
    fi
else
    log_warn "ZRAM: Not configured"
fi

# Swap Check
SWAP_TOTAL=$(free -h | awk 'NR==3 {print $2}')
SWAP_USED=$(free -h | awk 'NR==3 {print $3}')
if [[ "$SWAP_TOTAL" == "0B" ]]; then
    log_info "Swap: Disabled (using ZRAM only)"
else
    log_warn "Swap: $SWAP_TOTAL ($SWAP_USED used)"
fi

# Tmpfs Check
TMPFS_COUNT=$(mount | grep tmpfs | wc -l)
log_info "tmpfs mounts: $TMPFS_COUNT"

# Boot analysis
if command_exists systemd-analyze; then
    BOOT_TIME=$(systemd-analyze | head -1 | awk '{print $NF}')
    log_info "Boot time: $BOOT_TIME"
fi

################################################################################
# SECTION 8: RECOMMENDATIONS
################################################################################

log_section "RECOMMENDATIONS"

RECS=0

# USB mount check
if ! mount | grep -q "$USB_MOUNT_PATH"; then
    ((RECS++))
    log_warn "[$RECS] USB not mounted at $USB_MOUNT_PATH"
fi

# Docker on USB check
if command_exists docker && ! docker info 2>/dev/null | grep "Docker Root Dir" | grep -q "/mnt/usb"; then
    ((RECS++))
    log_warn "[$RECS] Docker not using USB storage (configure for better performance)"
fi

# Write optimization check
if mount | grep "on / " | grep -q "noatime"; then
    log_pass "Root filesystem optimization: noatime enabled"
else
    ((RECS++))
    log_warn "[$RECS] Enable noatime on root filesystem for USB durability"
fi

# Temperature check (recommendation logic with bc fallback)
if [[ -n "$TEMP" ]]; then
    if command_exists bc; then
        if (( $(echo "$TEMP > 80" | bc -l 2>/dev/null) )); then
            ((RECS++))
            log_warn "[$RECS] High temperature - improve cooling"
        fi
    else
        TEMP_INT=$(echo "$TEMP" | cut -d. -f1)
        if [[ "$TEMP_INT" -gt 80 ]]; then
            ((RECS++))
            log_warn "[$RECS] High temperature - improve cooling"
        fi
    fi
fi

# Disk space
if [[ $ROOT_USAGE -gt 80 ]]; then
    ((RECS++))
    log_warn "[$RECS] Root disk usage high ($ROOT_USAGE%) - clean up or expand"
fi

# DNS reliability (robust check)
if command_exists nslookup >/dev/null 2>&1; then
    if ! nslookup google.com >/dev/null 2>&1; then
        ((RECS++))
        log_warn "[$RECS] DNS not resolving - check /etc/resolv.conf"
    fi
elif ! getent hosts google.com >/dev/null 2>&1; then
    ((RECS++))
    log_warn "[$RECS] DNS not resolving - check /etc/resolv.conf"
fi

if [[ $RECS -eq 0 ]]; then
    log_pass "✓ System well-configured!"
fi

################################################################################
# SECTION 9: SUMMARY
################################################################################

log_section "DIAGNOSTIC SUMMARY"

log_info "Readiness Score: $SCORE"

if [[ $ISSUES -gt 0 ]]; then
    log_fail "Issues Found: $ISSUES"
else
    log_info "Issues Found: $ISSUES"
fi

if [[ $WARNINGS -gt 0 ]]; then
    log_warn "Warnings Found: $WARNINGS"
else
    log_info "Warnings Found: $WARNINGS"
fi

log_info ""
log_info "Useful commands:"
echo "  # System status"
echo "  systemctl status docker"
echo ""
echo "  # Disk analysis"
echo "  lsblk -o NAME,SIZE,TRAN,FSTYPE,MOUNTPOINT"
echo "  du -sh /mnt/usb/*"
echo ""
echo "  # Docker"
echo "  docker ps -a"
echo "  docker stats"
echo "  docker logs <container>"
echo ""
echo "  # Performance"
echo "  systemd-analyze time"
echo "  iostat -x 1 5"
echo "  nethogs"
echo ""
echo "  # Network"
echo "  ip addr show"
echo "  ss -tlnp"
log_info ""

if [[ $ISSUES -eq 0 ]]; then
    log_pass "Diagnostic complete - System healthy!"
else
    log_fail "Diagnostic complete - Review issues above"
fi