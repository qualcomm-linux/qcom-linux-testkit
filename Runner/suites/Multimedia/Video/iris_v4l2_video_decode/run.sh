#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Import test suite definitions
# shellcheck source=../../../../init_env
. "${PWD}"/init_env
TESTNAME="iris_v4l2_video_decode"
TAR_URL="https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/IRIS-Video-Files-v1.0/video_clips_iris.tar.gz"

#import test functions library
# shellcheck source=../../../../utils/functestlib.sh
. "${TOOLS}"/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

log_info "Checking if dependency binary is available"
check_dependencies iris_v4l2_test
extract_tar_from_url "$TAR_URL"

# Run the first test
iris_v4l2_test --config "${test_path}/h264Decoder.json" --loglevel 15 >> "${test_path}/video_dec.txt"

if grep -q "SUCCESS" "${test_path}/video_dec.txt"; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$test_path/$TESTNAME.res"
else
	log_fail "$TESTNAME : Test Failed"
	echo "$TESTNAME FAIL" > "$test_path/$TESTNAME.res"
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"