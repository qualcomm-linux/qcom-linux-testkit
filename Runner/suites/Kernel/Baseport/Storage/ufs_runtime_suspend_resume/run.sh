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
    exit 0
fi

# Only source if not already loaded
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    export __INIT_ENV_LOADED=1
fi

# Always source functestlib.sh
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="ufs_runtime_suspend_resume"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 0
res_file="./$TESTNAME.res"

log_info "--------------------------------------------------"
log_info "------------- Starting $TESTNAME Test ------------"

check_dependencies dd sleep

# Run common UFS prechecks
if ! ufs_precheck_common; then
    log_skip "Required UFS configurations are not available"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi
log_info "UFS prechecks successful"

log_info "Validating UFS Runtime Suspend/Resume on load & no-load conditions"

if PRIMARY_UFS_CONTROLLER=$(get_primary_ufs_controller "/"); then
    log_info "Primary UFS Controller is $PRIMARY_UFS_CONTROLLER"
else
    log_fail "Failed to get the primary UFS controller from rootfs"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

# Check for UFS runtime status node and assign to variable
log_info "Checking for UFS runtime status node..."
if RUNTIME_STATUS_NODE=$(ufs_get_dt_node_path "/sys/devices/platform/soc@0/$PRIMARY_UFS_CONTROLLER/power/runtime_status"); then
    log_info "Found runtime status node: $RUNTIME_STATUS_NODE"
else
    log_skip "Failed to get runtime status node"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

# Generate load using dd command and check for active state
log_info "Starting I/O load test to verify UFS runtime active state..."
tmpfile="$test_path/${TESTNAME}.tmp"

# checking if necessary space is available in rootfs
ensure_rootfs_min_size 3

# Start dd in background
dd if=/dev/zero of="$tmpfile" bs=2M count=1024 >/dev/null 2>&1 &
DD_PID=$!

log_info "Checking UFS runtime status during load..."
RUNTIME_STATUS_CHECK_LOAD=0

# Use ufs_check_node_status to verify ufs if ufs runtime status is active
if ! ufs_check_node_status "$RUNTIME_STATUS_NODE" "active" 10 1; then
    log_fail "UFS runtime status validation failed during load"
    RUNTIME_STATUS_CHECK_LOAD=1
else
    log_pass "UFS runtime status during load is active"
fi

# Wait for dd to complete if it's still running
if kill -0 $DD_PID 2>/dev/null; then
    log_info "Waiting for I/O load test to complete..."
    wait $DD_PID 2>/dev/null
    sync
fi

# Clean up temp file
rm -f "$tmpfile"

# Wait for UFS to enter suspended state
log_info "Waiting for UFS to enter suspended state..."

RUNTIME_STATUS_CHECK_NO_LOAD=0
# Use ufs_check_node_status_with_timeout to verify ufs runtime status is suspended
if ! ufs_check_node_status_with_timeout "$RUNTIME_STATUS_NODE" "suspended" 180; then
    log_fail "UFS runtime status validation failed without load"
    RUNTIME_STATUS_CHECK_NO_LOAD=1
else
    log_pass "UFS runtime status without load is suspended"
fi

if [ "$RUNTIME_STATUS_CHECK_LOAD" -ne 0 ] || [ "$RUNTIME_STATUS_CHECK_NO_LOAD" -ne 0 ]; then
    log_fail "UFS active/suspended test failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

scan_dmesg_errors "$test_path" "ufs"
log_pass "$TESTNAME completed successfully"
echo "$TESTNAME PASS" > "$res_file"
exit 0
