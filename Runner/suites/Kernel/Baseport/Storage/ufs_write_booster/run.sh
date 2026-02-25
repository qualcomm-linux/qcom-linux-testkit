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

TESTNAME="ufs_write_booster"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 0
res_file="./$TESTNAME.res"

log_info "--------------------------------------------------"
log_info "------------- Starting $TESTNAME Test ------------"

check_dependencies dd

# Run common UFS prechecks
if ! ufs_precheck_common; then
    log_skip "Required UFS configurations are not available"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi
log_info "UFS prechecks successful"

# Function to compare UFS specification versions
# Returns 0 if version1 >= version2, 1 otherwise
compare_ufs_version() {
    version1="$1"
    version2="$2"
    
    # Convert hex to decimal for comparison
    # shellcheck disable=SC3052
    ver1_dec=$((16#$(printf '%s' "$version1" | sed 's/^0x//')))
    # shellcheck disable=SC3052
    ver2_dec=$((16#$(printf '%s' "$version2" | sed 's/^0x//')))
    
    if [ "$ver1_dec" -ge "$ver2_dec" ]; then
        return 0
    else
        return 1
    fi
}


log_info "Validating UFS Write Booster feature"

# Check for UFS Spec Version node and assign to variable
log_info "Checking for UFS device descriptor specification_version node..."
if SPEC_VERSION=$(ufs_get_dt_node_path "/sys/devices/platform/soc@0/*ufs*/device_descriptor/specification_version"); then
    log_info "Found UFS controller's specification version node: $SPEC_VERSION"
else
    log_skip "Failed to get UFS specification_version node"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

# Get UFS version
spec_version_value=$(cat "$SPEC_VERSION" 2>/dev/null)
if [ -z "$spec_version_value" ]; then
    log_fail "Failed to read specification version from $SPEC_VERSION"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi
log_info "UFS Specification Version: $spec_version_value"

# Check if UFS version is 2.2 or higher (0x0220)
if ! compare_ufs_version "$spec_version_value" "0x0220"; then
    log_skip "Write booster feature is supported from and after UFS spec 2.2"
    log_info "Current UFS spec version: $spec_version_value (Required: >= 0x0220)"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

log_info "UFS spec version $spec_version_value supports Write Booster feature"

if PRIMARY_UFS_CONTROLLER=$(get_primary_ufs_controller "/"); then
    log_info "Primary UFS Controller is $PRIMARY_UFS_CONTROLLER"
else
    log_fail "Failed to get the primary UFS controller from rootfs"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

# Check for Write Booster status node
log_info "Checking for UFS Write Booster status node..."
if WB_STATUS_NODE=$(ufs_get_dt_node_path "/sys/devices/platform/soc@0/$PRIMARY_UFS_CONTROLLER/wb_on"); then
    log_info "Found Write Booster status node: $WB_STATUS_NODE"
else
    log_skip "Failed to get Write Booster status node"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

# Generate load using dd command and check Write Booster status
log_info "Starting I/O load test to verify Write Booster activation..."
tmpfile="$test_path/${TESTNAME}.tmp"

# checking if necessary space is available in rootfs
ensure_rootfs_min_size 3

# Start dd in background
dd if=/dev/zero of="$tmpfile" bs=2M count=1024 >/dev/null 2>&1 &
DD_PID=$!

log_info "Checking Write Booster Activation on UFS Write"
WB_STATUS_CHECK=0

# Use ufs_check_node_status to verify whether UFS WB is enabled
if ! ufs_check_node_status "$WB_STATUS_NODE" "1" 10 1; then
    log_fail "UFS Write Booster is disabled during write"
    WB_STATUS_CHECK=1
else
    log_pass "UFS Write Booster is enabled during write"
fi

# Wait for dd to complete if it's still running
if kill -0 $DD_PID 2>/dev/null; then
    log_info "Waiting for I/O load test to complete..."
    wait $DD_PID 2>/dev/null
    sync
fi

# Clean up temp file
rm -f "$tmpfile"

if [ "$WB_STATUS_CHECK" -ne 0 ]; then
    log_fail "UFS Write Booster Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

# Final validation
log_pass "UFS Write Booster validation passed"

scan_dmesg_errors "$test_path" "ufs"
log_pass "$TESTNAME completed successfully"
echo "$TESTNAME PASS" > "$res_file"
exit 0
