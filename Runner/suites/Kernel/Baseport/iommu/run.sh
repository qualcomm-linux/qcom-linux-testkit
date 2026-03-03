#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
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

# Only source if not already loaded (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="iommu"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

check_runtime_behavior() {
    if dmesg | grep -i -q "msm_iommu.*enabled"; then
        log_info "Runtime logs show Qualcomm MSM IOMMU is active"
    elif dmesg | grep -i -q "iommu.*enabled"; then
        log_info "Runtime logs show IOMMU is active"
    else
        log_fail "No runtime indication of IOMMU being active"
        return 1
    fi
    return 0
}

pass=true

CONFIGS="CONFIG_IOMMU_SUPPORT CONFIG_QCOM_IOMMU CONFIG_ARM_SMMU"
check_kernel_config "$CONFIGS" || {
    log_fail "Kernel config validation failed."
    log_info "Writing to file $res_file"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
}
LOADED_MODULES="msm_iommu arm_smmu"
check_driver_loaded "$LOADED_MODULES" || {
    log_fail "Failed to load required driver modules"
    log_info "Writing to file $res_file"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
}

DT_NODES="/proc/device-tree/soc@0/iommu@15000000 /proc/device-tree/soc/iommu@15000000"
check_dt_nodes "$DT_NODES" || {
    log_fail "Device tree validation failed."
    log_info "Writing to file $res_file"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
}

check_runtime_behavior || pass=false

if $pass; then
    log_pass "$TESTNAME : Test Passed"
    log_info "Writing to file $res_file"
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
else
    log_fail "$TESTNAME : Test Failed"
    log_info "Writing to file $res_file"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
