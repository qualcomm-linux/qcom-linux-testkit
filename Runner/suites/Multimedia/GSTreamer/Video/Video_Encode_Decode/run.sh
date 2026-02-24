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
  exit 0
fi

# shellcheck disable=SC1090
. "$INIT_ENV"

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
codecList="${VIDEO_CODECS:-h264,h265}"
resolutionList="${VIDEO_RESOLUTIONS:-480p,4k}"
duration="${VIDEO_DURATION:-${RUNTIMESEC:-30}}"
framerate="${VIDEO_FRAMERATE:-30}"
gstDebugLevel="${VIDEO_GST_DEBUG:-${GST_DEBUG_LEVEL:-2}}"
videoStack="${VIDEO_STACK:-auto}"
clipUrl="${VIDEO_CLIP_URL:-https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/IRIS-Video-Files-v1.0/video_clips_iris.tar.gz}"

# Validate environment variables if set
# Validate numeric parameters
for param in VIDEO_DURATION RUNTIMESEC VIDEO_FRAMERATE VIDEO_GST_DEBUG GST_DEBUG_LEVEL; do
  val="${!param:-}"
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
      if [ -n "$2" ] && ! is_u32 "$2"; then
        log_warn "Invalid --framerate '$2' (must be numeric)"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
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

    -h|--help)
      cat <<EOF
Usage:
  $0 [options]

Options:
  --mode <all|encode|decode>
      Default: all (run both encode and decode tests)

  --codecs <h264,h265,vp9>
      Comma-separated list of codecs to test
      Default: h264,h265,vp9
      Note: VP9 only supports decode mode with pre-existing clips

  --resolutions <480p,4k>
      Comma-separated list of resolutions to test
      Default: 480p,4k (480p=640x480, 4k=3840x2160)

  --duration <seconds>
      Duration for encoding (in seconds)
      Default: ${duration}

  --framerate <fps>
      Framerate for video generation
      Default: ${framerate}

  --stack <auto|upstream|downstream>
      Video stack selection
      Default: auto

    --gst-debug <level>
      Sets GST_DEBUG=<level> (1-9)
      Default: ${gstDebugLevel}

    --clip-url <url>
      URL to download video clips for VP9 decode tests
      Default: ${clipUrl}

Examples:
  # Run all tests (encode + decode) for H264 and H265 at 480p and 4K
  ./run.sh

  # Run only encoding tests
  ./run.sh --mode encode

  # Run only H264 tests at 480p
  ./run.sh --codecs h264 --resolutions 480p

  # Run with 10 second duration
  ./run.sh --duration 10

  # Run VP9 decode test
  ./run.sh --mode decode --codecs vp9

EOF
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
check_dependencies "gst-launch-1.0 gst-inspect-1.0 awk grep head sed tr stat find curl" >/dev/null 2>&1 || {
  log_skip "Missing required tools (gst-launch-1.0, gst-inspect-1.0, awk, grep, head, sed, tr, stat, find, curl)"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
}

log_info "Test: $TESTNAME"
log_info "Mode: $testMode"
log_info "Codecs: $codecList"
log_info "Resolutions: $resolutionList"
log_info "Duration: ${duration}s, Framerate: ${framerate}fps"
log_info "GST debug: GST_DEBUG=$gstDebugLevel"
log_info "Logs: $OUTDIR"

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
  
  # For VP9, use pre-downloaded and converted WebM clip; for others, use encoded file
  if [ "$codec" = "vp9" ]; then
    input_file="$OUTDIR/vp9_test_320p.webm"
    if [ ! -f "$input_file" ]; then
      log_warn "VP9 WebM clip not found: $input_file (conversion may have failed)"
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

# -------------------- VP9 clip download (if VP9 in codec list) --------------------
need_vp9_clip=0
for codec in $codecs; do
  if [ "$codec" = "vp9" ]; then
    need_vp9_clip=1
    break
  fi
done

if [ "$need_vp9_clip" -eq 1 ] && [ "$testMode" != "encode" ]; then
  log_info "=========================================="
  log_info "VP9 CLIP DOWNLOAD & CONVERSION"
  log_info "=========================================="
  
  vp9_clip_ivf="$OUTDIR/320_240_10fps.ivf"
  vp9_clip_webm="$OUTDIR/vp9_test_320p.webm"
  
  # Check if WebM file already exists
  if [ -f "$vp9_clip_webm" ]; then
    log_info "VP9 WebM clip already exists: $vp9_clip_webm"
  else
    # Download IVF file if not present
    if [ ! -f "$vp9_clip_ivf" ]; then
      log_info "Checking network connectivity and downloading VP9 clips..."
      
      # Check network status first
      net_rc=1
      if command -v check_network_status_rc >/dev/null 2>&1; then
        check_network_status_rc
        net_rc=$?
      elif command -v check_network_status >/dev/null 2>&1; then
        check_network_status >/dev/null 2>&1
        net_rc=$?
      fi
      
      # If offline, try to bring network online
      if [ "$net_rc" -ne 0 ]; then
        if command -v bring_network_online >/dev/null 2>&1; then
          log_info "Attempting to bring network online..."
          bring_network_online
          # Stabilization sleep after bringing network up
          sleep 5
        else
          log_warn "Could not establish network connectivity"
        fi
      else
        log_info "Network already online"
        # Brief stabilization sleep
        sleep 2
      fi
    
      # Attempt download if we have connectivity
      if command -v check_network_status_rc >/dev/null 2>&1; then
        if check_network_status_rc; then
          log_info "Downloading VP9 clips from: $clipUrl"
          if extract_tar_from_url "$clipUrl" "$OUTDIR"; then
            log_pass "VP9 clips downloaded and extracted successfully"
          else
            log_warn "Failed to download/extract VP9 clips (network online but download failed)"
          fi
        else
          log_warn "Network still offline after connectivity attempt"
        fi
      else
        # Fallback: attempt download without explicit network check
        log_info "Downloading VP9 clips from: $clipUrl"
        if extract_tar_from_url "$clipUrl" "$OUTDIR"; then
          log_pass "VP9 clips downloaded and extracted successfully"
        else
          log_warn "Failed to download/extract VP9 clips"
        fi
      fi
    fi
    
    # Verify clip exists after download attempt (robust: locate *.ivf if tar has subdirs)
    if [ ! -f "$vp9_clip_ivf" ]; then
      found_ivf=$(find "$OUTDIR" -type f -name '*.ivf' 2>/dev/null | head -n 1 || true)
      if [ -n "$found_ivf" ]; then
        log_info "Found IVF clip: $found_ivf"
        cp "$found_ivf" "$vp9_clip_ivf" 2>/dev/null || true
      fi
    fi

    if [ ! -f "$vp9_clip_ivf" ]; then
      log_warn "VP9 clip not found after download attempt: $vp9_clip_ivf"
      log_warn "VP9 decode tests will be skipped"
      skip_count=$((skip_count + 1))
    else
      # Convert IVF to WebM container using GStreamer for better compatibility
      if [ ! -f "$vp9_clip_webm" ]; then
        log_info "Converting IVF to WebM container using GStreamer..."

        mux=""
        if has_element webmmux; then
          mux="webmmux"
        elif has_element matroskamux; then
          mux="matroskamux"
        fi

        if ! has_element ivfparse || [ -z "$mux" ]; then
          log_warn "Missing ivfparse or muxer (webmmux/matroskamux); VP9 decode tests will be skipped"
          rm -f "$vp9_clip_webm" 2>/dev/null || true
          skip_count=$((skip_count + 1))
        else
          # Use GStreamer pipeline to remux IVF to WebM/Matroska container
          pipeline="filesrc location=\"$vp9_clip_ivf\" ! ivfparse ! $mux ! filesink location=\"$vp9_clip_webm\""
          if gstreamer_run_gstlaunch_timeout 30 "$pipeline" >/dev/null 2>&1; then
            log_pass "Successfully converted IVF to WebM (320x240)"
          else
            log_fail "GStreamer IVF to WebM conversion failed"
            log_warn "VP9 decode tests will be skipped (reason: GST conversion failure)"
            rm -f "$vp9_clip_webm" 2>/dev/null || true
            rm -f "$vp9_clip_ivf" 2>/dev/null || true
            skip_count=$((skip_count + 1))
          fi
        fi
      else
        log_info "WebM file already exists: $vp9_clip_webm"
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
      for res in $resolutions; do
        total_tests=$((total_tests + 1))
        skip_count=$((skip_count + 1))
      done
      log_info "Skipping VP9 encode (not supported in this test suite)"
      continue
    fi
    
    for res in $resolutions; do
      params=$(gstreamer_resolution_to_wh "$res")
      set -- $params
      width="$1"
      height="$2"
      
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
    # For VP9, only run once (not per resolution, as we use a fixed 320p clip)
    if [ "$codec" = "vp9" ]; then
      total_tests=$((total_tests + 1))
      run_decode_test "$codec" "320p" || true
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
log_info "Total tests executed: $actual_total"
log_info "Passed: $pass_count"
log_info "Failed: $fail_count"
log_info "Skipped: $skip_count"

# -------------------- Emit result --------------------
if [ "$pass_count" -gt 0 ] && [ "$fail_count" -eq 0 ]; then
  result="PASS"
  reason="All tests passed ($pass_count/$actual_total)"
elif [ "$pass_count" -gt 0 ] && [ "$fail_count" -gt 0 ]; then
  result="FAIL"
  reason="Some tests failed (passed: $pass_count, failed: $fail_count, total: $actual_total)"
elif [ "$fail_count" -gt 0 ]; then
  result="FAIL"
  reason="All tests failed ($fail_count/$actual_total)"
else
  result="SKIP"
  reason="No tests executed or all skipped"
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
