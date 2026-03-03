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
 
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
 
TESTNAME="stm_cpu"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"
 
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="
 
# Step 1: Check required kernel configs individually
CONFIGS="CONFIG_STM_PROTO_BASIC CONFIG_STM_PROTO_SYS_T CONFIG_STM_DUMMY CONFIG_STM_SOURCE_CONSOLE CONFIG_STM_SOURCE_HEARTBEAT"
for cfg in $CONFIGS; do
    log_info "Checking if $cfg is enabled"
    if ! check_kernel_config "$cfg" >/dev/null; then
        log_fail "$cfg is not enabled"
        echo "$TESTNAME FAIL" > "$res_file"
        exit 1
    fi
done
 
# Step 2: Mount configfs if not mounted
if ! mountpoint -q /sys/kernel/config 2>/dev/null && [ -z "$(ls /sys/kernel/config 2>/dev/null)" ]; then
    mount -t configfs configfs /sys/kernel/config || {
        log_skip "$TESTNAME : Failed to mount configfs"
        echo "$TESTNAME SKIP" > "$res_file"
        exit 0
    }
fi
 
# Step 3: Create STM policy directories
mkdir -p /sys/kernel/config/stp-policy/stm0_basic.policy/default || {
    log_skip "$TESTNAME : Failed to create STM policy directories"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
}
 
# Step 4: Enable ETF sink only if not already enabled
if [ "$(cat /sys/bus/coresight/devices/tmc_etf0/enable_sink)" != "1" ]; then
    echo 1 > /sys/bus/coresight/devices/tmc_etf0/enable_sink || {
        log_skip "$TESTNAME : Failed to enable ETF sink"
        echo "$TESTNAME SKIP" > "$res_file"
        exit 0
    }
fi
 
# Step 5: Load STM modules
for mod in stm_heartbeat stm_console stm_ftrace; do
    mod_path=$(find_kernel_module "$mod")
    load_kernel_module "$mod_path" || {
        log_skip "$TESTNAME : Failed to load module $mod"
        echo "$TESTNAME SKIP" > "$res_file"
        exit 0
    }
done
 
# Step 6: Link STM source to ftrace
echo stm0 > /sys/class/stm_source/ftrace/stm_source_link
 
# Step 7: Mount debugfs if not mounted
if ! mountpoint -q /sys/kernel/debug 2>/dev/null && [ -z "$(ls /sys/kernel/debug 2>/dev/null)" ]; then
    mount -t debugfs nodev /sys/kernel/debug || {
        log_skip "$TESTNAME : Failed to mount debugfs"
        echo "$TESTNAME SKIP" > "$res_file"
        exit 0
    }
fi
 
# Step 8: Enable tracing
echo 1 > /sys/kernel/debug/tracing/tracing_on
echo 1 > /sys/kernel/debug/tracing/events/sched/sched_switch/enable
echo 1 > /sys/bus/coresight/devices/stm0/enable_source
 
# Step 9: Capture trace output
trace_output="/tmp/qdss_etf_stm.bin"
rm -f "$trace_output"
 
if [ ! -e /dev/tmc_etf0 ]; then
    log_skip "$TESTNAME : Trace device /dev/tmc_etf0 not found"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi
 
cat /dev/tmc_etf0 > "$trace_output"
 
# Step 10: Validate trace output is not empty
if [ -s "$trace_output" ]; then
    log_pass "$TESTNAME : Trace captured successfully"
    echo "$TESTNAME PASS" > "$res_file"
    rm -f "$trace_output"
    log_info "------------------- Completed $TESTNAME Testcase ----------------------------"
    exit 0
else
    log_fail "$TESTNAME : Trace output is empty"
    echo "$TESTNAME FAIL" > "$res_file"
    rm -f "$trace_output"
    log_info "------------------- Completed $TESTNAME Testcase ----------------------------"
    exit 1
fi
 