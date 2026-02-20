#!/usr/bin/env bats

setup() {
    # Create temp environment
    TEST_DIR=$(mktemp -d)
    export TEST_DIR
    export LIB_DIR="${TEST_DIR}/lib"
    mkdir -p "$LIB_DIR"

    # Copy library
    cp lib/utils.sh "$LIB_DIR/"

    # Prepare optimize.sh for testing
    cp optimize.sh "${TEST_DIR}/optimize.sh"

    # 1. Remove main call (robustly)
    sed -i '/^main "\$@"/d' "${TEST_DIR}/optimize.sh"

    # 2. Change override_dir path to temp dir
    # We use | as delimiter for sed because path contains /
    sed -i "s|/etc/systemd/system/ollama.service.d|${TEST_DIR}/ollama.service.d|g" "${TEST_DIR}/optimize.sh"

    # 3. Change log file path
    sed -i "s|/var/log/rpi-optimize.log|${TEST_DIR}/optimize.log|g" "${TEST_DIR}/optimize.sh"

    # 4. Change lock file path
    sed -i "s|/run/rpi-optimize.lock|${TEST_DIR}/optimize.lock|g" "${TEST_DIR}/optimize.sh"

    # 5. Change config file path (boot config)
    sed -i "s|/boot/firmware/config.txt|${TEST_DIR}/config.txt|g" "${TEST_DIR}/optimize.sh"

    # Mock files
    mkdir -p "${TEST_DIR}/ollama.service.d"
    export OVERRIDE_FILE="${TEST_DIR}/ollama.service.d/override.conf"
    touch "${TEST_DIR}/config.txt"

    # Define mocks BEFORE sourcing? No, functions are defined in source.
    # But sourcing executes top-level code.

    # Source the modified script
    # This will define functions and run top-level checks/constants.
    source "${TEST_DIR}/optimize.sh"

    # Override functions used by optimize_ollama_service
    # We must override them AFTER sourcing because sourcing defines them (from utils.sh or optimize.sh).

    command_exists() {
        if [[ "$1" == "ollama" ]]; then return 0; fi
        if [[ "$1" == "curl" ]]; then return 0; fi
        if [[ "$1" == "systemctl" ]]; then return 0; fi
        return 1
    }

    systemctl() {
        return 0
    }

    ollama() {
        echo "ollama version is 0.0.0"
    }

    curl() {
        # Return empty or dummy version to avoid update logic
        echo ""
    }

    # Mock logging to avoid spam
    log_pass() { :; }
    log_info() { :; }
    log_warn() { :; }
    log_skip() { :; }
    log_error() { echo "ERROR: $1"; return 1; }

    prompt_update() {
        return 1 # Say no to update
    }

    confirm_action() {
        return 1
    }

    id() {
        return 0
    }

    groups() {
        echo "root"
    }

    usermod() {
        return 0
    }

    # Mock grep? No, we need grep for file checking.
    # But optimize.sh uses grep.
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "optimize_ollama_service extracts OLLAMA_MODELS path correctly" {
    # Setup override file with OLLAMA_MODELS
    cat > "$OVERRIDE_FILE" <<EOF
[Service]
Environment="OLLAMA_MODELS=/mnt/usb/ollama"
Environment="ANOTHER_VAR=foo"
EOF

    # Run the function
    optimize_ollama_service

    # Check if the file was updated with RequiresMountsFor
    run grep "RequiresMountsFor=/mnt/usb/ollama" "$OVERRIDE_FILE"
    [ "$status" -eq 0 ]

    # Ensure it didn't use the variable name "OLLAMA_MODELS"
    run grep "RequiresMountsFor=OLLAMA_MODELS" "$OVERRIDE_FILE"
    [ "$status" -ne 0 ]
}

@test "optimize_ollama_service extracts OLLAMA_MODELS path correctly (unquoted)" {
    # Setup override file with OLLAMA_MODELS without quotes
    cat > "$OVERRIDE_FILE" <<EOF
[Service]
Environment=OLLAMA_MODELS=/mnt/usb/ollama
Environment="ANOTHER_VAR=foo"
EOF

    optimize_ollama_service

    run grep "RequiresMountsFor=/mnt/usb/ollama" "$OVERRIDE_FILE"
    [ "$status" -eq 0 ]
}

@test "optimize_ollama_service uses default if OLLAMA_MODELS missing" {
    # Setup override file WITHOUT OLLAMA_MODELS but WITH /mnt/usb check passing
    # The script checks: grep -q "/mnt/usb" "$override_file"
    # So we need /mnt/usb somewhere.
    cat > "$OVERRIDE_FILE" <<EOF
[Service]
Environment="SOME_VAR=/mnt/usb/something"
EOF

    optimize_ollama_service

    # Default is /mnt/usb/ollama
    run grep "RequiresMountsFor=/mnt/usb/ollama" "$OVERRIDE_FILE"
    [ "$status" -eq 0 ]
}
