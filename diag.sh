#!/bin/bash

################################################################################
# Raspberry Pi Home Server Diagnostic Tool - PRO EDITION
# Enhanced for Debian Trixie with Docker + USB storage
# License: MIT (Copyright 2025 Rahul)
################################################################################

set -o pipefail
IFS=$'\n\t'

# --- Constants ---
SCRIPT_VERSION="4.0.0"
LOG_FILE="/var/log/rpi-diag.log"
SCORE=0
TOTAL_CHECKS=0
ISSUES=0
WARNINGS=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# --- Logging ---
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[✓]${NC} $1"; ((SCORE++)); ((TOTAL_CHECKS++)); }
log_fail() { echo -e "${RED}[✗]${NC} $1"; ((ISSUES++)); ((TOTAL_CHECKS++)); }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; ((WARNINGS++)); ((TOTAL_CHECKS++)); }
log_section() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

# --- Utilities ---
command_exists() { command -v "$1" >/dev/null 2>&1; }
service_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

################################################################################
# 1. System Vital Signs
################################################################################

log_section "SYSTEM VITAL SIGNS"

# OS & Model
MODEL=$(cat /proc/device-tree/model 2>/dev/null || echo "Unknown Pi")
source /etc/os-release 2>/dev/null
log_info "Hardware: $MODEL"
log_info "OS: $PRETTY_NAME ($(uname -m))"
log_info "Kernel: $(uname -r)"

# Failed Units
FAILED_UNITS=$(systemctl list-units --state=failed --no-legend | wc -l)
if [[ $FAILED_UNITS -eq 0 ]]; then
    log_pass "Systemd units: All healthy"
else
    log_fail "Systemd units: $FAILED_UNITS failed units detected"
    systemctl list-units --state=failed --no-legend | sed 's/^/    /'
fi

# Zombie Processes
ZOMBIES=$(ps aux | awk '{if ($8=="Z") print $2}' | wc -l)
if [[ $ZOMBIES -eq 0 ]]; then
    log_pass "Zombie processes: None"
else
    log_warn "Zombie processes: $ZOMBIES detected"
fi

# Load Average
LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)
log_info "Load Average: $LOAD"

# Temperature
if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
    TEMP=$(cat /sys/class/thermal/thermal_zone0/temp | awk '{printf "%.1f", $1/1000}')
    if command_exists bc; then
        if (( $(echo "$TEMP < 65" | bc -l) )); then log_pass "Temp: ${TEMP}°C (Optimal)"
elif (( $(echo "$TEMP < 80" | bc -l) )); then log_warn "Temp: ${TEMP}°C (Warm)"
else log_fail "Temp: ${TEMP}°C (CRITICAL)"
fi
    else
        log_info "Temp: ${TEMP}°C"
    fi
fi

# Throttling
if command_exists vcgencmd; then
    THROTTLED=$(vcgencmd get_throttled | cut -d= -f2)
    [[ "$THROTTLED" == "0x0" ]] && log_pass "Throttling: None" || log_fail "Throttling detected: $THROTTLED"
fi

################################################################################
# 2. Storage Health
################################################################################

log_section "STORAGE HEALTH"

# Disk Usage
df -h / | awk 'NR==2 {usage=$5; gsub(/%/,"",usage); if(usage<85) print "PASS", $4; else print "FAIL", $4}' | while read status free;
    do
    [[ "$status" == "PASS" ]] && log_pass "Root space: $free free" || log_fail "Root space low: $free free"
done

# USB Mount
USB_PATH="/mnt/usb"
if mountpoint -q "$USB_PATH"; then
    log_pass "USB Mount: $USB_PATH active"
    OPTIONS=$(mount | grep "$USB_PATH" | grep -o "(.*)")
    [[ "$OPTIONS" == *"noatime"* ]] && log_pass "  noatime: Enabled" || log_warn "  noatime: Missing"
else
    log_fail "USB Mount: $USB_PATH NOT MOUNTED"
fi

# SMART Status (if available)
if command_exists smartctl; then
    for dev in $(lsblk -d -o NAME,TRAN | grep "usb" | awk '{print $1}'); do
        smartctl -H "/dev/$dev" | grep -q "PASSED" && log_pass "SMART ($dev): Passed" || log_warn "SMART ($dev): Check required"
    done
fi

################################################################################
# 3. Docker Ecosystem
################################################################################

log_section "DOCKER ECOSYSTEM"

if command_exists docker; then
    if service_active docker; then
        log_pass "Docker Daemon: Running"
        
        # Container Counts
        RUNNING=$(docker ps -q | wc -l)
        TOTAL=$(docker ps -a -q | wc -l)
        log_info "Containers: $RUNNING running / $TOTAL total"
        
        # Dead/Exited Containers
        EXITED=$(docker ps -a --filter "status=exited" -q | wc -l)
        [[ $EXITED -gt 0 ]] && log_warn "Exited containers: $EXITED detected"
        
        # Network Check
        docker network ls | grep -q "wg-easy" && log_pass "Network 'wg-easy': Exists" || log_warn "Network 'wg-easy': Missing"
        
        # Volume usage
        VOLUMES=$(docker volume ls -q | wc -l)
        log_info "Docker volumes: $VOLUMES"
        
        # Logging Driver
        DRIVER=$(docker info --format '{{.LoggingDriver}}')
        [[ "$DRIVER" == "json-file" ]] && log_pass "Log driver: $DRIVER" || log_warn "Log driver: $DRIVER (not optimized)"
    else
        log_fail "Docker Daemon: Inactive"
    fi
else
    log_fail "Docker: Not installed"
fi

################################################################################
# 4. Networking & Connectivity
################################################################################

log_section "NETWORKING"

# Internet
ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && log_pass "Internet: Connected" || log_fail "Internet: Offline"

# DNS
if command_exists nslookup;
    then
    nslookup google.com >/dev/null 2>&1 && log_pass "DNS: Resolving" || log_fail "DNS: Failed"
fi

# Interfaces
ip -4 addr show | grep -v "127.0.0.1" | grep "inet " | awk '{print $NF, $2}' | while read iface addr;
    do
    log_info "Interface $iface: $addr"
done

# Tailscale
if command_exists tailscale;
    then
    tailscale status >/dev/null 2>&1 && log_pass "Tailscale: Connected" || log_warn "Tailscale: Disconnected"
fi

################################################################################
# 5. Summary
################################################################################

log_section "DIAGNOSTIC SUMMARY"

SCORE_PERC=$(( SCORE * 100 / TOTAL_CHECKS ))
log_info "System Health Score: $SCORE_PERC% ($SCORE/$TOTAL_CHECKS)"

if [[ $ISSUES -gt 0 ]]; then
    log_fail "Status: $ISSUES CRITICAL ISSUES FOUND"
elif [[ $WARNINGS -gt 0 ]]; then
    log_warn "Status: Healthy with $WARNINGS warnings"
else
    log_pass "Status: System Perfect"
fi

echo -e "\nRecommended action: sudo ./optimize.sh"