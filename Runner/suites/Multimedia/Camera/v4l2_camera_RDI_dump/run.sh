#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# --------- Robustly source init_env and functestlib.sh ----------
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

if [ -z "$__INIT_ENV_LOADED" ]; then
    . "$INIT_ENV"
fi
. "$TOOLS/functestlib.sh"
# ---------------------------------------------------------------

TESTNAME="v4l2_camera_RDI_dump"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

log_info "Checking if dependency binary is available"
check_dependencies yavta media-ctl

log_info "-------------------Camera commands execution start----------------------------"
# Run the test
mount -o rw,remount /
mount -o rw,remount /usr/
media-ctl -d /dev/media0 --reset
yavta --no-query -w '0x009f0903 0' /dev/v4l-subdev0
media-ctl -d /dev/media0 -V '"msm_tpg0":0[fmt:SRGGB10/1920x1080 field:none]'
media-ctl -d /dev/media0 -V '"msm_csid0":0[fmt:SRGGB10/1920x1080 field:none]'
media-ctl -d /dev/media0 -V '"msm_vfe0_rdi0":0[fmt:SRGGB10/1920x1080 field:none]'
media-ctl -d /dev/media0 -l '"msm_tpg0":1->"msm_csid0":0[1]'
media-ctl -d /dev/media0 -l '"msm_csid0":1->"msm_vfe0_rdi0":0[1]'

#Removing previous logs in the device
rm -rf "${test_path}"/Camera_RDI_Test.txt
rm -rf "${test_path}"/v4l2_camera_RDI_dump.res
rm -rf "${test_path}"/*.bin

yavta --no-query -w '0x009f0903 9' /dev/v4l-subdev0
yavta -B capture-mplane -n 5 -f SRGGB10P -s 1920x1080 /dev/video1 --capture=10 --file='frame-#.bin' >> "${test_path}/Camera_RDI_Test.txt"


if grep -q "Captured 10 frames" "${test_path}/Camera_RDI_Test.txt"; then
    log_pass "$TESTNAME : Test Passed"
else
    log_fail "$TESTNAME : Test Failed"
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"