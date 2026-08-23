#!/usr/bin/env bats

# Tests for optimize_memory: swap-manager ownership (rpi-swap vs zram-generator),
# fstab swap-commenting, and swapfile lifecycle. All filesystem access is
# redirected into a sandbox via the FSTAB_FILE / SWAPFILE_PATH / RPI_SWAP_CONF /
# ZRAM_GENERATOR_CONF seams.

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

    # Sandbox seams
    export FSTAB_FILE="$MOCK_DIR/fstab"
    export SWAPFILE_PATH="$MOCK_DIR/swapfile"
    export RPI_SWAP_CONF="$MOCK_DIR/rpi-swap.conf"
    export ZRAM_GENERATOR_CONF="$MOCK_DIR/zram-generator.conf"
    touch "$FSTAB_FILE"

    # Mock swapon: nothing active unless a test pre-seeds state
    cat <<'EOF' > "$MOCK_DIR/bin/swapon"
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/bin/swapon"

    # Mock mkswap/fallocate/dd so an accidental creation path stays sandboxed
    for c in mkswap fallocate dd swapoff; do
        printf '#!/bin/bash\nexit 0\n' > "$MOCK_DIR/bin/$c"
        chmod +x "$MOCK_DIR/bin/$c"
    done
}

teardown() {
    rm -rf "$MOCK_DIR"
}

@test "optimize_memory NVMe branch comments out foreign swap lines correctly" {
    export BOOT_TRAN="nvme"
    cat > "$FSTAB_FILE" <<EOF
PARTUUID=6d6d5a7a-02  /  ext4  defaults,noatime  0  1
/dev/sda2  none  swap  sw  0  0
$SWAPFILE_PATH  none  swap  sw,pri=10,nofail  0  0
EOF
    echo "placeholder" > "$SWAPFILE_PATH"
    # du mock reports correct size so no recreation is attempted
    cat <<'EOF' > "$MOCK_DIR/bin/du"
#!/bin/bash
echo "4096"
EOF
    chmod +x "$MOCK_DIR/bin/du"

    run optimize_memory

    [ "$status" -eq 0 ]
    # Regression test for the mid-line '#' injection bug:
    # the whole line must be commented, not spliced ("none# swap")
    run grep "swap" "$FSTAB_FILE"
    [[ "$output" == *"#/dev/sda2  none  swap  sw"* ]]
    [[ "$output" != *"none#"* ]]
}

@test "optimize_memory NVMe branch preserves existing swapfile fstab entry" {
    export BOOT_TRAN="nvme"
    cat > "$FSTAB_FILE" <<EOF
PARTUUID=6d6d5a7a-02  /  ext4  defaults,noatime  0  1
$SWAPFILE_PATH  none  swap  sw,pri=10,nofail  0  0
EOF
    echo "placeholder" > "$SWAPFILE_PATH"
    cat <<'EOF' > "$MOCK_DIR/bin/du"
#!/bin/bash
echo "4096"
EOF
    chmod +x "$MOCK_DIR/bin/du"

    run optimize_memory

    [ "$status" -eq 0 ]
    run grep "sw,pri=10,nofail" "$FSTAB_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" != *"#"* ]]
}

@test "optimize_memory flash branch comments all disk swap entries" {
    unset BOOT_TRAN
    cat > "$FSTAB_FILE" <<'EOF'
/dev/mmcblk0p2  /  ext4  defaults,noatime  0  1
/dev/sda2  none  swap  sw  0  0
EOF

    run optimize_memory

    [ "$status" -eq 0 ]
    run cat "$FSTAB_FILE"
    [[ "$output" == *"#/dev/sda2  none  swap  sw"* ]]
    [[ "$output" != *"none#"* ]]
}

@test "optimize_memory removes zram-generator.conf when rpi-swap owns zram" {
    unset BOOT_TRAN
    echo "[Main]
Mechanism=zram" > "$RPI_SWAP_CONF"
    echo "[zram0]
zram-size = min(ram / 2, 4096)" > "$ZRAM_GENERATOR_CONF"

    run optimize_memory

    [ "$status" -eq 0 ]
    [ ! -f "$ZRAM_GENERATOR_CONF" ]
    [[ "$output" =~ "sole zram manager" ]]
}

@test "optimize_memory keeps zram-generator.conf when rpi-swap absent (legacy path)" {
    unset BOOT_TRAN
    rm -f "$RPI_SWAP_CONF"

    run optimize_memory

    [ "$status" -eq 0 ]
    [ -f "$ZRAM_GENERATOR_CONF" ]
    [[ "$output" =~ "zstd" ]]
}
