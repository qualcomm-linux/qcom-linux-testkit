#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
#
# Audio Record/Playback Validation using GStreamer (10 tests total)
#
# Test Sequence:
#   ENCODE PHASE (4 tests):
#     1. record_wav          - audiotestsrc → wavenc → file
#     2. record_flac         - audiotestsrc → flacenc → file
#     3. record_pulsesrc_wav - pulsesrc HW → wavenc → file
#     4. record_pulsesrc_flac- pulsesrc HW → flacenc → file
#
#   DECODE PHASE (6 tests):
#     5. playback_wav             - file → wavparse → pulsesink
#     6. playback_flac            - file → flacparse → flacdec → pulsesink
#     7. playback_pulsesrc_wav    - file → wavparse → pulsesink
#     8. playback_pulsesrc_flac   - file → flacparse → flacdec → pulsesink
#     9. playback_sample_ogg      - file → oggdemux → vorbisdec → pulsesink
#    10. playback_sample_mp3      - file → mpegaudioparse → mpg123audiodec → pulsesink
#
# Features:
#   - audiotestsrc: Synthetic audio generation (uses num-buffers for duration control)
#   - pulsesrc: Hardware audio capture (uses timeout for duration control)
#   - pulsesink: Audio playback
#   - Formats: WAV (wavenc/wavparse), FLAC (flacenc/flacparse/flacdec), OGG (oggdemux/vorbisdec), MP3 (mpegaudioparse/mpg123audiodec)
#   - Test file provisioning via URL download or local path
#   - Duration control via AUDIO_DURATION env var (default: 10 seconds)
#
# Logs everything to console and local log files.
# PASS/FAIL/SKIP is emitted to .res. Always exits 0 (LAVA-friendly).

# -------------------- Configuration --------------------
# Audio parameters for buffer calculation
SAMPLE_RATE=44100        # 44.1 kHz
SAMPLES_PER_BUFFER=1024  # Standard buffer size

SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"

TESTNAME="Audio_Record_Playback"
RESULT_TESTNAME="$TESTNAME"
RES_FILE="${SCRIPT_DIR}/${TESTNAME}.res"
LOG_DIR="${SCRIPT_DIR}/logs"
OUTDIR="$LOG_DIR/$TESTNAME"
GST_LOG="$OUTDIR/gst.log"
DMESG_DIR="$OUTDIR/dmesg"

INIT_ENV=""
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
  if [ -f "$SEARCH/init_env" ]; then
    INIT_ENV="$SEARCH/init_env"
    break
  fi
  SEARCH=$(dirname "$SEARCH")
done

if [ -z "${INIT_ENV:-}" ]; then
  echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
  echo "$RESULT_TESTNAME SKIP" >"$RES_FILE" 2>/dev/null || true
  exit 0
fi

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
  # shellcheck disable=SC1090
  . "$INIT_ENV"
  __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

# shellcheck disable=SC1091
. "$TOOLS/lib_gstreamer.sh"

# Create required directories now that log functions are available
if ! mkdir -p "$OUTDIR" "$DMESG_DIR"; then
  log_error "Failed to create required directories:"
  log_error "  OUTDIR=$OUTDIR"
  log_error "  DMESG_DIR=$DMESG_DIR"
  echo "$RESULT_TESTNAME FAIL" >"$RES_FILE" 2>/dev/null || true
  exit 0
fi
: >"$RES_FILE"
: >"$GST_LOG"

# -------------------- Set up shared recorded directory --------------------
# Use gstreamer_shared_recorded_dir() as single source of truth for directory resolution
# Priority: 1) AUDIO_SHARED_RECORDED_DIR env var, 2) LAVA/tests shared path, 3) local fallback
if [ -n "${AUDIO_SHARED_RECORDED_DIR:-}" ]; then
    RECORDED_DIR="$AUDIO_SHARED_RECORDED_DIR"
elif command -v gstreamer_shared_recorded_dir >/dev/null 2>&1; then
    RECORDED_DIR="$(gstreamer_shared_recorded_dir "$SCRIPT_DIR" "$OUTDIR")"
else
    RECORDED_DIR="$OUTDIR/recorded"
fi

# Create the recorded directory
if ! mkdir -p "$RECORDED_DIR"; then
  log_error "Failed to create recorded directory: $RECORDED_DIR"
  echo "$RESULT_TESTNAME FAIL" >"$RES_FILE"
  exit 0
fi

result="FAIL"
reason="unknown"
pass_count=0
fail_count=0
skip_count=0
total_tests=0

# Track whether external clip provisioning was explicitly requested.
USER_CLIP_URL_SET=0
USER_CLIP_PATH_SET=0

if [ "${AUDIO_CLIP_URL+x}" = "x" ] && [ -n "${AUDIO_CLIP_URL:-}" ]; then
  USER_CLIP_URL_SET=1
fi

if [ "${AUDIO_CLIP_PATH+x}" = "x" ] && [ -n "${AUDIO_CLIP_PATH:-}" ]; then
  USER_CLIP_PATH_SET=1
fi
# -------------------- Defaults (LAVA env vars -> defaults; CLI overrides) --------------------
testMode="${AUDIO_TEST_MODE:-all}"
testName="${AUDIO_TEST_NAME:-}"
formatList="${AUDIO_FORMATS:-wav,flac}"
duration="${AUDIO_DURATION:-${RUNTIMESEC:-10}}"
gstDebugLevel="${AUDIO_GST_DEBUG:-${GST_DEBUG_LEVEL:-2}}"
clipUrl="${AUDIO_CLIP_URL:-https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/GST-Audio-Files-v1.0/audio_clips_gst.tar.gz}"
clipPath="${AUDIO_CLIP_PATH:-}"

# Validate numeric parameters (only validate if explicitly set)
for param in AUDIO_DURATION AUDIO_GST_DEBUG GST_DEBUG_LEVEL; do
  val=""
  case "$param" in
    AUDIO_DURATION) val="${AUDIO_DURATION-}" ;;
    AUDIO_GST_DEBUG) val="${AUDIO_GST_DEBUG-}" ;;
    GST_DEBUG_LEVEL) val="${GST_DEBUG_LEVEL-}" ;;
  esac

  if [ -n "$val" ]; then
    case "$val" in
      ''|*[!0-9]*)
        log_warn "$param must be numeric (got '$val')"
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
        ;;
      *)
        if [ "$val" -le 0 ] 2>/dev/null; then
          log_warn "$param must be positive (got '$val')"
          echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
          exit 0
        fi
        ;;
    esac
  fi
done

# shellcheck disable=SC2317,SC2329
cleanup() {
  # Best-effort: try to kill only children first; fall back to name-based kill
  if ! pkill -P "$$" -x gst-launch-1.0 >/dev/null 2>&1; then
    pkill -x gst-launch-1.0 >/dev/null 2>&1 || true
  fi
}
trap cleanup INT TERM EXIT

# -------------------- Arg parse --------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --mode"
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      [ -n "$2" ] && testMode="$2"
      shift 2
      ;;

    --formats)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --formats"
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      [ -n "$2" ] && formatList="$2"
      shift 2
      ;;

    --duration)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --duration"
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      if [ -n "$2" ]; then
        case "$2" in
          ''|*[!0-9]*)
            log_warn "Invalid --duration '$2' (must be numeric)"
            echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
            exit 0
            ;;
          *)
            duration="$2"
            ;;
        esac
      fi
      shift 2
      ;;

    --gst-debug)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --gst-debug"
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      [ -n "$2" ] && gstDebugLevel="$2"
      shift 2
      ;;

    --clip-url)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --clip-url"
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      if [ -n "$2" ]; then
        clipUrl="$2"
        USER_CLIP_URL_SET=1
      fi
      shift 2
      ;;
 
    --clip-path)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --clip-path"
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      if [ -n "$2" ]; then
        clipPath="$2"
        USER_CLIP_PATH_SET=1
      fi
      shift 2
      ;;
 
    --test-name)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --test-name"
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      [ -n "$2" ] && testName="$2"
      shift 2
      ;;

    --lava-testcase-id)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --lava-testcase-id"
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      [ -n "$2" ] && RESULT_TESTNAME="$2"
      shift 2
      ;;

    -h|--help)
      cat <<EOF
Usage: $0 [OPTIONS]

Audio Record/Playback Validation using GStreamer

OPTIONS:
  --mode <all|record|playback>
                        Test mode (default: all)
                        - all: Run both record and playback tests
                        - record: Run only recording tests
                        - playback: Run only playback tests

  --formats <format1,format2,...>
                        Comma-separated list of audio formats to test
                        (default: wav,flac)
                        Supported: wav, flac

  --duration <seconds>  Duration for recording/playback in seconds
                        (default: 10)

  --gst-debug <level>   GStreamer debug level (1-9)
                        (default: 2)

  --clip-url <url>      URL to download test audio files (OGG/MP3)
                        (default: GitHub release URL)

  --clip-path <path>    Local path to test audio files
                        (overrides --clip-url if files exist)

  --lava-testcase-id <name>
                        Override the test case name reported to LAVA
                        (default: Audio_Record_Playback)
                        Used by LAVA to match expected test case names

  -h, --help            Display this help message

ENVIRONMENT VARIABLES:
  AUDIO_TEST_MODE       Same as --mode
  AUDIO_FORMATS         Same as --formats
  AUDIO_DURATION        Same as --duration
  AUDIO_GST_DEBUG       Same as --gst-debug
  AUDIO_CLIP_URL        Same as --clip-url
  AUDIO_CLIP_PATH       Same as --clip-path
  GST_DEBUG_LEVEL       Alternative to AUDIO_GST_DEBUG
  RUNTIMESEC            Alternative to AUDIO_DURATION

EXAMPLES:
  # Run all tests with default settings
  $0

  # Run only recording tests for 5 seconds
  $0 --mode record --duration 5

  # Test only WAV format
  $0 --formats wav

  # Use local test files
  $0 --clip-path /path/to/audio/files

TEST SEQUENCE:
  ENCODE PHASE (4 tests):
    1. record_wav          - audiotestsrc → wavenc → file
    2. record_flac         - audiotestsrc → flacenc → file
    3. record_pulsesrc_wav - pulsesrc HW → wavenc → file
    4. record_pulsesrc_flac- pulsesrc HW → flacenc → file

  DECODE PHASE (6 tests):
    5. playback_wav             - file → wavparse → pulsesink
    6. playback_flac            - file → flacparse → flacdec → pulsesink
    7. playback_pulsesrc_wav    - file → wavparse → pulsesink
    8. playback_pulsesrc_flac   - file → flacparse → flacdec → pulsesink
    9. playback_sample_ogg      - file → oggdemux → vorbisdec → pulsesink
   10. playback_sample_mp3      - file → mpegaudioparse → mpg123audiodec → pulsesink

EOF
      exit 0
      ;;

    *)
      log_warn "Unknown argument: $1"
      echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
      exit 0
      ;;
  esac
done

# -------------------- Validate parsed values --------------------
case "$testMode" in all|record|playback) : ;; *)
  log_warn "Invalid --mode '$testMode'"
  echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
  exit 0
  ;;
esac

case "$gstDebugLevel" in 1|2|3|4|5|6|7|8|9) : ;; *)
  log_warn "Invalid --gst-debug '$gstDebugLevel' (allowed: 1-9)"
  echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
  exit 0
  ;;
esac

case "$duration" in
  ''|*[!0-9]*)
    log_warn "Invalid duration '$duration' (must be numeric)"
    echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
    exit 0
    ;;
  *)
    if [ "$duration" -le 0 ] 2>/dev/null; then
      log_warn "Duration must be positive (got '$duration')"
      echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
      exit 0
    fi
    ;;
esac

# Validate test name if provided
if [ -n "$testName" ]; then
  case "$testName" in
    record_wav|record_flac|record_pulsesrc_wav|record_pulsesrc_flac|\
    playback_wav|playback_flac|playback_pulsesrc_wav|playback_pulsesrc_flac|\
    playback_sample_ogg|playback_sample_mp3)
      log_info "Test name: $testName (individual test mode)"
      ;;
    *)
      log_warn "Invalid --test-name '$testName'"
      log_warn "Valid names: record_wav, record_flac, record_pulsesrc_wav, record_pulsesrc_flac,"
      log_warn "             playback_wav, playback_flac, playback_pulsesrc_wav, playback_pulsesrc_flac,"
      log_warn "             playback_sample_ogg, playback_sample_mp3"
      echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
      exit 0
      ;;
  esac
fi

# Calculate num_buffers based on final duration value
# Formula: num_buffers = (sample_rate * duration) / samples_per_buffer
# Example: (44100 * 10) / 1024 = 430 buffers for 10 seconds
NUM_BUFFERS=$(( (SAMPLE_RATE * duration) / SAMPLES_PER_BUFFER ))

# -------------------- Pre-checks --------------------
check_dependencies "gst-launch-1.0 gst-inspect-1.0 awk grep head sed tr stat find curl tar" >/dev/null 2>&1 || {
  log_skip "Missing required tools (gst-launch-1.0, gst-inspect-1.0, awk, grep, head, sed, tr, stat, find, curl, tar)"
  echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
  exit 0
}

log_info "Checking dependencies: gst-launch-1.0 gst-inspect-1.0 awk grep head sed tr stat find curl tar"
log_info "Test: $TESTNAME"
log_info "Mode: $testMode"
log_info "Formats: $formatList"
log_info "Duration: ${duration}s"
log_info "Backend: audiotestsrc + pulsesrc for recording, pulsesink for playback"
log_info "Audio params: sample_rate=${SAMPLE_RATE}Hz, samples_per_buffer=${SAMPLES_PER_BUFFER}"
log_info "Calculated num_buffers: $NUM_BUFFERS (for ${duration}s duration)"
log_info "GST debug: GST_DEBUG=$gstDebugLevel"
log_info "Logs: $OUTDIR"
log_info "Recorded artifact dir: $RECORDED_DIR"

# -------------------- Required element validation --------------------
check_required_elements() {
  if ! has_element audiotestsrc; then
    log_warn "audiotestsrc element not available"
    return 1
  fi
  if ! has_element pulsesink; then
    log_warn "pulsesink element not available"
    return 1
  fi
  return 0
}

# -------------------- Record test function (audiotestsrc) --------------------
run_record_test() {
  fmt="$1"

  testname="record_${fmt}"
  log_info "=========================================="
  log_info "Running: $testname"
  log_info "=========================================="

  # Check required plugins
  case "$fmt" in
    wav)
      if ! has_element wavenc; then
        log_warn "$testname: wavenc plugin not available"
        return 1
      fi
      ;;
    flac)
      if ! has_element flacenc; then
        log_warn "$testname: flacenc plugin not available"
        return 1
      fi
      ;;
  esac

  ext="$fmt"
  output_file="$RECORDED_DIR/${testname}.${ext}"
  test_log="$OUTDIR/${testname}.log"

  : >"$test_log"

  pipeline="$(gstreamer_build_audio_record_pipeline "audiotestsrc" "$fmt" "$output_file" "$NUM_BUFFERS")"

  if [ -z "$pipeline" ]; then
    log_fail "$testname: FAIL (could not build record pipeline)"
    fail_count=$((fail_count + 1))
    return 1
  fi

  log_info "Pipeline: $pipeline"

  # Run recording
  if gstreamer_run_gstlaunch_timeout "$((duration + 10))" "$pipeline" >>"$test_log" 2>&1; then
    gstRc=0
  else
    gstRc=$?
  fi

  log_info "Record exit code: $gstRc"

  # Check for GStreamer errors in log
  if ! gstreamer_validate_log "$test_log" "$testname"; then
    log_fail "$testname: FAIL (GStreamer errors detected)"
    fail_count=$((fail_count + 1))
    return 1
  fi

  # Check if output file was created and has content
  if [ -f "$output_file" ] && [ -s "$output_file" ]; then
    file_size="$(gstreamer_file_size_bytes "$output_file")"
    log_info "Recorded file: $output_file (size: $file_size bytes)"

    if [ "$file_size" -gt 1000 ]; then
      log_pass "$testname: PASS"
      pass_count=$((pass_count + 1))
      return 0
    else
      log_fail "$testname: FAIL (file too small: $file_size bytes)"
      fail_count=$((fail_count + 1))
      return 1
    fi
  else
    log_fail "$testname: FAIL (no output file created)"
    fail_count=$((fail_count + 1))
    return 1
  fi
}

# -------------------- Playback test function --------------------
run_playback_test() {
  fmt="$1"

  testname="playback_${fmt}"
  log_info "=========================================="
  log_info "Running: $testname"
  log_info "=========================================="

  ext="$fmt"
  input_file="$RECORDED_DIR/record_${fmt}.${ext}"

  if [ ! -f "$input_file" ]; then
    log_warn "$testname: SKIP - recorded file not found: $input_file (run record first)"
    skip_count=$((skip_count + 1))
    return 1
  fi

  # Check if file has minimum content (same threshold as recording: 1000 bytes)
  file_size="$(gstreamer_file_size_bytes "$input_file")"
  if [ "$file_size" -le 1000 ]; then
    log_warn "$testname: SKIP - recorded file too small: $file_size bytes (recording likely failed)"
    skip_count=$((skip_count + 1))
    return 1
  fi

  test_log="$OUTDIR/${testname}.log"
  : >"$test_log"

  pipeline="$(gstreamer_build_audio_playback_pipeline "$fmt" "$input_file")"

  if [ -z "$pipeline" ]; then
    log_fail "$testname: FAIL (could not build playback pipeline)"
    fail_count=$((fail_count + 1))
    return 1
  fi

  log_info "Pipeline: $pipeline"

  # Run playback
  if gstreamer_run_gstlaunch_timeout "$((duration + 10))" "$pipeline" >>"$test_log" 2>&1; then
    gstRc=0
  else
    gstRc=$?
  fi

  log_info "Playback exit code: $gstRc"

  # Check for GStreamer errors in log
  if ! gstreamer_validate_log "$test_log" "$testname"; then
    log_fail "$testname: FAIL (GStreamer errors detected)"
    fail_count=$((fail_count + 1))
    return 1
  fi

  # Check for successful completion
  if [ "$gstRc" -eq 0 ]; then
    log_pass "$testname: PASS"
    pass_count=$((pass_count + 1))
    return 0
  else
    log_fail "$testname: FAIL (rc=$gstRc)"
    fail_count=$((fail_count + 1))
    return 1
  fi
}

# -------------------- PulseSrc Record test function --------------------
run_record_pulsesrc_test() {
  fmt="$1"

  testname="record_pulsesrc_${fmt}"
  log_info "=========================================="
  log_info "Running: $testname"
  log_info "=========================================="

  # Check required plugins
  if ! has_element pulsesrc; then
    log_warn "$testname: pulsesrc plugin not available"
    skip_count=$((skip_count + 1))
    return 1
  fi

  case "$fmt" in
    wav)
      if ! has_element wavenc; then
        log_warn "$testname: wavenc plugin not available"
        skip_count=$((skip_count + 1))
        return 1
      fi
      ;;
    flac)
      if ! has_element flacenc; then
        log_warn "$testname: flacenc plugin not available"
        skip_count=$((skip_count + 1))
        return 1
      fi
      ;;
  esac

  ext="$fmt"
  output_file="$RECORDED_DIR/${testname}.${ext}"
  test_log="$OUTDIR/${testname}.log"

  : >"$test_log"

  pipeline="$(gstreamer_build_audio_record_pipeline "pulsesrc" "$fmt" "$output_file")"

  if [ -z "$pipeline" ]; then
    log_fail "$testname: FAIL (could not build pulsesrc record pipeline)"
    fail_count=$((fail_count + 1))
    return 1
  fi

  log_info "Pipeline: $pipeline"

  # Run recording with timeout
  if gstreamer_run_gstlaunch_timeout "$duration" "$pipeline" >>"$test_log" 2>&1; then
    gstRc=0
  else
    gstRc=$?
  fi

  log_info "Record exit code: $gstRc"

  # Check for GStreamer errors in log
  if ! gstreamer_validate_log "$test_log" "$testname"; then
    log_fail "$testname: FAIL (GStreamer errors detected)"
    fail_count=$((fail_count + 1))
    return 1
  fi

  # Check if output file was created and has content
  if [ -f "$output_file" ] && [ -s "$output_file" ]; then
    file_size="$(gstreamer_file_size_bytes "$output_file")"
    log_info "Recorded file: $output_file (size: $file_size bytes)"

    if [ "$file_size" -gt 1000 ]; then
      log_pass "$testname: PASS"
      pass_count=$((pass_count + 1))
      return 0
    else
      log_fail "$testname: FAIL (file too small: $file_size bytes)"
      fail_count=$((fail_count + 1))
      return 1
    fi
  else
    log_fail "$testname: FAIL (no output file created)"
    fail_count=$((fail_count + 1))
    return 1
  fi
}

# -------------------- PulseSrc Playback test function --------------------
run_playback_pulsesrc_test() {
  fmt="$1"
 
  testname="playback_pulsesrc_${fmt}"
  log_info "=========================================="
  log_info "Running: $testname"
  log_info "=========================================="
 
  ext="$fmt"
  input_file="$RECORDED_DIR/record_pulsesrc_${fmt}.${ext}"
 
  if [ ! -f "$input_file" ]; then
    if [ "$testMode" = "all" ]; then
      log_fail "$testname: FAIL - expected recorded file is missing: $input_file (pulsesrc record testcase failed in same run)"
      fail_count=$((fail_count + 1))
      return 1
    fi
 
    log_warn "$testname: SKIP - recorded file not found: $input_file (run pulsesrc record first)"
    skip_count=$((skip_count + 1))
    return 1
  fi
 
  file_size="$(gstreamer_file_size_bytes "$input_file")"
  if [ "$file_size" -le 1000 ]; then
    if [ "$testMode" = "all" ]; then
      log_fail "$testname: FAIL - recorded file too small: $file_size bytes (pulsesrc recording failed in same run)"
      fail_count=$((fail_count + 1))
      return 1
    fi
 
    log_warn "$testname: SKIP - recorded file too small: $file_size bytes (pulsesrc recording likely failed)"
    skip_count=$((skip_count + 1))
    return 1
  fi
 
  test_log="$OUTDIR/${testname}.log"
  : >"$test_log"
 
  pipeline="$(gstreamer_build_audio_playback_pipeline "$fmt" "$input_file")"
 
  if [ -z "$pipeline" ]; then
    log_fail "$testname: FAIL (could not build playback pipeline)"
    fail_count=$((fail_count + 1))
    return 1
  fi
 
  log_info "Pipeline: $pipeline"
 
  if gstreamer_run_gstlaunch_timeout "$((duration + 10))" "$pipeline" >>"$test_log" 2>&1; then
    gstRc=0
  else
    gstRc=$?
  fi
 
  log_info "Playback exit code: $gstRc"
 
  if ! gstreamer_validate_log "$test_log" "$testname"; then
    log_fail "$testname: FAIL (GStreamer errors detected)"
    fail_count=$((fail_count + 1))
    return 1
  fi
 
  if [ "$gstRc" -eq 0 ]; then
    log_pass "$testname: PASS"
    pass_count=$((pass_count + 1))
    return 0
  else
    log_fail "$testname: FAIL (rc=$gstRc)"
    fail_count=$((fail_count + 1))
    return 1
  fi
}
# -------------------- Test file playback test function (OGG/MP3) --------------------
run_playback_ogg_mp3_test() {
  fmt="$1"
  
  testname="playback_sample_${fmt}"
  log_info "=========================================="
  log_info "Running: $testname"
  log_info "=========================================="
  
  # Determine input file based on format
  case "$fmt" in
    ogg)
      input_file="$OUTDIR/sample_audio.ogg"
      ;;
    mp3)
      input_file="$OUTDIR/sample_audio.mp3"
      ;;
    *)
      log_warn "$testname: SKIP - unsupported format: $fmt"
      skip_count=$((skip_count + 1))
      return 1
      ;;
  esac
  
  if [ ! -f "$input_file" ]; then
    log_warn "$testname: SKIP - Test file not found: $input_file"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  # Check if file has minimum content
  file_size="$(gstreamer_file_size_bytes "$input_file")"
  if [ "$file_size" -le 1000 ]; then
    log_warn "$testname: SKIP - Test file too small: $file_size bytes"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  test_log="$OUTDIR/${testname}.log"
  : >"$test_log"
  
  pipeline="$(gstreamer_build_audio_playback_pipeline "$fmt" "$input_file")"
  
  if [ -z "$pipeline" ]; then
    log_fail "$testname: FAIL (could not build playback pipeline - format not supported or elements missing)"
    fail_count=$((fail_count + 1))
    return 1
  fi
  
  log_info "Pipeline: $pipeline"
  
  # Run playback
  if gstreamer_run_gstlaunch_timeout "$((duration + 10))" "$pipeline" >>"$test_log" 2>&1; then
    gstRc=0
  else
    gstRc=$?
  fi
  
  log_info "Playback exit code: $gstRc"
  
  # Check for GStreamer errors in log
  if ! gstreamer_validate_log "$test_log" "$testname"; then
    log_fail "$testname: FAIL (GStreamer errors detected)"
    fail_count=$((fail_count + 1))
    return 1
  fi
  
  # Check for successful completion
  if [ "$gstRc" -eq 0 ]; then
    log_pass "$testname: PASS"
    pass_count=$((pass_count + 1))
    return 0
  else
    log_fail "$testname: FAIL (rc=$gstRc)"
    fail_count=$((fail_count + 1))
    return 1
  fi
}

# -------------------- GStreamer debug capture --------------------
export GST_DEBUG_NO_COLOR=1
export GST_DEBUG="$gstDebugLevel"
export GST_DEBUG_FILE="$GST_LOG"

# -------------------- Test file provisioning (OGG/MP3) --------------------
provision_test_files() {
  outdir="$1"
  num_buffers="$2"
  duration_secs="$3"
  clip_path="$4"
  clip_url="$5"
  user_clip_path_set="$6"
  user_clip_url_set="$7"

  log_info "=========================================="
  log_info "TEST FILE PROVISIONING"
  log_info "=========================================="

  sample_ogg="$outdir/sample_audio.ogg"
  sample_mp3="$outdir/sample_audio.mp3"

  have_ogg=0
  have_mp3=0

  mark_existing_samples() {
    if [ -f "$sample_ogg" ]; then
      size="$(gstreamer_file_size_bytes "$sample_ogg")"
      if [ "$size" -gt 1000 ]; then
        have_ogg=1
        log_info "OGG Test file available (size: $size bytes)"
      fi
    fi

    if [ -f "$sample_mp3" ]; then
      size="$(gstreamer_file_size_bytes "$sample_mp3")"
      if [ "$size" -gt 1000 ]; then
        have_mp3=1
        log_info "MP3 Test file available (size: $size bytes)"
      fi
    fi
  }

  generate_local_ogg() {
    test_log="$outdir/provision_sample_ogg.log"
    : >"$test_log"

    pipeline="audiotestsrc wave=sine freq=440 volume=1.0 num-buffers=$num_buffers ! audioconvert ! vorbisenc ! oggmux ! filesink location=$sample_ogg"

    log_info "Generating local OGG sample from audiotestsrc..."
    log_info "Pipeline: $pipeline"

    if gstreamer_run_gstlaunch_timeout "$((duration_secs + 10))" "$pipeline" >>"$test_log" 2>&1; then
      gstRc=0
    else
      gstRc=$?
    fi

    log_info "OGG generation exit code: $gstRc"

    if gstreamer_validate_log "$test_log" "provision_sample_ogg"; then
      if [ -f "$sample_ogg" ] && [ -s "$sample_ogg" ]; then
        size="$(gstreamer_file_size_bytes "$sample_ogg")"
        if [ "$size" -gt 1000 ]; then
          have_ogg=1
          log_pass "Local OGG sample generated successfully (size: $size bytes)"
        else
          log_warn "Generated OGG sample is too small: $size bytes"
        fi
      else
        log_warn "Local OGG sample was not created"
      fi
    else
      log_warn "Local OGG sample generation reported GStreamer errors"
    fi
  }

  generate_local_mp3() {
    test_log="$outdir/provision_sample_mp3.log"
    : >"$test_log"

    pipeline="audiotestsrc wave=sine freq=440 volume=1.0 num-buffers=$num_buffers ! audioconvert ! lamemp3enc target=bitrate cbr=true bitrate=128 ! filesink location=$sample_mp3"

    log_info "Generating local MP3 sample from audiotestsrc..."
    log_info "Pipeline: $pipeline"

    if gstreamer_run_gstlaunch_timeout "$((duration_secs + 10))" "$pipeline" >>"$test_log" 2>&1; then
      gstRc=0
    else
      gstRc=$?
    fi

    log_info "MP3 generation exit code: $gstRc"

    if gstreamer_validate_log "$test_log" "provision_sample_mp3"; then
      if [ -f "$sample_mp3" ] && [ -s "$sample_mp3" ]; then
        size="$(gstreamer_file_size_bytes "$sample_mp3")"
        if [ "$size" -gt 1000 ]; then
          have_mp3=1
          log_pass "Local MP3 sample generated successfully (size: $size bytes)"
        else
          log_warn "Generated MP3 sample is too small: $size bytes"
        fi
      else
        log_warn "Local MP3 sample was not created"
      fi
    else
      log_warn "Local MP3 sample generation reported GStreamer errors"
    fi
  }

  # Prefer files already present in OUTDIR.
  mark_existing_samples

  # If user explicitly gave --clip-path (or AUDIO_CLIP_PATH), honor it first.
  if [ "$have_ogg" -eq 0 ] || [ "$have_mp3" -eq 0 ]; then
    if [ "$user_clip_path_set" -eq 1 ] && [ -n "$clip_path" ]; then
      log_info "Using user-provided clip path: $clip_path"

      if [ "$have_ogg" -eq 0 ] && [ -f "$clip_path/sample_audio.ogg" ]; then
        cp "$clip_path/sample_audio.ogg" "$sample_ogg" 2>/dev/null || true
      fi

      if [ "$have_mp3" -eq 0 ] && [ -f "$clip_path/sample_audio.mp3" ]; then
        cp "$clip_path/sample_audio.mp3" "$sample_mp3" 2>/dev/null || true
      fi

      mark_existing_samples
    fi
  fi

  # If user explicitly gave --clip-url (or AUDIO_CLIP_URL), honor it next.
  if [ "$have_ogg" -eq 0 ] || [ "$have_mp3" -eq 0 ]; then
    if [ "$user_clip_url_set" -eq 1 ] && [ -n "$clip_url" ]; then
      log_info "Using user-provided clip URL: $clip_url"
      if extract_tar_from_url "$clip_url" "$outdir"; then
        log_pass "Test files downloaded and extracted successfully"
      else
        log_warn "Test file download failed (offline or URL issue)"
      fi

      mark_existing_samples
    fi
  fi

  # If user did NOT explicitly request clip-path or clip-url, prefer local generation.
  if [ "$user_clip_path_set" -eq 0 ] && [ "$user_clip_url_set" -eq 0 ]; then
    if [ "$have_ogg" -eq 0 ]; then
      if has_element vorbisenc && has_element oggmux; then
        generate_local_ogg
      else
        log_warn "OGG sample generation skipped: vorbisenc or oggmux plugin not available"
      fi
    fi

    if [ "$have_mp3" -eq 0 ]; then
      if has_element lamemp3enc; then
        generate_local_mp3
      else
        log_warn "MP3 sample generation skipped: lamemp3enc plugin not available"
      fi
    fi
  fi

  # If user explicitly requested an external source but it was incomplete,
  # local generation can still fill in missing files as best effort.
  if [ "$user_clip_path_set" -eq 1 ] || [ "$user_clip_url_set" -eq 1 ]; then
    if [ "$have_ogg" -eq 0 ]; then
      if has_element vorbisenc && has_element oggmux; then
        generate_local_ogg
      fi
    fi

    if [ "$have_mp3" -eq 0 ]; then
      if has_element lamemp3enc; then
        generate_local_mp3
      fi
    fi
  fi

  mark_existing_samples

  if [ "$have_ogg" -eq 0 ] && [ "$have_mp3" -eq 0 ]; then
    log_warn "No Test files (OGG/MP3) available for playback tests"
  fi
}

# -------------------- Main test execution --------------------
log_info "Starting audio record/playback tests..."

# Check required elements
if ! check_required_elements; then
  log_warn "Required GStreamer elements (audiotestsrc/pulsesink) not available"
  echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi
log_info "Required GStreamer elements verified"

# Parse format list
formats=$(printf '%s' "$formatList" | tr ',' ' ')

# -------------------- Individual Test Mode --------------------
if [ -n "$testName" ]; then
  # Only provision test files if running OGG/MP3 playback tests
  case "$testName" in
    playback_sample_ogg|playback_sample_mp3)
      provision_test_files "$OUTDIR" "$NUM_BUFFERS" "$duration" "$clipPath" "$clipUrl" "$USER_CLIP_PATH_SET" "$USER_CLIP_URL_SET"
      ;;
  esac
  log_info "=========================================="
  log_info "INDIVIDUAL TEST MODE: $testName"
  log_info "=========================================="
  
  total_tests=1
  
  case "$testName" in
    record_wav)
      run_record_test "wav" || true
      ;;
    record_flac)
      run_record_test "flac" || true
      ;;
    record_pulsesrc_wav)
      run_record_pulsesrc_test "wav" || true
      ;;
    record_pulsesrc_flac)
      run_record_pulsesrc_test "flac" || true
      ;;
    playback_wav)
      run_playback_test "wav" || true
      ;;
    playback_flac)
      run_playback_test "flac" || true
      ;;
    playback_pulsesrc_wav)
      run_playback_pulsesrc_test "wav" || true
      ;;
    playback_pulsesrc_flac)
      run_playback_pulsesrc_test "flac" || true
      ;;
    playback_sample_ogg)
      run_playback_ogg_mp3_test "ogg" || true
      ;;
    playback_sample_mp3)
      run_playback_ogg_mp3_test "mp3" || true
      ;;
  esac
  
# -------------------- Grouped Test Mode (Original) --------------------
else
  # Run ALL record/encode tests first (4 tests total)
  if [ "$testMode" = "all" ] || [ "$testMode" = "record" ]; then
    log_info "=========================================="
    log_info "RECORD TESTS"
    log_info "=========================================="

    # 1. Record with audiotestsrc (2 tests: wav, flac)
    log_info "Recording with audiotestsrc..."
    for fmt in $formats; do
      total_tests=$((total_tests + 1))
      run_record_test "$fmt" || true
    done

    # 2. Record with pulsesrc HW (2 tests: wav, flac)
    log_info "Recording with pulsesrc HW..."
    for fmt in $formats; do
      total_tests=$((total_tests + 1))
      run_record_pulsesrc_test "$fmt" || true
    done
  fi

  # Run ALL playback/decode tests after recording (6 tests total)
  if [ "$testMode" = "all" ] || [ "$testMode" = "playback" ]; then
    # Provision test files only when running playback tests
    provision_test_files "$OUTDIR" "$NUM_BUFFERS" "$duration" "$clipPath" "$clipUrl" "$USER_CLIP_PATH_SET" "$USER_CLIP_URL_SET"
    
    log_info "=========================================="
    log_info "PLAYBACK TESTS"
    log_info "=========================================="

    # 3. Playback audiotestsrc recordings (2 tests: wav, flac)
    log_info "Playing back audiotestsrc recordings..."
    for fmt in $formats; do
      total_tests=$((total_tests + 1))
      run_playback_test "$fmt" || true
    done

    # 4. Playback pulsesrc recordings (2 tests: wav, flac)
    log_info "Playing back pulsesrc recordings..."
    for fmt in $formats; do
      total_tests=$((total_tests + 1))
      run_playback_pulsesrc_test "$fmt" || true
    done
    
    # 5. Playback Test files (2 tests: ogg, mp3)
    log_info "Playing back Test files (OGG/MP3)..."
    for fmt in ogg mp3; do
      total_tests=$((total_tests + 1))
      run_playback_ogg_mp3_test "$fmt" || true
    done
  fi
fi

# -------------------- Dmesg error scan --------------------
log_info "=========================================="
log_info "DMESG ERROR SCAN"
log_info "=========================================="

module_regex="audio|sound|pulse|codec|dsp"
exclude_regex="dummy regulator|supply [^ ]+ not found|using dummy regulator"

if command -v scan_dmesg_errors >/dev/null 2>&1; then
  scan_dmesg_errors "$DMESG_DIR" "$module_regex" "$exclude_regex" || true

  if [ -s "$DMESG_DIR/dmesg_errors.log" ]; then
    log_warn "dmesg scan found audio-related warnings or errors in $DMESG_DIR/dmesg_errors.log"
  else
    log_info "No relevant audio-related errors found in dmesg"
  fi
else
  log_info "scan_dmesg_errors not available, skipping dmesg scan"
fi

# -------------------- Summary --------------------
log_info "=========================================="
log_info "TEST SUMMARY"
log_info "=========================================="
log_info "Total testcases: $total_tests"
log_info "Passed: $pass_count"
log_info "Failed: $fail_count"
log_info "Skipped: $skip_count"

# -------------------- Emit result --------------------
if [ "$fail_count" -eq 0 ] && [ "$pass_count" -gt 0 ]; then
  result="PASS"
  if [ "$skip_count" -gt 0 ]; then
    reason="No failures (passed: $pass_count, failed: $fail_count, skipped: $skip_count, total: $total_tests)"
  else
    reason="All tests passed ($pass_count/$total_tests)"
  fi
elif [ "$fail_count" -gt 0 ]; then
  result="FAIL"
  reason="Some tests failed (passed: $pass_count, failed: $fail_count, skipped: $skip_count, total: $total_tests)"
else
  result="SKIP"
  reason="No tests passed (skipped: $skip_count, total: $total_tests)"
fi

case "$result" in
  PASS)
    log_pass "$TESTNAME $result: $reason"
    echo "$RESULT_TESTNAME PASS" >"$RES_FILE"
    ;;
  FAIL)
    log_fail "$TESTNAME $result: $reason"
    echo "$RESULT_TESTNAME FAIL" >"$RES_FILE"
    ;;
  *)
    log_warn "$TESTNAME $result: $reason"
    echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
    ;;
esac

exit 0
