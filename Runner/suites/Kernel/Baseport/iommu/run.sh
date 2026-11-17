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

check_iommu_bound() {
    bound=""
    for unit in /sys/class/iommu/*; do
        [ -e "$unit/device/driver" ] || continue
        log_info "IOMMU ${unit##*/} bound to $(basename "$(readlink -f "$unit/device/driver")")"
        bound=1
    done
    if [ -z "$bound" ]; then
        log_fail "No bound IOMMU in /sys/class/iommu"
        return 1
    fi
    for group in /sys/kernel/iommu_groups/*; do
        [ -e "$group" ] && return 0
    done
    log_fail "No IOMMU groups in /sys/kernel/iommu_groups"
    return 1
}

pass=true

CONFIGS="CONFIG_IOMMU_SUPPORT CONFIG_QCOM_IOMMU CONFIG_ARM_SMMU"
check_kernel_config "$CONFIGS" || {
    log_fail "Kernel config validation failed."
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

check_iommu_bound || pass=false

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

