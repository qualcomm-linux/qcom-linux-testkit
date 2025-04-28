#!/bin/sh
# Import test suite definitions
/var/Runner/init_env
TESTNAME="remoteproc"

#import test functions library
source $TOOLS/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

log_info "Getting the number of subsystems aavailable"
subsystem_count=$(cat /sys/class/remoteproc/remoteproc*/state | wc -l)

# Execute the command and get the output
log_info "Checking if all the remoteprocs are in running state"
output=$(cat /sys/class/remoteproc/remoteproc*/state)

# Count the number of "running" values
count=$(echo "$output" | grep -c "running")
log_info "rproc subsystems in running state : $count, expected subsystems : $subsystem_count"

# Print overall test result
if [ $count -eq $subsystem_count ]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME : Test Passed" > $test_path/$TESTNAME.res
else
	log_fail "$TESTNAME : Test Failed"
	echo "$TESTNAME : Test Failed" > $test_path/$TESTNAME.res
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"