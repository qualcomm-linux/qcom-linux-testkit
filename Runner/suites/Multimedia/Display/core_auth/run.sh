#!/bin/sh
# Import test suite definitions
/var/Runner/init_env
TESTNAME="core_auth"

# Import test functions
source $TOOLS/functestlib.sh

test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"


# Print the start of the test case
echo "-----------------------------------------------------------------------------------------"
echo "-------------------Starting $TESTNAME Testcase----------------------------"

# Print a message to indicate checking for dependency binary
echo "Checking if dependency binary is available"

# Set the library path for the IGT tests
LD_LIBRARY_PATH=/data/igt/lib
export LD_LIBRARY_PATH

# Navigate to the directory containing the IGT tests
cd /data/igt/tests/

# Run the core_auth test and log the output to a file
./core_auth 2>&1 | tee /data/core_auth_log.txt

# Check the log file for the string "SUCCESS" to determine if the test passed
if grep -q "SUCCESS" /data/core_auth_log.txt; then
# If "SUCCESS" is found, print that the test passe
	echo "$TESTNAME : Test Passed"

else
	# If "SUCCESS" is not found, print that the test failed
	echo "$TESTNAME : Test Failed"
fi

# Print the completion of the test case
echo "-------------------Completed $TESTNAME Testcase----------------------------"




