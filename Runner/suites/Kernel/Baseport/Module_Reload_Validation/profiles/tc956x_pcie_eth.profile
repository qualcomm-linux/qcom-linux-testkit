#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Profile variables are consumed by the shared module-reload engine.
# shellcheck disable=SC2034

PROFILE_NAME="tc956x_pcie_eth"
PROFILE_DESCRIPTION="TC956x PCIe Ethernet module reload validation"
MODULE_NAME="tc956x_pcie_eth"

MODULE_RELOAD_SUPPORTED="yes"
PROFILE_MODE_DEFAULT="basic"

PROFILE_REQUIRED_CMDS="modprobe rmmod ps sed"

MODULE_UNLOAD_CMD="modprobe -r tc956x_pcie_eth"
MODULE_LOAD_CMD="modprobe tc956x_pcie_eth"

PROFILE_EXPECT_ABSENT_AFTER_UNLOAD="tc956x_pcie_eth"
PROFILE_DEVICE_PATTERNS="/sys/class/net/*"
PROFILE_SYSFS_PATTERNS="/sys/module/tc956x_pcie_eth"

# profile_load_only <result-dir>
#   Opt-in dynamic module load/readiness validation with target-only restoration.
#   stdout: diagnostics. return: 0 ready, 1 failed, 2 unavailable.
profile_load_only() {
    # shellcheck disable=SC1091
    . "$TOOLS/lib_ethernet.sh"
    ethv_qps615_validate_module_load "$1" "$TIMEOUT_LOAD" "$TIMEOUT_SETTLE"
}
