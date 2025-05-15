# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

#!/bin/sh
# Import test suite definitions
/var/Runner/init_env
TESTNAME="pinctrl"

#import test functions library
source $TOOLS/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "Mounting debugfs"
mount -t debugfs debugfs /sys/kernel/debug
# Execute the command and store the output
output=$(ls /sys/kernel/debug/pinctrl)

# Print overall test result
if [ -z "$output" ]; then
    log_fail "$TESTNAME : Test Failed"
	echo "$TESTNAME : Test Failed" > $test_path/$TESTNAME.res
else
	log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME : Test Passed" > $test_path/$TESTNAME.res
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"