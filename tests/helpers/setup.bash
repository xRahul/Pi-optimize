#!/bin/bash
# Shared test helpers for the rpi-optimize bats suite.

# make_testable <script_path> <output_path>
# Produces a sourceable copy of a main-script by disabling its `main "$@"`
# invocation. Unlike the previous `sed '$d'` (which stripped "the last line"
# and silently executed main whenever the file gained trailing content), this
# matches the exact invocation line.
# Also strips `set -euo pipefail` and the ERR/EXIT `trap` lines: leaking those
# into the bats shell makes any failing command abort the whole test silently
# (trap_error exits 1) instead of reporting an assertion failure.
make_testable() {
    local src="$1" dst="$2"
    sed -e 's/^set -euo pipefail$/# strict mode disabled for tests/' \
        -e '/^trap /d' \
        -e 's/^BOOT_TRAN=""$/# BOOT_TRAN managed by tests (do not reset on source)/' \
        -e 's/^main "\$@".*/# main disabled for tests/' "$src" > "$dst"
}

# standard_log_overrides
# Installs no-op logging overrides and common stubs into the sourcing shell.
# Call AFTER sourcing the script under test.

# shellcheck disable=SC2317
standard_log_overrides() {
    log_info() { echo "LOG_INFO: $*"; }
    log_warn() { echo "LOG_WARN: $*"; }
    log_skip() { echo "LOG_SKIP: $*"; }
    log_pass() { echo "LOG_PASS: $*"; }
    log_section() { :; }
    log_error() { echo "LOG_ERROR: $*"; exit 1; }
    log_fail() { echo "LOG_FAIL: $*"; }
    backup_file() { :; }
    files_differ() { return 0; }
}

# new_mock_dir
# Creates a fresh sandbox with a bin/ dir prepended to PATH (exported MOCK_DIR).
new_mock_dir() {
    MOCK_DIR=$(mktemp -d)
    export MOCK_DIR
    mkdir -p "$MOCK_DIR/bin"
}
