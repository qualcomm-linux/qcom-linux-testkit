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

TESTNAME="ufs_runtime_suspend_resume"
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

log_info "Validating UFS Runtime/Suspend on load & no-load conditions"
# Check for UFS runtime status node and assign to variable
log_info "Checking for UFS runtime status node..."
if ! check_dt_nodes "/sys/devices/platform/soc@0/*ufs*/power/runtime_status"; then
    log_skip "UFS runtime status node not found"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

RUNTIME_STATUS_NODE=$(get_dt_node_path "/sys/devices/platform/soc@0/*ufs*/power/runtime_status")
if [ -z "$RUNTIME_STATUS_NODE" ]; then
    log_skip "Failed to get runtime status node path"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi
log_info "Found runtime status node: $RUNTIME_STATUS_NODE"

# Step 2: Generate load using dd command and check for active state
log_info "Starting I/O load test to verify UFS runtime active state..."
tmpfile="/ufs_runtime_test.tmp"

# Start dd in background
dd if=/dev/zero of="$tmpfile" bs=3M count=1024 >/dev/null 2>&1 &
DD_PID=$!

# Wait 0.5 seconds for I/O to ramp up
sleep 1

# Read runtime status during load
RUNTIME_STATUS_LOAD=$(cat "$RUNTIME_STATUS_NODE" 2>/dev/null | tr -d '[:space:]')
log_info "Runtime status under load: $RUNTIME_STATUS_LOAD"

# Verify the status is "active" during load
if [ "$RUNTIME_STATUS_LOAD" != "active" ]; then
    log_fail "UFS runtime status is not 'active' during load. Current status: $RUNTIME_STATUS_LOAD"
    kill "$DD_PID" 2>/dev/null
    wait "$DD_PID" 2>/dev/null
    rm -f "$tmpfile"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
log_pass "UFS runtime status is 'active' during load"

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

# Step 3: Wait for 60 seconds for runtime suspend
log_info "Waiting 60 seconds for UFS to enter runtime suspend..."
sleep 60

# Step 4: Check runtime status after idle period
RUNTIME_STATUS_IDLE=$(cat "$RUNTIME_STATUS_NODE" 2>/dev/null | tr -d '[:space:]')
log_info "Runtime status after 60 seconds idle: $RUNTIME_STATUS_IDLE"

# Verify the status is "suspended" after idle period
if [ "$RUNTIME_STATUS_IDLE" != "suspended" ]; then
    log_fail "UFS runtime status is not 'suspended' after idle period. Current status: $RUNTIME_STATUS_IDLE"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
log_pass "UFS runtime status is 'suspended' after idle period"

# Final validation
log_pass "UFS Runtime Suspend/Resume validation passed"
log_info "Status during load: $RUNTIME_STATUS_LOAD (Expected: active)"
log_info "Status after idle: $RUNTIME_STATUS_IDLE (Expected: suspended)"

scan_dmesg_errors "ufs" "$test_path"
log_pass "$TESTNAME completed successfully"
echo "$TESTNAME PASS" > "$res_file"
exit 0