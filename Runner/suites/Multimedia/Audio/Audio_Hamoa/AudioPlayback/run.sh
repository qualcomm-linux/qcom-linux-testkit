#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Audio Hamoa Playback Test
# Tests audio playback on handset speakers and headset (headphones)
# using ALSA mixer configurations verified on X1E80100-EVK platform.
#
# Devices tested:
#   - Handset: plughw:0,1 (4-way speaker system)
#   - Headset: plughw:0,0 (stereo headphones)

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

TESTNAME="AudioPlayback_Hamoa"
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

AUDIO_FILE="${AUDIO_FILE:-}"
SKIP_ACTUAL_PLAYBACK="${SKIP_ACTUAL_PLAYBACK:-0}"
DEVICE="${DEVICE:-all}"
VERBOSE="${VERBOSE:-0}"
CLIP_NAMES="${CLIP_NAMES:-}"
AUDIO_CLIPS_BASE_DIR="${AUDIO_CLIPS_BASE_DIR:-AudioClips}"

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --clip-name NAME
      Clip configuration name for auto-discovery (e.g., playback_config1).
      Discovers and tests multiple audio clips from the specified configuration.

  --audio-clips-path PATH
      Path to audio clips directory.
      Default: AudioClips

  --audio-file PATH
      Path to single audio file for playback testing (alternative to --clip-name).
      If neither --clip-name nor --audio-file provided, only mixer configuration will be tested.

  --skip-actual-playback
      Skip actual audio playback, only test mixer configuration.

  --device DEVICE
      Select which device to test: handset, headset, or all.
      handset = Test only handset speakers (plughw:0,1)
      headset = Test only headset headphones (plughw:0,0)
      all = Test both devices (default)
      Default: all

  --res-suffix SUFFIX
      Suffix for unique result file (for parallel CI execution).
      Generates AudioPlayback_Hamoa_SUFFIX.res instead of AudioPlayback_Hamoa.res

  --lava-testcase-id ID
      Custom testcase identifier for LAVA reporting.
      Default: AudioPlayback_Hamoa

  --verbose
      Enable verbose logging.

  --help|-h
      Show this help.

Examples:
  # Mixer-only validation
  $0 --device handset --skip-actual-playback

  # Test with clip discovery (multiple clips)
  $0 --device handset --clip-name playback_config1 --audio-clips-path /home/AudioClips

  # Test with single file
  $0 --device handset --audio-file /tmp/test.wav

  # Test both devices with clips
  $0 --device all --clip-name playback_config1 --audio-clips-path /home/AudioClips
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --audio-file)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --audio-file requires an argument" >&2
                exit 1
            fi
            AUDIO_FILE="$2"
            shift 2
            ;;
        --skip-actual-playback)
            SKIP_ACTUAL_PLAYBACK=1
            shift
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
        --res-suffix)
            # Already parsed above
            shift 2
            ;;
        --lava-testcase-id)
            # Already parsed above
            shift 2
            ;;
        --clip-name)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --clip-name requires an argument" >&2
                exit 1
            fi
            CLIP_NAMES="$2"
            shift 2
            ;;
        --audio-clips-path)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --audio-clips-path requires an argument" >&2
                exit 1
            fi
            AUDIO_CLIPS_BASE_DIR="$2"
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

log_info "Configuration:"
log_info "  Audio File: ${AUDIO_FILE:-<not provided>}"
log_info "  Skip Actual Playback: $SKIP_ACTUAL_PLAYBACK"
log_info "  Device: $DEVICE"

# Discover clips if CLIP_NAMES provided
CLIPS_TO_TEST=""
if [ -n "$CLIP_NAMES" ]; then
    log_info "  Clip Names: $CLIP_NAMES"
    log_info "  Audio Clips Path: $AUDIO_CLIPS_BASE_DIR"
    
    # Export for clip discovery functions
    export AUDIO_CLIPS_BASE_DIR
    
    # Discover and filter clips
    CLIPS_TO_TEST="$(discover_and_filter_clips "$CLIP_NAMES" "")" || {
        log_error "Failed to discover clips for: $CLIP_NAMES"
        log_fail "$RESULT_TESTNAME FAIL - Clip discovery failed"
        echo "$RESULT_TESTNAME FAIL" > "$RES_FILE"
        exit 1
    }
    
    # Count clips
    clip_count=0
    for clip_file in $CLIPS_TO_TEST; do
        clip_count=$((clip_count + 1))
    done
    log_info "  Discovered Clips: $clip_count"
elif [ -n "$AUDIO_FILE" ]; then
    # Single file mode
    CLIPS_TO_TEST="$AUDIO_FILE"
fi

test_handset_playback() {
    log_info "=========================================="
    log_info "TEST 1: Handset Playback (Speakers)"
    log_info "=========================================="
    
    if ! setup_handset_playback_mixer; then
        log_fail "Failed to configure handset playback mixer"
        return 1
    fi
    
    if ! validate_mixer_state "handset_playback"; then
        log_fail "Handset playback mixer validation failed"
        return 1
    fi
    
    if [ "$SKIP_ACTUAL_PLAYBACK" -eq 0 ] && [ -n "$CLIPS_TO_TEST" ]; then
        device=$(get_alsa_device "handset_playback")
        
        # Test each clip
        for clip_file in $CLIPS_TO_TEST; do
            # Resolve full path
            clip_path="$AUDIO_CLIPS_BASE_DIR/$clip_file"
            
            if [ ! -f "$clip_path" ]; then
                log_warn "Audio file not found: $clip_path"
                continue
            fi
            
            log_info "Playing clip: $clip_file on device: $device"
            
            if ! aplay -D "$device" "$clip_path"; then
                log_fail "Handset playback failed for: $clip_file"
                return 1
            fi
        done
    else
        log_info "Skipping actual playback (mixer configuration verified)"
    fi
    
    log_pass "Handset playback test PASSED"
    return 0
}

test_headset_playback() {
    log_info "=========================================="
    log_info "TEST 2: Headset Playback (Headphones)"
    log_info "=========================================="
    
    if ! setup_headset_playback_mixer; then
        log_fail "Failed to configure headset playback mixer"
        return 1
    fi
    
    if ! validate_mixer_state "headset_playback"; then
        log_fail "Headset playback mixer validation failed"
        return 1
    fi
    
    if [ "$SKIP_ACTUAL_PLAYBACK" -eq 0 ] && [ -n "$CLIPS_TO_TEST" ]; then
        device=$(get_alsa_device "headset_playback")
        
        # Test each clip
        for clip_file in $CLIPS_TO_TEST; do
            # Resolve full path
            clip_path="$AUDIO_CLIPS_BASE_DIR/$clip_file"
            
            if [ ! -f "$clip_path" ]; then
                log_warn "Audio file not found: $clip_path"
                continue
            fi
            
            log_info "Playing clip: $clip_file on device: $device"
            
            if ! aplay -D "$device" "$clip_path"; then
                log_fail "Headset playback failed for: $clip_file"
                return 1
            fi
        done
    else
        log_info "Skipping actual playback (mixer configuration verified)"
    fi
    
    log_pass "Headset playback test PASSED"
    return 0
}

test_failed=0

# Run tests based on device selection
if [ "$DEVICE" = "handset" ] || [ "$DEVICE" = "all" ]; then
    if ! test_handset_playback; then
        log_fail "Handset playback test FAILED"
        test_failed=1
    fi
    echo ""
fi

if [ "$DEVICE" = "headset" ] || [ "$DEVICE" = "all" ]; then
    if ! test_headset_playback; then
        log_fail "Headset playback test FAILED"
        test_failed=1
    fi
    echo ""
fi

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