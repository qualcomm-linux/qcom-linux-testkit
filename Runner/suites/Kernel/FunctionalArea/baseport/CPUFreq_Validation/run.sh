#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

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

if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="CPUFreq_Validation"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "------------------------------------------------------------"
log_info "Starting $TESTNAME Testcase"

overall_pass=0
status_dir="/tmp/cpufreq_status.$$"
mkdir -p "$status_dir"

for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
    policy=$(basename "$policy_dir")

    if [ ! -d "$policy_dir" ]; then
        log_warn "Skipping $policy_dir, not a directory"
        continue
    fi

    cpus=$(cat "$policy_dir/related_cpus" 2>/dev/null)
    [ -z "$cpus" ] && {
        log_warn "No related CPUs found for $policy_dir"
        continue
    }

    available_freqs=$(cat "$policy_dir/scaling_available_frequencies" 2>/dev/null)
    [ -z "$available_freqs" ] && {
        log_warn "No available frequencies for $policy_dir"
        continue
    }

    original_governor=$(cat "$policy_dir/scaling_governor" 2>/dev/null)
    if ! echo "userspace" > "$policy_dir/scaling_governor"; then
        log_fail "$policy_dir: Unable to set userspace governor"
        echo "fail" > "$status_dir/$policy"
        overall_pass=1
        continue
    fi

    echo "pass" > "$status_dir/$policy"

    for freq in $available_freqs; do
        log_info "$policy: Trying frequency $freq"
        echo "$freq" > "$policy_dir/scaling_min_freq" 2>/dev/null
        echo "$freq" > "$policy_dir/scaling_max_freq" 2>/dev/null
        if ! echo "$freq" > "$policy_dir/scaling_setspeed" 2>/dev/null; then
            log_warn "$policy: Kernel rejected frequency $freq"
            continue
        fi

        sleep 0.3
        cur_freq=$(cat "$policy_dir/scaling_cur_freq" 2>/dev/null)

        if [ "$cur_freq" = "$freq" ]; then
            log_info "[PASS] $policy reached $freq kHz"
        else
            log_warn "Mismatch freq: tried $freq, got $cur_freq on $policy"
            echo "fail" > "$status_dir/$policy"
            overall_pass=1
        fi
    done

    echo "$original_governor" > "$policy_dir/scaling_governor"
done

log_info ""
log_info "=== Per-Policy CPU Group Summary ==="
for f in "$status_dir"/*; do
    policy=$(basename "$f")
    result=$(cat "$f")
    cpus=$(tr '\n' ' ' < "/sys/devices/system/cpu/cpufreq/$policy/related_cpus")
    cpulist=$(echo "$cpus" | sed 's/ /,/g')
    status_str=$(echo "$result" | tr '[:lower:]' '[:upper:]')
    echo "CPU$cpulist [via $policy] = $status_str"
done

log_info ""
log_info "=== Final Result ==="
if [ "$overall_pass" -eq 0 ]; then
    log_pass "$TESTNAME: All policies passed"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "$TESTNAME: One or more policies failed"
    echo "$TESTNAME FAIL" > "$res_file"
fi

rm -rf "$status_dir"
exit "$overall_pass"
