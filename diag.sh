#!/bin/bash

################################################################################
# Raspberry Pi Home Server Diagnostic Tool
# Enhanced for Debian Trixie with Docker + USB storage
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

SCRIPT_VERSION="2.0"
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

# Temperature
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

# Throttling Check
if command_exists vcgencmd; then
    THROTTLED=$(vcgencmd get_throttled | cut -d= -f2)
    if [[ "$THROTTLED" == "0x0" ]]; then
        log_pass "Power/Thermal: Normal"
    else
        log_fail "Power/Thermal: Issues detected ($THROTTLED)"
    fi
fi

# Memory
MEM_TOTAL=$(free -h | awk 'NR==2 {print $2}')
MEM_USED=$(free -h | awk 'NR==2 {print $3}')
MEM_PERCENT=$(free | awk 'NR==2 {printf "%.0f", $3/$2*100}')
if [[ $MEM_PERCENT -lt 80 ]]; then
    log_pass "Memory: $MEM_USED/$MEM_TOTAL ($MEM_PERCENT%)"
else
    log_warn "Memory: High usage ($MEM_PERCENT%)"
fi

# Disk - Root
ROOT_USAGE=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
ROOT_FREE=$(df -h / | awk 'NR==2 {print $4}')
if [[ $ROOT_USAGE -lt 90 ]]; then
    log_pass "Root disk: $ROOT_FREE free (${ROOT_USAGE}%)"
else
    log_fail "Root disk: Only $ROOT_FREE free (${ROOT_USAGE}%)"
fi

################################################################################
# SECTION 2: USB MOUNT & STORAGE
################################################################################

log_section "USB STORAGE & MOUNTS"

USB_MOUNT_PATH="/mnt/usb"

# Check if USB mount exists
if mount | grep -q "$USB_MOUNT_PATH"; then
    USB_DEVICE=$(mount | grep "on $USB_MOUNT_PATH " | awk '{print $1}')
    log_pass "USB mount: $USB_MOUNT_PATH"
    log_info "  Device: $USB_DEVICE"
    
    # Get mount options
    MOUNT_OPTS=$(mount | grep "on $USB_MOUNT_PATH " | sed -n 's/.*(\(.*\)).*/\1/p')
    log_info "  Mount options: $MOUNT_OPTS"
    
    # Check for optimal mount options
    if echo "$MOUNT_OPTS" | grep -q "noatime"; then
        log_pass "  noatime: Enabled"
    else
        log_fail "  noatime: Disabled (should enable for USB durability)"
    fi
    
    # Only check error handling for ext4 (not supported by vFAT/NTFS)
    if echo "$MOUNT_OPTS" | grep -q "errors=remount-ro"; then
        log_pass "  Error handling: Configured (ext4)"
    elif echo "$MOUNT_OPTS" | grep -qE "vfat|ntfs|exfat"; then
        log_info "  Error handling: N/A for $(echo $MOUNT_OPTS | awk '{print $1}') filesystem"
    else
        log_warn "  Error handling: Not configured (recommended for ext4)"
    fi
    
    # USB disk usage
    USB_TOTAL=$(df "$USB_MOUNT_PATH" | awk 'NR==2 {print $2}' | numfmt --from=auto 2>/dev/null || echo "N/A")
    USB_USED=$(df "$USB_MOUNT_PATH" | awk 'NR==2 {print $3}' | numfmt --from=auto 2>/dev/null || echo "N/A")
    USB_PERCENT=$(df "$USB_MOUNT_PATH" | awk 'NR==2 {print $5}' | sed 's/%//')
    
    if [[ $USB_PERCENT -lt 90 ]]; then
        log_pass "USB space: $(df -h $USB_MOUNT_PATH | awk 'NR==2 {print $3}')/$(df -h $USB_MOUNT_PATH | awk 'NR==2 {print $2}') ($USB_PERCENT%)"
    else
        log_fail "USB space: Low ($USB_PERCENT% used)"
    fi
else
    log_fail "USB mount: Not mounted at $USB_MOUNT_PATH"
    log_info "Expected configuration: /mnt/usb for Docker volumes"
fi

# Show all block devices
if command_exists lsblk; then
    log_info "Block devices:"
    lsblk -o NAME,SIZE,TYPE,TRAN,FSTYPE,MOUNTPOINT | tail -n +2 | sed 's/^/  /'
fi

################################################################################
# SECTION 3: DOCKER STATUS
################################################################################

log_section "DOCKER STATUS"

if command_exists docker; then
    VERSION=$(docker --version 2>/dev/null | awk '{print $3}' | sed 's/,//')
    log_pass "Docker: $VERSION"
    
    if service_active docker; then
        log_pass "Docker daemon: Running"
        
        # Container stats
        CONTAINER_COUNT=$(docker ps -aq 2>/dev/null | wc -l)
        RUNNING_COUNT=$(docker ps -q 2>/dev/null | wc -l)
        log_info "  Containers: $RUNNING_COUNT running / $CONTAINER_COUNT total"
        
        # Container health
        if [[ $RUNNING_COUNT -gt 0 ]]; then
            UNHEALTHY=$(docker ps --filter "health=unhealthy" -q 2>/dev/null | wc -l)
            if [[ $UNHEALTHY -gt 0 ]]; then
                log_fail "  Unhealthy containers: $UNHEALTHY"
            else
                log_pass "  Container health: All healthy"
            fi
            
            RESTARTING=$(docker ps --filter "status=restarting" -q 2>/dev/null | wc -l)
            if [[ $RESTARTING -gt 0 ]]; then
                log_warn "  Restarting containers: $RESTARTING"
            fi
        fi
        
        # Images
        IMAGE_COUNT=$(docker images -q 2>/dev/null | wc -l)
        log_info "  Images: $IMAGE_COUNT"
        
        # Docker storage
        DOCKER_ROOT=$(docker info 2>/dev/null | grep "Docker Root Dir" | awk '{print $4}')
        if [[ -n "$DOCKER_ROOT" ]]; then
            DOCKER_SIZE=$(du -sh "$DOCKER_ROOT" 2>/dev/null | awk '{print $1}')
            log_info "  Storage root: $DOCKER_ROOT"
            log_info "  Storage size: $DOCKER_SIZE"
            
            # Check if on USB
            if echo "$DOCKER_ROOT" | grep -q "/mnt/usb"; then
                log_pass "  Storage: On USB (/mnt/usb) ✓"
            else
                log_warn "  Storage: Not on USB (consider moving for better performance)"
            fi
            
            # Free space on Docker drive
            DOCKER_SPACE=$(df "$DOCKER_ROOT" 2>/dev/null | awk 'NR==2 {print int($4)}')
            if [[ $DOCKER_SPACE -lt 500000 ]]; then
                log_fail "  Docker drive space: Low ($(df -h "$DOCKER_ROOT" | awk 'NR==2 {print $4}'))"
            else
                log_pass "  Docker drive space: $(df -h "$DOCKER_ROOT" | awk 'NR==2 {print $4}') free"
            fi
        fi
        
        # Log configuration
        DOCKER_CONFIG="/etc/docker/daemon.json"
        if [[ -f "$DOCKER_CONFIG" ]]; then
            if grep -q "log-driver" "$DOCKER_CONFIG"; then
                log_info "  Log driver: Configured"
            else
                log_warn "  Log driver: Not configured (may cause large logs)"
            fi
        fi
        
        # Top containers by size
        log_info "  Top containers by size:"
        docker ps --format "{{.Names}}" | while read container; do
            size=$(docker inspect --format='{{.State.Pid}}' "$container" 2>/dev/null | xargs -I {} du -sh /proc/{}/root 2>/dev/null || echo "N/A")
            echo "    $container: $size"
        done | head -5
        
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

# Interfaces
if command_exists ip; then
    INTERFACES=$(ip -br link show | grep -v lo | wc -l)
    log_pass "Network interfaces: $INTERFACES"
    
    ip -br addr show | grep -v lo | while read -r line; do
        IFACE=$(echo "$line" | awk '{print $1}')
        STATE=$(echo "$line" | awk '{print $2}')
        IP=$(echo "$line" | awk '{print $3}' | cut -d'/' -f1)
        
        if [[ "$STATE" == "UP" ]]; then
            log_pass "  $IFACE: $IP (active)"
        else
            log_warn "  $IFACE: down"
        fi
    done
fi

# Internet connectivity
if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    log_pass "Internet: Connected"
else
    log_fail "Internet: Not connected"
fi

# DNS
if command -v nslookup >/dev/null 2>&1; then
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
    
    # Gemini CLI Check
    if [[ -f "$HOME/.gemini/settings.json" ]]; then
        PREVIEW=$(grep "previewFeatures" "$HOME/.gemini/settings.json" | grep -q "true" && echo "Enabled" || echo "Disabled")
        log_pass "  Gemini CLI: Configured (Preview: $PREVIEW)"
    else
        log_warn "  Gemini CLI: No settings found at ~/.gemini/settings.json"
    fi
    
    # npm cache
    NPM_CACHE_SIZE=$(du -sh "$HOME/.npm" 2>/dev/null | awk '{print $1}')
    if [[ -n "$NPM_CACHE_SIZE" ]]; then
        log_info "  npm cache size: $NPM_CACHE_SIZE"
    fi
    
    # npm config
    if [[ -f "$HOME/.npmrc" ]]; then
        log_pass "  npm config: ~/.npmrc exists"
    else
        log_warn "  npm config: No ~/.npmrc found (default settings used)"
    fi
    
    # Global packages
    GLOBAL_PACKAGES=$(npm list -g --depth=0 2>/dev/null | grep -c " -")
    if [[ $GLOBAL_PACKAGES -gt 2 ]]; then
        log_info "  Global packages: $((GLOBAL_PACKAGES - 1)) installed"
    fi
else
    log_info "npm: Not installed"
fi

################################################################################
# SECTION 6: SECURITY
################################################################################

log_section "SECURITY STATUS"

# Firewall
if command_exists ufw; then
    UFW_STATUS=$(ufw status 2>/dev/null | head -1)
    if echo "$UFW_STATUS" | grep -q "active"; then
        log_pass "UFW: Active"
    else
        log_warn "UFW: Inactive"
    fi
fi

# SSH config
SSH_CONFIG="/etc/ssh/sshd_config"
if [[ -f "$SSH_CONFIG" ]]; then
    if grep -q "^PermitRootLogin no" "$SSH_CONFIG"; then
        log_pass "SSH root login: Disabled"
    else
        log_warn "SSH root login: Not disabled"
    fi
    
    if grep -q "^PasswordAuthentication yes" "$SSH_CONFIG" || ! grep -q "^PasswordAuthentication" "$SSH_CONFIG"; then
        log_pass "SSH password auth: Enabled"
    else
        log_warn "SSH password auth: Disabled"
    fi
fi

# Fail2Ban
if command_exists fail2ban-client; then
    if service_active fail2ban; then
        JAILS=$(fail2ban-client status 2>/dev/null | grep "Jail list" | sed -E 's/^[^:]+:\s+//' | wc -w)
        log_pass "Fail2Ban: Active ($JAILS jails)"
    else
        log_warn "Fail2Ban: Installed but not running"
    fi
else
    log_info "Fail2Ban: Not installed"
fi

# User accounts
USERS=$(getent passwd | wc -l)
ADMIN_USERS=$(getent group sudo | cut -d: -f4 | tr ',' '\n' | grep -v '^$' | wc -l)
log_info "Users: $USERS total, $ADMIN_USERS admin"

################################################################################
# SECTION 7: SERVICES & OPTIMIZATIONS
################################################################################

log_section "SERVICES & OPTIMIZATIONS"

# Systemd services
log_info "Key system services:"
for service in docker ssh cron systemd-resolved avahi-daemon; do
    if service_active "$service" 2>/dev/null; then
        log_pass "  $service: active"
    else
        log_warn "  $service: inactive"
    fi
done

# ZRAM (Compressed Swap)
if [[ -f /sys/block/zram0/disksize ]]; then
    ZRAM_SIZE=$(cat /sys/block/zram0/disksize 2>/dev/null)
    if [[ "$ZRAM_SIZE" != "0" ]] && [[ -n "$ZRAM_SIZE" ]]; then
        ZRAM_MB=$((ZRAM_SIZE / 1048576))
        log_pass "ZRAM: Enabled (${ZRAM_MB}MB)"
    else
        log_warn "ZRAM: Disabled"
    fi
fi

# Swap
SWAP_TOTAL=$(free -h | grep Swap | awk '{print $2}')
SWAP_USED=$(free -h | grep Swap | awk '{print $3}')
if [[ "$SWAP_TOTAL" == "0B" ]] || [[ "$SWAP_TOTAL" == "0" ]]; then
    log_pass "Swap: Disabled (optimal for Docker)"
else
    log_warn "Swap: ${SWAP_TOTAL} (${SWAP_USED} used)"
fi

# tmpfs
TMPFS=$(mount | grep tmpfs | wc -l)
log_info "tmpfs mounts: $TMPFS"

# Boot time analysis
if command_exists systemd-analyze; then
    BOOT_TIME=$(systemd-analyze | grep "Startup finished" | awk '{print $NF}')
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

# Tailscale authentication
# Temperature check
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

# DNS reliability
if command -v nslookup >/dev/null 2>&1; then
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
log_info "Issues Found: $ISSUES"
log_info "Warnings: $WARNINGS"

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
