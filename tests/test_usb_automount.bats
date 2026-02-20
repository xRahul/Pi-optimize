#!/usr/bin/env bats

setup() {
    # Create a temporary directory for mocks
    MOCK_DIR=$(mktemp -d)
    export MOCK_DIR

    # Create bin directory for mocked commands
    mkdir -p "$MOCK_DIR/bin"
    export PATH="$MOCK_DIR/bin:$PATH"

    # Mock utils.sh
    mkdir -p "$MOCK_DIR/lib"
    touch "$MOCK_DIR/lib/utils.sh"

    # Prepare optimize.sh for sourcing
    sed '$d' optimize.sh > "$MOCK_DIR/optimize_testable.sh"

    # Replace /etc/fstab with a mock file path to allow writing
    sed -i "s|/etc/fstab|${MOCK_DIR}/fstab|g" "$MOCK_DIR/optimize_testable.sh"

    # Bypass [[ -b ... ]] check for USB device
    # Matches: if [[ ! -b "$usb_dev_path" ]]; then
    # We replace it with: if [[ -z "$usb_dev_path" ]]; then (which is false as it's set)
    sed -i 's|if \[\[ ! -b "\$usb_dev_path" \]\]; then|if [[ -z "$usb_dev_path" ]]; then|' "$MOCK_DIR/optimize_testable.sh"

    chmod +x "$MOCK_DIR/optimize_testable.sh"

    # Create mock fstab
    touch "$MOCK_DIR/fstab"

    # Mock systemctl
    echo '#!/bin/bash' > "$MOCK_DIR/bin/systemctl"
    chmod +x "$MOCK_DIR/bin/systemctl"

    # Mock findmnt to return root source
    echo '#!/bin/bash' > "$MOCK_DIR/bin/findmnt"
    echo 'echo /dev/mmcblk0p2' >> "$MOCK_DIR/bin/findmnt"
    chmod +x "$MOCK_DIR/bin/findmnt"

    # Mock blkid - handle both UUID and TYPE queries
    cat << 'EOF' > "$MOCK_DIR/bin/blkid"
#!/bin/bash
# Usage: blkid -s TAG -o value DEVICE
if [[ "$2" == "UUID" ]]; then
    echo "UUID-1234"
elif [[ "$2" == "TYPE" ]]; then
    echo "ext4"
else
    echo "mock-value"
fi
EOF
    chmod +x "$MOCK_DIR/bin/blkid"

    # Mock mount
    echo '#!/bin/bash' > "$MOCK_DIR/bin/mount"
    chmod +x "$MOCK_DIR/bin/mount"

    # Mock mkdir
    echo '#!/bin/bash' > "$MOCK_DIR/bin/mkdir"
    chmod +x "$MOCK_DIR/bin/mkdir"

    # Mock lsblk with a configurable output
    cat << 'EOF' > "$MOCK_DIR/bin/lsblk"
#!/bin/bash
# Check if PKNAME is requested for root_dev (first call in setup_usb_automount)
if [[ "$*" == *"/dev/mmcblk0p2"* ]]; then
    echo "mmcblk0"
    exit 0
fi

# Main listing call (the one we are testing)
if [[ "$*" == *"NAME,TRAN,TYPE,PKNAME"* ]]; then
    if [[ -n "$LSBLK_OUTPUT" ]]; then
        echo -e "$LSBLK_OUTPUT"
    else
        # Default scenario
        echo "mmcblk0 mmc disk"
        echo "mmcblk0p1 mmc part mmcblk0"
        echo "mmcblk0p2 mmc part mmcblk0"
        echo "sda usb disk"
        echo "sda1 usb part sda"
    fi
    exit 0
fi
EOF
    chmod +x "$MOCK_DIR/bin/lsblk"

    # Source the script
    set +u
    source "$MOCK_DIR/optimize_testable.sh"
    set -u

    # Override log functions to capture output
    log_info() { echo "LOG_INFO: $*"; }
    log_warn() { echo "LOG_WARN: $*"; }
    log_skip() { echo "LOG_SKIP: $*"; }
    log_pass() { echo "LOG_PASS: $*"; }
    log_section() { :; }
    log_error() { echo "LOG_ERROR: $*"; }
    backup_file() { :; }
}

teardown() {
    rm -rf "$MOCK_DIR"
}

@test "setup_usb_automount selects correct USB partition" {
    export LSBLK_OUTPUT="mmcblk0p1 mmc part mmcblk0\nsda1 usb part sda"

    run setup_usb_automount

    echo "Output: $output"
    [[ "$output" =~ "LOG_PASS: USB mount added to fstab" ]]
}

@test "setup_usb_automount ignores root disk partitions" {
    export LSBLK_OUTPUT="mmcblk0p1 mmc part mmcblk0\nmmcblk0p2 mmc part mmcblk0"

    run setup_usb_automount

    echo "Output: $output"
    [[ "$output" =~ "LOG_WARN: No USB device detected" ]]
}

@test "setup_usb_automount detects SD card as valid external storage" {
    export LSBLK_OUTPUT="mmcblk0p1 mmc part mmcblk0\nmmcblk1p1 mmc part mmcblk1"

    run setup_usb_automount

    echo "Output: $output"
    [[ "$output" =~ "LOG_PASS: USB mount added to fstab" ]]
}
