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

# Source library first
. "$TOOLS/functestlib.sh"

# Override with BusyBox-compatible version
check_network_status() {
    ip addr | awk '/state UP/ {iface=$2} /inet / {if (iface) print iface; iface=""}' | cut -d: -f1 | head -n 1
}

# ---------------------------------------------------------------

TESTNAME="AudioPlayback"
TAR_URL="https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/Pulse-Audio-Files-v1.0/AudioClips.tar.gz"
PLAYBACK_CLIP="AudioClips/yesterday_48KHz.wav"
AUDIO_DEVICE="low-latency0"
LOGDIR="results/audioplayback"
RESULT_FILE="$TESTNAME.res"

# Determine backend and binary
AUDIO_BACKEND="${AUDIO_BACKEND:-pulseaudio}"  # Default to pulseaudio if not set

# PLAYBACK_VOLUME: 0-65536 for paplay, 0.0-1.0 for pw-play
# PLAYBACK_TIMEOUT: seconds (default: 15)
# PLAYBACK_LOOPS: number of times to repeat playback
PLAYBACK_TIMEOUT="${PLAYBACK_TIMEOUT:-15s}"
PLAYBACK_LOOPS="${PLAYBACK_LOOPS:-1}"
# Set default volume based on backend
# paplay volume range: 0–65536
# pw-play volume range: 0.0–1.0
if [ "$AUDIO_BACKEND" = "pulseaudio" ]; then
    PLAYBACK_VOLUME="${PLAYBACK_VOLUME:-65536}"
elif [ "$AUDIO_BACKEND" = "pipewire" ]; then
    PLAYBACK_VOLUME="${PLAYBACK_VOLUME:-1.0}"
fi

# Select playback command based on backend										  
case "$AUDIO_BACKEND" in
    pulseaudio)
        TESTBINARY="paplay"
        PLAY_CMD="paplay --volume=$PLAYBACK_VOLUME \"$PLAYBACK_CLIP\" -d \"$AUDIO_DEVICE\""
        ;;
    pipewire)
        TESTBINARY="pw-play"
        PLAY_CMD="pw-play --volume=$PLAYBACK_VOLUME \"$PLAYBACK_CLIP\""
        ;;
    *)
        log_fail "Invalid AUDIO_BACKEND specified: $AUDIO_BACKEND. Use 'pulseaudio' or 'pipewire'."
        echo "$TESTNAME FAIL" > "$RESULT_FILE"
        exit 1
        ;;
esac

test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# Prepare logdir
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
check_dependencies "$TESTBINARY" pgrep grep
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
get_kernel_log > "$LOGDIR/dmesg_before.log"

# --- Start the Playback, capture output ---
PLAYBACK_SUCCESS=0

for i in $(seq 1 "$PLAYBACK_LOOPS"); do
    log_info "Playback loop $i of $PLAYBACK_LOOPS"
    # Choose timeout method
    if command -v timeout >/dev/null 2>&1; then
        # Use system timeout if available
        timeout "$PLAYBACK_TIMEOUT" sh -c "$PLAY_CMD" >> "$LOGDIR/playback_stdout.log" 2>&1
        ret=$?
    else
        # Use library fallback if timeout is missing
        run_with_timeout "$PLAYBACK_TIMEOUT" sh -c "$PLAY_CMD" >> "$LOGDIR/playback_stdout.log" 2>&1
        ret=$?
    fi

    if [ "$ret" -eq 0 ]; then
        log_pass "Playback loop $i: Completed successfully (ret=0)"
    elif [ "$ret" -eq 1 ] && [ "$AUDIO_BACKEND" = "pipewire" ]; then
        log_warn "Playback loop $i: Interrupted/timed out for PipeWire (ret=1)"
    elif [ "$ret" -eq 124 ]; then
        log_warn "Playback loop $i: Timed out (ret=124)"
    else
        log_fail "Playback loop $i: Failed with error code $ret"
        PLAYBACK_SUCCESS=1
        break  # Early exit on first true failure
    fi
done

# --- Capture logs AFTER playback (for debugging) ---
get_kernel_log > "$LOGDIR/dmesg_after.log"
scan_dmesg_errors "audio" "$LOGDIR"

# Set final result based on loop outcomes
if [ "$PLAYBACK_SUCCESS" -eq 0 ]; then
    log_pass_exit "$TESTNAME" "Audio playback test completed successfully for all loops"
    echo "$TESTNAME PASS" > "$RESULT_FILE"
    exit 0
else
    log_fail_exit "$TESTNAME" "Audio playback test failed in loop $i"
    echo "$TESTNAME FAIL" > "$RESULT_FILE"
    exit 1
fi

log_info "See $LOGDIR/playback_stdout.log, dmesg_before/after.log for debug details"
log_info "------------------- Completed $TESTNAME Testcase -------------"
exit 0