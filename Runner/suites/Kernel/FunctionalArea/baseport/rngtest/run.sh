#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Import test suite definitions
. "${PWD}"/init_env
TESTNAME="rngtest"

#import test functions library
. "${TOOLS}"/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

log_info "Checking if dependency binary is available"
check_dependencies rngtest

cat /dev/random | rngtest -c 1000 > /tmp/rngtest_output.txt

grep 'count of bits' /tmp/rngtest_output.txt | awk '{print $NF}' > /tmp/rngtest_value.txt

value=$(cat /tmp/rngtest_value.txt)


if [ "$value" -lt 10 ]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > $test_path/$TESTNAME.res
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
