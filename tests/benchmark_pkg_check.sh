#!/bin/bash
set -u

# Ensure we have a list of packages to test
# We'll use a mix of real and fake packages
# 50 packages total to simulate a reasonable setup list
PACKAGES=()
# 'bash' and 'coreutils' should definitely be installed
for i in {1..15}; do PACKAGES+=("bash"); done
for i in {1..10}; do PACKAGES+=("coreutils"); done
# Fake packages that shouldn't exist
for i in {1..25}; do PACKAGES+=("fake-package-benchmark-$i"); done

echo "Starting Benchmark with ${#PACKAGES[@]} package checks..."
echo "Simulating setup.sh environment..."

# Method 1: Current Approach (Looping dpkg -s)
echo "------------------------------------------------"
echo "Method 1: Looping 'dpkg -s' (Baseline)"
start_time=$(date +%s%N)

for pkg in "${PACKAGES[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        : # Installed
    else
        : # Not installed
    fi
done

end_time=$(date +%s%N)
duration_ns=$((end_time - start_time))
duration_ms=$((duration_ns / 1000000))
echo "Time: ${duration_ms} ms"

# Method 2: Optimized Approach (Map Lookup)
echo "------------------------------------------------"
echo "Method 2: Associative Array Lookup (Optimized)"
start_time=$(date +%s%N)

declare -A installed_map
# Use dpkg-query to populate map once
# Corresponds to: dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n'
# We capture 'ii' (installed) status
while read -r status name; do
    if [[ "$status" == "ii" ]]; then
        installed_map["$name"]=1
    fi
done < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null)

for pkg in "${PACKAGES[@]}"; do
    if [[ -n "${installed_map[$pkg]:-}" ]]; then
        : # Installed
    else
        : # Not installed
    fi
done

end_time=$(date +%s%N)
duration_ns=$((end_time - start_time))
duration_ms=$((duration_ns / 1000000))
echo "Time: ${duration_ms} ms"

echo "------------------------------------------------"
