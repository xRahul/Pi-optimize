#!/usr/bin/env bats

# Unit tests for diag.sh's pure float-comparison helpers.
# Cases ported from tests/benchmark_compare.sh (scratch tool deleted after this port),
# including the historical failure cases (negatives, trailing dot).

setup() {
    load helpers/setup
    new_mock_dir
    mkdir -p "$MOCK_DIR/lib"
    touch "$MOCK_DIR/lib/utils.sh"
    # diag.sh is directly sourceable: entry point is guarded by BASH_SOURCE check
    set +u
    source diag.sh
    set -u
}

@test "float_to_int converts simple decimals" {
    # res is the nameref out-param of float_to_int; init so a silent failure asserts loudly
    res=""
    float_to_int "3.14" res
    [ "$res" = "314" ]
    float_to_int "60" res
    [ "$res" = "6000" ]
    # Leading zeros are stripped from the integer part; value equality is what matters
    float_to_int "0.5" res
    [ "$res" = "50" ]
    float_to_int ".5" res
    [ "$res" = "50" ]
}

@test "float_to_int handles negatives and trailing dots" {
    res=""
    float_to_int "-0.08" res
    [ "$res" = "-8" ]
    float_to_int "-0.4" res
    [ "$res" = "-40" ]
    float_to_int "80." res
    [ "$res" = "8000" ]
}

@test "is_greater strict comparisons" {
    run is_greater "45.5" "60"
    [ "$status" -eq 1 ]
    run is_greater "60.1" "60"
    [ "$status" -eq 0 ]
    run is_greater "60" "60"
    [ "$status" -eq 1 ]
    run is_greater "3.14" "3.1"
    [ "$status" -eq 0 ]
    run is_greater "0.5" "0.51"
    [ "$status" -eq 1 ]
    run is_greater "100" "99.99"
    [ "$status" -eq 0 ]
}

@test "is_less strict comparisons" {
    run is_less "3.0" "5.0"
    [ "$status" -eq 0 ]
    run is_less "5.0" "3.0"
    [ "$status" -eq 1 ]
    run is_less "80" "80"
    [ "$status" -eq 1 ]
    run is_less "2.99" "3.0"
    [ "$status" -eq 0 ]
    run is_less "3.01" "3.0"
    [ "$status" -eq 1 ]
}

@test "historical failure cases: negatives and trailing dot" {
    run is_greater "0.08" "0.07"
    [ "$status" -eq 0 ]
    run is_less "-0.08" "-0.07"
    [ "$status" -eq 0 ]
    run is_greater "-0.4" "-0.5"
    [ "$status" -eq 0 ]
    run is_less "-0.5" "-0.4"
    [ "$status" -eq 0 ]
    run is_greater "-0.5" "-0.4"
    [ "$status" -eq 1 ]
    run is_greater "80." "60"
    [ "$status" -eq 0 ]
    run is_greater "80." "79.99"
    [ "$status" -eq 0 ]
}

@test "parse_nvme_temp parses degree-celsius composite line" {
    out=$(printf 'temperature\t\t\t: 41 °C (314 K)\n' | parse_nvme_temp)
    [ "$out" = "41" ]
}

@test "parse_nvme_temp converts kelvin-only output" {
    out=$(printf 'temperature : 315 K\n' | parse_nvme_temp)
    [ "$out" = "42" ]
}

@test "parse_nvme_temp ignores sensor lines and negative artifacts" {
    out=$(printf 'Temperature Sensor 1 : 46 °C (319 K)\ntemperature : 41 °C (314 K)\n' | parse_nvme_temp)
    [ "$out" = "41" ]
}
