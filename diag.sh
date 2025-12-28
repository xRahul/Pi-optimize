#!/bin/sh

################################################################################
# Raspberry Pi Home Server Diagnostic Tool - PRO EDITION
# Enhanced for Debian Trixie with Docker + USB storage
# License: MIT (Copyright 2025 Rahul)
################################################################################

# Standardize path
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- Constants ---
SCRIPT_VERSION="4.0.1"
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
log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
log_pass() { 
    printf "${GREEN}[✓]${NC} %s\n" "$1"
    SCORE=$((SCORE + 1))
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
}
log_fail() { 
    printf "${RED}[✗]${NC} %s\n" "$1"
    ISSUES=$((ISSUES + 1))
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
}
log_warn() { 
    printf "${YELLOW}[!]${NC} %s\n" "$1"
    WARNINGS=$((WARNINGS + 1))
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
}
log_section() { printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }

# --- Utilities ---
command_exists() { command -v "$1" >/dev/null 2>&1; }
service_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

################################################################################
# 1. System Vital Signs
################################################################################

log_section "SYSTEM VITAL SIGNS"

# OS & Model
# Use tr to remove null bytes if present, handle potential read errors
if [ -f /proc/device-tree/model ]; then
    MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
else
    MODEL="Unknown Pi"
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
fi
log_info "Hardware: $MODEL"
log_info "OS: ${PRETTY_NAME:-Unknown} ($(uname -m))"
log_info "Kernel: $(uname -r)"

# Failed Units
FAILED_UNITS=$(systemctl list-units --state=failed --no-legend 2>/dev/null | wc -l)
# wc -l might output whitespace, trim it by arithmetic context or simple test
if [ "$FAILED_UNITS" -eq 0 ]; then
    log_pass "Systemd units: All healthy"
else
    log_fail "Systemd units: $FAILED_UNITS failed units detected"
    systemctl list-units --state=failed --no-legend 2>/dev/null | sed 's/^/    /'
fi

# Zombie Processes
ZOMBIES=$(ps aux | awk '{if ($8=="Z") print $2}' | wc -l)
if [ "$ZOMBIES" -eq 0 ]; then
    log_pass "Zombie processes: None"
else
    log_warn "Zombie processes: $ZOMBIES detected"
fi

# Load Average
LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)
log_info "Load Average: $LOAD"

# Temperature
if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    TEMP=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp)
    if command_exists bc; then
        # POSIX compliant floating point comparison using bc
        if [ "$(echo "$TEMP < 65" | bc -l)" -eq 1 ]; then
             log_pass "Temp: ${TEMP}°C (Optimal)"
        elif [ "$(echo "$TEMP < 80" | bc -l)" -eq 1 ]; then
             log_warn "Temp: ${TEMP}°C (Warm)"
        else
             log_fail "Temp: ${TEMP}°C (CRITICAL)"
        fi
    else
        log_info "Temp: ${TEMP}°C"
    fi
fi

# Throttling
if command_exists vcgencmd; then
    THROTTLED=$(vcgencmd get_throttled | cut -d= -f2)
    if [ "$THROTTLED" = "0x0" ]; then
        log_pass "Throttling: None"
    else
        log_fail "Throttling detected: $THROTTLED"
    fi
fi

################################################################################
# 2. Storage Health
################################################################################

log_section "STORAGE HEALTH"

# Disk Usage
# Use a temp file or safe pipe structure to avoid subshell variable loss if needed, 
# but loop runs log_pass inside, which updates global vars.
# Wait, in sh/bash, pipes create subshells. Variables updated inside loop won't persist!
# We need to process line by line without a pipe or accept that counts might be off inside loop?
# Actually, the original script had this bug too if using pipes!
# To fix: Write to temp file or use recursive function?
# Simplest fix for this specific script: Just print. The score is less important than the output.
# But "TOTAL_CHECKS" being 0 caused div/0.
# I will fix the counting issue by avoiding the pipe for the loop where possible or just reading into a var first.

# Root FS check
ROOT_CHECK=$(df -h --output=pcent,avail / | tail -n 1 | awk '{usage=$1; gsub(/%/,"",usage); if(usage<85) print "PASS " $2; else print "FAIL " $2}')
ROOT_STATUS=$(echo "$ROOT_CHECK" | awk '{print $1}')
ROOT_FREE=$(echo "$ROOT_CHECK" | awk '{print $2}')

if [ "$ROOT_STATUS" = "PASS" ]; then
     log_pass "Root space: $ROOT_FREE free"
else
     log_fail "Root space low: $ROOT_FREE free"
fi

# USB Mount
USB_PATH="/mnt/usb"
if mountpoint -q "$USB_PATH"; then
    log_pass "USB Mount: $USB_PATH active"
    OPTIONS=$(mount | grep "$USB_PATH" | grep -o "(.*)")
    case "$OPTIONS" in
        *noatime*) log_pass "  noatime: Enabled" ;; 
        *) log_warn "  noatime: Missing" ;; 
    esac
else
    log_fail "USB Mount: $USB_PATH NOT MOUNTED"
fi

# SMART Status (if available)
if command_exists smartctl; then
    # Avoid pipe loop for variables
    USB_DEVICES=$(lsblk -d -o NAME,TRAN | grep "usb" | awk '{print $1}')
    for dev in $USB_DEVICES; do
        if smartctl -H "/dev/$dev" | grep -q "PASSED"; then
             log_pass "SMART ($dev): Passed"
        else
             log_warn "SMART ($dev): Check required"
        fi
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
        if [ "$EXITED" -gt 0 ]; then
             log_warn "Exited containers: $EXITED detected"
        fi
        
        # Network Check
        if docker network ls | grep -q "wg-easy"; then
             log_pass "Network 'wg-easy': Exists"
        else
             log_warn "Network 'wg-easy': Missing"
        fi
        
        # Volume usage
        VOLUMES=$(docker volume ls -q | wc -l)
        log_info "Docker volumes: $VOLUMES"
        
        # Logging Driver
        DRIVER=$(docker info --format '{{.LoggingDriver}}')
        if [ "$DRIVER" = "json-file" ]; then
             log_pass "Log driver: $DRIVER"
        else
             log_warn "Log driver: $DRIVER (not optimized)"
        fi
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
if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
     log_pass "Internet: Connected"
else
     log_fail "Internet: Offline"
fi

# DNS
if command_exists nslookup; then
    if nslookup google.com >/dev/null 2>&1; then
         log_pass "DNS: Resolving"
    else
         log_fail "DNS: Failed"
    fi
fi

# Interfaces
# Loop here is for display only, so subshell is fine
ip -4 addr show | grep -v "127.0.0.1" | grep "inet " | awk '{print $NF "\t" $2}' | while read iface addr; do
    log_info "Interface $iface: $addr"
done

# Tailscale
if command_exists tailscale; then
    if tailscale status >/dev/null 2>&1; then
         log_pass "Tailscale: Connected"
    else
         log_warn "Tailscale: Disconnected"
    fi
fi

################################################################################
# 5. Summary
################################################################################

log_section "DIAGNOSTIC SUMMARY"

if [ "$TOTAL_CHECKS" -gt 0 ]; then
    SCORE_PERC=$(( SCORE * 100 / TOTAL_CHECKS ))
else
    SCORE_PERC=0
fi

log_info "System Health Score: $SCORE_PERC% ($SCORE/$TOTAL_CHECKS)"

if [ "$ISSUES" -gt 0 ]; then
    log_fail "Status: $ISSUES CRITICAL ISSUES FOUND"
elif [ "$WARNINGS" -gt 0 ]; then
    log_warn "Status: Healthy with $WARNINGS warnings"
else
    log_pass "Status: System Perfect"
fi

printf "\nRecommended action: sudo ./optimize.sh\n"
