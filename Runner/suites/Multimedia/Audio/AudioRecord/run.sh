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

# Determine backend and binary
AUDIO_BACKEND="${AUDIO_BACKEND:-pulseaudio}"  # Default to pulseaudio if not set

if [ "$AUDIO_BACKEND" = "pulseaudio" ]; then
    TESTBINARY="parec"
elif [ "$AUDIO_BACKEND" = "pipewire" ]; then
    TESTBINARY="pw-record"
else
    log_fail "Invalid AUDIO_BACKEND specified: $AUDIO_BACKEND. Use 'pulseaudio' or 'pipewire'."
    echo "$TESTNAME FAIL" > "$RESULT_FILE"
    exit 1
fi

# Dependency checks and PipeWire source selection
if [ "$AUDIO_BACKEND" = "pulseaudio" ]; then
    check_dependencies "$TESTBINARY" pgrep grep
elif [ "$AUDIO_BACKEND" = "pipewire" ]; then
    check_dependencies "$TESTBINARY" wpctl grep sed
    # Search for either "pal source handset mic" or "Built-in Audio internal Mic"
    SOURCE_ID=$(wpctl status | grep -i -E "pal source handset mic|Built-in Audio internal Mic" | sed -n 's/^[^0-9]*\([0-9]\+\)\..*/\1/p' | head -n 1)
    if echo "$SOURCE_ID" | grep -qE '^[0-9]+$'; then
        log_info "Detected PipeWire source ID: $SOURCE_ID"
        wpctl set-default "$SOURCE_ID"
    else
        log_warn "Could not find valid source ID for 'pal source handset mic' or 'Built-in Audio internal Mic'. Falling back to default source."
    fi
fi

# Assign RECORD_CMD after backend and source selection
if [ "$AUDIO_BACKEND" = "pulseaudio" ]; then
    RECORD_CMD="parec --rate=48000 --format=s16le --channels=1 --file-format=wav \"$RECORD_FILE\" -d \"$AUDIO_DEVICE\""
elif [ "$AUDIO_BACKEND" = "pipewire" ]; then
    RECORD_CMD="pw-record \"$RECORD_FILE\" -v"
fi

# RECORD_TIMEOUT: seconds (default: 12s)
# RECORD_LOOPS: number of times to repeat recording
RECORD_TIMEOUT="${RECORD_TIMEOUT:-12s}"
RECORD_LOOPS="${RECORD_LOOPS:-1}"

test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
mkdir -p "$LOGDIR"
chmod -R 777 "$LOGDIR"

log_info "------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase ------------"
log_info "Using audio backend: $AUDIO_BACKEND"

# Daemon check
if [ "$AUDIO_BACKEND" = "pulseaudio" ]; then
    if ! pgrep pulseaudio > /dev/null && ! pgrep pipewire-pulse > /dev/null; then
        log_skip_exit "$TESTNAME" "Neither PulseAudio nor pipewire-pulse daemon is running"
    fi
elif [ "$AUDIO_BACKEND" = "pipewire" ]; then
    pgrep pipewire > /dev/null || log_skip_exit "$TESTNAME" "PipeWire daemon not running"
fi

log_info "Checking if dependency binary is available"

# --- Capture logs BEFORE recording (for debugging) ---
get_kernel_log > "$LOGDIR/dmesg_before.log"
rm -f "$RECORD_FILE"

# --- Start the Recording, capture output ---
RECORD_SUCCESS=0

for i in $(seq 1 "$RECORD_LOOPS"); do
    log_info "Recording loop $i of $RECORD_LOOPS"
    # Use timeout if available, else fallback to run_with_timeout
    if command -v timeout >/dev/null 2>&1; then
        timeout "$RECORD_TIMEOUT" sh -c "$RECORD_CMD" >> "$LOGDIR/${TESTBINARY}_stdout.log" 2>&1
        ret=$?
    else
        run_with_timeout "$RECORD_TIMEOUT" sh -c "$RECORD_CMD" >> "$LOGDIR/${TESTBINARY}_stdout.log" 2>&1
        ret=$?
    fi

    if [ "$ret" -eq 0 ]; then
        if [ -s "$RECORD_FILE" ]; then
            log_pass "Recording loop $i: Completed successfully (ret=0, file exists)"
        else
            log_fail "Recording loop $i: No data recorded (file missing/empty)"
            RECORD_SUCCESS=1
            break
        fi
    elif [ "$ret" -eq 1 ] && [ "$AUDIO_BACKEND" = "pipewire" ]; then
        if [ -s "$RECORD_FILE" ]; then
            log_warn "Recording loop $i: Interrupted/timed out for PipeWire (ret=1, file exists)"
        else
            log_fail "Recording loop $i: Interrupted/timed out for PipeWire (ret=1, file missing/empty)"
            RECORD_SUCCESS=1
            break
        fi
    elif [ "$ret" -eq 124 ]; then
        if [ -s "$RECORD_FILE" ]; then
            log_warn "Recording loop $i: Timed out (ret=124, file exists)"
        else
            log_fail "Recording loop $i: Timed out (ret=124, file missing/empty)"
            RECORD_SUCCESS=1
            break
        fi
    else
        log_fail "Recording loop $i: Failed with error code $ret"
        RECORD_SUCCESS=1
        break
    fi
done

# --- Capture logs AFTER recording (for debugging) ---
get_kernel_log > "$LOGDIR/dmesg_after.log"
scan_dmesg_errors "audio" "$LOGDIR"

# Set final result based on loop outcomes
if [ "$RECORD_SUCCESS" -eq 0 ]; then
    log_pass_exit "$TESTNAME" "Audio record test completed successfully for all loops"
    echo "$TESTNAME PASS" > "$RESULT_FILE"
    exit 0
else
    log_fail_exit "$TESTNAME" "Audio record test failed in loop $i"
    echo "$TESTNAME FAIL" > "$RESULT_FILE"
    exit 1
fi

log_info "See $LOGDIR/${TESTBINARY}_stdout.log, dmesg_before/after.log for debug details"
log_info "------------------- Completed $TESTNAME Testcase -------------"
exit 0