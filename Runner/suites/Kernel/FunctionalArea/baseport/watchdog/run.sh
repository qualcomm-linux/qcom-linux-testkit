# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

#!/bin/sh
# Import test suite definitions
. $(pwd)/init_env
TESTNAME="watchdog"

#import test functions library
. $TOOLS/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

if [ -e /dev/watchdog ]; then
    log_pass "/dev/watchdog node is present."
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > $test_path/$TESTNAME.res
else
    log_fail "/dev/watchdog node is not present."
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
fi
log_info "-------------------Completed $TESTNAME Testcase---------------------------"
