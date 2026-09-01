#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Video Encode/Decode validation using GStreamer with V4L2 hardware accelerated codecs
# Supports: v4l2h264dec, v4l2h265dec, v4l2h264enc, v4l2h265enc
# Uses videotestsrc for encoding, then decodes the encoded files
# Logs everything to console and also to local log files.
# PASS/FAIL/SKIP is emitted to .res. Always exits 0 (LAVA-friendly).

SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"

TESTNAME="Video_Encode_Decode"
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

# shellcheck disable=SC1091
[ -f "$TOOLS/lib_video.sh" ] && . "$TOOLS/lib_video.sh"

# shellcheck disable=SC1091
[ -f "$TOOLS/lib_display.sh" ] && . "$TOOLS/lib_display.sh"

# Use the shared encoded directory if supported; otherwise default to $OUTDIR/encoded.
if command -v gstreamer_shared_encoded_dir >/dev/null 2>&1; then
    ENCODED_DIR="$(gstreamer_shared_encoded_dir "$SCRIPT_DIR" "$OUTDIR")"
else
    ENCODED_DIR="$OUTDIR/encoded"
fi

if ! mkdir -p "$OUTDIR" "$DMESG_DIR" "$ENCODED_DIR"; then
  log_error "Failed to create required directories:"
  log_error "  OUTDIR=$OUTDIR"
  log_error "  DMESG_DIR=$DMESG_DIR"
  log_error "  ENCODED_DIR=$ENCODED_DIR"
  echo "$RESULT_TESTNAME FAIL" >"$RES_FILE" 2>/dev/null || true
  exit 0
fi

# Keep the codec-fault evidence with the run's artifacts, and widen the module
# filter to the set this suite cares about so the single capture below serves
# both the codec classification and the end-of-run check.
GST_CODEC_DMESG_DIR="$DMESG_DIR"
GST_CODEC_MODULE_RE="qcom-iris[^:]*|qcom-venus[^:]*|venus_core[^:]*|[^ ]*video-codec|venus[^:]*|vcodec[^:]*|v4l2[^:]*|video[^:]*|gstreamer[^:]*"
export GST_CODEC_DMESG_DIR GST_CODEC_MODULE_RE

: >"$RES_FILE"
: >"$GST_LOG"

result="FAIL"
reason="unknown"
pass_count=0
fail_count=0
skip_count=0
total_tests=0

# -------------------- Defaults (LAVA env vars -> defaults; CLI overrides) --------------------
testMode="${VIDEO_TEST_MODE:-all}"
testType="${VIDEO_TEST_TYPE:-basic}"
codecList="${VIDEO_CODECS:-h264,h265,vp9}"
resolutionList="${VIDEO_RESOLUTIONS:-480p}"
duration="${VIDEO_DURATION:-${RUNTIMESEC:-30}}"
framerate="${VIDEO_FRAMERATE:-30}"
gstDebugLevel="${VIDEO_GST_DEBUG:-${GST_DEBUG_LEVEL:-2}}"
videoStack="${VIDEO_STACK:-auto}"
clipUrl="${VIDEO_CLIP_URL:-https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/GST-Video-Files-v1.0/video_clips_gst.tar.gz}"
clipPath="${VIDEO_CLIP_PATH:-}"

# Validate environment variables if set
# Validate numeric parameters (POSIX-safe; no indirect expansion)
for param in VIDEO_DURATION RUNTIMESEC VIDEO_FRAMERATE VIDEO_GST_DEBUG GST_DEBUG_LEVEL; do
  val=""
  case "$param" in
    VIDEO_DURATION) val="${VIDEO_DURATION-}" ;;
    RUNTIMESEC) val="${RUNTIMESEC-}" ;;
    VIDEO_FRAMERATE) val="${VIDEO_FRAMERATE-}" ;;
    VIDEO_GST_DEBUG) val="${VIDEO_GST_DEBUG-}" ;;
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

# shellcheck disable=SC2317
cleanup() {
  # Best-effort: try to kill only children first; fall back to name-based kill
  if ! pkill -P "$$" -x gst-launch-1.0 >/dev/null 2>&1; then
    pkill -x gst-launch-1.0 >/dev/null 2>&1 || true
  fi
  # The element-probe cache is backed by files under TMPDIR; do not leave them.
  if command -v gstreamer_reset_element_cache >/dev/null 2>&1; then
    gstreamer_reset_element_cache
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
      # If empty, keep default; otherwise use provided value
      [ -n "$2" ] && testMode="$2"
      shift 2
      ;;

    --test-type)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --test-type"
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      [ -n "$2" ] && testType="$2"
      shift 2
      ;;

    --codecs)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --codecs"
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      # If empty, keep default; otherwise use provided value
      [ -n "$2" ] && codecList="$2"
      shift 2
      ;;

    --resolutions)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --resolutions"
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      # If empty, keep default; otherwise use provided value
      [ -n "$2" ] && resolutionList="$2"
      shift 2
      ;;

    --duration)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --duration"
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      # If empty or non-numeric, keep default; otherwise use provided value
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

    --framerate)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --framerate"
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      if [ -n "$2" ]; then
        case "$2" in
          ''|*[!0-9]*) 
            log_warn "Invalid --framerate '$2' (must be numeric)"
            echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
            exit 0
            ;;
          *)
            if [ "$2" -le 0 ] 2>/dev/null; then
              log_warn "Framerate must be positive (got '$2')"
              echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
              exit 0
            fi
            ;;
        esac
      fi
      # If empty, keep default; otherwise use provided value
      [ -n "$2" ] && framerate="$2"
      shift 2
      ;;

    --stack)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --stack"
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      # If empty, keep default; otherwise use provided value
      [ -n "$2" ] && videoStack="$2"
      shift 2
      ;;

    --gst-debug)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --gst-debug"
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      # If empty, keep default; otherwise use provided value
      [ -n "$2" ] && gstDebugLevel="$2"
      shift 2
      ;;

    --clip-url)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --clip-url"
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      # If empty, keep default; otherwise use provided value
      [ -n "$2" ] && clipUrl="$2"
      shift 2
      ;;
    --clip-path)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --clip-path"
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      [ -n "$2" ] && clipPath="$2"
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

Video Encode/Decode Validation using GStreamer with V4L2 hardware accelerated codecs

OPTIONS:
  --mode <all|encode|decode>
                        Test mode (default: all)
                        - all: Run both encode and decode tests
                        - encode: Run only encoding tests
                        - decode: Run only decoding tests

  --test-type <basic|uvc|drc|concurrency|advanced-encode|all>
                        Test type (default: basic)
                        - basic: Standard encode/decode tests only (H.264, H.265, VP9)
                        - all: Run ALL tests (basic + uvc + drc + concurrency + advanced-encode)
                        - uvc: UVC camera live preview at 1080p@5fps (PR76474)
                        - drc: Dynamic Resolution Change H.264 decode (FR82787)
                        - concurrency: Concurrent decode tests (PR43865, PR43866, FR98277)
                          * 8x H.264 480p decode sessions
                          * 8x H.265 480p decode sessions
                          * 2x MJPEG 1080p decode sessions
                        - advanced-encode: Advanced encoding tests (downstream only)
                          * HEVC Smart encode 720p (FR74943)
                          * HEVC 1080p Cyclic IR (FR82773)
                          * H.264 VGA Slice MB (FR82771)
                          * HEVC 1080p Rotate 90° (FR72846)

  --codecs <codec1,codec2,...>
                        Comma-separated list of codecs to test
                        (default: h264,h265,vp9)
                        Supported: h264, h265, vp9

  --resolutions <res1,res2,...>
                        Comma-separated list of resolutions to test
                        (default: 480p)
                        Supported: 480p, 720p, 1080p, 4k

  --duration <seconds>  Duration for encoding/decoding in seconds
                        (default: 30)

  --framerate <fps>     Framerate for video encoding
                        (default: 30)

  --stack <auto|upstream|downstream>
                        Video stack to use
                        (default: auto)

  --gst-debug <level>   GStreamer debug level (1-9)
                        (default: 2)

  --clip-url <url>      URL to download test video files (VP9)
                        (default: GitHub release URL)

  --clip-path <path>    Local path to test video files
                        (overrides --clip-url if files exist)
                        Example: --clip-path /opt

  --lava-testcase-id <name>
                        Override the test case name reported to LAVA
                        (default: Video_Encode_Decode)
                        Used by LAVA to match expected test case names

  -h, --help            Display this help message

FILE LOCATIONS:
  Test clips and logs are stored in:
    $SCRIPT_DIR/logs/Video_Encode_Decode/

  On device, this typically resolves to:
    /var/Runner/suites/Multimedia/GSTreamer/Video/Video_Encode_Decode/logs/Video_Encode_Decode/

  Downloaded/copied clips:
    - VP9_640x480_10s.webm
    - H264_480p_30fps.mp4
    - H265_480p_30fps.mp4
    - mjpeg1.avi
    - 1080_720_h264.mp4

  Encoded files:
    logs/Video_Encode_Decode/encoded/
      - encode_h264_480p.mp4
      - encode_h265_480p.mp4
      - (etc.)

  Log files:
    - gst.log (GStreamer debug output)
    - encode_*.log (individual test logs)
    - decode_*.log
    - UVC_*.log
    - DRC_*.log
    - H264_Decode_Concurrency_*.log
    - (etc.)

ENVIRONMENT VARIABLES:
  VIDEO_TEST_TYPE       Same as --test-type
  VIDEO_TEST_MODE       Same as --mode
  VIDEO_CODECS          Same as --codecs
  VIDEO_RESOLUTIONS     Same as --resolutions
  VIDEO_DURATION        Same as --duration
  VIDEO_FRAMERATE       Same as --framerate
  VIDEO_STACK           Same as --stack
  VIDEO_GST_DEBUG       Same as --gst-debug
  VIDEO_CLIP_URL        Same as --clip-url
  VIDEO_CLIP_PATH       Same as --clip-path
  GST_DEBUG_LEVEL       Alternative to VIDEO_GST_DEBUG
  RUNTIMESEC            Alternative to VIDEO_DURATION

EXAMPLES:
  # Run basic tests with default settings (backward compatible)
  $0

  # Run ALL tests (basic + advanced)
  $0 --test-type all

  # Run only encoding tests for H.264 at 720p
  $0 --mode encode --codecs h264 --resolutions 720p

  # Test multiple codecs and resolutions
  $0 --codecs h264,h265 --resolutions 480p,720p

  # Use upstream video stack
  $0 --stack upstream

SUPPORTED CODECS:
  - h264: H.264/AVC encoding and decoding (v4l2h264enc, v4l2h264dec)
  - h265: H.265/HEVC encoding and decoding (v4l2h265enc, v4l2h265dec)
  - vp9:  VP9 decoding only (v4l2vp9dec) - uses pre-recorded WebM clip

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
case "$testMode" in all|encode|decode) : ;; *)
  log_warn "Invalid --mode '$testMode'"
  echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
  exit 0
  ;;
esac

case "$testType" in basic|uvc|drc|concurrency|advanced-encode|all) : ;; *)
  log_warn "Invalid --test-type '$testType' (allowed: basic, uvc, drc, concurrency, advanced-encode, all)"
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

case "$framerate" in
  ''|*[!0-9]*) 
    log_warn "Invalid framerate '$framerate' (must be numeric)"
    echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
    exit 0
    ;;
  *)
    if [ "$framerate" -le 0 ] 2>/dev/null; then
      log_warn "Framerate must be positive (got '$framerate')"
      echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
      exit 0
    fi
    ;;
esac

# -------------------- Pre-checks --------------------
check_dependencies "gst-launch-1.0 gst-inspect-1.0 awk grep head sed tr stat find curl tar" >/dev/null 2>&1 || {
  log_skip "Missing required tools (gst-launch-1.0, gst-inspect-1.0, awk, grep, head, sed, tr, stat, find, curl, tar)"
  echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
  exit 0
}

log_info "Checking dependencies: gst-launch-1.0 gst-inspect-1.0 awk grep head sed tr stat find curl tar"
log_info "Test: $TESTNAME"
log_info "Mode: $testMode"
log_info "Codecs: $codecList"
log_info "Resolutions: $resolutionList"
log_info "Duration: ${duration}s, Framerate: ${framerate}fps"
log_info "GST debug: GST_DEBUG=$gstDebugLevel"
log_info "Logs: $OUTDIR"
log_info "Encoded artifact dir: $ENCODED_DIR"
log_info "VP9 clip URL: $clipUrl"
if [ -n "$clipPath" ]; then
  log_info "VP9 clip local path: $clipPath"
fi

# -------------------- Video stack handling --------------------
detected_stack="$videoStack"
if command -v video_ensure_stack >/dev/null 2>&1; then
  log_info "Ensuring video stack: $videoStack"
  stack_result=$(video_ensure_stack "$videoStack" "" 2>&1)
  if printf '%s' "$stack_result" | grep -q "downstream"; then
    detected_stack="downstream"
    log_info "Detected stack: downstream"
  elif printf '%s' "$stack_result" | grep -q "upstream"; then
    detected_stack="upstream"
    log_info "Detected stack: upstream"
  else
    log_info "Stack detection result: $stack_result"
  fi
fi

# -------------------- GStreamer debug capture --------------------
export GST_DEBUG_NO_COLOR=1
export GST_DEBUG="$gstDebugLevel"
export GST_DEBUG_FILE="$GST_LOG"


# -------------------- Encode test function --------------------
run_encode_test() {
  codec="$1"
  resolution="$2"
  width="$3"
  height="$4"
  
  testname="encode_${codec}_${resolution}"
  log_info "=========================================="
  log_info "Running: $testname"
  log_info "=========================================="
  
  # Check if encoder is available
  encoder=$(gstreamer_v4l2_encoder_for_codec "$codec")
  probe_rc=$?
  if [ -z "$encoder" ]; then
    # A probe that timed out, or could not be bounded, means the codec is
    # broken - not absent. Reporting SKIP there hides a hardware failure.
    if gstreamer_probe_unhealthy "$probe_rc"; then
      log_fail "$testname: FAIL (encoder for $codec unusable: $(gstreamer_probe_reason "$probe_rc"))"
      fail_count=$((fail_count + 1))
      return 1
    fi
    log_warn "Encoder not available for $codec"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  ext=$(gstreamer_container_ext_for_codec "$codec")
  output_file="$ENCODED_DIR/${testname}.${ext}"
  test_log="$OUTDIR/${testname}.log"
  
  : >"$test_log"
  
  # Calculate bitrate based on resolution
  bitrate=$(gstreamer_bitrate_for_resolution "$width" "$height")
  
  # Build pipeline using library function
  pipeline=$(gstreamer_build_v4l2_encode_pipeline "$codec" "$width" "$height" "$duration" "$framerate" "$bitrate" "$output_file" "$detected_stack")
  
  if [ -z "$pipeline" ]; then
    log_fail "$testname: FAIL (could not build pipeline)"
    fail_count=$((fail_count + 1))
    return 1
  fi
  
  log_info "Pipeline: $pipeline"

  # Never judge this run on a file left behind by an earlier one: the encoded
  # directory is shared between the test definitions in a job, so a stale or
  # partially written artifact would otherwise satisfy the size check below.
  rm -f "$output_file" 2>/dev/null || true

  # Run encoding
  if gstreamer_run_gstlaunch_timeout "$((duration + 10))" "$pipeline" >>"$test_log" 2>&1; then
    gstRc=0
  else
    gstRc=$?
  fi
  
  log_info "Encode exit code: $gstRc"

  # An encode that did not exit cleanly is a failure. videotestsrc delivers a
  # fixed number of buffers and the pipeline EOSes well inside the bound, so a
  # timeout or a signal here means the encoder never completed - unlike the
  # playback cases, where running until the bound is the intended behaviour.
  if [ "$gstRc" -ne 0 ]; then
    log_fail "$testname: FAIL (rc=$gstRc)"
    fail_count=$((fail_count + 1))
    return 1
  fi

  # Check for GStreamer errors in log
  if ! gstreamer_validate_log "$test_log" "$testname"; then
    log_fail "$testname: FAIL (GStreamer errors detected)"
    fail_count=$((fail_count + 1))
    return 1
  fi
  
  # Check if output file was created and has content
  if [ -f "$output_file" ] && [ -s "$output_file" ]; then
    file_size=$(gstreamer_file_size_bytes "$output_file")
    log_info "Encoded file: $output_file (size: $file_size bytes)"
    
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

# -------------------- Decode test function --------------------
run_decode_test() {
  codec="$1"
  resolution="$2"
  
  testname="decode_${codec}_${resolution}"
  log_info "=========================================="
  log_info "Running: $testname"
  log_info "=========================================="
  
  # Check if decoder is available
  decoder=$(gstreamer_v4l2_decoder_for_codec "$codec")
  probe_rc=$?
  if [ -z "$decoder" ]; then
    if gstreamer_probe_unhealthy "$probe_rc"; then
      log_fail "$testname: FAIL (decoder for $codec unusable: $(gstreamer_probe_reason "$probe_rc"))"
      fail_count=$((fail_count + 1))
      return 1
    fi
    log_warn "Decoder not available for $codec"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  ext=$(gstreamer_container_ext_for_codec "$codec")
  
  # For VP9, use WebM clip directly; for others, use encoded file
  if [ "$codec" = "vp9" ]; then
    input_file="$OUTDIR/VP9_640x480_10s.webm"
    if [ ! -f "$input_file" ]; then
      log_warn "VP9 WebM clip not found: $input_file"
      skip_count=$((skip_count + 1))
      return 1
    fi
  else
    input_file="$ENCODED_DIR/encode_${codec}_${resolution}.${ext}"
    if [ ! -f "$input_file" ]; then
      log_warn "Input file not found: $input_file (run encode first)"
      skip_count=$((skip_count + 1))
      return 1
    fi
  fi
  
  test_log="$OUTDIR/${testname}.log"
  : >"$test_log"
  
  # Build pipeline using library function
  pipeline=$(gstreamer_build_v4l2_decode_pipeline "$codec" "$input_file" "$detected_stack")
  
  if [ -z "$pipeline" ]; then
    log_fail "$testname: FAIL (could not build pipeline)"
    fail_count=$((fail_count + 1))
    return 1
  fi
  
  log_info "Pipeline: $pipeline"
  
  # Run decoding
  if gstreamer_run_gstlaunch_timeout "$((duration + 10))" "$pipeline" >>"$test_log" 2>&1; then
    gstRc=0
  else
    gstRc=$?
  fi
  
  log_info "Decode exit code: $gstRc"
  
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

# -------------------- Helper: Check display connection --------------------
check_display_connected() {
  # Check if a physical display is connected
  # Returns 0 if display is confirmed connected, 1 otherwise
  if ! command -v display_connected_summary >/dev/null 2>&1; then
    log_warn "display_connected_summary not available, cannot verify display connection"
    return 1
  fi
  
  display_status=$(display_connected_summary)
  if [ "$display_status" = "none" ] || [ -z "$display_status" ]; then
    log_warn "No display connected (status: ${display_status:-empty})"
    return 1
  fi
  
  log_info "Display connected: $display_status"
  return 0
}

# -------------------- UVC Live Preview Test --------------------
# Test: UVC_Live_Preview_1080p (PR76474)
run_uvc_preview_test() {
  testname="UVC_Live_Preview_1080p"
  log_info "=========================================="
  log_info "Running: $testname (PR76474)"
  log_info "=========================================="
  
  total_tests=$((total_tests + 1))
  
  # Check for required elements first (fast checks)
  if ! has_element v4l2src; then
    log_skip "$testname: v4l2src not available"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  if ! has_element waylandsink; then
    log_skip "$testname: waylandsink not available"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  # Detect UVC camera
  uvc_dev=$(gstreamer_detect_uvc_camera)
  if [ -z "$uvc_dev" ]; then
    log_skip "$testname: No UVC camera detected"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  log_info "UVC camera detected: $uvc_dev"
  
  # Check if display is connected (required for waylandsink)
  if ! check_display_connected; then
    log_skip "$testname: No display connected (required for waylandsink)"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  # Set up Wayland display using shared function
  if ! camera_setup_wayland_environment "uvc-preview"; then
    log_skip "$testname: Failed to set up Wayland environment"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  test_log="$OUTDIR/${testname}.log"
  : >"$test_log"
  
  # Build pipeline using library function
  pipeline=$(gstreamer_build_uvc_preview_pipeline "$uvc_dev" "1920" "1080" "5")
  
  if [ -z "$pipeline" ]; then
    log_fail "$testname: FAIL (could not build pipeline)"
    fail_count=$((fail_count + 1))
    return 1
  fi
  
  log_info "Pipeline: $pipeline"
  
  # Use run_pipeline_with_logs with extended validation
  if run_pipeline_with_logs "$testname" "$pipeline" "$OUTDIR" "$duration" "uvc" "1"; then
    pass_count=$((pass_count + 1))
    return 0
  else
    fail_count=$((fail_count + 1))
    return 1
  fi
}

# -------------------- DRC H.264 Decode Test --------------------
# Test: DRC_H264_Decode_1080p_720p (FR82787)
run_drc_decode_test() {
  testname="DRC_H264_Decode_1080p_720p"
  log_info "=========================================="
  log_info "Running: $testname (FR82787)"
  log_info "=========================================="
  
  total_tests=$((total_tests + 1))
  
  # Check for required elements first (fast checks)
  if ! has_element v4l2h264dec; then
    log_skip "$testname: v4l2h264dec not available"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  if ! has_element fpsdisplaysink; then
    log_skip "$testname: fpsdisplaysink not available"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  if ! has_element waylandsink; then
    log_skip "$testname: waylandsink not available"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  # Check for DRC test clip
  drc_clip="$OUTDIR/1080_720_h264.mp4"
  if [ ! -f "$drc_clip" ]; then
    if [ -n "$clipPath" ] && [ -f "$clipPath/1080_720_h264.mp4" ]; then
      cp "$clipPath/1080_720_h264.mp4" "$drc_clip"
    else
      log_skip "$testname: DRC test clip not found (1080_720_h264.mp4)"
      skip_count=$((skip_count + 1))
      return 1
    fi
  fi
  
  # Check if display is connected (required for waylandsink)
  if ! check_display_connected; then
    log_skip "$testname: No display connected (required for waylandsink)"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  # Set up Wayland display using shared function
  if ! camera_setup_wayland_environment "drc-test"; then
    log_skip "$testname: Failed to set up Wayland environment"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  test_log="$OUTDIR/${testname}.log"
  : >"$test_log"
  
  # Build pipeline using library function
  pipeline=$(gstreamer_build_drc_decode_pipeline "$drc_clip" "$detected_stack")
  
  if [ -z "$pipeline" ]; then
    log_fail "$testname: FAIL (could not build pipeline)"
    fail_count=$((fail_count + 1))
    return 1
  fi
  
  log_info "Pipeline: $pipeline"
  
  # Use run_pipeline_with_logs with extended validation
  if run_pipeline_with_logs "$testname" "$pipeline" "$OUTDIR" "$((duration + 10))" "drc" "1"; then
    pass_count=$((pass_count + 1))
    return 0
  else
    fail_count=$((fail_count + 1))
    return 1
  fi
}

# -------------------- H.264 Concurrency Decode Test --------------------
# Test: H264_Decode_Concurrency_8x480p (PR43865)
run_h264_concurrency_test() {
  testname="H264_Decode_Concurrency_8x480p"
  log_info "=========================================="
  log_info "Running: $testname (PR43865)"
  log_info "=========================================="
  
  total_tests=$((total_tests + 1))
  
  # Check for required elements first (fast checks)
  if ! has_element v4l2h264dec; then
    log_skip "$testname: v4l2h264dec not available"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  if ! has_element qtivcomposer; then
    log_skip "$testname: qtivcomposer not available"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  if ! has_element waylandsink; then
    log_skip "$testname: waylandsink not available"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  # Check for test clip
  h264_clip="$OUTDIR/H264_480p_30fps.mp4"
  if [ ! -f "$h264_clip" ]; then
    if [ -n "$clipPath" ] && [ -f "$clipPath/H264_480p_30fps.mp4" ]; then
      cp "$clipPath/H264_480p_30fps.mp4" "$h264_clip"
    else
      log_skip "$testname: Test clip not found (H264_480p_30fps.mp4)"
      skip_count=$((skip_count + 1))
      return 1
    fi
  fi
  
  # Set up Wayland display using shared function
  if ! camera_setup_wayland_environment "h264-concurrency"; then
    log_skip "$testname: Failed to set up Wayland environment"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  test_log="$OUTDIR/${testname}.log"
  : >"$test_log"
  
  # Increase file descriptor limit
  # shellcheck disable=SC3045  # ulimit -n is intentionally non-POSIX with fallback
  ulimit -n 4096 2>/dev/null || true
  
  # Build pipeline using library function (8 sessions for H.264)
  pipeline=$(gstreamer_build_concurrency_decode_pipeline "h264" "$h264_clip" "$detected_stack" "8")
  
  if [ -z "$pipeline" ]; then
    log_fail "$testname: FAIL (could not build pipeline)"
    fail_count=$((fail_count + 1))
    return 1
  fi
  
  log_info "Pipeline: gst-launch-1.0 -e $pipeline"
  
  # Use run_pipeline_with_logs with extended validation (8 sessions fixed)
  if run_pipeline_with_logs "$testname" "$pipeline" "$OUTDIR" "$((duration + 10))" "concurrency-h264" "8"; then
    log_pass "$testname: PASS (8 concurrent sessions)"
    pass_count=$((pass_count + 1))
    return 0
  else
    fail_count=$((fail_count + 1))
    return 1
  fi
}

# -------------------- H.265 Concurrency Decode Test --------------------
# Test: H265_Decode_Concurrency_8x480p (PR43866)
run_h265_concurrency_test() {
  testname="H265_Decode_Concurrency_8x480p"
  log_info "=========================================="
  log_info "Running: $testname (PR43866)"
  log_info "=========================================="
  
  total_tests=$((total_tests + 1))
  
  # Check for required elements first (fast checks)
  if ! has_element v4l2h265dec; then
    log_skip "$testname: v4l2h265dec not available"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  if ! has_element qtivcomposer; then
    log_skip "$testname: qtivcomposer not available"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  if ! has_element waylandsink; then
    log_skip "$testname: waylandsink not available"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  # Check for test clip
  h265_clip="$OUTDIR/H265_480p_30fps.mp4"
  if [ ! -f "$h265_clip" ]; then
    if [ -n "$clipPath" ] && [ -f "$clipPath/H265_480p_30fps.mp4" ]; then
      cp "$clipPath/H265_480p_30fps.mp4" "$h265_clip"
    else
      log_skip "$testname: Test clip not found (H265_480p_30fps.mp4)"
      skip_count=$((skip_count + 1))
      return 1
    fi
  fi
  
  # Check if display is connected (required for waylandsink)
  if ! check_display_connected; then
    log_skip "$testname: No display connected (required for waylandsink)"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  # Set up Wayland display using shared function
  if ! camera_setup_wayland_environment "h265-concurrency"; then
    log_skip "$testname: Failed to set up Wayland environment"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  test_log="$OUTDIR/${testname}.log"
  : >"$test_log"
  
  # Increase file descriptor limit
  # shellcheck disable=SC3045  # ulimit -n is intentionally non-POSIX with fallback
  ulimit -n 4096 2>/dev/null || true
  
  # Build pipeline using library function (8 sessions for H.265)
  pipeline=$(gstreamer_build_concurrency_decode_pipeline "h265" "$h265_clip" "$detected_stack" "8")
  
  if [ -z "$pipeline" ]; then
    log_fail "$testname: FAIL (could not build pipeline)"
    fail_count=$((fail_count + 1))
    return 1
  fi
  
  log_info "Pipeline: gst-launch-1.0 -e $pipeline"
  
  # Use run_pipeline_with_logs with extended validation (8 sessions fixed)
  if run_pipeline_with_logs "$testname" "$pipeline" "$OUTDIR" "$((duration + 10))" "concurrency-h265" "8"; then
    log_pass "$testname: PASS (8 concurrent sessions)"
    pass_count=$((pass_count + 1))
    return 0
  else
    fail_count=$((fail_count + 1))
    return 1
  fi
}

# -------------------- MJPEG Concurrency Decode Test --------------------
# Test: MJPEG_Decode_Concurrency_2x1080p (FR98277)
run_mjpeg_concurrency_test() {
  testname="MJPEG_Decode_Concurrency_2x1080p"
  log_info "=========================================="
  log_info "Running: $testname (FR98277)"
  log_info "=========================================="
  
  total_tests=$((total_tests + 1))
  
  # Check for required elements first (fast checks)
  if ! has_element jpegdec; then
    log_skip "$testname: jpegdec not available"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  if ! has_element qtivcomposer; then
    log_skip "$testname: qtivcomposer not available"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  if ! has_element waylandsink; then
    log_skip "$testname: waylandsink not available"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  # Check for test clip
  mjpeg_clip="$OUTDIR/mjpeg1.avi"
  if [ ! -f "$mjpeg_clip" ]; then
    if [ -n "$clipPath" ] && [ -f "$clipPath/mjpeg1.avi" ]; then
      cp "$clipPath/mjpeg1.avi" "$mjpeg_clip"
    else
      log_skip "$testname: Test clip not found (mjpeg1.avi)"
      skip_count=$((skip_count + 1))
      return 1
    fi
  fi
  
  # Check if display is connected (required for waylandsink)
  if ! check_display_connected; then
    log_skip "$testname: No display connected (required for waylandsink)"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  # Set up Wayland display using shared function
  if ! camera_setup_wayland_environment "mjpeg-concurrency"; then
    log_skip "$testname: Failed to set up Wayland environment"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  test_log="$OUTDIR/${testname}.log"
  : >"$test_log"
  
  # Build pipeline using library function (2 sessions for MJPEG)
  pipeline=$(gstreamer_build_concurrency_decode_pipeline "mjpeg" "$mjpeg_clip" "$detected_stack" "2")
  
  if [ -z "$pipeline" ]; then
    log_fail "$testname: FAIL (could not build pipeline)"
    fail_count=$((fail_count + 1))
    return 1
  fi
  
  log_info "Pipeline: gst-launch-1.0 -e $pipeline"
  
  # Use run_pipeline_with_logs with extended validation (2 sessions)
  if run_pipeline_with_logs "$testname" "$pipeline" "$OUTDIR" "$((duration + 10))" "concurrency-mjpeg" "2"; then
    log_pass "$testname: PASS (2 concurrent sessions)"
    pass_count=$((pass_count + 1))
    return 0
  else
    fail_count=$((fail_count + 1))
    return 1
  fi
}

# -------------------- HEVC Smart Encode Test --------------------
# Test: HEVC_Encode_Smart_Bitrate_FPS_720p (FR74943) - Downstream only
run_smart_encode_test() {
  testname="HEVC_Encode_Smart_Bitrate_FPS_720p"
  log_info "=========================================="
  log_info "Running: $testname (FR74943)"
  log_info "=========================================="
  
  total_tests=$((total_tests + 1))
  
  # Check if downstream stack
  if ! gstreamer_is_downstream_stack; then
    log_skip "$testname: Requires downstream video driver (Config2)"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  # Check for required elements
  if ! has_element qtiqmmfsrc; then
    log_skip "$testname: qtiqmmfsrc not available (camera source required)"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  if ! has_element qtismartvencbin; then
    log_skip "$testname: qtismartvencbin not available"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  test_log="$OUTDIR/${testname}.log"
  output_file="$ENCODED_DIR/${testname}.mp4"
  
  # Remove output file before encoding to ensure fresh file
  rm -f "$output_file"
  : >"$test_log"
  
  # Build pipeline using shared helper function
  pipeline=$(gstreamer_build_smart_encode_pipeline "$output_file")
  
  if [ -z "$pipeline" ]; then
    log_fail "$testname: FAIL (could not build pipeline)"
    fail_count=$((fail_count + 1))
    return 1
  fi
  
  log_info "Pipeline: $pipeline"
  
  # Run encoding
  if gstreamer_run_gstlaunch_timeout "$((duration + 10))" "$pipeline" >>"$test_log" 2>&1; then
    gstRc=0
  else
    gstRc=$?
  fi
  
  log_info "Exit code: $gstRc"
  
  # Validate log
  if ! gstreamer_validate_log "$test_log" "$testname"; then
    log_fail "$testname: FAIL (GStreamer errors detected)"
    fail_count=$((fail_count + 1))
    return 1
  fi
  
  # Comprehensive validation using shared helper
  if gstreamer_validate_encode_output "$testname" "$output_file" "$gstRc" "h265" "1280" "720" "$duration"; then
    log_pass "$testname: PASS"
    pass_count=$((pass_count + 1))
    return 0
  else
    fail_count=$((fail_count + 1))
    return 1
  fi
}

# -------------------- HEVC Cyclic IR Encode Test --------------------
# Test: HEVC_Encode_1080p_Cyclic_IR (FR82773) - Downstream only
run_cyclic_ir_encode_test() {
  testname="HEVC_Encode_1080p_Cyclic_IR"
  log_info "=========================================="
  log_info "Running: $testname (FR82773)"
  log_info "=========================================="
  
  total_tests=$((total_tests + 1))
  
  # Check if downstream stack
  if ! gstreamer_is_downstream_stack; then
    log_skip "$testname: Requires downstream video driver (Config2)"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  # Check for required elements
  if ! has_element qtiqmmfsrc; then
    log_skip "$testname: qtiqmmfsrc not available (camera source required)"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  if ! has_element v4l2h265enc; then
    log_skip "$testname: v4l2h265enc not available"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  test_log="$OUTDIR/${testname}.log"
  output_file="$ENCODED_DIR/${testname}.mp4"
  
  # Remove output file before encoding to ensure fresh file
  rm -f "$output_file"
  : >"$test_log"
  
  # Build pipeline using shared helper function with cyclic intra refresh controls
  # 1080p (1920x1080) with CBR mode, intra refresh period=20, and comprehensive QP controls
  pipeline=$(gstreamer_build_camera_encode_pipeline \
    "h265" "1920" "1080" "$output_file" \
    "controls,intra_refresh_period_type=1,intra_refresh_period=20,video_bitrate_mode=1,video_bitrate=5000000,hevc_minimum_qp_value=10,hevc_maximum_qp_value=51,hevc_i_frame_qp_value=27,hevc_b_frame_qp_value=28,hevc_p_frame_qp_value=28,hevc_i_frame_minimum_qp_value=10,hevc_i_frame_maximum_qp_value=51,hevc_p_frame_minimum_qp_value=10,hevc_p_frame_maximum_qp_value=51,hevc_b_frame_minimum_qp_value=10,hevc_b_frame_maximum_qp_value=51,video_gop_size=29" \
    "$detected_stack")
  
  if [ -z "$pipeline" ]; then
    log_fail "$testname: FAIL (could not build pipeline)"
    fail_count=$((fail_count + 1))
    return 1
  fi
  
  log_info "Pipeline: $pipeline"
  
  # Run encoding
  if gstreamer_run_gstlaunch_timeout "$((duration + 10))" "$pipeline" >>"$test_log" 2>&1; then
    gstRc=0
  else
    gstRc=$?
  fi
  
  log_info "Exit code: $gstRc"
  
  # Validate log
  if ! gstreamer_validate_log "$test_log" "$testname"; then
    log_fail "$testname: FAIL (GStreamer errors detected)"
    fail_count=$((fail_count + 1))
    return 1
  fi
  
  # Comprehensive validation using shared helper (validates output as 1920x1080)
  if gstreamer_validate_encode_output "$testname" "$output_file" "$gstRc" "h265" "1920" "1080" "$duration"; then
    log_pass "$testname: PASS"
    pass_count=$((pass_count + 1))
    return 0
  else
    fail_count=$((fail_count + 1))
    return 1
  fi
}

# -------------------- H.264 Slice MB Encode Test --------------------
# Test: H264_Encode_Slice_MB_VGA (FR82771) - Downstream only
run_slice_mb_encode_test() {
  testname="H264_Encode_Slice_MB_VGA"
  log_info "=========================================="
  log_info "Running: $testname (FR82771)"
  log_info "=========================================="
  
  total_tests=$((total_tests + 1))
  
  # Check if downstream stack
  if ! gstreamer_is_downstream_stack; then
    log_skip "$testname: Requires downstream video driver (Config2)"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  # Check for required elements
  if ! has_element qtiqmmfsrc; then
    log_skip "$testname: qtiqmmfsrc not available (camera source required)"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  if ! has_element v4l2h264enc; then
    log_skip "$testname: v4l2h264enc not available"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  test_log="$OUTDIR/${testname}.log"
  output_file="$ENCODED_DIR/${testname}.mp4"
  
  # Remove output file before encoding to ensure fresh file
  rm -f "$output_file"
  : >"$test_log"
  
  # Build pipeline using shared helper function with slice MB controls
  pipeline=$(gstreamer_build_camera_encode_pipeline \
    "h264" "640" "480" "$output_file" \
    "controls,video_bitrate=1000000,slice_partitioning_method=1,number_of_mbs_in_a_slice=368" \
    "$detected_stack")
  
  if [ -z "$pipeline" ]; then
    log_fail "$testname: FAIL (could not build pipeline)"
    fail_count=$((fail_count + 1))
    return 1
  fi
  
  log_info "Pipeline: $pipeline"
  
  # Run encoding
  if gstreamer_run_gstlaunch_timeout "$((duration + 10))" "$pipeline" >>"$test_log" 2>&1; then
    gstRc=0
  else
    gstRc=$?
  fi
  
  log_info "Exit code: $gstRc"
  
  # Validate log
  if ! gstreamer_validate_log "$test_log" "$testname"; then
    log_fail "$testname: FAIL (GStreamer errors detected)"
    fail_count=$((fail_count + 1))
    return 1
  fi
  
  # Comprehensive validation using shared helper
  if gstreamer_validate_encode_output "$testname" "$output_file" "$gstRc" "h264" "640" "480" "$duration"; then
    log_pass "$testname: PASS"
    pass_count=$((pass_count + 1))
    return 0
  else
    fail_count=$((fail_count + 1))
    return 1
  fi
}

# -------------------- HEVC 1080p Rotate90 Encode Test --------------------
# Test: HEVC_Encode_1080p_Rotate90 (FR72846)
run_rotate_encode_test() {
  testname="HEVC_Encode_1080p_Rotate90"
  log_info "=========================================="
  log_info "Running: $testname (FR72846)"
  log_info "=========================================="
  
  total_tests=$((total_tests + 1))
  
  # Check for required elements
  if ! has_element qtiqmmfsrc; then
    log_skip "$testname: qtiqmmfsrc not available (camera source required)"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  if ! has_element v4l2h265enc; then
    log_skip "$testname: v4l2h265enc not available"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  # Rotation control requires downstream stack
  if [ "$detected_stack" != "downstream" ]; then
    log_skip "$testname: rotate=90 control is unavailable on this stack"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  test_log="$OUTDIR/${testname}.log"
  output_file="$ENCODED_DIR/${testname}.mp4"
  
  # Remove output file before encoding to ensure fresh file
  rm -f "$output_file"
  : >"$test_log"
  
  # Build pipeline using shared helper function with rotation control and extended QP parameters
  # Updated to 1080p (1920x1080) with VBR mode and comprehensive QP controls
  pipeline=$(gstreamer_build_camera_encode_pipeline \
    "h265" "1920" "1080" "$output_file" \
    "controls,rotate=90,video_bitrate_mode=0,video_bitrate=2200000,hevc_minimum_qp_value=10,hevc_maximum_qp_value=51,hevc_i_frame_qp_value=27,hevc_b_frame_qp_value=28,hevc_p_frame_qp_value=28,hevc_i_frame_minimum_qp_value=10,hevc_i_frame_maximum_qp_value=51,hevc_p_frame_minimum_qp_value=10,hevc_p_frame_maximum_qp_value=51,hevc_b_frame_minimum_qp_value=10,hevc_b_frame_maximum_qp_value=51,video_gop_size=29" \
    "$detected_stack")
  
  if [ -z "$pipeline" ]; then
    log_fail "$testname: FAIL (could not build pipeline)"
    fail_count=$((fail_count + 1))
    return 1
  fi
  
  log_info "Pipeline: $pipeline"
  
  # Run encoding
  if gstreamer_run_gstlaunch_timeout "$((duration + 10))" "$pipeline" >>"$test_log" 2>&1; then
    gstRc=0
  else
    gstRc=$?
  fi
  
  log_info "Exit code: $gstRc"
  
  # Validate log
  if ! gstreamer_validate_log "$test_log" "$testname"; then
    log_fail "$testname: FAIL (GStreamer errors detected)"
    fail_count=$((fail_count + 1))
    return 1
  fi
  
  # Verify rotation using shared helper (90° rotation should swap dimensions: 1920x1080 → 1080x1920)
  # This validates BOTH rotation AND output quality (codec, container, duration, etc.)
  if ! gstreamer_verify_rotation "$testname" "$output_file" "1920" "1080" "90"; then
    fail_count=$((fail_count + 1))
    return 1
  fi
  
  # Comprehensive validation using shared helper with ROTATED dimensions (1080x1920)
  if gstreamer_validate_encode_output "$testname" "$output_file" "$gstRc" "h265" "1080" "1920" "$duration"; then
    log_pass "$testname: PASS (with rotation verified)"
    pass_count=$((pass_count + 1))
    return 0
  else
    fail_count=$((fail_count + 1))
    return 1
  fi
}

# -------------------- Parse codec and resolution lists --------------------
codecs=$(printf '%s' "$codecList" | tr ',' ' ')
resolutions=$(printf '%s' "$resolutionList" | tr ',' ' ')

# -------------------- Helper: Get test clip --------------------
get_test_clip() {
  clip_name="$1"
  dest_path="$2"
  
  # Check if clip already exists
  if [ -f "$dest_path" ]; then
    log_info "Clip already exists: $clip_name"
    return 0
  fi
  
  # Try to get from provided local path first
  if [ -n "$clipPath" ] && [ -f "$clipPath/$clip_name" ]; then
    log_info "Copying $clip_name from local path: $clipPath"
    if cp "$clipPath/$clip_name" "$dest_path"; then
      log_info "Successfully copied $clip_name"
      return 0
    else
      log_warn "Failed to copy $clip_name from local path"
    fi
  fi
  
  # Try to download from URL
  log_info "Attempting to download $clip_name from URL..."
  if extract_tar_from_url "$clipUrl" "$OUTDIR"; then
    # Check if file was extracted
    if [ -f "$clip_name" ]; then
      mv "$clip_name" "$dest_path"
      log_info "Successfully downloaded and moved $clip_name"
      return 0
    elif [ -f "$OUTDIR/$clip_name" ]; then
      log_info "Clip $clip_name already in correct location"
      return 0
    else
      log_warn "Clip $clip_name not found in downloaded content"
      return 1
    fi
  else
    log_warn "Download failed for $clip_name (offline or URL issue)"
    return 1
  fi
}

# -------------------- Prepare basic clips --------------------
prepare_basic_clips() {
  log_info "=========================================="
  log_info "PREPARING BASIC TEST CLIPS"
  log_info "=========================================="
  
  # VP9 clip for basic decode tests
  need_vp9_clip=0
  for codec in $codecs; do
    if [ "$codec" = "vp9" ]; then
      need_vp9_clip=1
      break
    fi
  done
  
  if [ "$need_vp9_clip" -eq 1 ] && [ "$testMode" != "encode" ]; then
    get_test_clip "VP9_640x480_10s.webm" "$OUTDIR/VP9_640x480_10s.webm"
  fi
  
  log_info "Basic clip preparation complete"
}

# -------------------- Prepare advanced clips --------------------
prepare_advanced_clips() {
  log_info "=========================================="
  log_info "PREPARING ADVANCED TEST CLIPS"
  log_info "=========================================="
  
  # DRC test clip
  get_test_clip "1080_720_h264.mp4" "$OUTDIR/1080_720_h264.mp4"
  
  # Concurrency test clips
  get_test_clip "H264_480p_30fps.mp4" "$OUTDIR/H264_480p_30fps.mp4"
  get_test_clip "H265_480p_30fps.mp4" "$OUTDIR/H265_480p_30fps.mp4"
  get_test_clip "mjpeg1.avi" "$OUTDIR/mjpeg1.avi"
  
  log_info "Advanced clip preparation complete"
}

# -------------------- Run basic tests --------------------
run_basic_tests() {
  log_info "=========================================="
  log_info "RUNNING BASIC ENCODE/DECODE TESTS"
  log_info "=========================================="
  
  # Run encode tests (skip VP9 as it doesn't support encoding in this test)
  if [ "$testMode" = "all" ] || [ "$testMode" = "encode" ]; then
    log_info "=========================================="
    log_info "ENCODE TESTS"
    log_info "=========================================="
    
    for codec in $codecs; do
      # Skip VP9 for encode tests (no v4l2vp9enc support in this test)
      if [ "$codec" = "vp9" ]; then
        log_info "Skipping VP9 encode (not supported)"
        continue
      fi
      
      for res in $resolutions; do
        params=$(gstreamer_resolution_to_wh "$res")

        # ---------------- FIX: robust split independent of IFS ----------------
        width=$(printf '%s\n' "$params" | awk '{print $1}')
        height=$(printf '%s\n' "$params" | awk '{print $2}')
        case "$width" in ''|*[!0-9]*) width="640" ;; esac
        case "$height" in ''|*[!0-9]*) height="480" ;; esac
        # ---------------------------------------------------------------------

        total_tests=$((total_tests + 1))
        run_encode_test "$codec" "$res" "$width" "$height" || true
      done
    done
  fi

  # Run decode tests
  if [ "$testMode" = "all" ] || [ "$testMode" = "decode" ]; then
    log_info "=========================================="
    log_info "DECODE TESTS"
    log_info "=========================================="
    
    for codec in $codecs; do
      if [ "$codec" = "vp9" ]; then
        total_tests=$((total_tests + 1))
        run_decode_test "$codec" "480p" || true
      else
        for res in $resolutions; do
          total_tests=$((total_tests + 1))
          run_decode_test "$codec" "$res" || true
        done
      fi
    done
  fi
}

# -------------------- Run advanced tests --------------------
run_advanced_tests() {
  log_info "=========================================="
  log_info "RUNNING ADVANCED TESTS"
  log_info "=========================================="
  
  # Run UVC test (no mode restriction - it's a preview test)
  log_info "Will run: UVC camera test"
  run_uvc_preview_test || true
  
  # Run DRC test (decode only)
  if [ "$testMode" = "all" ] || [ "$testMode" = "decode" ]; then
    log_info "Will run: DRC decode test"
    run_drc_decode_test || true
    
    # Run concurrency tests (decode only)
    log_info "Will run: Concurrency decode tests"
    run_h264_concurrency_test || true
    run_h265_concurrency_test || true
    run_mjpeg_concurrency_test || true
  fi
  
  # Run advanced encode tests (encode only)
  if [ "$testMode" = "all" ] || [ "$testMode" = "encode" ]; then
    log_info "Will run: Advanced encode tests"
    run_smart_encode_test || true
    run_cyclic_ir_encode_test || true
    run_slice_mb_encode_test || true
    run_rotate_encode_test || true
  fi
}

# -------------------- Main test execution --------------------
log_info "=========================================="
log_info "STARTING TEST EXECUTION"
log_info "=========================================="
log_info "Test type: $testType, Mode: $testMode"

# Route to appropriate test based on test type
case "$testType" in
  basic|all)
    # Prepare and run basic tests
    prepare_basic_clips
    run_basic_tests
    
    # If test type is 'all', prepare and run advanced tests too
    if [ "$testType" = "all" ]; then
      prepare_advanced_clips
      run_advanced_tests
    fi
    ;;
    
  uvc)
    # Run only UVC test (no clips needed)
    log_info "Running UVC camera test only"
    run_uvc_preview_test
    ;;
    
  drc)
    # Prepare DRC clip and run test
    log_info "Running DRC decode test only"
    get_test_clip "1080_720_h264.mp4" "$OUTDIR/1080_720_h264.mp4"
    run_drc_decode_test
    ;;
    
  concurrency)
    # Prepare concurrency clips and run tests
    log_info "Running concurrency decode tests only"
    get_test_clip "H264_480p_30fps.mp4" "$OUTDIR/H264_480p_30fps.mp4"
    get_test_clip "H265_480p_30fps.mp4" "$OUTDIR/H265_480p_30fps.mp4"
    get_test_clip "mjpeg1.avi" "$OUTDIR/mjpeg1.avi"
    run_h264_concurrency_test
    run_h265_concurrency_test
    run_mjpeg_concurrency_test
    ;;
    
  advanced-encode)
    # Run only advanced encoding tests (no clips needed - uses camera)
    log_info "Running advanced encode tests only"
    run_smart_encode_test
    run_cyclic_ir_encode_test
    run_slice_mb_encode_test
    run_rotate_encode_test
    ;;
    
  *)
    log_warn "Unknown test type: $testType"
    echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
    exit 0
    ;;
esac

# -------------------- Dmesg error scan --------------------
log_info "=========================================="
log_info "DMESG ERROR SCAN"
log_info "=========================================="

# Report from the run's single dmesg capture rather than re-reading the live
# buffer. gstreamer_codec_dmesg_snapshot() takes it the first time a codec is
# classified and is a no-op afterwards, so the errors reported here are the same
# evidence the codec verdicts were based on.
if gstreamer_codec_dmesg_snapshot >/dev/null 2>&1; then
  log_info "dmesg snapshot: $DMESG_DIR/dmesg_snapshot.log"
  if [ -s "$DMESG_DIR/dmesg_errors.log" ]; then
    log_warn "dmesg scan found video-related warnings or errors in $DMESG_DIR/dmesg_errors.log"
  else
    log_info "No relevant video-related errors found in dmesg"
  fi
else
  log_info "dmesg snapshot unavailable, skipping dmesg scan"
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
