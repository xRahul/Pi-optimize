#!/bin/bash

# Original functions using awk
is_greater_awk() { awk -v n1="$1" -v n2="$2" 'BEGIN {if (n1>n2) exit 0; exit 1}'; }
is_less_awk() { awk -v n1="$1" -v n2="$2" 'BEGIN {if (n1<n2) exit 0; exit 1}'; }

# Helper for floating point comparison (pure bash)
float_to_int() {
    local n="$1"
    local -n out="$2"

    local sign=""
    if [[ "$n" == -* ]]; then
        sign="-"
        n="${n#-}"
    fi

    if [[ "$n" != *.* ]]; then
        n="${n}00"
    else
        local i="${n%.*}"
        local f="${n#*.}"
        if [[ -z "$f" ]]; then f="00";
        elif [[ ${#f} -eq 1 ]]; then f="${f}0";
        elif [[ ${#f} -ge 2 ]]; then f="${f:0:2}"; fi
        [[ -z "$i" ]] && i="0"
        n="$i$f"
    fi

    # Remove leading zeros (safely)
    n="${n#${n%%[!0]*}}"
    [[ -z "$n" ]] && n="0"

    out="$sign$n"
}

is_greater_bash() {
    local n1 n2
    float_to_int "$1" n1
    float_to_int "$2" n2
    (( n1 > n2 ))
}

is_less_bash() {
    local n1 n2
    float_to_int "$1" n1
    float_to_int "$2" n2
    (( n1 < n2 ))
}

# Verification
errors=0
check() {
    local fn="$1"
    local n1="$2"
    local n2="$3"
    local expected="$4" # 0 for true, 1 for false
    if "$fn" "$n1" "$n2"; then
        result=0
    else
        result=1
    fi
    if [ "$result" -ne "$expected" ]; then
        echo "Error: $fn $n1 $n2 returned $result, expected $expected"
        ((errors++))
    fi
}

echo "Verifying correctness..."
# greater
check is_greater_bash "45.5" "60" 1
check is_greater_bash "60.1" "60" 0
check is_greater_bash "60" "60" 1 # strict greater
check is_greater_bash "3.14" "3.1" 0 # 3.14 > 3.10
check is_greater_bash "0.5" "0.51" 1
check is_greater_bash "0" "0.01" 1
check is_greater_bash "100" "99.99" 0

# less
check is_less_bash "3.0" "5.0" 0
check is_less_bash "5.0" "3.0" 1
check is_less_bash "0.5" "0.6" 0
check is_less_bash "80" "80" 1   # strict less
check is_less_bash "2.99" "3.0" 0
check is_less_bash "3.01" "3.0" 1

# FAIL CASES identified in previous review
echo "Checking failing cases..."
check is_greater_bash "0.08" "0.07" 0
check is_less_bash "-0.08" "-0.07" 0
check is_greater_bash "-0.4" "-0.5" 0 # -0.4 > -0.5
check is_less_bash "-0.5" "-0.4" 0    # -0.5 < -0.4
check is_greater_bash "-0.5" "-0.4" 1

# NEW FAIL CASE: Trailing dot
echo "Checking trailing dot..."
check is_greater_bash "80." "60" 0 || echo "Failed 80. > 60"
check is_greater_bash "80." "79.99" 0 || echo "Failed 80. > 79.99"

if [ $errors -eq 0 ]; then
    echo "Verification Passed!"
else
    echo "Verification Failed with $errors errors."
    exit 1
fi

# Benchmark
ITERATIONS=2000

echo "Benchmarking awk version ($ITERATIONS iterations)..."
start_time=$(date +%s%N)
for ((i=0; i<ITERATIONS; i++)); do
    is_greater_awk "45.5" "60"
    is_less_awk "3.0" "5.0"
    is_greater_awk "80.1" "80"
    is_less_awk "0.5" "0.6"
    is_greater_awk "100.55" "100.5"
done
end_time=$(date +%s%N)
awk_duration=$((end_time - start_time))
echo "Awk duration: $((awk_duration/1000000)) ms"

echo "Benchmarking bash version ($ITERATIONS iterations)..."
start_time=$(date +%s%N)
for ((i=0; i<ITERATIONS; i++)); do
    is_greater_bash "45.5" "60"
    is_less_bash "3.0" "5.0"
    is_greater_bash "80.1" "80"
    is_less_bash "0.5" "0.6"
    is_greater_bash "100.55" "100.5"
done
end_time=$(date +%s%N)
bash_duration=$((end_time - start_time))
echo "Bash duration: $((bash_duration/1000000)) ms"

improvement=$(( (awk_duration - bash_duration) * 100 / awk_duration ))
echo "Improvement: ${improvement}%"
