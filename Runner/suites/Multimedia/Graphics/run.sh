#!/bin/sh
# Import test suite definitions
/var/Runner/init_env
TESTNAME="Graphics"

#import test functions library
. $TOOLS/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

log_info "Checking if dependency binary is available"
check_dependencies a660_sqe.fw a660_zap.mbn a660_gmu.bin

# Clear dmesg logs
dmesg -c

cat /dev/dri/card0 &
OUTPUT=$(dmesg)

if echo "${OUTPUT}" | grep "Loaded GMU firmware"; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME : Test Passed" > $test_path/$TESTNAME.res
else
	log_fail "$TESTNAME : Test Failed"
	echo "$TESTNAME : Test Failed" > $test_path/$TESTNAME.res
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
