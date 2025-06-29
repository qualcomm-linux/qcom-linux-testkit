#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Import test suite definitions
. $(pwd)/init_env
TESTNAME="core_auth"

# Import test functions
. $TOOLS/functestlib.sh

test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"


# Print the start of the test case
echo "-----------------------------------------------------------------------------------------"
echo "-------------------Starting $TESTNAME Testcase----------------------------"

# Print a message to indicate checking for dependency binary
echo "Checking if dependency binary is available"

# Set the library path for the IGT tests
if [ -d "/data/" ] && [ -d "/data/igt/lib" ]; then
	# Set the LD_LIBRARY_PATH environment variable
	export LD_LIBRARY_PATH=/data/igt/lib
	echo "LD_LIBRARY_PATH is set to /data/igt/lib"
else
	echo "Directory either /data/ or /data/igt/lib or both does not exist"
	exit 1
fi

# Navigate to the directory containing the IGT tests
cd /data/igt/tests/

# Run the core_auth test and log the output to a file
./core_auth 2>&1 | tee /data/core_auth_log.txt

# Check the log file for the string "SUCCESS" to determine if the test passed
if grep -q "SUCCESS" /data/core_auth_log.txt; then
# If "SUCCESS" is found, print that the test passe
	log_pass "$TESTNAME : Test Passed"
	echo "$TESTNAME PASS" > $test_path/$TESTNAME.res

else
	# If "SUCCESS" is not found, print that the test failed
	log_pass "$TESTNAME : Test Failed"
	echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
fi

# Print the completion of the test case
echo "-------------------Completed $TESTNAME Testcase----------------------------"