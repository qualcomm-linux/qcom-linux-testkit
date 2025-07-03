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
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

log_info "Checking if dependency binary is available"
check_dependencies yavta media-ctl

# To find the exact probed media and video nodes for camera
camera_node_finder

log_info "-------------------Camera commands execution start----------------------------"

# Load configuration
source "$test_path/media_topology.conf"


# Execute commands using variables
eval $RESET_CMD
eval $DISABLE_STREAM
eval $FORMAT_TPG
eval $FORMAT_CSID
eval $FORMAT_VFE
eval $LINK_TPG_CSID
eval $LINK_CSID_VFE
eval $ENABLE_STREAM
 
# Removing the previous execution logs 
rm -rf "${test_path}"/Camera_RDI_Test.txt
rm -rf "${test_path}"/v4l2_camera_RDI_dump.res
rm -rf "${test_path}"/*.bin
 
# Start capture using the dynamic video node
eval $CAPTURE_CMD

if grep -q "Captured 10 frames" "${test_path}/Camera_RDI_Test.txt"; then
    log_pass "$TESTNAME : Test Passed"
	echo "$TESTNAME PASS" > "$test_path/$TESTNAME.res"
else
    log_fail "$TESTNAME : Test Failed"
	echo "$TESTNAME FAIL" > "$test_path/$TESTNAME.res"
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
