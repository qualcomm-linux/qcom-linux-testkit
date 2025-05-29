# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

#!/bin/sh
# Import test suite definitions
. $(pwd)/init_env
TESTNAME="Opencv_core"

# Import test functions
. $TOOLS/functestlib.sh

test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"


log_info "Checking if dependency binary is available"
check_dependencies opencv_test_core

# Navigate to the directory where the fastrpc_test application is located
cd /usr/bin/
chmod 777 opencv_test_core

# Execute the command and capture the output
export OPENCV_OPENCL_RUNTIME=disabled && /usr/bin/opencv_perf_core --gtest_filter=Core_AddMixed/ArithmMixedTest.accuracy/0 > /data/opencv_core_result.txt

# Check the log file for the string "SUCCESS" to determine if the test passed
if grep -q "PASSED" /data/opencv_core_result.txt; then
	log_pass "$TESTNAME : Test Passed"
	echo "$TESTNAME PASS" > $test_path/$TESTNAME.res

else
	log_fail "$TESTNAME : Test Failed"
	echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
fi

# Print the completion of the test case
log_info "-------------------Completed $TESTNAME Testcase----------------------------"




