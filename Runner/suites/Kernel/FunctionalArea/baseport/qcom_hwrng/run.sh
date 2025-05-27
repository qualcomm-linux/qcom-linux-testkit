#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Import test suite definitions
. "${PWD}"/init_env
TESTNAME="qcom_hwrng"

#import test functions library
. "${TOOLS}"/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

# Set the hardware RNG source to Qualcomm's RNG
if [ -e /sys/class/misc/hw_random/rng_current ]; then
    echo qcom_hwrng > /sys/class/misc/hw_random/rng_current
else
    echo "Path /sys/class/misc/hw_random/rng_current does not exist."
    log_fail "$TESTNAME : Test Failed"
    exit 1
fi

# Verify that qcom_hwrng was successfully set
current_rng=$(cat /sys/class/misc/hw_random/rng_current)
if [ "$current_rng" != "qcom_hwrng" ]; then
    log_info "Error: Failed to set qcom_hwrng as the current RNG source."
    log_fail "$TESTNAME : Test Failed"
    exit 1
else
    log_info "qcom_hwrng successfully set as the current RNG source."
fi

log_info "Checking if dependency binary is available"
check_dependencies rngtest

cat /dev/random | rngtest -c 1000 > /tmp/qcom_hwrng_output.txt 2>&1

grep 'FIPS 140-2 failures' /tmp/qcom_hwrng_output.txt | awk '{print $NF}' > /tmp/rngtest_failures.txt

value=$(cat /tmp/rngtest_failures.txt)

if [ "$value" -lt 10 ]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > $test_path/$TESTNAME.res
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"