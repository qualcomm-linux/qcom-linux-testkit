# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

#!/bin/sh
# Import test suite definitions
/var/Runner/init_env
TESTNAME="Timer"

#import test functions library
source $TOOLS/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

chmod -R 777 /APT/timers

# Path to the binary
BINARY_PATH="/var/common/bins/timers/posix_timers"

# Run the binary and capture the output
OUTPUT=$($BINARY_PATH)

# Check if "pass:7" is in the output
if [[ $OUTPUT == *"pass:7"* ]]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME : Test Passed" > $test_path/$TESTNAME.res
else
	log_fail "$TESTNAME : Test Failed"
	echo "$TESTNAME : Test Failed" > $test_path/$TESTNAME.res
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"