#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Import test suite definitions
# shellcheck source=../../../../init_env
. "${PWD}"/init_env
TESTNAME="AudioPlayback"
TESTBINARY="paplay"
TAR_URL="https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/Pulse-Audio-Files-v1.0/AudioClips.tar.gz"

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

extract_tar_from_url "$TAR_URL"

lscontent=$(ls "${PWD}"/AudioClips)
case "$lscontent" in
  *yesterday_48KHz.wav*) log_info "Playback clip downloaded" ;;
  *) log_info "Playback clip not downloaded" ;;
esac

# Prepare environment
mkdir -p results/audiotestresult
chmod -R 777 results/audiotestresult

# Start logs
dmesg -C
tail -f /var/log/syslog > results/audiotestresult/syslog_log.txt &
KILLPID="$KILLPID $!"

dmesg -w > results/audiotestresult/dmesg_log.txt &
KILLPID="$KILLPID $!"

# Start the Playback
paplay "${PWD}"/AudioClips/yesterday_48KHz.wav -d low-latency0 &
PID=$!
KILLPID="$KILLPID $!"
sleep 10

# Check whether playback started
if [ -z "$PID" ]; then
  log_info "Fail to start the test binary $TESTBINARY"
  exit 1
else
  log_info "Test Binary $TESTBINARY is running successfully"
fi

check_audio_pid_alive() {
    log_info "Checking if audio process with PID $1 is alive"
    local pid="$1"
    local result_file="results/audiotestresult/stdout.txt"
    pgrep -af "$TESTBINARY" | head -1 | tee "$result_file"

    if grep -q "$pid" "$result_file"; then
        log_info "Successfully audio playback completed"
        return 0
    else 
        log_info "Fail to start audio playback"
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

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
