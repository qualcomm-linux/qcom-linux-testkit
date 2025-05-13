# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

#!/bin/sh
# Import test suite definitions
. $(pwd)/init_env
TESTNAME="cdsp_remoteproc"

#import test functions library
. $TOOLS/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

# Get the firmware output and find the position of cdsp
log_info "Get the firmware output and find the position of cdsp"
firmware_output=$(cat /sys/class/remoteproc/remoteproc*/firmware)
cdsp_position=$(echo "$firmware_output" | grep -n "cdsp" | cut -d: -f1)

# Adjust the position to match the remoteproc numbering (starting from 0)
remoteproc_number=$((cdsp_position - 1))

# Construct the remoteproc path based on the cdsp position
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
    log_fail "cdsp stop failed"
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
    exit 1
else
    log_pass "cdsp stop successful"
fi
log_info "Restarting remoteproc"
# Execute command 4 (no output expected)
echo start > ${remoteproc_path}/state

# Execute command 5 and check if the output is "running"
state5=$(cat ${remoteproc_path}/state)
if [ "$state5" != "running" ]; then
    log_fail "cdsp start failed"
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
    exit 1
fi

# If all checks pass, print "PASS"
echo "cdsp PASS"
log_pass "cdsp PASS"
echo "$TESTNAME PASS" > $test_path/$TESTNAME.res
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
