#!/bin/sh
# Import test suite definitions
$(pwd)/init_env
TESTNAME="video_decode"

#import test functions library
source $TOOLS/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

log_info "Checking if dependency binary is available"
check_dependencies iris_v4l2_test

# Run the first test
iris_v4l2_test --config /Video/DEC_AVC_NV12_BASIC_CFG.json --loglevel 15 >> video_dec.txt

if grep -q "Test Passed" "video_dec.txt"; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > $test_path/$TESTNAME.res
else
	log_fail "$TESTNAME : Test Failed"
	echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"