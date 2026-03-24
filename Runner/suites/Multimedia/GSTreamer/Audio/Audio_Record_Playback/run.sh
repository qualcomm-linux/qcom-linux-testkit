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
RES_FILE="${SCRIPT_DIR}/${TESTNAME}.res"
LOG_DIR="${SCRIPT_DIR}/logs"
OUTDIR="$LOG_DIR/$TESTNAME"
GST_LOG="$OUTDIR/gst.log"
DMESG_DIR="$OUTDIR/dmesg"

# Use the shared recorded directory if supported; otherwise default to $OUTDIR/recorded.
if command -v gstreamer_shared_encoded_dir >/dev/null 2>&1; then
    RECORDED_DIR="$(gstreamer_shared_encoded_dir "$SCRIPT_DIR" "$OUTDIR")"
else
    RECORDED_DIR="$OUTDIR/recorded"
fi

if ! mkdir -p "$OUTDIR" "$DMESG_DIR" "$RECORDED_DIR"; then
  log_error "Failed to create required directories:"
  log_error "  OUTDIR=$OUTDIR"
  log_error "  DMESG_DIR=$DMESG_DIR"
  log_error "  RECORDED_DIR=$RECORDED_DIR"
  echo "$TESTNAME FAIL" >"$RES_FILE" 2>/dev/null || true
  exit 0
fi
: >"$RES_FILE"
: >"$GST_LOG"
 
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
  echo "$TESTNAME SKIP" >"$RES_FILE" 2>/dev/null || true
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

result="FAIL"
reason="unknown"
pass_count=0
fail_count=0
skip_count=0
total_tests=0

# -------------------- Defaults (LAVA env vars -> defaults; CLI overrides) --------------------
testMode="${AUDIO_TEST_MODE:-all}"
formatList="${AUDIO_FORMATS:-wav,flac}"
duration="${AUDIO_DURATION:-${RUNTIMESEC:-10}}"
gstDebugLevel="${AUDIO_GST_DEBUG:-${GST_DEBUG_LEVEL:-2}}"
clipUrl="${AUDIO_CLIP_URL:-https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/GST-Audio-Files-v1.0/audio_clips_gst.tar.gz}"
clipPath="${AUDIO_CLIP_PATH:-}"

# Calculate num_buffers based on duration
# Formula: num_buffers = (sample_rate * duration) / samples_per_buffer
# Example: (44100 * 10) / 1024 = 430 buffers for 10 seconds
NUM_BUFFERS=$(( (SAMPLE_RATE * duration) / SAMPLES_PER_BUFFER ))

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
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
        ;;
      *)
        if [ "$val" -le 0 ] 2>/dev/null; then
          log_warn "$param must be positive (got '$val')"
          echo "$TESTNAME SKIP" >"$RES_FILE"
          exit 0
        fi
        ;;
    esac
  fi
done

# shellcheck disable=SC2317
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
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      [ -n "$2" ] && testMode="$2"
      shift 2
      ;;

    --formats)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --formats"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      [ -n "$2" ] && formatList="$2"
      shift 2
      ;;

    --duration)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --duration"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      if [ -n "$2" ]; then
        case "$2" in
          ''|*[!0-9]*)
            log_warn "Invalid --duration '$2' (must be numeric)"
            echo "$TESTNAME SKIP" >"$RES_FILE"
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
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      [ -n "$2" ] && gstDebugLevel="$2"
      shift 2
      ;;

    --clip-url)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --clip-url"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      [ -n "$2" ] && clipUrl="$2"
      shift 2
      ;;

    --clip-path)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --clip-path"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      [ -n "$2" ] && clipPath="$2"
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
      echo "$TESTNAME SKIP" >"$RES_FILE"
      exit 0
      ;;
  esac
done

# -------------------- Validate parsed values --------------------
case "$testMode" in all|record|playback) : ;; *)
  log_warn "Invalid --mode '$testMode'"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
  ;;
esac

case "$gstDebugLevel" in 1|2|3|4|5|6|7|8|9) : ;; *)
  log_warn "Invalid --gst-debug '$gstDebugLevel' (allowed: 1-9)"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
  ;;
esac

case "$duration" in
  ''|*[!0-9]*)
    log_warn "Invalid duration '$duration' (must be numeric)"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
    ;;
  *)
    if [ "$duration" -le 0 ] 2>/dev/null; then
      log_warn "Duration must be positive (got '$duration')"
      echo "$TESTNAME SKIP" >"$RES_FILE"
      exit 0
    fi
    ;;
esac

# -------------------- Pre-checks --------------------
check_dependencies "gst-launch-1.0 gst-inspect-1.0 awk grep head sed tr stat find curl tar" >/dev/null 2>&1 || {
  log_skip "Missing required tools (gst-launch-1.0, gst-inspect-1.0, awk, grep, head, sed, tr, stat, find, curl, tar)"
  echo "$TESTNAME SKIP" >"$RES_FILE"
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
    log_warn "$testname: SKIP - recorded file not found: $input_file (run pulsesrc record first)"
    skip_count=$((skip_count + 1))
    return 1
  fi

  # Check if file has minimum content (same threshold as recording: 1000 bytes)
  file_size="$(gstreamer_file_size_bytes "$input_file")"
  if [ "$file_size" -le 1000 ]; then
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
  log_info "=========================================="
  log_info "TEST FILE PROVISIONING"
  log_info "=========================================="
  
  sample_ogg="$OUTDIR/sample_audio.ogg"
  sample_mp3="$OUTDIR/sample_audio.mp3"
  
  # Check if Test files already exist
  if [ -f "$sample_ogg" ] && [ -f "$sample_mp3" ]; then
    log_info "Test files already exist"
  else
    # Try to get Test files from provided path or URL
    if [ -n "$clipPath" ]; then
      log_info "Attempting to get Test files from local path: $clipPath"
      if [ -f "$clipPath/sample_audio.ogg" ]; then
        cp "$clipPath/sample_audio.ogg" "$sample_ogg" 2>/dev/null || true
        log_info "Sample OGG file copied from local path"
      fi
      if [ -f "$clipPath/sample_audio.mp3" ]; then
        cp "$clipPath/sample_audio.mp3" "$sample_mp3" 2>/dev/null || true
        log_info "Sample MP3 file copied from local path"
      fi
    fi
    
    # If not found locally, try URL download
    if [ ! -f "$sample_ogg" ] || [ ! -f "$sample_mp3" ]; then
      log_info "Test files not found locally; attempting download from URL..."
      if extract_tar_from_url "$clipUrl" "$OUTDIR"; then
        log_pass "Test files downloaded and extracted successfully"
      else
        log_warn "Test file download failed (offline or URL issue)"
      fi
    fi
    
  fi
  
  # Check what we have AFTER all provisioning attempts
  have_ogg=0
  have_mp3=0
  
  if [ -f "$sample_ogg" ]; then
    size=$(gstreamer_file_size_bytes "$sample_ogg")
    if [ "$size" -gt 1000 ]; then
      have_ogg=1
      log_info "OGG Test file available (size: $size bytes)"
    fi
  fi
  
  if [ -f "$sample_mp3" ]; then
    size=$(gstreamer_file_size_bytes "$sample_mp3")
    if [ "$size" -gt 1000 ]; then
      have_mp3=1
      log_info "MP3 Test file available (size: $size bytes)"
    fi
  fi
  
  # Only warn if BOTH files are missing after all attempts
  if [ "$have_ogg" -eq 0 ] && [ "$have_mp3" -eq 0 ]; then
    log_warn "No Test files (OGG/MP3) available for playback tests"
  fi
}

# -------------------- Main test execution --------------------
log_info "Starting audio record/playback tests..."

# Check required elements
if ! check_required_elements; then
  log_warn "Required GStreamer elements (audiotestsrc/pulsesink) not available"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi
log_info "Required GStreamer elements verified"

# Provision Test files for OGG/MP3 playback tests
provision_test_files

# Parse format list
formats=$(printf '%s' "$formatList" | tr ',' ' ')

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

# Run ALL playback/decode tests after recording (4 tests total)
if [ "$testMode" = "all" ] || [ "$testMode" = "playback" ]; then
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
    echo "$TESTNAME PASS" >"$RES_FILE"
    ;;
  FAIL)
    log_fail "$TESTNAME $result: $reason"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    ;;
  *)
    log_warn "$TESTNAME $result: $reason"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    ;;
esac

exit 0
