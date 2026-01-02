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

# Only source if not already loaded
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    export __INIT_ENV_LOADED=1
fi

# Always source functestlib.sh
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="ufs_hibern8"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "--------------------------------------------------"
log_info "------------- Starting $TESTNAME Test ------------"

check_dependencies dd sleep

MANDATORY_CONFIGS="CONFIG_SCSI_UFSHCD CONFIG_SCSI_UFS_QCOM"
OPTIONAL_CONFIGS="CONFIG_SCSI_UFSHCD_PLATFORM CONFIG_SCSI_UFSHCD_PCI CONFIG_SCSI_UFS_CDNS_PLATFORM CONFIG_SCSI_UFS_HISI CONFIG_SCSI_UFS_EXYNOS CONFIG_SCSI_UFS_ROCKCHIP CONFIG_SCSI_UFS_BSG"

log_info "Checking mandatory kernel configs for UFS..."
if ! check_kernel_config "$MANDATORY_CONFIGS" 2>/dev/null; then
    log_skip "Missing mandatory UFS kernel configs: $MANDATORY_CONFIGS"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

log_info "Checking optional kernel configs for UFS..."
missing_optional=""
for cfg in $OPTIONAL_CONFIGS; do
    if ! check_kernel_config "$cfg" 2>/dev/null; then
        log_info "[OPTIONAL] $cfg is not enabled"
        missing_optional="$missing_optional $cfg"
    fi
done
[ -n "$missing_optional" ] && log_info "Optional configs not present but continuing:$missing_optional"

check_dt_nodes "/sys/bus/platform/devices/*ufs*" || {
    echo "$TESTNAME SKIP" > "$res_file"
    log_skip "UFS Device Tree nodes not found"
    exit 0
}

block_dev=$(detect_ufs_partition_block)
if [ -z "$block_dev" ]; then
    log_skip "No UFS block device found."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi
log_info "Detected UFS block: $block_dev"

log_info "Validating UFS link state on load & no-load conditions"

# Check for UFS link state node and assign to variable
log_info "Checking for UFS link state node..."
if ! check_dt_nodes "/sys/bus/platform/devices/*ufs*/power_info/link_state"; then
    log_skip "UFS link state node not found"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

LINK_STATE_NODE=$(get_dt_node_path "/sys/bus/platform/devices/*ufs*/power_info/link_state")
if [ -z "$LINK_STATE_NODE" ]; then
    log_skip "Failed to get UFS link state node path"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi
log_info "Found UFS link state node: $LINK_STATE_NODE"

# Generate load using dd command and check for ACTIVE state
log_info "Starting I/O load test to verify UFS link state transitions..."
tmpfile="/ufs_hibern8_test.tmp"

# Start dd in background
dd if=/dev/zero of="$tmpfile" bs=2M count=1024 >/dev/null 2>&1 &
DD_PID=$!

log_info "Checking UFS link state during load..."
LINK_STATUS_CHECK_LOAD=0

# Use check_node_status to verify ufs link state
if ! check_node_status "$LINK_STATE_NODE" "ACTIVE" 5 0.5; then
    log_fail "UFS link state validation failed during load"
    LINK_STATUS_CHECK_LOAD=1
else
    log_pass "UFS link state during load is ACTIVE"
fi

# Wait for dd to complete if it's still running
if kill -0 $DD_PID 2>/dev/null; then
    log_info "Waiting for I/O load test to complete..."
    wait $DD_PID 2>/dev/null
    sync
fi

# Clean up temp file
rm -f "$tmpfile"

# Wait for 180 seconds for Hibern8 entry
log_info "Waiting 180 seconds for UFS to enter Hibern8 state..."
sleep 180

LINK_STATUS_CHECK_NO_LOAD=0
# Use check_node_status to verify link state is HIBERN8
if ! check_node_status "$LINK_STATE_NODE" "HIBERN8" 2 1; then
    log_fail "UFS link state validation failed without load"
    LINK_STATUS_CHECK_NO_LOAD=1
else
    log_pass "UFS link state without load is HIBERN8"
fi

if [ "$LINK_STATUS_CHECK_LOAD" -ne 0 ] || [ "$LINK_STATUS_CHECK_NO_LOAD" -ne 0 ]; then
    log_fail "UFS ACTIVE/HIBERN8 test failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

scan_dmesg_errors "$test_path" "ufs"
log_pass "$TESTNAME completed successfully"
echo "$TESTNAME PASS" > "$res_file"
exit 0