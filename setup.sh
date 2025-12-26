#!/bin/bash

################################################################################
# Raspberry Pi Home Server Setup
# Target: Raspberry Pi OS Debian Trixie (aarch64)
# Features: Docker setup, USB mounting, Tailscale, optimizations
################################################################################

set -o pipefail
IFS=$'\n\t'

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
SCRIPT_VERSION="2.0"
USB_MOUNT_PATH="/mnt/usb"
CONFIG_FILE="/boot/firmware/config.txt"
BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Counters
CHECKS_PASSED=0
CHECKS_FAILED=0
WARNINGS=0

################################################################################
# Logging Functions
################################################################################

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[✓]${NC} $1"; ((CHECKS_PASSED++)); }
log_fail() { echo -e "${RED}[✗]${NC} $1"; ((CHECKS_FAILED++)); }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; ((WARNINGS++)); }
log_section() { echo -e "\n${CYAN}=== $1 ===${NC}"; }
log_success() { echo -e "\n${GREEN}$1${NC}"; }
log_error() { echo -e "\n${RED}ERROR: $1${NC}"; exit 1; }

################################################################################
# Utility Functions
################################################################################

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (sudo)"
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

confirm_action() {
    local prompt="$1"
    local response
    
    while true; do
        read -p "$(echo -e ${CYAN}$prompt${NC} [y/N]: )" -r response
        case "$response" in
            [yY][eE][sS]|[yY]) return 0 ;;
            [nN][oO]|[nN]|"") return 1 ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
}

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        cp "$file" "${file}.backup.${BACKUP_TIMESTAMP}"
        log_pass "Backed up: ${file}"
    fi
}

wait_for_user() {
    local message="${1:-Press Enter to continue...}"
    read -p "$(echo -e ${CYAN}$message${NC})"
}

################################################################################
# Pre-flight Checks
################################################################################

preflight_checks() {
    log_section "PRE-FLIGHT CHECKS"
    
    # Check distribution
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot determine OS release"
    fi
    
    source /etc/os-release
    log_info "OS: $PRETTY_NAME"
    log_info "Kernel: $(uname -r)"
    
    # Check for Debian Trixie
    if [[ "$VERSION_CODENAME" != "trixie" ]] && [[ "$PRETTY_NAME" != *"Trixie"* ]]; then
        log_warn "This script is optimized for Debian Trixie. Current: $VERSION_CODENAME"
        if ! confirm_action "Continue anyway?"; then
            log_error "Aborted by user"
        fi
    fi
    
    # Check architecture
    local arch=$(uname -m)
    if [[ "$arch" != "aarch64" ]]; then
        log_fail "Architecture: $arch (expected aarch64)"
        log_error "This script is for 64-bit ARM (aarch64) only"
    else
        log_pass "Architecture: $arch (64-bit ARM)"
    fi
    
    # Check internet connectivity
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        log_pass "Internet connectivity: Available"
    else
        log_fail "Internet connectivity: Unavailable"
        log_error "Internet connection required for package installation"
    fi
    
    # Check disk space
    local free_space=$(df / | awk 'NR==2 {print $4}')
    if [[ $free_space -lt 1048576 ]]; then  # < 1GB
        log_fail "Root disk space: $(df -h / | awk 'NR==2 {print $4}') - need at least 1GB"
        log_error "Insufficient disk space on root partition"
    else
        log_pass "Root disk space: $(df -h / | awk 'NR==2 {print $4}')"
    fi
}

################################################################################
# System Update & Dependencies
################################################################################

system_update() {
    log_section "SYSTEM UPDATE"
    
    if ! confirm_action "Update system packages?"; then
        log_warn "Skipped system update"
        return 0
    fi
    
    log_info "Running apt update..."
    apt update || log_error "Failed to update package lists"
    
    log_info "Running apt full-upgrade (Trixie requires full-upgrade)..."
    apt full-upgrade -y || log_error "Failed to upgrade packages"
    
    log_pass "System updated successfully"
}

install_dependencies() {
    log_section "INSTALLING DEPENDENCIES"
    
    local packages=(
        "ca-certificates"
        "curl"
        "gnupg"
        "lsb-release"
        "apt-transport-https"
        "wget"
        "htop"
        "iotop"
        "nethogs"
        "git"
        "jq"
        "bc"
        "pciutils"
        "usbutils"
        "nvme-cli"
        "smartmontools"
        "util-linux"
        "watchdog"
        "e2fsprogs"
    )
    
    log_info "Installing required packages..."
    for pkg in "${packages[@]}"; do
        if ! command_exists "${pkg}" 2>/dev/null && ! dpkg -l | grep -q "^ii.*${pkg}"; then
            log_info "  Installing $pkg..."
            apt install -y "$pkg" || log_warn "Failed to install $pkg"
        fi
    done
    
    log_pass "Dependencies installed"
}

################################################################################
# Docker Installation & Setup
################################################################################

docker_install() {
    log_section "DOCKER INSTALLATION"
    
    if command_exists docker; then
        log_pass "Docker already installed: $(docker --version)"
        return 0
    fi
    
    if ! confirm_action "Install Docker?"; then
        log_warn "Skipped Docker installation"
        return 1
    fi
    
    log_info "Adding Docker's official GPG key..."
    apt update || log_error "Failed to update package lists"
    
    apt install -y ca-certificates curl || log_error "Failed to install ca-certificates and curl"
    
    install -m 0755 -d /etc/apt/keyrings || log_error "Failed to create keyrings directory"
    
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc || \
        log_error "Failed to download Docker GPG key"
    
    chmod a+r /etc/apt/keyrings/docker.asc || log_error "Failed to set permissions on GPG key"
    
    log_info "Adding Docker repository to APT sources..."
    local codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    tee /etc/apt/sources.list.d/docker.sources > /dev/null << EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $codename
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    
    log_info "Updating package lists with Docker repository..."
    apt update || log_error "Failed to update package lists with Docker repository"
    
    log_info "Installing Docker packages..."
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || \
        log_error "Failed to install Docker packages"
    
    log_pass "Docker installed: $(docker --version)"
}

docker_setup() {
    log_section "DOCKER SETUP & VERIFICATION"
    
    if ! command_exists docker; then
        log_warn "Docker not installed, skipping setup"
        return 1
    fi
    
    # Enable Docker service
    log_info "Enabling Docker service..."
    systemctl enable docker || log_warn "Failed to enable Docker service"
    
    # Start Docker service
    log_info "Starting Docker service..."
    systemctl start docker || log_error "Failed to start Docker service"
    
    # Verify Docker is running
    if systemctl is-active --quiet docker; then
        log_pass "Docker service: Running"
    else
        log_error "Docker service failed to start"
    fi
    
    # Verify Docker functionality
    log_info "Testing Docker functionality..."
    if docker run --rm hello-world >/dev/null 2>&1; then
        log_pass "Docker hello-world test: Passed"
    else
        log_fail "Docker hello-world test: Failed"
        log_warn "Docker may not be fully functional"
    fi
    
    # Create docker daemon configuration for USB
    log_info "Configuring Docker daemon..."
    mkdir -p /etc/docker
    
    # Check if USB is mounted and is ext4 (required for overlay2)
    local usb_fstype=$(findmnt -n -o FSTYPE -T "$USB_MOUNT_PATH" 2>/dev/null)
    
    if [[ "$usb_fstype" == "ext4" ]]; then
        if [[ ! -f /etc/docker/daemon.json ]]; then
            cat > /etc/docker/daemon.json << 'EOF'
{
    "data-root": "/mnt/usb/docker",
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "50m",
        "max-file": "3"
    },
    "storage-driver": "overlay2",
    "live-restore": true,
    "userland-proxy": false,
    "experimental": true,
    "features": {
        "buildkit": true
    }
}
EOF
            log_pass "Docker daemon configuration created (using USB storage)"
        else
            log_info "Docker daemon configuration already exists"
            log_warn "Manual review recommended for USB paths"
        fi
    else
        log_warn "USB filesystem is $usb_fstype (not ext4)"
        log_warn "Skipping Docker USB storage configuration to prevent errors"
        log_info "Docker will use default storage (SD card)"
    fi
    
    # Restart Docker to apply configuration
    log_info "Restarting Docker service..."
    systemctl restart docker || log_warn "Failed to restart Docker service"
    
    # Verify Docker is still running
    if systemctl is-active --quiet docker; then
        log_pass "Docker configured and running"
    else
        log_fail "Docker service died after configuration"
        log_error "Check daemon.json configuration"
    fi
    
    # Get Docker info
    local docker_version=$(docker --version)
    local docker_info=$(docker info 2>/dev/null | grep -E "Storage Driver|Root Dir")
    log_info "Docker version: $docker_version"
    log_info "Docker storage info:"
    echo "$docker_info" | sed 's/^/  /'
}

################################################################################
# USB Mount Setup
#
# FILESYSTEM SUPPORT:
# - ext4: Full support with error recovery (errors=remount-ro)
# - vFAT/FAT32: Compatible but no error handling options (use defaults,nofail,noatime)
# - exFAT: Compatible but requires exfat-fuse package
# - NTFS: Compatible but requires ntfs-3g package
# 
# The USB device will be auto-detected or can be manually specified by the user.
# For Docker storage, ext4 is recommended but other filesystems will work.
################################################################################

select_usb_device() {
    log_section "USB DEVICE SELECTION"
    
    log_info "Scanning for USB devices..."
    
    if ! command_exists lsblk; then
        log_error "lsblk not found - cannot detect USB devices"
    fi
    
    # Find boot device
    local boot_dev=$(mount | grep "on / " | awk '{print $1}' | sed 's/[0-9]*$//')
    log_pass "Boot device: $boot_dev"
    
    # Find USB devices (excluding boot device)
    local boot_dev_name=$(basename "$boot_dev")
    local usb_devices=$(lsblk -d -o NAME,SIZE,TRAN | grep -i usb | awk '{print $1}' | \
        while read dev; do
            if [[ "$dev" != "$boot_dev_name" ]] && [[ ! "$dev" =~ ^${boot_dev_name%[0-9]*} ]]; then
                echo "/dev/$dev"
            fi
        done)
    
    # Show devices
    echo ""
    log_info "Available block devices:"
    lsblk -o NAME,SIZE,TRAN,FSTYPE
    echo ""
    
    if [[ -z "$usb_devices" ]]; then
        log_warn "No additional USB devices auto-detected"
    else
        local usb_count=$(echo "$usb_devices" | wc -l)
        log_pass "Found $usb_count additional USB device(s):"
        echo "$usb_devices" | while read dev; do
            local size=$(lsblk -d -h -o SIZE "$dev" | tail -1)
            local fstype=$(lsblk -d -o FSTYPE "$dev" | tail -1)
            log_info "  $dev ($size, $fstype)"
        done
    fi
    
    # Ask user for device path
    log_warn "Please specify the USB device to use (e.g., /dev/sdb1)"
    local user_device
    read -p "$(echo -e ${CYAN}Enter USB device path${NC} []: )" -r user_device
    
    if [[ -z "$user_device" ]]; then
        if [[ -n "$usb_devices" ]]; then
            user_device=$(echo "$usb_devices" | head -1)
            log_info "Using auto-detected device: $user_device"
        else
            log_error "No device specified and no USB devices auto-detected"
        fi
    fi
    
    SELECTED_USB_DEVICE="$user_device"
}

usb_mount_setup() {
    log_section "USB MOUNT CONFIGURATION"
    
    # Detect USB device
    select_usb_device
    local usb_device="$SELECTED_USB_DEVICE"
    
    if [[ -z "$usb_device" ]]; then
        return 1
    fi
    
    # Check if device exists
    if [[ ! -b "$usb_device" ]]; then
        log_error "USB device not found: $usb_device"
    fi
    
    log_pass "Using USB device: $usb_device"
    
    # Check filesystem on the device
    log_info "Detecting filesystem on $usb_device..."
    local fstype=$(lsblk -d -o FSTYPE "$usb_device" | tail -1)
    if [[ -z "$fstype" ]]; then
        log_warn "No filesystem detected on $usb_device"
        if confirm_action "Format $usb_device to ext4 (ERASES ALL DATA)?"; then
             log_info "Formatting $usb_device to ext4..."
             mkfs.ext4 -F "$usb_device" || log_error "Failed to format $usb_device"
             fstype="ext4"
             log_pass "Formatted $usb_device to ext4"
             sleep 2
        else
             log_fail "No filesystem detected on $usb_device"
             log_error "Please format the USB device with a filesystem first"
        fi
    fi
    log_pass "Filesystem: $fstype"
    
    # Create mount point
    if [[ ! -d "$USB_MOUNT_PATH" ]]; then
        mkdir -p "$USB_MOUNT_PATH" || log_error "Failed to create mount point: $USB_MOUNT_PATH"
        log_pass "Created mount point: $USB_MOUNT_PATH"
    else
        log_pass "Mount point exists: $USB_MOUNT_PATH"
    fi
    
    # Mount the device
    if mount | grep -q "on $USB_MOUNT_PATH type"; then
        log_info "Device already mounted at $USB_MOUNT_PATH"
    else
        log_info "Mounting $usb_device at $USB_MOUNT_PATH..."
        mount "$usb_device" "$USB_MOUNT_PATH" || log_error "Failed to mount $usb_device"
        log_pass "USB device mounted at $USB_MOUNT_PATH"
    fi
    
    # Determine mount options based on filesystem type
    local mount_opts
    case "$fstype" in
        ext4)
            # ext4 supports error handling options
            mount_opts="defaults,nofail,noatime,errors=remount-ro"
            ;;
        vfat|ntfs|exfat)
            # FAT/NTFS/exFAT filesystems don't support all ext4 options
            # Skip errors=remount-ro for compatibility
            mount_opts="defaults,nofail,noatime"
            ;;
        *)
            # Default fallback for unknown filesystems
            mount_opts="defaults,nofail,noatime"
            log_warn "Unknown filesystem type: $fstype - using default mount options"
            ;;
    esac
    
    log_pass "Using mount options for $fstype: $mount_opts"
    
    # Configure persistent mounting via fstab
    backup_file /etc/fstab
    
    log_info "Configuring persistent mount in /etc/fstab..."
    
    # Remove existing entry if present (check by mount point)
    if grep -q "$USB_MOUNT_PATH" /etc/fstab; then
        log_warn "Entry already exists in /etc/fstab for $USB_MOUNT_PATH"
        log_info "Removing old entry..."
        sed -i "\|$USB_MOUNT_PATH|d" /etc/fstab
    fi
    
    cat >> /etc/fstab << EOF
# External USB drive for Docker volumes and data storage
$usb_device $USB_MOUNT_PATH $fstype $mount_opts 0 2
EOF
    log_pass "Added fstab entry for USB device: $usb_device"
    
    # Set permissions
    log_info "Setting permissions on $USB_MOUNT_PATH..."
    chmod 755 "$USB_MOUNT_PATH"
    
    # Create subdirectories for Docker
    mkdir -p "$USB_MOUNT_PATH/docker" "$USB_MOUNT_PATH/data" "$USB_MOUNT_PATH/backups"
    chmod 700 "$USB_MOUNT_PATH/docker"
    chmod 755 "$USB_MOUNT_PATH/data" "$USB_MOUNT_PATH/backups"
    
    log_pass "USB mount configured successfully"
    log_info "  Mount point: $USB_MOUNT_PATH"
    log_info "  Docker root: $USB_MOUNT_PATH/docker"
    log_info "  Data directory: $USB_MOUNT_PATH/data"
    log_info "  Backups directory: $USB_MOUNT_PATH/backups"
}

################################################################################
# Hardware Pruning
################################################################################

hardware_pruning() {
    log_section "HARDWARE PRUNING"
    
    if ! confirm_action "Disable Bluetooth and audio (saves power/interrupts)?"; then
        log_warn "Skipped hardware pruning"
        return 0
    fi
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Config file not found: $CONFIG_FILE"
    fi
    
    backup_file "$CONFIG_FILE"
    
    log_info "Disabling Bluetooth..."
    if grep -q "dtoverlay=disable-bt" "$CONFIG_FILE"; then
        log_info "  Bluetooth already disabled"
    else
        echo "dtoverlay=disable-bt" >> "$CONFIG_FILE"
        log_pass "Bluetooth disabled"
    fi
    
    log_info "Disabling audio..."
    if grep -q "dtparam=audio=off" "$CONFIG_FILE"; then
        log_info "  Audio already disabled"
    else
        echo "dtparam=audio=off" >> "$CONFIG_FILE"
        log_pass "Audio disabled"
    fi
    
    log_warn "Hardware changes require reboot to apply"
}

################################################################################
# Optimization Configuration
################################################################################

apply_optimizations() {
    log_section "APPLYING OPTIMIZATIONS"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Config file not found: $CONFIG_FILE"
    fi
    
    backup_file "$CONFIG_FILE"
    
    # Fan configuration for Pi 5
    log_info "Configuring active cooling (Pi 5)..."
    if grep -q "dtparam=fan_temp0" "$CONFIG_FILE"; then
        log_info "  Fan curve already configured"
    else
        cat >> "$CONFIG_FILE" << 'EOF'

# Active Cooling for Pi 5
dtparam=fan_temp0=35000
dtparam=fan_temp0_hyst=5000
dtparam=fan_temp0_speed=125
dtparam=fan_temp1=50000
dtparam=fan_temp1_speed=200
EOF
        log_pass "Fan curve configured"
    fi
    
    # Optimize fstab for USB longevity
    backup_file /etc/fstab
    
    log_info "Optimizing root filesystem (noatime)..."
    if grep -q "/ .*noatime" /etc/fstab; then
        log_info "  Optimizations already applied"
    else
        # Backup original
        cp /etc/fstab /etc/fstab.orig
        
        # Update root entry - add noatime if not present
        sed -i 's|^\(/[^ ]* / [^ ]* \)\([^ ]*\)|\1\2,noatime|' /etc/fstab
        
        log_pass "Root filesystem optimized"
    fi
    
    # ZRAM configuration
    log_info "Configuring ZRAM for compression..."
    mkdir -p /etc/rpi/swap.conf.d
    
    if [[ ! -f /etc/rpi/swap.conf.d/size.conf ]]; then
        cat > /etc/rpi/swap.conf.d/size.conf << 'EOF'
[Zram]
MaxSizeMiB=2048
CompressionAlgorithm=zstd
EOF
        log_pass "ZRAM configuration created"
    else
        log_info "  ZRAM already configured"
    fi
    
    # Disable log2ram's ZL2R to avoid conflicts
    if [[ -f /etc/log2ram.conf ]]; then
        log_info "Optimizing log2ram..."
        sed -i 's/ZL2R=true/ZL2R=false/' /etc/log2ram.conf
        sed -i 's/SIZE=40M/SIZE=100M/' /etc/log2ram.conf
        log_pass "log2ram optimized"
    fi
}

################################################################################
# Reboot Prompt
################################################################################

reboot_prompt() {
    log_section "INSTALLATION COMPLETE"
    
    log_success "✓ Setup completed successfully!"
    
    log_info ""
    log_info "Summary:"
    log_info "  Checks passed: $CHECKS_PASSED"
    log_info "  Issues found: $CHECKS_FAILED"
    log_info "  Warnings: $WARNINGS"
    
    log_info ""
    log_info "Next steps:"
    log_info "  1. Review configurations in:"
    log_info "     - $CONFIG_FILE"
    log_info "     - /etc/fstab"
    log_info "     - /etc/docker/daemon.json"
    log_info "  2. Verify USB mount:"
    log_info "     mount | grep $USB_MOUNT_PATH"
    log_info "  3. Test Docker:"
    log_info "     docker ps"
    log_info "  4. Run diagnostic:"
    log_info "     sudo ./diag.sh"
    
    log_warn ""
    log_warn "REBOOT REQUIRED to apply changes!"
    
    if confirm_action "Reboot system now?"; then
        log_info "Rebooting..."
        sleep 2
        reboot
    else
        log_info "Remember to reboot manually: sudo reboot"
    fi
}

################################################################################
# Main Execution
################################################################################

main() {
    require_root
    
    log_section "RASPBERRY PI HOME SERVER SETUP v$SCRIPT_VERSION"
    log_info "Target: Raspberry Pi OS Debian Trixie with Docker + USB"
    log_info ""
    
    # Pre-flight
    preflight_checks
    
    # System update
    system_update
    install_dependencies
    
    # Docker
    docker_install
    docker_setup
    
    # USB Mount
    usb_mount_setup
    
    # Hardware
    hardware_pruning
    
    # Optimizations
    apply_optimizations
    
    # Reboot
    reboot_prompt
}

# Execute main
main "$@"
