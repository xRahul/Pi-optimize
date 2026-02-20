#!/usr/bin/env bats

setup() {
    # Create a temporary directory for mocks
    MOCK_DIR=$(mktemp -d)
    export MOCK_DIR

    # Create bin directory for mocked commands
    mkdir -p "$MOCK_DIR/bin"
    export PATH="$MOCK_DIR/bin:$PATH"

    # Mock lsblk
    cat << 'EOF' > "$MOCK_DIR/bin/lsblk"
#!/bin/bash
echo "sda"
EOF
    chmod +x "$MOCK_DIR/bin/lsblk"

    # Mock systemctl (called by optimize_storage)
    cat << 'EOF' > "$MOCK_DIR/bin/systemctl"
#!/bin/bash
if [[ "$1" == "list-unit-files" ]]; then
    exit 1 # simulate fstrim not found or inactive
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/bin/systemctl"

    # Prepare optimize.sh for sourcing
    # Strip main call
    sed '$d' optimize.sh > "$MOCK_DIR/optimize_testable.sh"
    chmod +x "$MOCK_DIR/optimize_testable.sh"

    # Create lib directory and mock utils.sh
    mkdir -p "$MOCK_DIR/lib"
    touch "$MOCK_DIR/lib/utils.sh"

    # Prepare mock fstab
    export FSTAB_FILE="$MOCK_DIR/fstab"
    touch "$FSTAB_FILE"

    # Mock /sys/block
    export SYS_BLOCK_DIR="$MOCK_DIR/sys/block"
    mkdir -p "$SYS_BLOCK_DIR/sda/queue"

    # Source the script
    # We ignore errors from sourcing because valid utils.sh functions might be missing
    # But we will define them immediately after.
    # Also set +u to avoid unbound variable errors during source if any
    set +u
    source "$MOCK_DIR/optimize_testable.sh"
    set -u

    # Override log functions
    log_info() { echo "LOG_INFO: $*"; }
    log_warn() { echo "LOG_WARN: $*"; }
    log_skip() { echo "LOG_SKIP: $*"; }
    log_pass() { echo "LOG_PASS: $*"; }
    log_section() { :; }
    log_error() { echo "LOG_ERROR: $*"; }

    # Mock backup_file
    backup_file() { :; }
}

teardown() {
    rm -rf "$MOCK_DIR"
}

@test "optimize_storage detects BFQ already active" {
    echo "mq-deadline [bfq] none" > "$SYS_BLOCK_DIR/sda/queue/scheduler"

    run optimize_storage

    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "LOG_SKIP: BFQ already active for sda" ]]
}

@test "optimize_storage sets BFQ when available but not active" {
    echo "mq-deadline bfq [none]" > "$SYS_BLOCK_DIR/sda/queue/scheduler"

    run optimize_storage

    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "LOG_PASS: BFQ set for sda" ]]

    # Verify file content was changed
    run cat "$SYS_BLOCK_DIR/sda/queue/scheduler"
    [[ "$output" == "bfq" ]]
}

@test "optimize_storage skips when BFQ unavailable" {
    echo "mq-deadline [none]" > "$SYS_BLOCK_DIR/sda/queue/scheduler"

    run optimize_storage

    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "LOG_SKIP: BFQ not available for sda" ]]
}

@test "optimize_storage adds noatime to root if missing" {
    # Prepare fstab
    echo "UUID=1234-5678 / ext4 defaults 0 1" > "$FSTAB_FILE"

    run optimize_storage

    echo "$output"
    [[ "$output" =~ "Adding noatime to root filesystem" ]]
    run cat "$FSTAB_FILE"
    [[ "$output" =~ "defaults,noatime" ]]
}

@test "optimize_storage skips noatime if present" {
    # Prepare fstab
    echo "UUID=1234-5678 / ext4 defaults,noatime 0 1" > "$FSTAB_FILE"

    run optimize_storage

    echo "$output"
    [[ "$output" =~ "Root filesystem already has noatime" ]]
    # Ensure it wasn't added twice
    run grep -c "noatime" "$FSTAB_FILE"
    [ "$output" -eq 1 ]
}
