#!/usr/bin/env bats

# MOCKS must be exported to be visible in subshells like <(...)
mock_dpkg_query() {
    # Return 'ii' status for some packages
    echo "ii curl"
    echo "ii rsyslog"
    echo "ii bash"
}
export -f mock_dpkg_query

setup() {
    # Prepare setup.sh
    sed '$d' setup.sh > setup_no_main.sh
    chmod +x setup_no_main.sh

    # Source it
    source ./setup_no_main.sh

    # Redefine log functions here to override utils.sh
    log_info() { echo "LOG_INFO: $*"; }
    log_warn() { echo "LOG_WARN: $*"; }
    log_skip() { echo "LOG_SKIP: $*"; }
    log_pass() { echo "LOG_PASS: $*"; }
    log_section() { :; }
    log_error() { echo "LOG_ERROR: $*"; exit 1; }

    # Alias dpkg-query to our mock function
    # We can't export a function with a hyphen easily in some shells,
    # but we can try exporting the function definition or use a wrapper script.
    # The easiest way to mock a command in a subshell is to create a bin dir in PATH.

    mkdir -p test_bin
    cat << 'EOF' > test_bin/dpkg-query
#!/bin/bash
echo "ii curl"
echo "ii rsyslog"
echo "ii bash"
EOF
    chmod +x test_bin/dpkg-query

    # Mock apt-get as well in bin
    cat << 'EOF' > test_bin/apt-get
#!/bin/bash
echo "MOCK_APT: $*"
EOF
    chmod +x test_bin/apt-get

    # Add test_bin to PATH
    export PATH="$PWD/test_bin:$PATH"
}

teardown() {
    rm -f setup_no_main.sh
    rm -rf test_bin
}

# Mock wait_for_apt_lock to avoid delay (function override works for main shell)
wait_for_apt_lock() {
    :
}

@test "system_core skips installed packages (e.g. curl)" {
    run system_core
    [ "$status" -eq 0 ]
    [[ "$output" =~ "LOG_SKIP: curl already installed" ]]
}

@test "system_core installs missing packages (e.g. vim)" {
    # vim is in the list, but not in our dpkg-query mock
    run system_core
    [ "$status" -eq 0 ]
    [[ "$output" =~ "LOG_INFO: Installing vim..." ]]
    [[ "$output" =~ "MOCK_APT: install -y vim" ]]
}

@test "system_core detects conflict between busybox-syslogd and rsyslog" {
    # busybox-syslogd is in the setup.sh list
    # rsyslog is in our dpkg-query mock
    run system_core
    [ "$status" -eq 0 ]
    [[ "$output" =~ "LOG_WARN: Skipping busybox-syslogd: rsyslog detected (conflict)" ]]
    # Ensure it did NOT try to install it
    [[ ! "$output" =~ "MOCK_APT: install -y busybox-syslogd" ]]
}
