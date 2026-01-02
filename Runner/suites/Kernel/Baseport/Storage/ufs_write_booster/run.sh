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

TESTNAME="ufs_write_booster"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "--------------------------------------------------"
log_info "------------- Starting $TESTNAME Test ------------"

check_dependencies dd

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

# Function to compare UFS specification versions
# Returns 0 if version1 >= version2, 1 otherwise
compare_ufs_version() {
    version1="$1"
    version2="$2"
    
    # Convert hex to decimal for comparison
    ver1_dec=$((version1))
    ver2_dec=$((version2))
    
    if [ "$ver1_dec" -ge "$ver2_dec" ]; then
        return 0
    else
        return 1
    fi
}

log_info "Validating UFS Write Booster feature"

# Check for UFS Spec Version node and assign to variable
log_info "Checking for UFS device descriptor specification_version node..."
if ! check_dt_nodes "/sys/devices/platform/soc@0/*ufs*/device_descriptor/specification_version"; then
    log_skip "UFS device descriptor specification_version node not found"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

SPEC_VERSION=$(get_dt_node_path "/sys/devices/platform/soc@0/*ufs*/device_descriptor/specification_version")
if [ -z "$SPEC_VERSION" ]; then
    log_skip "Failed to get specification_version node path"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi
log_info "Found specification version node: $SPEC_VERSION"

# Get UFS version
spec_version_value=$(cat "$SPEC_VERSION" 2>/dev/null)
if [ -z "$spec_version_value" ]; then
    log_fail "Failed to read specification version from $SPEC_VERSION"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
log_info "UFS Specification Version: $spec_version_value"

# Check if UFS version is 3.1 or higher (0x0310)
if ! compare_ufs_version "$spec_version_value" "0x0310"; then
    log_skip "Write booster feature is supported from and after UFS spec 3.1"
    log_info "Current UFS spec version: $spec_version_value (Required: >= 0x0310)"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

log_info "UFS spec version $spec_version_value supports Write Booster feature"

# Check for Write Booster status node
log_info "Checking for UFS Write Booster status node..."
if ! check_dt_nodes "/sys/devices/platform/soc@0/*ufs*/devfreq/*ufs*/device/wb_on"; then
    log_skip "UFS Write Booster status node not found"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

WB_STATUS_NODE=$(get_dt_node_path "/sys/devices/platform/soc@0/*ufs*/devfreq/*ufs*/device/wb_on")
if [ -z "$WB_STATUS_NODE" ]; then
    log_skip "Failed to get Write Booster status node path"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi
log_info "Found Write Booster status node: $WB_STATUS_NODE"

# Generate load using dd command and check Write Booster status
log_info "Starting I/O load test to verify Write Booster activation..."
tmpfile="/ufs_wb_test.tmp"

# Start dd in background
dd if=/dev/zero of="$tmpfile" bs=2M count=1024 >/dev/null 2>&1 &
DD_PID=$!

log_info "Checking Write Booster Activation on UFS Write"
WB_STATUS_CHECK=0

# Use check_node_status to verify whether UFS WB is enabled
if ! check_node_status "$WB_STATUS_NODE" "1" 5 0.5; then
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
    exit 1
fi

# Final validation
log_pass "UFS Write Booster validation passed"

scan_dmesg_errors "$test_path" "ufs"
log_pass "$TESTNAME completed successfully"
echo "$TESTNAME PASS" > "$res_file"
exit 0