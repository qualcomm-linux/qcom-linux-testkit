# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

#!/bin/sh
# Import test suite definitions
. $(pwd)/init_env
TESTNAME="RMNET"

#import test functions library
log() {
    local level="$1"
	shift
    # echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" | tee -a /var/test_framework.log
	echo "[$level] $(/bin/date '+%Y-%m-%d %H:%M:%S') - $*" | /usr/bin/tee -a /var/test_output.log
}
# Find test case path by name
find_test_case_by_name() {
    local test_name="$1"
    find /var/Runner/suites -type d -name "$test_name" 2>/dev/null
}
# Logging levels
log_info() { log "INFO" "$@"; }
log_pass() { log "PASS" "$@"; }
log_fail() { log "FAIL" "$@"; }
log_error() { log "ERROR" "$@"; }

test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

PATH=$(find / -name "rmnet.ko" 2>/dev/null)

if [ -z "$PATH" ]; then
  log_error "rmnet.ko file not found."
  exit 1
fi

TEST=$(/sbin/insmod "$PATH")
log_info "output of insmod $TEST"

if /sbin/lsmod | /bin/grep "rmnet"; then
    log_info "$(/sbin/lsmod | /bin/grep "rmnet")" 
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > $test_path/$TESTNAME.res
else
    log_error "rmnet module not running"
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"