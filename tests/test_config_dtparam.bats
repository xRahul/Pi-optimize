#!/usr/bin/env bats
# Unit tests for optimize.sh config-writing helpers: fan curve and watchdog assertion.
# CONFIG_FILE is env-overridable so these never touch the real /boot/firmware/config.txt.
# shellcheck disable=SC2317
setup() {
    MOCK_DIR=$(mktemp -d)
    export MOCK_DIR
    mkdir -p "$MOCK_DIR/bin" "$MOCK_DIR/lib"
    export PATH="$MOCK_DIR/bin:$PATH"
    # optimize.sh sources ${SCRIPT_DIR}/lib/utils.sh; empty stub is enough with overrides below
    : > "$MOCK_DIR/lib/utils.sh"

    export CONFIG_FILE="$MOCK_DIR/config.txt"
    : > "$CONFIG_FILE"

    # Mock systemctl so the watchdog assertion is deterministic
    cat << 'EOF' > "$MOCK_DIR/bin/systemctl"
#!/bin/bash
if [[ "$1" == "show" ]]; then
    echo "RuntimeWatchdogUSec=${MOCK_WD:-15s}"
    exit 0
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/bin/systemctl"

    load helpers/setup
    make_testable optimize.sh "$MOCK_DIR/optimize_testable.sh"
    chmod +x "$MOCK_DIR/optimize_testable.sh"

    set +u
    # shellcheck source=/dev/null
    source "$MOCK_DIR/optimize_testable.sh"
    set -u

    log_info() { echo "LOG_INFO: $*"; }
    log_warn() { echo "LOG_WARN: $*"; }
    log_skip() { echo "LOG_SKIP: $*"; }
    log_pass() { echo "LOG_PASS: $*"; }
    log_section() { :; }
    log_error() { echo "LOG_ERROR: $*"; }
    log_fail() { echo "LOG_FAIL: $*"; }
    backup_file() { :; }
    files_differ() { return 0; }
    command_exists() { command -v "$1" >/dev/null 2>&1; }
}

teardown() {
    rm -rf "$MOCK_DIR"
}

@test "optimize_fan_curve skips when all five stock values are present" {
    cat > "$CONFIG_FILE" << 'EOF'
# Active Cooling for Pi 5
dtparam=fan_temp0=50000
dtparam=fan_temp0_hyst=5000
dtparam=fan_temp0_speed=75
dtparam=fan_temp1=60000
dtparam=fan_temp1_speed=125
EOF
    before=$(md5sum "$CONFIG_FILE")
    run optimize_fan_curve
    echo "$output"
    [[ "$output" == *"LOG_SKIP: Fan curve already configured"* ]]
    [ "$(md5sum "$CONFIG_FILE")" = "$before" ]
}

@test "optimize_fan_curve rewrites stale aggressive values in place" {
    cat > "$CONFIG_FILE" << 'EOF'
[all]
dtparam=audio=off

# Active Cooling for Pi 5
dtparam=fan_temp0=35000
dtparam=fan_temp0_hyst=5000
dtparam=fan_temp0_speed=125
dtparam=fan_temp1=50000
dtparam=fan_temp1_speed=200
dtparam=watchdog=on
EOF
    run optimize_fan_curve
    echo "$output"
    [[ "$output" == *"LOG_PASS: Fan curve updated to quiet profile"* ]]
    grep -q '^dtparam=fan_temp0=50000$' "$CONFIG_FILE"
    grep -q '^dtparam=fan_temp0_speed=75$' "$CONFIG_FILE"
    grep -q '^dtparam=fan_temp1=60000$' "$CONFIG_FILE"
    grep -q '^dtparam=fan_temp1_speed=125$' "$CONFIG_FILE"
    ! grep -q '35000' "$CONFIG_FILE"
    # Unrelated keys must survive untouched
    grep -q '^dtparam=audio=off$' "$CONFIG_FILE"
    grep -q '^dtparam=watchdog=on$' "$CONFIG_FILE"
}

@test "optimize_fan_curve appends full curve when absent" {
    printf '[all]\ndtparam=audio=off\n' > "$CONFIG_FILE"
    run optimize_fan_curve
    echo "$output"
    [[ "$output" == *"LOG_PASS: Fan curve optimized"* ]]
    grep -q '^dtparam=fan_temp0=50000$' "$CONFIG_FILE"
    grep -q '^dtparam=fan_temp0_hyst=5000$' "$CONFIG_FILE"
    grep -q '^dtparam=fan_temp0_speed=75$' "$CONFIG_FILE"
    grep -q '^dtparam=fan_temp1=60000$' "$CONFIG_FILE"
    grep -q '^dtparam=fan_temp1_speed=125$' "$CONFIG_FILE"
}

@test "assert_watchdog_armed passes when systemd armed the watchdog" {
    export MOCK_WD="15s"
    run assert_watchdog_armed
    echo "$output"
    [[ "$output" == *"LOG_PASS: Watchdog armed by systemd (15s)"* ]]
}

@test "assert_watchdog_armed warns when the watchdog is not armed" {
    export MOCK_WD="0"
    run assert_watchdog_armed
    echo "$output"
    [[ "$output" == *"LOG_WARN: Watchdog not armed"* ]]
}
