#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc.
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

TESTNAME="etm_trace"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="
 
pass=true
 
# Step 1: Check required kernel config
required_configs="CONFIG_CORESIGHT_SOURCE_ETM4X"
check_kernel_config "$required_configs" || {
    log_skip "$TESTNAME : Required kernel config missing"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
}
 
# Step 2: Enable CoreSight sink
log_info "Enabling CoreSight sink (tmc_etr0)..."
echo 1 > /sys/bus/coresight/devices/tmc_etr0/enable_sink
if [ "$(cat /sys/bus/coresight/devices/tmc_etr0/enable_sink)" -eq 1 ]; then
    log_info "Sink enabled successfully."
else
    log_fail "Failed to enable sink."
    pass=false
fi
 
# Step 3: Enable CoreSight source
log_info "Enabling CoreSight source (etm0)..."
echo 1 > /sys/bus/coresight/devices/etm0/enable_source
if [ "$(cat /sys/bus/coresight/devices/etm0/enable_source)" -eq 1 ]; then
    log_info "Source enabled successfully."
else
    log_fail "Failed to enable source."
    pass=false
fi
 
# Step 4: Capture trace data
TRACE_FILE="/tmp/qdss.bin"
log_info "Capturing trace data to $TRACE_FILE..."
if cat /dev/tmc_etr0 > "$TRACE_FILE"; then
    log_info "Trace data captured successfully."
else
    log_fail "Failed to capture trace data."
    pass=false
fi
 
# Step 5: Validate trace output
if [ -s "$TRACE_FILE" ]; then
    log_info "Trace file is not empty."
else
    log_fail "Trace file is empty."
    pass=false
fi
 
# Final result and cleanup
if $pass; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
    rm -f "$TRACE_FILE"
    log_info "-------------------Completed $TESTNAME Testcase----------------------------"
    exit 0
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
    rm -f "$TRACE_FILE"
    log_info "-------------------Completed $TESTNAME Testcase----------------------------"
    exit 1
fi
 

