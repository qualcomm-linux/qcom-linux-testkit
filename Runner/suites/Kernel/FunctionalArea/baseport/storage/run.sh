#!/bin/sh
# Import test suite definitions
. $(pwd)/init_env
TESTNAME="storage"

#import test functions library
. $TOOLS/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

log_info "Run the dd command to create a file with random data"
dd if=/dev/random of=/tmp/a.txt bs=1M count=1024

# Check if the file is created
if [ -f /tmp/a.txt ]; then
    echo "File /tmp/a.txt is created."

    # Check if the file is not empty
    if [ -s /tmp/a.txt ]; then
        log_pass "File /tmp/a.txt is not empty. Test Passed"
        log_pass "$TESTNAME : Test Passed"
        echo "$TESTNAME PASS" > $test_path/$TESTNAME.res
    else
        log_fail "File /tmp/a.txt is empty. Test Failed."
        log_fail "$TESTNAME : Test Failed"
        echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
    fi
else
    log_fail "File /tmp/a.txt is not created. Test Failed"
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
fi
if [ -f /tmp/a.txt ]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > $test_path/$TESTNAME.res
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"