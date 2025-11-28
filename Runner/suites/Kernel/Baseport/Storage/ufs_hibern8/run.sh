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

check_dependencies dd grep cut head tail udevadm sleep

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
    exit 0
}

block_dev=$(detect_ufs_partition_block)
if [ -z "$block_dev" ]; then
    log_skip "No UFS block device found."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi
log_info "Detected UFS block: $block_dev"

if command -v findmnt >/dev/null 2>&1; then
    rootfs_dev=$(findmnt -n -o SOURCE /)
else
    log_warn "findmnt not available, using fallback rootfs detection"
    rootfs_dev=$(awk '$2 == "/" { print $1 }' /proc/mounts)
fi

resolved_block=$(readlink -f "$block_dev" 2>/dev/null)
resolved_rootfs=$(readlink -f "$rootfs_dev" 2>/dev/null)

if [ -n "$resolved_block" ] && [ -n "$resolved_rootfs" ] && [ "$resolved_block" = "$resolved_rootfs" ]; then
    log_warn "Detected block ($resolved_block) is the root filesystem. Skipping read test."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

# Function to get the first matching node path
get_dt_node_path() {
    node_pattern="$1"
    found_node=""

    for node in $node_pattern; do
        if [ -d "$node" ] || [ -f "$node" ]; then
            found_node="$node"
            break
        fi
    done

    printf "%s" "$found_node"
}

log_info "Validating UFS Hibern8/Active state on load & no-load conditions"

# Check for UFS Hibern8 link state node and assign to variable
log_info "Checking for UFS Hibern8 link state node..."
if ! check_dt_nodes "/sys/bus/platform/devices/*ufs*/power_info/link_state"; then
    log_skip "UFS Hibern8 link state node not found"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

HIBERN8_STATE_NODE=$(get_dt_node_path "/sys/bus/platform/devices/*ufs*/power_info/link_state")
if [ -z "$HIBERN8_STATE_NODE" ]; then
    log_skip "Failed to get Hibern8 link state node path"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi
log_info "Found Hibern8 link state node: $HIBERN8_STATE_NODE"

# Step 2: Generate load using dd command and check for ACTIVE state
log_info "Starting I/O load test to verify UFS link ACTIVE state..."
tmpfile="/ufs_hibern8_test.tmp"

# Start dd in background
dd if=/dev/zero of="$tmpfile" bs=3M count=1024 >/dev/null 2>&1 &
DD_PID=$!

# Wait 1 second for I/O to ramp up
sleep 1

# Read Hibern8 link state during load
HIBERN8_STATE_LOAD=$(cat "$HIBERN8_STATE_NODE" 2>/dev/null | tr -d '[:space:]')
log_info "Hibern8 link state under load: $HIBERN8_STATE_LOAD"

# Verify the state is "ACTIVE" during load
if [ "$HIBERN8_STATE_LOAD" != "ACTIVE" ]; then
    log_fail "UFS link state is not 'ACTIVE' during load. Current state: $HIBERN8_STATE_LOAD"
    kill "$DD_PID" 2>/dev/null
    wait "$DD_PID" 2>/dev/null
    rm -f "$tmpfile"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
log_pass "UFS link state is 'ACTIVE' during load"

# Wait for dd command to complete
log_info "Waiting for dd command to complete..."
wait "$DD_PID"
DD_EXIT_CODE=$?

# Clean up temp file
rm -f "$tmpfile"

if [ $DD_EXIT_CODE -ne 0 ]; then
    log_fail "dd command failed with exit code: $DD_EXIT_CODE"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
log_pass "dd command completed successfully"

# Step 3: Wait for 60 seconds for Hibern8 entry
log_info "Waiting 60 seconds for UFS to enter Hibern8 state..."
sleep 60

# Step 4: Check Hibern8 link state after idle period
HIBERN8_STATE_IDLE=$(cat "$HIBERN8_STATE_NODE" 2>/dev/null | tr -d '[:space:]')
log_info "Hibern8 link state after 60 seconds idle: $HIBERN8_STATE_IDLE"

# Verify the state is "HIBERN8" after idle period
if [ "$HIBERN8_STATE_IDLE" != "HIBERN8" ]; then
    log_fail "UFS link state is not 'HIBERN8' after idle period. Current state: $HIBERN8_STATE_IDLE"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
log_pass "UFS link state is 'HIBERN8' after idle period"

# Final validation
log_pass "UFS Hibern8/Active state validation passed"
log_info "Link state during load: $HIBERN8_STATE_LOAD (Expected: ACTIVE)"
log_info "Link state after idle: $HIBERN8_STATE_IDLE (Expected: HIBERN8)"

scan_dmesg_errors "ufs" "$test_path"
log_pass "$TESTNAME completed successfully"
echo "$TESTNAME PASS" > "$res_file"
exit 0