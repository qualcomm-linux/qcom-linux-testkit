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

TESTNAME="ufs_gear_lane"
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

log_info "Validating UFS Gear & Lane on load & no-load conditions"

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

# Check for UFS Gear node and assign to variable
log_info "Checking for UFS Gear node..."
if ! check_dt_nodes "/sys/devices/platform/soc@0/*ufs*/power_info/gear"; then
    log_skip "UFS Gear status node not found"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

GEAR_NODE=$(get_dt_node_path "/sys/devices/platform/soc@0/*ufs*/power_info/gear")
if [ -z "$GEAR_NODE" ]; then
    log_skip "Failed to get gear node path"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi
log_info "Found gear node: $GEAR_NODE"

# Check for UFS Lane node and assign to variable
log_info "Checking for UFS Lane node..."
if ! check_dt_nodes "/sys/devices/platform/soc@0/*ufs*/power_info/lane"; then
    log_skip "UFS Lane status node not found"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

LANE_NODE=$(get_dt_node_path "/sys/devices/platform/soc@0/*ufs*/power_info/lane")
if [ -z "$LANE_NODE" ]; then
    log_skip "Failed to get lane node path"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi
log_info "Found lane node: $LANE_NODE"

# Get UFS version and determine expected gear
spec_version_value=$(cat "$SPEC_VERSION" 2>/dev/null)
if [ -z "$spec_version_value" ]; then
    log_fail "Failed to read specification version from $SPEC_VERSION"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
log_info "UFS Specification Version: $spec_version_value"

EXPECTED_GEAR=$(get_ufs_gear "$spec_version_value")
if [ -z "$EXPECTED_GEAR" ]; then
    log_fail "Failed to determine expected gear for spec version $spec_version_value"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
log_info "Expected UFS Gear: HS_GEAR$EXPECTED_GEAR"

# Start dd command in background and check gear/lane under load
log_info "Starting I/O load test to verify UFS Gear and Lane under load..."
tmpfile="/ufs_gear_lane.tmp"

# Start dd in background
dd if=/dev/zero of="$tmpfile" bs=3M count=1024 >/dev/null 2>&1 &
DD_PID=$!

sleep 1

# Read current gear and lane values
CURRENT_GEAR=$(cat "$GEAR_NODE" 2>/dev/null | tr -d '[:space:]')
CURRENT_LANE=$(cat "$LANE_NODE" 2>/dev/null | tr -d '[:space:]')

wait $DD_PID 2>/dev/null

# Clean up temp file
rm -f "$tmpfile"

log_info "Current UFS Gear under load: $CURRENT_GEAR"
log_info "Current UFS Lane under load: $CURRENT_LANE"

# Verify gear and lane values
if [ -z "$CURRENT_GEAR" ] || [ -z "$CURRENT_LANE" ]; then
    log_fail "Failed to read current gear or lane values"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

# Check if gear matches expected and lane is 2
if [ "$CURRENT_GEAR" = "HS_GEAR$EXPECTED_GEAR" ] && [ "$CURRENT_LANE" = "2" ]; then
    log_pass "UFS Gear and Lane validation passed"
    log_info "Gear: $CURRENT_GEAR (Expected: HS_GEAR$EXPECTED_GEAR)"
    log_info "Lane: $CURRENT_LANE (Expected: 2)"
    scan_dmesg_errors "ufs" "$test_path"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "UFS Gear and Lane validation failed"
    if [ "$CURRENT_GEAR" != "HS_GEAR$EXPECTED_GEAR" ]; then
        log_fail "Gear mismatch: Current=$CURRENT_GEAR, Expected=HS_GEAR$EXPECTED_GEAR"
    fi
    if [ "$CURRENT_LANE" != "2" ]; then
        log_fail "Lane mismatch: Current=$CURRENT_LANE, Expected=2"
    fi
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

scan_dmesg_errors "ufs" "$test_path"
log_pass "$TESTNAME completed successfully"
echo "$TESTNAME PASS" > "$res_file"
exit 0