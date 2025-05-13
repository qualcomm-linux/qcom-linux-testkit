# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

#!/bin/sh
# Import test suite definitions
/var/Runner/init_env
TESTNAME="fastrpc_test"

#import test functions library
. $TOOLS/functestlib.sh

test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"


log_info "Checking if dependency binary is available"
export PATH=$PATH:/usr/share/bin
check_dependencies fastrpc_test

mkdir -p results/fastrpc_test
chmod -R 755 results/fastrpc_test

# Start logs
dmesg -C
tail -f /var/log/syslog > results/fastrpc_test/syslog_log.txt &
SYSLOG_PID=$!
dmesg -w > results/fastrpc_test/dmesg_log.txt &
DMESG_PID=$!


# Navigate to the directory where the fastrpc_test application is located

cd /usr/share/bin

# Execute the command and capture the output
output=$(./fastrpc_test -d 3 -U 1 -t linux -a v68)
echo $output

# Check if the output contains the desired string
if echo "$output" | grep -q "All tests completed successfully"; then
	log_pass "$TESTNAME : Test Passed"
	echo "$TESTNAME : Test Passed" > $test_path/$TESTNAME.res
else
	log_fail "$TESTNAME : Test Failed"
	echo "$TESTNAME : Test Failed" > $test_path/$TESTNAME.res
fi

# Cleanup
kill $DMESG_PID
kill $SYSLOG_PID

log_info "-------------------Completed $TESTNAME Testcase----------------------------"