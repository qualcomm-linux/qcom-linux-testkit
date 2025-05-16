# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

#!/bin/sh

# Import test suite definitions
. $(pwd)/init_env
TESTNAME="audio_record_test"
TESTBINARY="parec"

#Global variable to hold PID which  needs to be killed at the end of the test
KILLPID=()

# Import test functions
. $TOOLS/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
echo "--------------------------------------------------------------------------"
echo "-------------------Starting $TESTNAME Testcase----------------------------"

echo "Checking if dependency binary is available"
check_dependencies $TESTBINARY

# Prepare environment
mkdir -p results/audiotestresult
chmod -R 777 results/audiotestresult

# Start logs
dmesg -C
tail -f /var/log/syslog > results/audiotestresult/syslog_log.txt &
KILLPID[${#KILLPID[@]}+1]="$!"

dmesg -w > results/audiotestresult/dmesg_log.txt &
KILLPID[${#KILLPID[@]}+1]="$!"

#Start the Playback
parec --rate=48000 --format=s16le --channels=1 --file-format=wav /tmp/rec1.wav -d regular0 &
PID = $!
KILLPID[${#KILLPID[@]}+1]="$!"
sleep 10

#Check whether playback started
if [-z "$PID"]; then
  echo "Fail to start the test binary $TESTBINARY"
  exit 1
else
  echo "Test Binary $TESTBINARY is running successfully"
fi

check_audio_pid_alive() {
	echo "Param $$1"
	local pid = "$1"
	local result_file="results/audiotestresult/stdout.txt"
	ps -ax | grep $TESTBINARY | head -1 2>&1 | tee "$result_file"
	
	if grep -q "$pid" "$result_file"; then
		echo "Successfully audio record completed"
		return 0
	else 
		echo "Fail to start audio record"
		return 1
	fi
}

# Final status, Print overall test result
echo "=== Overall Audio Test Validation Result ==="
if check_audio_pid_alive "$PID"; then
    log_pass "$TESTNAME : Test PASS"
    echo "$TESTNAME : Test Pass" > $test_path/$TESTNAME.res
else
	log_fail "$TESTNAME : Test FAIL"
	echo "$TESTNAME : Test Fail" > $test_path/$TESTNAME.res
fi


#Clean up 
echo "Clean up the old PID by Killing the process"
# Loop through the array
for id in "${KILLPID[@]}"; do
    echo $id
	kill -9 $id >/dev/null 2>&1
	sleep 1
done

echo "-------------------Completed $TESTNAME Testcase----------------------------"
