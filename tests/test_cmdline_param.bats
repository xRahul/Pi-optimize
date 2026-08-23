#!/usr/bin/env bats

# Tests for add_cmdline_param (word-boundary matching, post-write verification).

setup() {
    load helpers/setup
    new_mock_dir
    export PATH="$MOCK_DIR/bin:$PATH"

    mkdir -p "$MOCK_DIR/lib"
    touch "$MOCK_DIR/lib/utils.sh"

    make_testable optimize.sh "$MOCK_DIR/optimize_testable.sh"
    set +u
    source "$MOCK_DIR/optimize_testable.sh"
    set -u
    standard_log_overrides

    export CMDLINE_FILE="$MOCK_DIR/cmdline.txt"
    printf 'console=serial0,115200 rootfstype=ext4 rootwait\n' > "$CMDLINE_FILE"
}

teardown() {
    rm -rf "$MOCK_DIR"
}

@test "add_cmdline_param appends missing parameter" {
    run add_cmdline_param "pcie_aspm=off"
    [ "$status" -eq 0 ]
    run grep -o "pcie_aspm=off" "$CMDLINE_FILE"
    [ "$status" -eq 0 ]
}

@test "add_cmdline_param skips exact existing parameter" {
    printf 'console=serial0,115200 pcie_aspm=off\n' > "$CMDLINE_FILE"
    orig=$(cat "$CMDLINE_FILE")

    run add_cmdline_param "pcie_aspm=off"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "already in cmdline.txt" ]]
    [ "$(cat "$CMDLINE_FILE")" = "$orig" ]
}

@test "add_cmdline_param does not treat superset value as present" {
    # foo=10 exists; asking for foo=1 must NOT be skipped (old grep -F bug)
    printf 'console=serial0 nvme_core.default_ps_max_latency_us=0\n' > "$CMDLINE_FILE"

    run add_cmdline_param "nvme_core.default_ps_max_latency_us=1000"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "added to cmdline.txt" ]]
    # grep -c counts LINES; cmdline.txt is single-line so count occurrences instead
    run bash -c "grep -o 'nvme_core.default_ps_max_latency_us=' '$CMDLINE_FILE' | wc -l"
    [ "$output" -eq 2 ]
}
