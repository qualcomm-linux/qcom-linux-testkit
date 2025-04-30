#!/bin/sh
# Import test suite definitions
/var/Runner/init_env
TESTNAME="video_encode"

#import test functions library
source $TOOLS/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

# Make the test executable
chmod -R 777 /Video

# Run the first test
/Video/iris_v4l2_test --config /Video/ENC_AVC_NV12_BASIC_CFG.json --loglevel 15 >> video_enc.txt

if grep -q "Test Passed" "video_enc.txt"; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME : Test Passed" > $test_path/$TESTNAME.res
else
	log_fail "$TESTNAME : Test Failed"
	echo "$TESTNAME : Test Failed" > $test_path/$TESTNAME.res
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"