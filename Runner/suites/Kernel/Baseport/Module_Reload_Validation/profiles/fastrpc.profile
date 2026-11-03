#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

PROFILE_NAME="fastrpc"
PROFILE_DESCRIPTION="FastRPC module reload validation"
MODULE_NAME="fastrpc"

PROFILE_MODE_DEFAULT="basic"
PROFILE_REQUIRED_CMDS="modprobe rmmod systemctl ps sed grep readlink sort awk tr"

PROFILE_QUIESCE_ONCE="yes"
PROFILE_DISCOVER_CLIENT_SERVICES="yes"
PROFILE_QUIESCE_SERVICES="adsprpcd.service cdsprpcd.service"
PROFILE_PROC_PATTERNS="adsprpcd cdsprpcd fastrpc_shell"
PROFILE_QUIESCE_PROC_PATTERNS="$PROFILE_PROC_PATTERNS"

PROFILE_DEVICE_PATTERNS="/dev/fastrpc-* /dev/adsprpc-* /dev/cdsprpc-*"
PROFILE_QUIESCE_DEVICE_PATTERNS="$PROFILE_DEVICE_PATTERNS"

PROFILE_SYSFS_PATTERNS="/sys/module/fastrpc /sys/class/remoteproc/* /sys/kernel/debug/fastrpc* /sys/kernel/debug/adsprpc*"

PROFILE_EXPECT_ABSENT_AFTER_UNLOAD="fastrpc"
PROFILE_EXPECT_PRESENT_AFTER_LOAD="fastrpc"

module_reload_profile_setup_stack

profile_quiesce() {
  module_reload_profile_quiesce_resources "$PROFILE_NAME" "$1" 20
}

profile_smoke() {
  module_reload_profile_smoke_modules_present "$PROFILE_NAME" "$PROFILE_EXPECT_PRESENT_AFTER_LOAD"
}
