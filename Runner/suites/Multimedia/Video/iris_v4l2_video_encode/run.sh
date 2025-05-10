# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

#!/bin/sh
# Import test suite definitions
/var/Runner/init_env
TESTNAME="iris_v4l2_video_encode"

#import test functions library
. $TOOLS/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

log_info "Checking if dependency binary is available"
check_dependencies iris_v4l2_test
check_network_status
extract_tar_from_url https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/IRIS-Video-Files-v1.0/video_clips_iris.tar.gz

mkdir -p results/iris_v4l2_video_encode
chmod -R 755 results/iris_v4l2_video_encode

# Start logs
dmesg -C
tail -f /var/log/syslog > results/iris_v4l2_video_encode/syslog_log.txt &
SYSLOG_PID=$!
dmesg -w > results/iris_v4l2_video_encode/dmesg_log.txt &
DMESG_PID=$!

# Run the first test
iris_v4l2_test --config ./suites/Multimedia/Video/iris_v4l2_video_encode/h264Encoder.json --loglevel 15 >> ./suites/Multimedia/Video/iris_v4l2_video_encode/video_enc.txt

if grep -q "SUCCESS" ./suites/Multimedia/Video/iris_v4l2_video_encode/video_enc.txt; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME : Test Passed" > $test_path/$TESTNAME.res
else
	log_fail "$TESTNAME : Test Failed"
	echo "$TESTNAME : Test Failed" > $test_path/$TESTNAME.res
fi

# Cleanup
kill $DMESG_PID
kill $SYSLOG_PID

log_info "-------------------Completed $TESTNAME Testcase----------------------------"