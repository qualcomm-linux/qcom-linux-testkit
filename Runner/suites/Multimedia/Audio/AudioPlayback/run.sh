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

TESTNAME="AudioPlayback"
TESTBINARY="paplay"
TAR_URL="https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/Pulse-Audio-Files-v1.0/AudioClips.tar.gz"
PLAYBACK_CLIP="AudioClips/yesterday_48KHz.wav"
AUDIO_DEVICE="low-latency0"
LOGDIR="results/audioplayback"
RESULT_FILE="$TESTNAME.res"

test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1

# Prepare logdir
mkdir -p "$LOGDIR"
chmod -R 777 "$LOGDIR"

log_info "------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase ------------"

log_info "Checking if dependency binary is available"
check_dependencies "$TESTBINARY" pgrep grep timeout

# Download/extract audio if not present
if [ ! -f "$PLAYBACK_CLIP" ]; then
    log_info "Audio clip not found, downloading..."
    extract_tar_from_url "$TAR_URL" || {
        log_fail "Failed to fetch/extract playback audio tarball"
        echo "$TESTNAME FAIL" > "$RESULT_FILE"
        exit 1
    }
fi

if [ ! -f "$PLAYBACK_CLIP" ]; then
    log_fail "Playback clip $PLAYBACK_CLIP not found after extraction."
    echo "$TESTNAME : FAIL" > "$RESULT_FILE"
    exit 1
fi

log_info "Playback clip present: $PLAYBACK_CLIP"

# --- Capture logs BEFORE playback (for debugging) ---
dmesg > "$LOGDIR/dmesg_before.log"

# --- Start the Playback, capture output ---
timeout 15s paplay "$PLAYBACK_CLIP" -d "$AUDIO_DEVICE" > "$LOGDIR/playback_stdout.log" 2>&1
ret=$?

# --- Capture logs AFTER playback (for debugging) ---
dmesg > "$LOGDIR/dmesg_after.log"

if [ "$ret" -eq 0 ] || [ "$ret" -eq 124 ] ; then
    log_pass "Playback completed or timed out (ret=$ret) as expected."
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$RESULT_FILE"
    exit 0
else
    log_fail "$TESTBINARY playback exited with error code $ret"
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$RESULT_FILE"
    exit 1
fi

log_info "See $LOGDIR/playback_stdout.log, dmesg_before/after.log, syslog_before/after.log for debug details"
log_info "------------------- Completed $TESTNAME Testcase -------------"
exit 0
