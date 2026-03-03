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

TESTNAME="Freq_Scaling"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "-------------------------------------------------"
log_info "----------- Starting $TESTNAME Test -------------"

check_dependencies zcat grep

CONFIGS="CONFIG_CPU_FREQ CONFIG_CPU_FREQ_GOV_SCHEDUTIL CONFIG_CPU_FREQ_GOV_PERFORMANCE"
check_kernel_config "$CONFIGS" || {
    log_fail "Kernel config validation failed."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
}

miss=0

for cpu_dir in /sys/devices/system/cpu/cpu[0-8]*; do
    CPUFREQ_PATH="$cpu_dir/cpufreq"
    if [ -d "$CPUFREQ_PATH" ]; then
        cpu_name="${cpu_dir##*/}"
        log_pass "$cpu_name has cpufreq interface"
    else
        miss=1
    fi
done

if [ "$miss" -eq 1 ]; then
    echo "CPUFreq interface not found. Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

log_info "Reading scaling governor..."
GOVERNOR=$(cat $CPUFREQ_PATH/scaling_governor)
log_info "Current governor: $GOVERNOR"

log_info "Reading min/max frequencies"
MIN_FREQ=$(cat $CPUFREQ_PATH/cpuinfo_min_freq)
MAX_FREQ=$(cat $CPUFREQ_PATH/cpuinfo_max_freq)
log_info "CPU frequency range: $MIN_FREQ - $MAX_FREQ"

log_info "Triggering frequency update via governor"
dd if=/dev/urandom of=/dev/null bs=1M count=1000 &
LOAD_PID=$!
sleep 2

CURRENT_FREQ=$(cat $CPUFREQ_PATH/scaling_cur_freq)
log_info "Observed frequency under load: $CURRENT_FREQ"

kill $LOAD_PID

if [ "$CURRENT_FREQ" -gt "$MIN_FREQ" ]; then
    log_pass "DCVS scaling appears functional. Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
else
    log_fail "DCVS did not scale as expected. Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

log_info "----------- Completed $TESTNAME Test ------------"
