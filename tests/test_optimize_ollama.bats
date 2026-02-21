#!/usr/bin/env bats

setup() {
    # Create a temporary directory for mocks
    MOCK_DIR=$(mktemp -d)
    export MOCK_DIR

    # Create bin directory for mocked commands
    mkdir -p "$MOCK_DIR/bin"
    export PATH="$MOCK_DIR/bin:$PATH"

    # Mock ollama
    cat << 'EOF' > "$MOCK_DIR/bin/ollama"
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    echo "ollama version is 0.1.20"
fi
EOF
    chmod +x "$MOCK_DIR/bin/ollama"

    # Mock curl (for version check)
    cat << 'EOF' > "$MOCK_DIR/bin/curl"
#!/bin/bash
# Mock GitHub API response
echo '{"tag_name": "v0.1.20"}'
EOF
    chmod +x "$MOCK_DIR/bin/curl"

    # Mock jq
    cat << 'EOF' > "$MOCK_DIR/bin/jq"
#!/bin/bash
if [[ "$1" == "-r" ]]; then
    echo "v0.1.20"
else
    cat
fi
EOF
    chmod +x "$MOCK_DIR/bin/jq"

    # Mock systemctl
    cat << 'EOF' > "$MOCK_DIR/bin/systemctl"
#!/bin/bash
if [[ "$1" == "daemon-reload" ]]; then
    exit 0
elif [[ "$1" == "is-enabled" ]]; then
    exit 0
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/bin/systemctl"

    # Mock id and groups for user check
    cat << 'EOF' > "$MOCK_DIR/bin/id"
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/bin/id"

    cat << 'EOF' > "$MOCK_DIR/bin/groups"
#!/bin/bash
echo "ollama : ollama"
EOF
    chmod +x "$MOCK_DIR/bin/groups"

    # Mock usermod
    cat << 'EOF' > "$MOCK_DIR/bin/usermod"
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_DIR/bin/usermod"

    # Prepare optimize.sh for sourcing
    cp optimize.sh "$MOCK_DIR/optimize_testable.sh"

    # Remove strict mode and traps to avoid issues during source
    sed -i '/set -euo pipefail/d' "$MOCK_DIR/optimize_testable.sh"
    sed -i '/trap /d' "$MOCK_DIR/optimize_testable.sh"

    # Remove main call (robustly)
    sed -i 's/^main "$@".*/# main "$@"/' "$MOCK_DIR/optimize_testable.sh"

    # Mock utils.sh sourcing location
    # Replace SCRIPT_DIR logic or just assume utils.sh is in lib relative to script
    # optimize.sh sources "${SCRIPT_DIR}/lib/utils.sh"

    # Prepare mock systemd override directory and file
    export OVERRIDE_DIR="$MOCK_DIR/etc/systemd/system/ollama.service.d"
    mkdir -p "$OVERRIDE_DIR"
    export OVERRIDE_FILE="$OVERRIDE_DIR/override.conf"

    # Replace hardcoded path in optimize_testable.sh
    local escaped_override_dir
    escaped_override_dir=$(echo "$OVERRIDE_DIR" | sed 's/\//\\\//g')
    sed -i "s|/etc/systemd/system/ollama.service.d|$escaped_override_dir|g" "$MOCK_DIR/optimize_testable.sh"

    # Create lib/utils.sh in MOCK_DIR so it can be sourced
    mkdir -p "$MOCK_DIR/lib"
    cat << 'EOF' > "$MOCK_DIR/lib/utils.sh"
log_info() { echo "LOG_INFO: $*"; }
log_pass() { echo "LOG_PASS: $*"; }
log_warn() { echo "LOG_WARN: $*"; }
log_skip() { echo "LOG_SKIP: $*"; }
log_section() { :; }
log_error() { echo "LOG_ERROR: $*"; exit 1; }
confirm_action() { return 1; } # Default to no for interactive prompts
command_exists() { command -v "$1" >/dev/null 2>&1; }
files_differ() { return 0; }
backup_file() { :; }
EOF

    # Create a mock override file with some content to test parsing
    cat <<EOF > "$OVERRIDE_FILE"
[Unit]
Description=Ollama Service

[Service]
Environment="OLLAMA_HOST=0.0.0.0"
Environment="OLLAMA_ORIGINS=*"
Environment="OLLAMA_NUM_PARALLEL=999"
Environment="OLLAMA_FLASH_ATTENTION=0"
Environment="OLLAMA_KV_CACHE_TYPE=f16"
Environment="OLLAMA_MAX_LOADED_MODELS=2"
Environment="OLLAMA_DEBUG=1"
# Simulate USB mount presence which triggers the logic
Environment="OLLAMA_MODELS=/mnt/usb/ollama"
EOF

    # Source the script
    source "$MOCK_DIR/optimize_testable.sh"
}

teardown() {
    rm -rf "$MOCK_DIR"
}

@test "optimize_ollama_service parses and updates Environment variables correctly" {
    # Run the function
    run optimize_ollama_service

    echo "$output"
    [ "$status" -eq 0 ]

    # Check if the function attempted to apply optimizations
    [[ "$output" =~ "LOG_INFO: Applying optimizations & boot-order fix to Ollama..." ]]

    # Read the file to verify content
    run cat "$OVERRIDE_FILE"
    echo "File content:"
    echo "$output"

    # Verify OLLAMA_NUM_PARALLEL was updated to 1 (not 999)
    [[ "$output" =~ 'Environment="OLLAMA_NUM_PARALLEL=1"' ]]
    # Verify OLLAMA_DEBUG (preserved) exists
    [[ "$output" =~ 'Environment="OLLAMA_DEBUG=1"' ]]
    # Verify OLLAMA_HOST (preserved) exists
    [[ "$output" =~ 'Environment="OLLAMA_HOST=0.0.0.0"' ]]
    # Verify OLLAMA_FLASH_ATTENTION is 1
    [[ "$output" =~ 'Environment="OLLAMA_FLASH_ATTENTION=1"' ]]
}
