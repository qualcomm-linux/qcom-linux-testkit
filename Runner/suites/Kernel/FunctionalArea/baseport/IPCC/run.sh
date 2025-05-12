#!/bin/sh
# Import test suite definitions
. $(pwd)/init_env
TESTNAME="IPCC"

#import test functions library
. $TOOLS/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

output=$(cat /sys/class/remoteproc/remoteproc*/state)

count=$(echo "$output" | grep -c "running")

if [ $count -eq 4 ]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > $test_path/$TESTNAME.res
else
	log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
