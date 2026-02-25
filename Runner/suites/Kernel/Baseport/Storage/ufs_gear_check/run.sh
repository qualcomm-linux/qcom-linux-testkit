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

TESTNAME="ufs_gear_check"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 0
res_file="./$TESTNAME.res"

log_info "--------------------------------------------------"
log_info "------------- Starting $TESTNAME Test ------------"

check_dependencies dd grep sleep findmnt awk

# Run common UFS prechecks
if ! ufs_precheck_common; then
    log_skip "Required UFS configurations are not available"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi
log_info "UFS prechecks successful"

# Get UFS gear based on specification version
get_ufs_gear() {
    spec_version="$1"
    gear=""

    case "$spec_version" in
        0x0100)  # UFS 1.0
            gear="1"
            ;;
        0x0110)  # UFS 1.1
            gear="1"
            ;;
        0x0200)  # UFS 2.0
            gear="2"
            ;;
        0x0210)  # UFS 2.1
            gear="3"
            ;;
        0x0220)  # UFS 2.2
            gear="3"
            ;;
        0x0300)  # UFS 3.0
            gear="4"
            ;;
        0x0310)  # UFS 3.1
            gear="4"
            ;;
        0x0400)  # UFS 4.0
            gear="5"
            ;;
        0x0410)  # UFS 4.1
            gear="5"
            ;;
        *)
            log_warn "Unknown UFS specification version: $spec_version"
            return 1
            ;;
    esac
    printf "%s" "$gear"
}

log_info "Validating UFS Gear on load"

if PRIMARY_UFS_CONTROLLER=$(get_primary_ufs_controller "/"); then
    log_info "Primary UFS Controller is $PRIMARY_UFS_CONTROLLER"
else
    log_fail "Failed to get the primary UFS controller from rootfs"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

# Check for UFS Spec Version node and assign to variable
log_info "Checking for UFS device descriptor specification_version node..."
if SPEC_VERSION=$(ufs_get_dt_node_path "/sys/devices/platform/soc@0/$PRIMARY_UFS_CONTROLLER/device_descriptor/specification_version"); then
    log_info "Found UFS controller's specification version node: $SPEC_VERSION"
else
    log_skip "Failed to get UFS specification_version node"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

# Check for UFS Gear node and assign to variable
log_info "Checking for UFS Gear node..."
if GEAR_NODE=$(ufs_get_dt_node_path "/sys/devices/platform/soc@0/$PRIMARY_UFS_CONTROLLER/power_info/gear"); then
    log_info "Found UFS gear node: $GEAR_NODE"
else
    log_skip "Failed to get gear node"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

# Get UFS version and determine expected gear
spec_version_value=$(cat "$SPEC_VERSION" 2>/dev/null)
if [ -z "$spec_version_value" ]; then
    log_fail "Failed to read specification version from $SPEC_VERSION"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi
log_info "UFS Specification Version: $spec_version_value"

EXPECTED_GEAR=$(get_ufs_gear "$spec_version_value")
if [ -z "$EXPECTED_GEAR" ]; then
    log_fail "Failed to determine expected gear for spec version $spec_version_value"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi
log_info "Expected UFS Gear: HS_GEAR$EXPECTED_GEAR"

log_info "Starting I/O load test to verify UFS Gear under load..."
tmpfile="$test_path/${TESTNAME}.tmp"

# checking if necessary space is available in rootfs
ensure_rootfs_min_size 3

# Start dd in background
dd if=/dev/zero of="$tmpfile" bs=2M count=1024 >/dev/null 2>&1 &
DD_PID=$!

# Check gear status during load
log_info "Checking UFS Gear status during load..."
GEAR_STATUS=0

# Use ufs_check_node_status to verify gear value
if ! ufs_check_node_status "$GEAR_NODE" "HS_GEAR$EXPECTED_GEAR" 10 1; then
    log_fail "UFS Gear validation failed during load"
    GEAR_STATUS=1
else
    log_pass "UFS Gear during load is HS_GEAR$EXPECTED_GEAR"
fi

# Wait for dd to complete if it's still running
if kill -0 $DD_PID 2>/dev/null; then
    log_info "Waiting for I/O load test to complete..."
    wait $DD_PID 2>/dev/null
    sync
fi

# Clean up temp file
rm -f "$tmpfile"

# Verify gear status
if [ "$GEAR_STATUS" -ne 0 ]; then
    log_fail "UFS Gear validation failed during load"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

scan_dmesg_errors "$test_path" "ufs"
log_pass "$TESTNAME completed successfully"
echo "$TESTNAME PASS" > "$res_file"
exit 0
