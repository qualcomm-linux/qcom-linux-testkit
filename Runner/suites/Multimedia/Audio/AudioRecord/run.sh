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
RECORD_FILE="/tmp/rec1.wav"
AUDIO_DEVICE="regular0"
LOGDIR="results/audiorecord"
RESULT_FILE="$TESTNAME.res"

AUDIO_BACKEND="${AUDIO_BACKEND:-pulseaudio}"  # Default to pulseaudio

test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
mkdir -p "$LOGDIR"
chmod -R 777 "$LOGDIR"

log_info "------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase ------------"
log_info "Using audio backend: $AUDIO_BACKEND"

if [ "$AUDIO_BACKEND" = "pulseaudio" ]; then
    TESTBINARY="parec"
    RECORD_CMD="$TESTBINARY --rate=48000 --format=s16le --channels=1 --file-format=wav \"$RECORD_FILE\" -d \"$AUDIO_DEVICE\""
    check_dependencies "$TESTBINARY" pgrep timeout
else
    TESTBINARY="pw-record"
    check_dependencies "$TESTBINARY" wpctl grep sed timeout

    # Extract source ID using sed
    SOURCE_ID=$(wpctl status | grep -i "pal source handset mic" | sed -n 's/^[^0-9]*\([0-9]\+\)\..*/\1/p')

    if echo "$SOURCE_ID" | grep -qE '^[0-9]+$'; then
        log_info "Detected PipeWire source ID: $SOURCE_ID"
        wpctl set-default "$SOURCE_ID"
    else
        log_warn "Could not find valid 'pal source handset mic' source ID. Falling back to default source."
    fi

    RECORD_CMD="$TESTBINARY \"$RECORD_FILE\" -v"
fi

dmesg > "$LOGDIR/dmesg_before.log"
rm -f "$RECORD_FILE"

eval "timeout 12s $RECORD_CMD" > "$LOGDIR/${TESTBINARY}_stdout.log" 2>&1
ret=$?

dmesg > "$LOGDIR/dmesg_after.log"

if ([ "$ret" -eq 0 ] || [ "$ret" -eq 124 ]) && [ -s "$RECORD_FILE" ]; then
    log_pass "Recording completed or timed out (ret=$ret) as expected and output file exists."
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$RESULT_FILE"
    exit 0
else
    log_fail "$TESTBINARY failed (status $ret) or recorded file missing/empty"
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$RESULT_FILE"
    exit 1
fi

log_info "See $LOGDIR/${TESTBINARY}_stdout.log, dmesg_before/after.log, syslog_before/after.log for debug details"
log_info "------------------- Completed $TESTNAME Testcase -------------"
exit 0
