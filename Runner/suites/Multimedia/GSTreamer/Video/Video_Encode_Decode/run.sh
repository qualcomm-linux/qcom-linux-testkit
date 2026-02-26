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
RES_FILE="${SCRIPT_DIR}/${TESTNAME}.res"
LOG_DIR="${SCRIPT_DIR}/logs"
OUTDIR="$LOG_DIR/$TESTNAME"
GST_LOG="$OUTDIR/gst.log"
DMESG_DIR="$OUTDIR/dmesg"
ENCODED_DIR="$OUTDIR/encoded"

mkdir -p "$OUTDIR" "$DMESG_DIR" "$ENCODED_DIR" >/dev/null 2>&1 || true
: >"$RES_FILE"
: >"$GST_LOG"

SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"
 
INIT_ENV=""
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
  if [ -f "$SEARCH/init_env" ]; then
    INIT_ENV="$SEARCH/init_env"
    break
  fi
  SEARCH=$(dirname "$SEARCH")
done
 
RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"
 
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

# shellcheck disable=SC1091
[ -f "$TOOLS/lib_video.sh" ] && . "$TOOLS/lib_video.sh"

result="FAIL"
reason="unknown"
pass_count=0
fail_count=0
skip_count=0
total_tests=0

# -------------------- Defaults (LAVA env vars -> defaults; CLI overrides) --------------------
testMode="${VIDEO_TEST_MODE:-all}"
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

cleanup() {
  pkill -x gst-launch-1.0 >/dev/null 2>&1 || true
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
      # If empty, keep default; otherwise use provided value
      [ -n "$2" ] && testMode="$2"
      shift 2
      ;;

    --codecs)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --codecs"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      # If empty, keep default; otherwise use provided value
      [ -n "$2" ] && codecList="$2"
      shift 2
      ;;

    --resolutions)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --resolutions"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      # If empty, keep default; otherwise use provided value
      [ -n "$2" ] && resolutionList="$2"
      shift 2
      ;;

    --duration)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --duration"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      # If empty or non-numeric, keep default; otherwise use provided value
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

    --framerate)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --framerate"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      if [ -n "$2" ]; then
        case "$2" in
          ''|*[!0-9]*) 
            log_warn "Invalid --framerate '$2' (must be numeric)"
            echo "$TESTNAME SKIP" >"$RES_FILE"
            exit 0
            ;;
          *)
            if [ "$2" -le 0 ] 2>/dev/null; then
              log_warn "Framerate must be positive (got '$2')"
              echo "$TESTNAME SKIP" >"$RES_FILE"
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
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      # If empty, keep default; otherwise use provided value
      [ -n "$2" ] && videoStack="$2"
      shift 2
      ;;

    --gst-debug)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --gst-debug"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      # If empty, keep default; otherwise use provided value
      [ -n "$2" ] && gstDebugLevel="$2"
      shift 2
      ;;

    --clip-url)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --clip-url"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      # If empty, keep default; otherwise use provided value
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
      echo "$TESTNAME SKIP" >"$RES_FILE"
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
case "$testMode" in all|encode|decode) : ;; *)
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

case "$framerate" in
  ''|*[!0-9]*) 
    log_warn "Invalid framerate '$framerate' (must be numeric)"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
    ;;
  *)
    if [ "$framerate" -le 0 ] 2>/dev/null; then
      log_warn "Framerate must be positive (got '$framerate')"
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
log_info "Codecs: $codecList"
log_info "Resolutions: $resolutionList"
log_info "Duration: ${duration}s, Framerate: ${framerate}fps"
log_info "GST debug: GST_DEBUG=$gstDebugLevel"
log_info "Logs: $OUTDIR"
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
  if [ -z "$encoder" ]; then
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
  
  # Run encoding
  if gstreamer_run_gstlaunch_timeout "$((duration + 10))" "$pipeline" >>"$test_log" 2>&1; then
    gstRc=0
  else
    gstRc=$?
  fi
  
  log_info "Encode exit code: $gstRc"
  
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
  if [ -z "$decoder" ]; then
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

# -------------------- Main test execution --------------------
log_info "Starting video encode/decode tests..."

# Parse codec list
codecs=$(printf '%s' "$codecList" | tr ',' ' ')

# Parse resolution list
resolutions=$(printf '%s' "$resolutionList" | tr ',' ' ')

# -------------------- VP9 clip prep --------------------
need_vp9_clip=0
for codec in $codecs; do
  if [ "$codec" = "vp9" ]; then
    need_vp9_clip=1
    break
  fi
done

if [ "$need_vp9_clip" -eq 1 ] && [ "$testMode" != "encode" ]; then
  log_info "=========================================="
  log_info "VP9 CLIP PREP"
  log_info "=========================================="
  
  vp9_clip_webm="$OUTDIR/VP9_640x480_10s.webm"
  
  # Check if WebM file already exists
  if [ -f "$vp9_clip_webm" ]; then
    log_info "VP9 WebM clip already exists: $vp9_clip_webm"
  else
    # Try to get WebM file from provided path or URL
    if [ -n "$clipPath" ]; then
      log_info "Attempting to get VP9 WebM clip from local path: $clipPath"
      if [ -f "$clipPath/VP9_640x480_10s.webm" ]; then
        cp "$clipPath/VP9_640x480_10s.webm" "$vp9_clip_webm"
        log_info "VP9 WebM clip copied from local path"
      else
        log_warn "VP9 WebM clip not found in local path: $clipPath"
      fi
    fi

    # If not found locally, try URL download
    if [ ! -f "$vp9_clip_webm" ]; then
      log_info "VP9 WebM clip not found locally; attempting download from URL..."
      if extract_tar_from_url "$clipUrl" "$OUTDIR"; then
        # Move the extracted file from current directory to OUTDIR
        if [ -f "VP9_640x480_10s.webm" ]; then
          mv "VP9_640x480_10s.webm" "$vp9_clip_webm"
          log_pass "VP9 WebM clip downloaded and moved successfully"
        else
          log_warn "VP9 WebM clip not found in downloaded content"
        fi
      else
        log_warn "VP9 WebM clip download failed (offline or URL issue)"
      fi
    fi
  fi
fi

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

# -------------------- Dmesg error scan --------------------
log_info "=========================================="
log_info "DMESG ERROR SCAN"
log_info "=========================================="

# Scan for video-related errors in dmesg
module_regex="venus|vcodec|v4l2|video|gstreamer"
exclude_regex="dummy regulator|supply [^ ]+ not found|using dummy regulator"

if command -v scan_dmesg_errors >/dev/null 2>&1; then
  scan_dmesg_errors "$DMESG_DIR" "$module_regex" "$exclude_regex" || true
  
  if [ -s "$DMESG_DIR/dmesg_errors.log" ]; then
    log_warn "dmesg scan found video-related warnings or errors in $DMESG_DIR/dmesg_errors.log"
  else
    log_info "No relevant video-related errors found in dmesg"
  fi
else
  log_info "scan_dmesg_errors not available, skipping dmesg scan"
fi

# -------------------- Summary --------------------
log_info "=========================================="
log_info "TEST SUMMARY"
log_info "=========================================="
# Calculate actual total for display (sum of pass/fail/skip)
actual_total=$((pass_count + fail_count + skip_count))
log_info "Total testcases: $actual_total"
log_info "Passed: $pass_count"
log_info "Failed: $fail_count"
log_info "Skipped: $skip_count"

# -------------------- Emit result --------------------
if [ "$fail_count" -eq 0 ] && [ "$pass_count" -gt 0 ]; then
  result="PASS"
  if [ "$skip_count" -gt 0 ]; then
    reason="No failures (passed: $pass_count, failed: $fail_count, skipped: $skip_count, total: $actual_total)"
  else
    reason="All tests passed ($pass_count/$actual_total)"
  fi
elif [ "$fail_count" -gt 0 ]; then
  result="FAIL"
  reason="Some tests failed (passed: $pass_count, failed: $fail_count, skipped: $skip_count, total: $actual_total)"
else
  result="SKIP"
  reason="No tests passed (skipped: $skip_count, total: $actual_total)"
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
