#!/bin/sh
# Import test suite definitions
/var/Runner/init_env
TESTNAME="DSP_AudioPD"

#import test functions library
. $TOOLS/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

log_info "Checking if dependency binary is available"
check_dependencies adsprpcd

adsprpcd &
PID=$!

if [ -z "$PID" ]; then
  echo "Failed to start the binary"
  exit 1
else
  echo "Binary is running successfully"
fi

check_stack_trace() {
	local pid=$1
	if cat /proc/$pid/stack 2>/dev/null | grep -q "do_sys_poll"; then
		return 0
	else
		return 1
	fi
}

# Print overall test result
if check_stack_trace "$PID"; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME : Test Passed" > $test_path/$TESTNAME.res
else
	log_fail "$TESTNAME : Test Failed"
	echo "$TESTNAME : Test Failed" > $test_path/$TESTNAME.res
fi

log_info "Kill the process"
if kill -0 "$PID" 2>/dev/null; then
	kill -9 "$PID"
	wait "$PID"
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
