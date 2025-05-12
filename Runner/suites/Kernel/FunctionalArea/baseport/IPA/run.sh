#!/bin/sh
# Import test suite definitions
. $(pwd)/init_env
TESTNAME="IPA"

test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

PATH=$(find / -name "ipa.ko" 2>/dev/null)

# Check if the file was found
if [ -z "$PATH" ]; then
  log_error "ipa.ko file not found."
  exit 1
fi

# Insert the module
TEST=$(/sbin/insmod "$PATH")
log_info "output of insmod $TEST"

if /sbin/lsmod | /bin/grep "ipa"; then
    log_info "$(/sbin/lsmod | /bin/grep "ipa")" 
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > $test_path/$TESTNAME.res
else
    log_error "rmnet module not running"
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"