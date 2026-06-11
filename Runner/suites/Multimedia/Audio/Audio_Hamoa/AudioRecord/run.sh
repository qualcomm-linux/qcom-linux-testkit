#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Audio Hamoa Record Test
# Tests audio recording on handset microphone and headset microphone
# using ALSA mixer configurations verified on X1E80100-EVK platform.
#
# Devices tested:
#   - Handset: plughw:0,3 (built-in microphone MSM_DMIC)
#   - Headset: plughw:0,2 (headset microphone SWR_MIC)

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

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1091
. "$TOOLS/audio_common.sh"
# shellcheck disable=SC1091
. "$TOOLS/audio/alsa_common.sh"

TESTNAME="AudioRecord_Hamoa"
RESULT_TESTNAME="$TESTNAME"
RES_SUFFIX=""

# Pre-parse --res-suffix and --lava-testcase-id for early failure handling
prev_arg=""
for arg in "$@"; do
  case "$prev_arg" in
    --res-suffix)
      RES_SUFFIX="$arg"
      ;;
    --lava-testcase-id)
      RESULT_TESTNAME="$arg"
      ;;
  esac
  prev_arg="$arg"
done

CONFIG_NAME="${CONFIG_NAME:-}"
RECORD_DURATION="${RECORD_DURATION:-5}"
RECORD_FORMAT="${RECORD_FORMAT:-S16_LE}"
RECORD_RATE="${RECORD_RATE:-48000}"
RECORD_CHANNELS="${RECORD_CHANNELS:-2}"
DEVICE="${DEVICE:-all}"
SKIP_ACTUAL_RECORDING="${SKIP_ACTUAL_RECORDING:-0}"
VERBOSE="${VERBOSE:-0}"

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --config-name NAME
      Record configuration name (e.g., record_config1).
      Automatically sets rate and channels from predefined configurations.
      record_config1  = 8000 Hz, 1 channel
      record_config2  = 16000 Hz, 1 channel
      record_config3  = 16000 Hz, 2 channels
      record_config4  = 24000 Hz, 1 channel
      record_config5  = 32000 Hz, 2 channels
      record_config6  = 44100 Hz, 2 channels
      record_config7  = 48000 Hz, 2 channels
      record_config8  = 48000 Hz, 6 channels
      record_config9  = 96000 Hz, 2 channels
      record_config10 = 96000 Hz, 6 channels

  --duration SECS
      Recording duration in seconds.
      Default: 5

  --format FORMAT
      Audio format (e.g., S16_LE, S24_LE).
      Default: S16_LE

  --rate RATE
      Sample rate in Hz.
      Default: 48000

  --channels N
      Number of channels.
      Default: 2

  --device DEVICE
      Device to test: handset, headset, or all.
      Default: all

  --skip-actual-recording
      Skip actual audio recording, only test mixer configuration.

  --res-suffix SUFFIX
      Suffix for unique result file (for parallel CI execution).
      Generates AudioRecord_Hamoa_SUFFIX.res instead of AudioRecord_Hamoa.res

  --lava-testcase-id ID
      Custom testcase identifier for LAVA reporting.
      Default: AudioRecord_Hamoa

  --verbose
      Enable verbose logging.

  --help|-h
      Show this help.

Examples:
  # Mixer-only validation
  $0 --skip-actual-recording

  # Test with config (auto-sets rate and channels)
  $0 --config-name record_config1

  # Test with custom parameters
  $0 --duration 10 --rate 48000 --channels 2

  # CI/LAVA usage
  $0 --config-name record_config7 --res-suffix Config7 --lava-testcase-id AudioRecord_Hamoa_Config7
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --duration)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --duration requires an argument" >&2
                exit 1
            fi
            RECORD_DURATION="$2"
            shift 2
            ;;
        --format)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --format requires an argument" >&2
                exit 1
            fi
            RECORD_FORMAT="$2"
            shift 2
            ;;
        --rate)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --rate requires an argument" >&2
                exit 1
            fi
            RECORD_RATE="$2"
            shift 2
            ;;
        --channels)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --channels requires an argument" >&2
                exit 1
            fi
            RECORD_CHANNELS="$2"
            shift 2
            ;;
        --config-name)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --config-name requires an argument" >&2
                exit 1
            fi
            CONFIG_NAME="$2"
            shift 2
            ;;
        --device)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --device requires an argument" >&2
                exit 1
            fi
            DEVICE="$2"
            if [ "$DEVICE" != "handset" ] && [ "$DEVICE" != "headset" ] && [ "$DEVICE" != "all" ]; then
                echo "[ERROR] --device must be 'handset', 'headset', or 'all'" >&2
                exit 1
            fi
            shift 2
            ;;
        --skip-actual-recording)
            SKIP_ACTUAL_RECORDING=1
            shift
            ;;
        --res-suffix)
            # Already parsed above
            shift 2
            ;;
        --lava-testcase-id)
            # Already parsed above
            shift 2
            ;;
        --verbose)
            VERBOSE=1
            export VERBOSE
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "[WARN] Unknown option: $1" >&2
            shift
            ;;
    esac
done

test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || echo "$SCRIPT_DIR")"
if ! cd "$test_path"; then
    log_fail "cd failed: $test_path"
    exit 1
fi

# Setup result file and log directory (with optional suffix)
if [ -n "$RES_SUFFIX" ]; then
    RES_FILE="$SCRIPT_DIR/${TESTNAME}_${RES_SUFFIX}.res"
    LOGDIR="$SCRIPT_DIR/results/${TESTNAME}_${RES_SUFFIX}"
    log_info "Using unique result file: $RES_FILE"
else
    RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
    LOGDIR="$SCRIPT_DIR/results/$TESTNAME"
fi

mkdir -p "$LOGDIR" 2>/dev/null || true
: > "$RES_FILE"

log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase --------------------------"
log_info "--------------------------------------------------------------------------"

if command -v detect_platform >/dev/null 2>&1; then
    detect_platform >/dev/null 2>&1 || true
    log_info "Platform: machine='${PLATFORM_MACHINE:-unknown}' target='${PLATFORM_TARGET:-unknown}'"
fi

# Apply config if CONFIG_NAME provided
if [ -n "$CONFIG_NAME" ]; then
    log_info "  Config Name: $CONFIG_NAME"
    
    # Get config parameters (rate channels)
    config_params="$(get_record_config_params "$CONFIG_NAME")" || {
        log_error "Invalid config name: $CONFIG_NAME"
        log_fail "$RESULT_TESTNAME FAIL - Invalid config"
        echo "$RESULT_TESTNAME FAIL" > "$RES_FILE"
        exit 1
    }
    
    # Parse rate and channels
    RECORD_RATE="$(echo "$config_params" | awk '{print $1}')"
    RECORD_CHANNELS="$(echo "$config_params" | awk '{print $2}')"
    
    log_info "  Config applied: Rate=$RECORD_RATE Hz, Channels=$RECORD_CHANNELS"
fi

log_info "Configuration:"
log_info "  Duration: ${RECORD_DURATION}s"
log_info "  Format: $RECORD_FORMAT"
log_info "  Rate: $RECORD_RATE Hz"
log_info "  Channels: $RECORD_CHANNELS"
log_info "  Skip Actual Recording: $SKIP_ACTUAL_RECORDING"

test_handset_capture() {
    log_info "=========================================="
    log_info "TEST 1: Handset Capture (Built-in Mic)"
    log_info "=========================================="
    
    if ! setup_handset_capture_mixer; then
        log_fail "Failed to configure handset capture mixer"
        return 1
    fi
    
    if ! validate_mixer_state "handset_capture"; then
        log_fail "Handset capture mixer validation failed"
        return 1
    fi
    
    if [ "$SKIP_ACTUAL_RECORDING" -eq 0 ]; then
        device=$(get_alsa_device "handset_capture")
        output_file="$LOGDIR/handset_recording.wav"
        log_info "Recording from device: $device"
        log_info "Output file: $output_file"
        
        if ! arecord -D "$device" -f "$RECORD_FORMAT" -r "$RECORD_RATE" -c "$RECORD_CHANNELS" -d "$RECORD_DURATION" "$output_file"; then
            log_fail "Handset recording failed"
            return 1
        fi
        
        if ! validate_recording "$output_file"; then
            log_fail "Handset recording validation failed"
            return 1
        fi
    else
        log_info "Skipping actual recording (mixer configuration verified)"
    fi
    
    log_pass "Handset capture test PASSED"
    return 0
}

test_headset_capture() {
    log_info "=========================================="
    log_info "TEST 2: Headset Capture (Headset Mic)"
    log_info "=========================================="
    
    if ! setup_headset_capture_mixer; then
        log_fail "Failed to configure headset capture mixer"
        return 1
    fi
    
    if ! validate_mixer_state "headset_capture"; then
        log_fail "Headset capture mixer validation failed"
        return 1
    fi
    
    if [ "$SKIP_ACTUAL_RECORDING" -eq 0 ]; then
        device=$(get_alsa_device "headset_capture")
        output_file="$LOGDIR/headset_recording.wav"
        log_info "Recording from device: $device"
        log_info "Output file: $output_file"
        
        if ! arecord -D "$device" -f "$RECORD_FORMAT" -r "$RECORD_RATE" -c "$RECORD_CHANNELS" -d "$RECORD_DURATION" "$output_file"; then
            log_fail "Headset recording failed"
            return 1
        fi
        
        if ! validate_recording "$output_file"; then
            log_fail "Headset recording validation failed"
            return 1
        fi
    else
        log_info "Skipping actual recording (mixer configuration verified)"
    fi
    
    log_pass "Headset capture test PASSED"
    return 0
}

test_failed=0

# Run tests based on device selection
case "$DEVICE" in
    handset)
        if ! test_handset_capture; then
            log_fail "Handset capture test FAILED"
            test_failed=1
        fi
        ;;
    headset)
        if ! test_headset_capture; then
            log_fail "Headset capture test FAILED"
            test_failed=1
        fi
        ;;
    all)
        if ! test_handset_capture; then
            log_fail "Handset capture test FAILED"
            test_failed=1
        fi
        
        echo ""
        
        if ! test_headset_capture; then
            log_fail "Headset capture test FAILED"
            test_failed=1
        fi
        ;;
    *)
        log_error "Invalid device: $DEVICE (must be handset, headset, or all)"
        log_fail "$RESULT_TESTNAME FAIL - Invalid device"
        echo "$RESULT_TESTNAME FAIL" > "$RES_FILE"
        exit 1
        ;;
esac

echo ""
log_info "=========================================="

if [ "$test_failed" -eq 0 ]; then
    log_pass "$RESULT_TESTNAME : PASS"
    echo "$RESULT_TESTNAME PASS" > "$RES_FILE"
else
    log_fail "$RESULT_TESTNAME : FAIL"
    echo "$RESULT_TESTNAME FAIL" > "$RES_FILE"
fi

log_info "------------------- Completed $RESULT_TESTNAME Testcase --------------------------"
exit 0
