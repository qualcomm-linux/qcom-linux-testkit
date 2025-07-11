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

TESTNAME="stm_cpu"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

# Step 1: Check required kernel configs
required_configs="CONFIG_STM_PROTO_BASIC CONFIG_STM_PROTO_SYS_T CONFIG_STM_DUMMY CONFIG_STM_SOURCE_CONSOLE CONFIG_STM_SOURCE_HEARTBEAT"
check_kernel_config "$required_configs" || {
    log_skip "$TESTNAME : Required kernel configs missing"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
}

# Step 2: Mount configfs
if ! mountpoint -q /sys/kernel/config; then
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

# Step 4: Enable ETF sink
echo 1 > /sys/bus/coresight/devices/tmc_etf0/enable_sink || {
    log_skip "$TESTNAME : Failed to enable ETF sink"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
}

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

# Step 7: Mount debugfs
if ! mountpoint -q /sys/kernel/debug; then
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
cat /dev/tmc_etf0 > "$trace_output"

# Step 10: Validate trace output is not empty
if [ -s "$trace_output" ]; then
    log_pass "$TESTNAME : Trace captured successfully"
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
else
    log_fail "$TESTNAME : Trace output is empty"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
