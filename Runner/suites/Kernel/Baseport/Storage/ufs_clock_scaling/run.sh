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

log_info "Validating UFS clock scaling & clock gating"
# Check for UFS clock freq node and assign to variable
log_info "Checking for UFS clock freq node..."
if ! check_dt_nodes "/sys/devices/platform/soc@0/*ufs*/devfreq/*ufs*/cur_freq"; then
    log_skip "UFS clock frequency node not found"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

UFS_CLOCK_FREQ_NODE=$(get_dt_node_path "/sys/devices/platform/soc@0/*ufs*/devfreq/*ufs*/cur_freq")
if [ -z "$UFS_CLOCK_FREQ_NODE" ]; then
    log_skip "Failed to get UFS clock frequency node path"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi
log_info "Found UFS clock freq node: $UFS_CLOCK_FREQ_NODE"

# Check for UFS clock max freq node and assign to variable
log_info "Checking for UFS max clock freq node..."
if ! check_dt_nodes "/sys/devices/platform/soc@0/*ufs*/devfreq/*ufs*/max_freq"; then
    log_skip "UFS max frequency node not found"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

UFS_MAX_FREQ_NODE=$(get_dt_node_path "/sys/devices/platform/soc@0/*ufs*/devfreq/*ufs*/max_freq")
if [ -z "$UFS_MAX_FREQ_NODE" ]; then
    log_skip "Failed to get UFS max clock frequency node path"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi
log_info "Found UFS max freq node: $UFS_MAX_FREQ_NODE"

UFS_MAX_FREQ=$(cat "$UFS_MAX_FREQ_NODE" 2>/dev/null)
if [ -z "$UFS_MAX_FREQ" ]; then
    log_skip "Failed to read max frequency from $UFS_MAX_FREQ_NODE"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi
log_info "Max UFS clock frequency supported is $UFS_MAX_FREQ"

# Generate load using dd command and check for ufs cur_freq
log_info "Starting I/O load test to verify UFS clock scaling..."
tmpfile="/ufs_clock_scaling.tmp"

# Start dd in background
dd if=/dev/zero of="$tmpfile" bs=2M count=1024 >/dev/null 2>&1 &
DD_PID=$!

log_info "Checking whether UFS clock is scaled during load..."
UFS_CLOCK_SCALED=0

# Use check_node_status to verify ufs clock scaling
if ! check_node_status "$UFS_CLOCK_FREQ_NODE" "$UFS_MAX_FREQ" 10 1; then
    log_fail "UFS clock is not scaled"
else
    log_pass "UFS clock is scaled to $UFS_MAX_FREQ"
    UFS_CLOCK_SCALED=1
fi

# Wait for dd to complete if it's still running
if kill -0 $DD_PID 2>/dev/null; then
    log_info "Waiting for I/O load test to complete..."
    wait $DD_PID 2>/dev/null
    sync
fi

# Clean up temp file
rm -f "$tmpfile"

# wait for 60 seconds for UFS driver to go to idle state
log_info "Waiting for 60 seconds for UFS clock to gate"
sync
sleep 60


UFS_MIN_FREQ_NODE=$(get_dt_node_path "/sys/devices/platform/soc@0/*ufs*/devfreq/*ufs*/min_freq")
if [ -z "$UFS_MIN_FREQ_NODE" ]; then
    log_skip "Failed to get UFS min clock frequency node path"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi
log_info "Found UFS min freq node: $UFS_MIN_FREQ_NODE"

UFS_MIN_FREQ=$(cat "$UFS_MIN_FREQ_NODE" 2>/dev/null)
if [ -z "$UFS_MIN_FREQ" ]; then
    log_skip "Failed to read min frequency from $UFS_MIN_FREQ"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi
log_info "Min UFS clock frequency supported is $UFS_MIN_FREQ"

log_info "Checking whether UFS clock is gated when no load is applied"
UFS_CLOCK_GATED=0

# Use check_node_status to verify ufs clock scaling
if ! check_node_status "$UFS_CLOCK_FREQ_NODE" "$UFS_MIN_FREQ" 10 1; then
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