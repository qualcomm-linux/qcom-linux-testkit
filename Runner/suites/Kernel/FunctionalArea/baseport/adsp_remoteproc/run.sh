#!/bin/sh
# Import test suite definitions
/var/Runner/init_env
TESTNAME="adsp_remoteproc"

#import test functions library
source $TOOLS/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

# Get the firmware output and find the position of adsp
log_info "Checking for firmware"
firmware_output=$(cat /sys/class/remoteproc/remoteproc*/firmware)
adsp_position=$(echo "$firmware_output" | grep -n "adsp" | cut -d: -f1)

# Adjust the position to match the remoteproc numbering (starting from 0)
remoteproc_number=$((adsp_position - 1))

# Construct the remoteproc path based on the adsp position
remoteproc_path="/sys/class/remoteproc/remoteproc${remoteproc_number}"
log_info "Remoteproc node is $remoteproc_path"
# Execute command 1 and check if the output is "running"
state1=$(cat ${remoteproc_path}/state)

if [ "$state1" != "running" ]; then
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME : Test Failed" > $test_path/$TESTNAME.res
	exit 1
fi

# Execute command 2 (no output expected)
log_info "Stopping remoteproc"
echo stop > ${remoteproc_path}/state

# Execute command 3 and check if the output is "offline"
state3=$(cat ${remoteproc_path}/state)
if [ "$state3" != "offline" ]; then
	log_fail "adsp stop failed"
	echo "$TESTNAME : Test Failed" > $test_path/$TESTNAME.res
    exit 1
else
	log_pass "adsp stop successful"
fi
log_info "Restarting remoteproc"
# Execute command 4 (no output expected)
echo start > ${remoteproc_path}/state

# Execute command 5 and check if the output is "running"
state5=$(cat ${remoteproc_path}/state)
if [ "$state5" != "running" ]; then
	log_fail "adsp start failed"
	echo "$TESTNAME : Test Failed" > $test_path/$TESTNAME.res
    exit 1
fi

# If all checks pass, print "PASS"
echo "adsp PASS"
log_pass "adsp PASS"
echo "$TESTNAME : Test Passed" > $test_path/$TESTNAME.res
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
