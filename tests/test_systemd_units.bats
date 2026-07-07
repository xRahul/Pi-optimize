#!/usr/bin/env bats

setup() {
    MOCK_DIR=$(mktemp -d)
    export MOCK_DIR

    mkdir -p "$MOCK_DIR/bin" "$MOCK_DIR/lib" "$MOCK_DIR/etc/systemd/system" "$MOCK_DIR/usr/local/bin"
    export PATH="$MOCK_DIR/bin:$PATH"

    cat << 'EOF' > "$MOCK_DIR/bin/systemctl"
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/bin/systemctl"

    cat << 'EOF' > "$MOCK_DIR/bin/ethtool"
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/bin/ethtool"

    cat << 'EOF' > "$MOCK_DIR/lib/utils.sh"
log_info() { echo "LOG_INFO: $*"; }
log_pass() { echo "LOG_PASS: $*"; }
log_warn() { echo "LOG_WARN: $*"; }
log_skip() { echo "LOG_SKIP: $*"; }
log_section() { :; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
files_differ() { return 0; }
backup_file() { :; }
get_target_user() { echo "${USER:-rahul}"; }
EOF

    cp optimize.sh "$MOCK_DIR/optimize_testable.sh"
    sed -i '/set -euo pipefail/d' "$MOCK_DIR/optimize_testable.sh"
    sed -i '/trap /d' "$MOCK_DIR/optimize_testable.sh"
    sed -i 's/^main "$@".*/# main "$@"/' "$MOCK_DIR/optimize_testable.sh"
    sed -i "s|/etc/systemd/system|$MOCK_DIR/etc/systemd/system|g" "$MOCK_DIR/optimize_testable.sh"
    sed -i "s|/usr/local/bin/graceful-reboot|$MOCK_DIR/usr/local/bin/graceful-reboot|g" "$MOCK_DIR/optimize_testable.sh"

    mkdir -p "$MOCK_DIR/sys/class/net/eth0"
    sed -i "s|/sys/class/net|$MOCK_DIR/sys/class/net|g" "$MOCK_DIR/optimize_testable.sh"

    source "$MOCK_DIR/optimize_testable.sh"
}

teardown() {
    rm -rf "$MOCK_DIR"
}

@test "setup_daily_reboot writes absolute ExecStart and readable units" {
    run setup_daily_reboot
    echo "$output"
    [ "$status" -eq 0 ]

    service_file="$MOCK_DIR/etc/systemd/system/rpi-daily-reboot.service"
    timer_file="$MOCK_DIR/etc/systemd/system/rpi-daily-reboot.timer"
    reboot_script="$MOCK_DIR/usr/local/bin/graceful-reboot"

    run cat "$service_file"
    [[ "$output" =~ "ConditionPathExists=$reboot_script" ]]
    [[ "$output" =~ "ExecStart=$reboot_script" ]]
    [[ ! "$output" =~ '$reboot_script' ]]

    run cat "$reboot_script"
    [[ "$output" =~ "/docker" ]]
    [[ ! "$output" =~ '$docker_dir' ]]

    run stat -c "%a" "$service_file"
    [ "$output" = "644" ]

    run stat -c "%a" "$timer_file"
    [ "$output" = "644" ]
}

@test "optimize_network installs rpi5-udp-gro.service with readable permissions" {
    run optimize_network
    echo "$output"
    [ "$status" -eq 0 ]

    service_file="$MOCK_DIR/etc/systemd/system/rpi5-udp-gro.service"
    run cat "$service_file"
    [[ "$output" =~ "ExecStart=/sbin/ethtool -K eth0 rx-udp-gro-forwarding on rx-gro-list off" ]]

    run stat -c "%a" "$service_file"
    [ "$output" = "644" ]
}
