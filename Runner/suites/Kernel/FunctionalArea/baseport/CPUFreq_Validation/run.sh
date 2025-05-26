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

# Only source if not already loaded (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="CPUFreq_Validation"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== CPUFreq Frequency Walker with Retry and Cleanup ==="

NUM_CPUS=$(nproc)
log_info "Detected $NUM_CPUS CPU cores."

overall_pass=0
status_dir="/tmp/cpufreq_status.$$"
mkdir -p "$status_dir"

validate_cpu_core() {
    local cpu="$1"
    local core_id="$2"
    local status_file="$status_dir/core_$core_id"
    echo "unknown" > "$status_file"

    log_info "Processing $cpu..."

    local cpu_num
    cpu_num=$(basename "$cpu" | tr -dc '0-9')
    if [ -f "/sys/devices/system/cpu/cpu$cpu_num/online" ]; then
        echo 1 > "/sys/devices/system/cpu/cpu$cpu_num/online"
    fi

    if [ ! -d "$cpu/cpufreq" ]; then
        log_info "[SKIP] $cpu does not support cpufreq."
        echo "skip" > "$status_file"
        return
    fi

    local freqs_file="$cpu/cpufreq/scaling_available_frequencies"
    read -r available_freqs < "$freqs_file" 2>/dev/null
    if [ -z "$available_freqs" ]; then
        log_info "[SKIP] No available frequencies for $cpu"
        echo "skip" > "$status_file"
        return
    fi

    local original_governor
    original_governor=$(cat "$cpu/cpufreq/scaling_governor" 2>/dev/null)

    if echo "userspace" > "$cpu/cpufreq/scaling_governor"; then
        log_info "[INFO] Set governor to userspace."
        sync
        sleep 0.5
    else
        log_error "Cannot set userspace governor for $cpu."
        echo "fail" > "$status_file"
        return
    fi

    echo "pass" > "$status_file"

    for freq in $available_freqs; do
        log_info "Setting $cpu to frequency $freq kHz..."

        echo "$freq" > "$cpu/cpufreq/scaling_min_freq" 2>/dev/null
        echo "$freq" > "$cpu/cpufreq/scaling_max_freq" 2>/dev/null

        if ! echo "$freq" > "$cpu/cpufreq/scaling_setspeed" 2>/dev/null; then
            log_error "[SKIP] Kernel rejected freq $freq for $cpu"
            continue
        fi

        retry=0
        success=0
        while [ "$retry" -lt 5 ]; do
            cur=$(cat "$cpu/cpufreq/scaling_cur_freq")
            if [ "$cur" = "$freq" ]; then
                log_info "[PASS] $cpu set to $freq kHz."
                success=1
                break
            fi
            sleep 0.2
            retry=$((retry + 1))
        done

        if [ "$success" -eq 0 ]; then
            log_info "[RETRY] Re-attempting to set $cpu to $freq kHz..."
            echo "$freq" > "$cpu/cpufreq/scaling_setspeed"
            sleep 0.3
            cur=$(cat "$cpu/cpufreq/scaling_cur_freq")
            if [ "$cur" = "$freq" ]; then
                log_info "[PASS-after-retry] $cpu set to $freq kHz."
            else
                log_error "[FAIL] $cpu failed to set $freq kHz twice. Current: $cur"
                echo "fail" > "$status_file"
            fi
        fi
    done

    log_info "Restoring $cpu governor to '$original_governor'..."
    echo "$original_governor" > "$cpu/cpufreq/scaling_governor"
    echo 0 > "$cpu/cpufreq/scaling_min_freq" 2>/dev/null
    echo 0 > "$cpu/cpufreq/scaling_max_freq" 2>/dev/null
}

cpu_index=0
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    validate_cpu_core "$cpu" "$cpu_index" &
    cpu_index=$((cpu_index + 1))
done

wait

log_info ""
log_info "=== Per-Core Test Summary ==="
for status_file in "$status_dir"/core_*; do
    idx=$(basename "$status_file" | cut -d_ -f2)
    status=$(cat "$status_file")
    case "$status" in
        pass)
            log_info "CPU$idx: [PASS]"
            ;;
        fail)
            log_error "CPU$idx: [FAIL]"
            overall_pass=1
            ;;
        skip)
            log_info "CPU$idx: [SKIPPED]"
            ;;
        *)
            log_error "CPU$idx: [UNKNOWN STATUS]"
            overall_pass=1
            ;;
    esac
done

log_info ""
log_info "=== Overall CPUFreq Validation Result ==="

if [ "$overall_pass" -eq 0 ]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
fi

rm -r "$status_dir"
sync
sleep 1
exit "$overall_pass"
