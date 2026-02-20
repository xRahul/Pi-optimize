#!/bin/bash
# tests/benchmark_docker.sh

# Source library functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Create a library version of diag.sh without the main call
sed '$d' "$ROOT_DIR/diag.sh" > "$ROOT_DIR/diag_lib.sh"

# We need to make sure diag_lib.sh can find lib/utils.sh
# diag.sh expects lib/utils.sh relative to its location.
# Since diag_lib.sh is in ROOT_DIR, it should work.

source "$ROOT_DIR/diag_lib.sh"

# Mock report functions to suppress output
report_pass() { :; }
report_warn() { :; }
report_fail() { :; }
report_info() { :; }
log_section_diag() { :; }

echo "Benchmarking check_docker (Baseline)..."
start_time=$(date +%s%N)
# Run check_docker 5 times
for i in {1..5}; do
    check_docker >/dev/null 2>&1
done
end_time=$(date +%s%N)

duration=$((end_time - start_time))
avg_duration=$((duration / 5))
avg_ms=$((avg_duration / 1000000))

echo "Average execution time: ${avg_ms} ms"

rm "$ROOT_DIR/diag_lib.sh"
