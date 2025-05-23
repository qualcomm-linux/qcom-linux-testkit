#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Import test suite definitions
# shellcheck source=../../../../init_env 
. "${PWD}"/init_env
TESTNAME="AudioRecord"
TESTBINARY="parec"

# Global variable to hold PIDs to be killed at the end of the test
KILLPID=""

# Import test functions
# shellcheck source=../../../../utils/functestlib.sh
. "${TOOLS}"/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")

log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

log_info "Checking if dependency binary is available"
check_dependencies "$TESTBINARY"

# Prepare environment
mkdir -p results/audiotestresult
chmod -R 777 results/audiotestresult

# Start logs
dmesg -C
tail -f /var/log/syslog > results/audiotestresult/syslog_log.txt &
KILLPID="$KILLPID $!"

dmesg -w > results/audiotestresult/dmesg_log.txt &
KILLPID="$KILLPID $!"

# Start the recording
rm -rf /tmp/rec1.wav
sleep 2
parec --rate=48000 --format=s16le --channels=1 --file-format=wav /tmp/rec1.wav -d regular0 &
PID=$!
KILLPID="$KILLPID $!"
sleep 10

# Check whether recording started
if [ -z "$PID" ]; then
    log_info "Fail to start the test binary $TESTBINARY"
    exit 1
else
    log_info "Test Binary $TESTBINARY is running successfully"
fi

check_audio_pid_alive() {
    log_info "Checking if process $1 is alive"
    local result_file="results/audiotestresult/stdout.txt"
    if pgrep -f "$TESTBINARY" > "$result_file"; then
        log_info "Successfully audio record completed"
        return 0
    else 
        log_info "Fail to start audio record"
        return 1
    fi
}

# Final status, Print overall test result
log_info "=== Overall Audio Test Validation Result ==="
if check_audio_pid_alive "$PID"; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME : PASS" > "$test_path/$TESTNAME.res"
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME : FAIL" > "$test_path/$TESTNAME.res"
fi

# Clean up
log_info "Clean up the old PID by Killing the process"
for id in $KILLPID; do
    log_info "$id"
    kill -9 "$id" >/dev/null 2>&1
    sleep 1
done

if [ -f /tmp/rec1.wav ]; then
    log_pass "$TESTNAME : Recorded clip available"
    echo "$TESTNAME PASS" > "$test_path/$TESTNAME.res"
else
    log_fail "$TESTNAME : Recorded clip not available"
    echo "$TESTNAME : FAIL" > "$test_path/$TESTNAME.res"
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
