#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# --------- Robustly source init_env and functestlib.sh ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INIT_ENV=""
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"
        break
    fi
    SEARCH=$(dirname "$SEARCH")
done

if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi

if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# ---------------------------------------------------------------

TESTNAME="AudioRecord"
TESTBINARY="parec"
RECORD_FILE="/tmp/rec1.wav"
AUDIO_DEVICE="regular0"
LOGDIR="results/audiorecord"
RESULT_FILE="$TESTNAME.res"

test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
mkdir -p "$LOGDIR"
chmod -R 777 "$LOGDIR"

log_info "------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase ------------"

log_info "Checking if dependency binary is available"
check_dependencies "$TESTBINARY" pgrep timeout
 
# --- Capture logs BEFORE recording (for debugging) ---
dmesg > "$LOGDIR/dmesg_before.log"

# Remove old record file if present
rm -f "$RECORD_FILE"

# --- Start recording ---
timeout 12s "$TESTBINARY" --rate=48000 --format=s16le --channels=1 --file-format=wav "$RECORD_FILE" -d "$AUDIO_DEVICE" > "$LOGDIR/parec_stdout.log" 2>&1
ret=$?

# --- Capture logs AFTER recording (for debugging) ---
dmesg > "$LOGDIR/dmesg_after.log"

# --- Evaluate result: pass only if process completed successfully and file is non-empty ---
if ([ "$ret" -eq 0 ] || [ "$ret" -eq 124 ]) && [ -s "$RECORD_FILE" ]; then
    log_pass "Recording completed or timed out (ret=$ret) as expected and output file exists."
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$RESULT_FILE"
else
    log_fail "parec failed (status $ret) or recorded file missing/empty"
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$RESULT_FILE"
fi

log_info "See $LOGDIR/parec_stdout.log, dmesg_before/after.log, syslog_before/after.log for debug details"
log_info "------------------- Completed $TESTNAME Testcase -------------"
exit 0
