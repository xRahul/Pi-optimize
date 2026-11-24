#!/usr/bin/env bats

# Mocks defined in setup() are invoked indirectly by the sourced script under test.
# shellcheck disable=SC2317
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
    load helpers/setup
    make_testable optimize.sh "$MOCK_DIR/optimize_testable.sh"

    # Replace /etc/fstab with a mock file path to allow writing
    sed -i "s|/etc/fstab|${MOCK_DIR}/fstab|g" "$MOCK_DIR/optimize_testable.sh"

    # Bypass [[ -b ... ]] check for USB device
    # Matches: if [[ ! -b "$usb_dev_path" ]]; then
    # We replace it with: if [[ -z "$usb_dev_path" ]]; then (which is false as it's set)
    # Single quotes required: sed needs the literal backslash-dollar escape
    # shellcheck disable=SC2016
    sed -i 's|if \[\[ ! -b "\$usb_dev_path" \]\]; then|if [[ -z "$usb_dev_path" ]]; then|' "$MOCK_DIR/optimize_testable.sh"

    chmod +x "$MOCK_DIR/optimize_testable.sh"

    # Create mock fstab
    touch "$MOCK_DIR/fstab"

    # Mock systemctl
    echo '#!/bin/bash' > "$MOCK_DIR/bin/systemctl"
    chmod +x "$MOCK_DIR/bin/systemctl"

    # Mock findmnt: root query returns the SD root, /mnt/usb query is configurable
    cat << 'EOF' > "$MOCK_DIR/bin/findmnt"
#!/bin/bash
if [[ "$*" == *"/mnt/usb"* ]]; then
    echo "${MOCK_FINDMNT_USB:-}"
else
    echo /dev/mmcblk0p2
fi
EOF
    chmod +x "$MOCK_DIR/bin/findmnt"
    export MOCK_FINDMNT_USB=""

    # Mock blkid - handle both UUID and TYPE queries (sdb1 can differ per test)
    cat << 'EOF' > "$MOCK_DIR/bin/blkid"
#!/bin/bash
# Usage: blkid -s TAG -o value DEVICE
if [[ "$*" == *"sdb1"* ]]; then
    echo "${MOCK_BLKID_UUID_SDB:-UUID-SDB}"
elif [[ "$2" == "UUID" ]]; then
    echo "${MOCK_BLKID_UUID:-UUID-1234}"
elif [[ "$2" == "TYPE" ]]; then
    echo "${MOCK_BLKID_TYPE:-ext4}"
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
    # Base state: empty -> mock falls back to its default scenario (tests override per scenario)
    export LSBLK_OUTPUT=""
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
    # Generated at test runtime; cannot be statically followed
    # shellcheck source=/dev/null
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
    # Exported in setup; plain assignment keeps the export attribute (mock lsblk child reads it)
    LSBLK_OUTPUT="mmcblk0p1 mmc part mmcblk0\nsda1 usb part sda"

    run setup_usb_automount

    echo "Output: $output"
    [[ "$output" == *"LOG_PASS: USB mount added to fstab"* ]]
}

@test "setup_usb_automount ignores root disk partitions" {
    LSBLK_OUTPUT="mmcblk0p1 mmc part mmcblk0\nmmcblk0p2 mmc part mmcblk0"

    run setup_usb_automount

    echo "Output: $output"
    [[ "$output" == *"LOG_WARN: No USB device detected"* ]]
}

@test "setup_usb_automount detects SD card as valid external storage" {
    LSBLK_OUTPUT="mmcblk0p1 mmc part mmcblk0\nmmcblk1p1 mmc part mmcblk1"

    run setup_usb_automount

    echo "Output: $output"
    [[ "$output" == *"LOG_PASS: USB mount added to fstab"* ]]
}

@test "setup_usb_automount configures exfat options correctly" {
    LSBLK_OUTPUT="mmcblk0p1 mmc part mmcblk0\nsda1 usb part sda"
    export MOCK_BLKID_TYPE="exfat"
    export MOCK_BLKID_UUID="9063-18C1"

    run setup_usb_automount

    echo "Output: $output"
    [[ "$output" == *"LOG_PASS: USB mount added to fstab (UUID: 9063-18C1, Type: exfat)"* ]]
    fstab_content=$(cat "$MOCK_DIR/fstab")
    echo "Fstab: $fstab_content"
    [[ "$fstab_content" == *"UUID=9063-18C1  /mnt/usb  exfat  defaults,nofail,noatime,uid=1000,gid=1000,umask=002,iocharset=utf8,errors=remount-ro  0  0"* ]]
    [[ "$fstab_content" != *",utf8,"* && "$fstab_content" != *" utf8 "* && "$fstab_content" != *",utf8 "* ]]
}

@test "setup_usb_automount updates existing fstab entry when UUID changes" {
    echo -e "# Old drive\nUUID=OLD-UUID-1111  /mnt/usb  vfat  defaults  0  0" > "$MOCK_DIR/fstab"
    LSBLK_OUTPUT="mmcblk0p1 mmc part mmcblk0\nsda1 usb part sda"
    export MOCK_BLKID_TYPE="exfat"
    export MOCK_BLKID_UUID="NEW-UUID-2222"

    run setup_usb_automount

    echo "Output: $output"
    [[ "$output" == *"LOG_PASS: USB mount updated in fstab (UUID: NEW-UUID-2222, Type: exfat)"* ]]
    fstab_content=$(cat "$MOCK_DIR/fstab")
    echo "Fstab: $fstab_content"
    [[ "$fstab_content" == *"# Old drive"* ]]
    [[ "$fstab_content" == *"UUID=NEW-UUID-2222  /mnt/usb  exfat  "* ]]
    [[ "$fstab_content" != *"OLD-UUID-1111"* ]]
}

@test "setup_usb_automount skips when exact UUID and mount point already in fstab" {
    echo -e "UUID=EXISTING-1234  /mnt/usb  exfat  defaults  0  0" > "$MOCK_DIR/fstab"
    LSBLK_OUTPUT="mmcblk0p1 mmc part mmcblk0\nsda1 usb part sda"
    export MOCK_BLKID_TYPE="exfat"
    export MOCK_BLKID_UUID="EXISTING-1234"

    run setup_usb_automount

    echo "Output: $output"
    [[ "$output" == *"LOG_SKIP: USB mount already configured in fstab"* ]]
}

@test "setup_usb_automount pins to the mounted device when another USB disk is listed first" {
    # Backup HDD (sda1) sorts first, but /mnt/usb is sdb1 and must stay pinned to it
    LSBLK_OUTPUT="mmcblk0p1 mmc part mmcblk0\nsda1 usb part sda\nsdb1 usb part sdb"
    export MOCK_FINDMNT_USB="/dev/sdb1"
    export MOCK_BLKID_UUID_SDB="GOOD-UUID"
    export MOCK_BLKID_UUID="BAD-UUID"
    export MOCK_BLKID_TYPE="exfat"
    echo "UUID=GOOD-UUID  /mnt/usb  exfat  defaults,nofail,noatime  0  0" > "$MOCK_DIR/fstab"

    run setup_usb_automount

    echo "Output: $output"
    [[ "$output" == *"LOG_SKIP: USB mount already configured in fstab (UUID: GOOD-UUID)"* ]]
    ! grep -q "BAD-UUID" "$MOCK_DIR/fstab"
}

@test "setup_usb_automount refuses to guess when multiple USB disks and mount not in fstab" {
    LSBLK_OUTPUT="mmcblk0p1 mmc part mmcblk0\nsda1 usb part sda\nsdb1 usb part sdb"
    export MOCK_FINDMNT_USB=""

    run setup_usb_automount

    echo "Output: $output"
    [[ "$output" == *"LOG_WARN: Multiple USB partitions found"* ]]
    [ ! -s "$MOCK_DIR/fstab" ]
}
