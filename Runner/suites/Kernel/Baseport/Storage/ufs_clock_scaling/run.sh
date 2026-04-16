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

TESTNAME="ufs_clock_scaling"
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

if PRIMARY_UFS_CONTROLLER=$(get_primary_ufs_controller "/"); then
    log_info "Primary UFS Controller is $PRIMARY_UFS_CONTROLLER"
else
    log_fail "Failed to get the primary UFS controller from rootfs"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

log_info "Validating UFS clock scaling & clock gating"
# Check for UFS clock freq node and assign to variable
log_info "Checking for UFS clock freq node..."
if UFS_CLOCK_FREQ_NODE=$(ufs_get_dt_node_path "/sys/devices/platform/soc@0/$PRIMARY_UFS_CONTROLLER/devfreq/*ufs*/cur_freq"); then
    log_info "Found UFS clock frequency node: $UFS_CLOCK_FREQ_NODE"
else
    log_skip "Failed to get UFS clock frequency node"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

# Check for UFS clock max freq node and assign to variable
log_info "Checking for UFS max clock freq node..."
if UFS_MAX_FREQ_NODE=$(ufs_get_dt_node_path "/sys/devices/platform/soc@0/$PRIMARY_UFS_CONTROLLER/devfreq/*ufs*/max_freq"); then
    log_info "Found UFS controller's max_frequency node: $UFS_MAX_FREQ_NODE"
else
    log_skip "Failed to get UFS max clock frequency node"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

UFS_MAX_FREQ=$(cat "$UFS_MAX_FREQ_NODE" 2>/dev/null)
if [ -z "$UFS_MAX_FREQ" ]; then
    log_fail "Failed to read max frequency from $UFS_MAX_FREQ_NODE"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi
log_info "Max UFS clock frequency supported is $UFS_MAX_FREQ"

# Check for UFS clock min freq node and assign to variable
log_info "Checking for UFS min clock freq node..."
if UFS_MIN_FREQ_NODE=$(ufs_get_dt_node_path "/sys/devices/platform/soc@0/$PRIMARY_UFS_CONTROLLER/devfreq/*ufs*/min_freq"); then
    log_info "Found UFS controller's min_frequency node: $UFS_MIN_FREQ_NODE"
else
    log_skip "Failed to get UFS min clock frequency node"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

UFS_MIN_FREQ=$(cat "$UFS_MIN_FREQ_NODE" 2>/dev/null)
if [ -z "$UFS_MIN_FREQ" ]; then
    log_fail "Failed to read min frequency from $UFS_MIN_FREQ_NODE"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi
log_info "Min UFS clock frequency supported is $UFS_MIN_FREQ"

# Generate load using dd command and check for ufs cur_freq
log_info "Starting I/O load test to verify UFS clock scaling..."
tmpfile="$test_path/${TESTNAME}.tmp"

# checking if necessary space is available in rootfs
ensure_rootfs_min_size 3

# Start dd in background
dd if=/dev/zero of="$tmpfile" bs=2M count=1024 >/dev/null 2>&1 &
DD_PID=$!

log_info "Checking whether UFS clock is scaled during load..."
UFS_CLOCK_SCALED=0
RETRIES=10
RETRY_TIMEOUT=1
attempt=1

# Start background sync process to flush the storage requests to disk
log_info "Starting continuous sync in background..."
(
    while :; do
        sync
        sleep 0.2
    done
) &
sync_pid=$!

while [ $attempt -le $RETRIES ]; do
    # shellcheck disable=SC2002
    current_freq=$(cat "$UFS_CLOCK_FREQ_NODE" 2>/dev/null | tr -d '\n' | tr -d '\r')
    
    if [ -n "$current_freq" ] && [ "$current_freq" -gt "$UFS_MIN_FREQ" ]; then
        log_pass "UFS clock is scaled to $current_freq (greater than MIN_FREQ: $UFS_MIN_FREQ)"
        UFS_CLOCK_SCALED=1
        break
    fi
    
    log_info "Attempt $attempt/$RETRIES: Current frequency $current_freq"
    
    if [ $attempt -lt $RETRIES ]; then
        sleep $RETRY_TIMEOUT
    fi
    
    attempt=$((attempt + 1))
done

# Wait for dd to complete if it's still running
if kill -0 $DD_PID 2>/dev/null; then
    log_info "Waiting for I/O load test to complete..."
    wait $DD_PID 2>/dev/null
fi

kill "$sync_pid" 2>/dev/null || true
wait "$sync_pid" 2>/dev/null || true
log_info "Stopped background sync process"

# Clean up temp file
rm -f "$tmpfile"

log_info "Checking whether UFS clock is gated when no load is applied"
UFS_CLOCK_GATED=0

# Use ufs_check_node_status to verify ufs clock scaling
if ! ufs_check_node_status_with_timeout "$UFS_CLOCK_FREQ_NODE" "$UFS_MIN_FREQ" 60; then
    log_fail "UFS clock is not gated"
else
    log_pass "UFS clock is gated to $UFS_MIN_FREQ"
    UFS_CLOCK_GATED=1
fi

if [ "$UFS_CLOCK_SCALED" -ne 1 ] || [ "$UFS_CLOCK_GATED" -ne 1 ]; then
    log_fail "UFS clock scaling & gating test failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

scan_dmesg_errors "$test_path" "ufs"
log_pass "$TESTNAME completed successfully"
echo "$TESTNAME PASS" > "$res_file"
exit 0
