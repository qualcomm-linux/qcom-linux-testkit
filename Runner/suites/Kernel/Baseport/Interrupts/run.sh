#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Robustly find and source init_env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INIT_ENV=""
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"
        break
    fi
    SEARCH=$(dirname "$SEARCH")
done

if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi

# Only source if not already loaded (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="Interrupts"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

# Function to get the timer count
get_timer_count() {
    get_interrupt_line_by_name "arch_timer"
}

# Get the initial timer count
echo "Initial timer count:"
initial_count=$(get_timer_count)
echo "$initial_count"

# Wait for 2 minutes
sleep 120

# Get the timer count after 2 minutes
echo "Timer count after 2 minutes:"
final_count=$(get_timer_count)
echo "$final_count"

# Compare the initial and final counts
echo "Comparing timer counts:"
while IFS= read -r line; do
    [ -n "$line" ] || continue

    irq_id=$(printf '%s\n' "$line" | awk '{print $1}')
    final_line=$(printf '%s\n' "$final_count" | awk -v irq="$irq_id" '$1 == irq { print; exit }')

    if [ -z "$final_line" ]; then
        log_fail "Could not find matching final timer line for IRQ $irq_id"
        log_fail "$TESTNAME : Test Failed"
        echo "$TESTNAME FAIL" > "$res_file"
        exit 1
    fi

    initial_values=$(extract_interrupt_cpu_counts "$line")
    final_values=$(extract_interrupt_cpu_counts "$final_line")

    initial_cpu_count=$(count_interrupt_cpu_counts "$initial_values")
    final_cpu_count=$(count_interrupt_cpu_counts "$final_values")

    log_info "Detected timer counters: initial=${initial_cpu_count} final=${final_cpu_count}"

    if [ "$initial_cpu_count" -eq 0 ] || [ "$final_cpu_count" -eq 0 ]; then
        log_fail "No per-CPU timer counters could be parsed from /proc/interrupts"
        log_fail "$TESTNAME : Test Failed"
        echo "$TESTNAME FAIL" > "$res_file"
        exit 1
    fi

    if [ "$initial_cpu_count" -ne "$final_cpu_count" ]; then
        log_fail "Mismatch in parsed CPU timer counters: initial=${initial_cpu_count} final=${final_cpu_count}"
        log_fail "$TESTNAME : Test Failed"
        echo "$TESTNAME FAIL" > "$res_file"
        exit 1
    fi

    fail_test=false
    i=0

    while [ "$i" -lt "$initial_cpu_count" ]; do
        initial_value=$(printf '%s\n' "$initial_values" | sed -n "$((i + 1))p")
        final_value=$(printf '%s\n' "$final_values" | sed -n "$((i + 1))p")

        if [ "$initial_value" -lt "$final_value" ]; then
            echo "CPU $i: Timer count has incremented. Test PASSED"
            log_pass "CPU $i: Timer count has incremented. Test PASSED"
        else
            echo "CPU $i: Timer count has not incremented. Test FAILED"
            log_fail "CPU $i: Timer count has not incremented. Test FAILED"
            fail_test=true
        fi
        i=$((i + 1))
    done

    if [ "$fail_test" = false ]; then
        log_pass "$TESTNAME : Test Passed"
        echo "$TESTNAME PASS" > "$res_file"
        exit 0
    else
        log_fail "$TESTNAME : Test Failed"
        echo "$TESTNAME FAIL" > "$res_file"
        exit 1
    fi
done <<EOF
$initial_count
EOF
