#!/bin/sh
# Import test suite definitions
. $(pwd)/init_env
TESTNAME="wpss_remoteproc"

#import test functions library
. $TOOLS/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

# Get the firmware output and find the position of wpss
firmware_output=$(cat /sys/class/remoteproc/remoteproc*/firmware)
wpss_position=$(echo "$firmware_output" | grep -n "wpss" | cut -d: -f1)

# Adjust the position to match the remoteproc numbering (starting from 0)
remoteproc_number=$((wpss_position - 1))

# Construct the remoteproc path based on the wpss position
remoteproc_path="/sys/class/remoteproc/remoteproc${remoteproc_number}"

# Execute command 1 and check if the output is "running"
state1=$(cat ${remoteproc_path}/state)
if [ "$state1" != "running" ]; then
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
	exit 1
fi

# Execute command 2 (no output expected)
echo stop > ${remoteproc_path}/state

# Execute command 3 and check if the output is "offline"
state3=$(cat ${remoteproc_path}/state)
if [ "$state3" != "offline" ]; then
    log_fail "wpss stop failed"
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
    exit 1
else
	log_pass "wpss stop successful"
fi

# Execute command 4 (no output expected)
echo start > ${remoteproc_path}/state

# Execute command 5 and check if the output is "running"
state5=$(cat ${remoteproc_path}/state)
if [ "$state5" != "running" ]; then
    log_fail "wpss start failed"
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
    exit 1
fi

# If all checks pass, print "PASS"
echo "wpss PASS"
log_pass "wpss PASS"
echo "$TESTNAME PASS" > $test_path/$TESTNAME.res
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
