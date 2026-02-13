#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Video Encode/Decode validation using GStreamer with V4L2 hardware accelerated codecs
# Supports: v4l2h264dec, v4l2h265dec, v4l2h264enc, v4l2h265enc
# Uses videotestsrc for encoding, then decodes the encoded files
# Logs everything to console and also to local log files.
# PASS/FAIL/SKIP is emitted to .res. Always exits 0 (LAVA-friendly).

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

result="FAIL"
reason="unknown"
pass_count=0
fail_count=0
skip_count=0
total_tests=0

# -------------------- Defaults (LAVA env vars -> defaults; CLI overrides) --------------------
testMode="${VIDEO_TEST_MODE:-all}"
codecList="${VIDEO_CODECS:-h264,h265,vp9}"
resolutionList="${VIDEO_RESOLUTIONS:-4k}"
duration="${VIDEO_DURATION:-${RUNTIMESEC:-30}}"
framerate="${VIDEO_FRAMERATE:-30}"
gstDebugLevel="${VIDEO_GST_DEBUG:-${GST_DEBUG_LEVEL:-2}}"
videoStack="${VIDEO_STACK:-auto}"
clipUrl="${VIDEO_CLIP_URL:-https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/IRIS-Video-Files-v1.0/video_clips_iris.tar.gz}"

cleanup() {
  pkill -x gst-launch-1.0 >/dev/null 2>&1 || true
}
trap cleanup INT TERM EXIT

# -------------------- Arg parse --------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --mode"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      testMode="$2"
      shift 2
      ;;

    --codecs)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --codecs"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      codecList="$2"
      shift 2
      ;;

  --clip-url)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --clip-url"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      clipUrl="$2"
      shift 2
      ;;

    --resolutions)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --resolutions"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      resolutionList="$2"
      shift 2
      ;;

    --duration)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --duration"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      duration="$2"
      shift 2
      ;;

    --framerate)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --framerate"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      framerate="$2"
      shift 2
      ;;

    --stack)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --stack"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      videoStack="$2"
      shift 2
      ;;

    --gst-debug)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --gst-debug"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      gstDebugLevel="$2"
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
      Default: h264,h265
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
      echo "SKIP" >"$RES_FILE"
      exit 0
      ;;

    *)
      log_warn "Unknown argument: $1"
      echo "SKIP" >"$RES_FILE"
      exit 0
      ;;
  esac
done

# -------------------- Validate parsed values --------------------
case "$testMode" in all|encode|decode) : ;; *)
  log_warn "Invalid --mode '$testMode'"
  echo "SKIP" >"$RES_FILE"
  exit 0
  ;;
esac

case "$gstDebugLevel" in 1|2|3|4|5|6|7|8|9) : ;; *)
  log_warn "Invalid --gst-debug '$gstDebugLevel' (allowed: 1-9)"
  echo "SKIP" >"$RES_FILE"
  exit 0
  ;;
esac

# -------------------- Pre-checks --------------------
check_dependencies "gst-launch-1.0" "gst-inspect-1.0" >/dev/null 2>&1 || {
  log_warn "Missing gstreamer runtime (gst-launch-1.0/gst-inspect-1.0)"
  echo "SKIP" >"$RES_FILE"
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

# -------------------- Helper functions --------------------
get_resolution_params() {
  res="$1"
  case "$res" in
    480p)
      printf '%s %s\n' "640" "480"
      ;;
    720p)
      printf '%s %s\n' "1280" "720"
      ;;
    1080p)
      printf '%s %s\n' "1920" "1080"
      ;;
    4k)
      printf '%s %s\n' "3840" "2160"
      ;;
    *)
      printf '%s %s\n' "640" "480"
      ;;
  esac
}

get_encoder_element() {
  codec="$1"
  case "$codec" in
    h264)
      if has_element v4l2h264enc; then
        printf '%s\n' "v4l2h264enc"
        return 0
      fi
      ;;
    h265|hevc)
      if has_element v4l2h265enc; then
        printf '%s\n' "v4l2h265enc"
        return 0
      fi
      ;;
  esac
  printf '%s\n' ""
  return 1
}

get_decoder_element() {
  codec="$1"
  case "$codec" in
    h264)
      if has_element v4l2h264dec; then
        printf '%s\n' "v4l2h264dec"
        return 0
      fi
      ;;
    h265|hevc)
      if has_element v4l2h265dec; then
        printf '%s\n' "v4l2h265dec"
        return 0
      fi
      ;;
    vp9)
      if has_element v4l2vp9dec; then
        printf '%s\n' "v4l2vp9dec"
        return 0
      fi
      ;;
  esac
  printf '%s\n' ""
  return 1
}

get_file_extension() {
  codec="$1"
  case "$codec" in
    vp9)
      printf '%s\n' "ivf"
      ;;
    *)
      # Use mp4 container format for h264/h265
      printf '%s\n' "mp4"
      ;;
  esac
}

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
  
  encoder=$(get_encoder_element "$codec")
  if [ -z "$encoder" ]; then
    log_warn "Encoder not available for $codec"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  ext=$(get_file_extension)
  output_file="$ENCODED_DIR/${testname}.${ext}"
  test_log="$OUTDIR/${testname}.log"
  
  : >"$test_log"
  
  # Build pipeline: videotestsrc -> NV12 format -> encoder with bitrate -> parser -> filesink
  case "$codec" in
    h264)
      parser="h264parse"
      ;;
    h265|hevc)
      parser="h265parse"
      ;;
    *)
      parser=""
      ;;
  esac
  
  # Calculate bitrate based on resolution (8Mbps for 4K, scaled for others)
  bitrate=8000000
  if [ "$width" -le 640 ]; then
    bitrate=1000000
  elif [ "$width" -le 1280 ]; then
    bitrate=2000000
  elif [ "$width" -le 1920 ]; then
    bitrate=4000000
  fi
  
  # Detect video stack and add IO mode parameters for downstream
  encoder_params="extra-controls=\"controls,video_bitrate=${bitrate}\""
  if [ "$detected_stack" = "downstream" ]; then
    encoder_params="${encoder_params} capture-io-mode=4 output-io-mode=4"
    log_info "Using downstream stack: adding IO mode parameters"
  else
    log_info "Using upstream stack: no IO mode parameters needed"
  fi
  
  # Build pipeline with mp4mux for MP4 container
  if [ -n "$parser" ]; then
    pipeline="videotestsrc num-buffers=$((duration * framerate)) pattern=smpte ! video/x-raw,width=${width},height=${height},format=NV12,framerate=${framerate}/1 ! ${encoder} ${encoder_params} ! ${parser} ! mp4mux ! filesink location=${output_file}"
  else
    pipeline="videotestsrc num-buffers=$((duration * framerate)) pattern=smpte ! video/x-raw,width=${width},height=${height},format=NV12,framerate=${framerate}/1 ! ${encoder} ${encoder_params} ! mp4mux ! filesink location=${output_file}"
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
    file_size=$(stat -f%z "$output_file" 2>/dev/null || stat -c%s "$output_file" 2>/dev/null || echo 0)
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
  
  decoder=$(get_decoder_element "$codec")
  if [ -z "$decoder" ]; then
    log_warn "Decoder not available for $codec"
    skip_count=$((skip_count + 1))
    return 1
  fi
  
  ext=$(get_file_extension "$codec")
  
  # For VP9, use pre-downloaded clip; for others, use encoded file
  if [ "$codec" = "vp9" ]; then
    input_file="$OUTDIR/320_240_10fps.ivf"
    if [ ! -f "$input_file" ]; then
      log_warn "VP9 clip not found: $input_file (download may have failed)"
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
  
  # Build pipeline: filesrc -> parser -> decoder -> fakesink
  case "$codec" in
    h264)
      parser="h264parse"
      container="qtdemux"
      ;;
    h265|hevc)
      parser="h265parse"
      container="qtdemux"
      ;;
    vp9)
      parser="ivfparse"
      container=""
      ;;
    *)
      parser="identity"
      container=""
      ;;
  esac
  
  # Add IO mode parameters for downstream stack
  decoder_params=""
  if [ "$detected_stack" = "downstream" ]; then
    decoder_params="capture-io-mode=4 output-io-mode=4"
    log_info "Using downstream stack: adding IO mode parameters to decoder"
  else
    log_info "Using upstream stack: no IO mode parameters needed for decoder"
  fi
  
  # Build pipeline based on container format
  if [ -n "$container" ]; then
    # MP4 container (h264/h265)
    if [ -n "$decoder_params" ]; then
      pipeline="filesrc location=${input_file} ! ${container} ! ${parser} ! ${decoder} ${decoder_params} ! videoconvert ! fakesink"
    else
      pipeline="filesrc location=${input_file} ! ${container} ! ${parser} ! ${decoder} ! videoconvert ! fakesink"
    fi
  else
    # IVF container (vp9) or no container
    if [ -n "$decoder_params" ]; then
      pipeline="filesrc location=${input_file} ! ${parser} ! ${decoder} ${decoder_params} ! videoconvert ! fakesink"
    else
      pipeline="filesrc location=${input_file} ! ${parser} ! ${decoder} ! videoconvert ! fakesink"
    fi
  fi
  
  log_info "Pipeline: $pipeline"
  
  # Run decoding
  if gstreamer_run_gstlaunch_timeout "$((duration + 10))" "$pipeline" >>"$test_log" 2>&1; then
    gstRc=0
  else
    gstRc=$?
  fi
  
  log_info "Decode exit code: $gstRc"
  
  # Check for successful completion in log
  if grep -q "Setting pipeline to NULL" "$test_log" 2>/dev/null || [ "$gstRc" -eq 0 ]; then
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
  log_info "VP9 CLIP DOWNLOAD"
  log_info "=========================================="
  
  vp9_clip="$OUTDIR/320_240_10fps.ivf"
  
  if [ -f "$vp9_clip" ]; then
    log_info "VP9 clip already exists: $vp9_clip"
  else
    log_info "Checking network connectivity and downloading VP9 clips..."
    
    # Use ensure_network_online from functestlib.sh to bring up connectivity
    if ensure_network_online; then
      log_pass "Network connectivity established"
      
      # Download and extract clips using functestlib helper
      log_info "Downloading VP9 clips from: $clipUrl"
      if extract_tar_from_url "$clipUrl" "$OUTDIR"; then
        log_pass "VP9 clips downloaded and extracted successfully"
      else
        log_warn "Failed to download/extract VP9 clips"
      fi
      
      # Verify clip exists after download attempt
      if [ ! -f "$vp9_clip" ]; then
        log_warn "VP9 clip not found after download attempt: $vp9_clip"
        log_warn "VP9 decode tests will be skipped"
      fi
    else
      log_warn "Could not establish network connectivity"
      log_warn "VP9 decode tests will be skipped"
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
      log_info "Skipping VP9 encode (not supported in this test suite)"
      continue
    fi
    
    for res in $resolutions; do
      params=$(get_resolution_params "$res")
      width=$(printf '%s' "$params" | awk '{print $1}')
      height=$(printf '%s' "$params" | awk '{print $2}')
      
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
    # For VP9, only run once (not per resolution, as we use a fixed clip)
    if [ "$codec" = "vp9" ]; then
      total_tests=$((total_tests + 1))
      run_decode_test "$codec" "720p" || true
    else
      for res in $resolutions; do
        total_tests=$((total_tests + 1))
        run_decode_test "$codec" "$res" || true
      done
    fi
  done
fi

# -------------------- Summary --------------------
log_info "=========================================="
log_info "TEST SUMMARY"
log_info "=========================================="
log_info "Total tests: $total_tests"
log_info "Passed: $pass_count"
log_info "Failed: $fail_count"
log_info "Skipped: $skip_count"

# -------------------- Emit result --------------------
if [ "$pass_count" -gt 0 ] && [ "$fail_count" -eq 0 ]; then
  result="PASS"
  reason="All tests passed ($pass_count/$total_tests)"
elif [ "$pass_count" -gt 0 ] && [ "$fail_count" -gt 0 ]; then
  result="FAIL"
  reason="Some tests failed (passed: $pass_count, failed: $fail_count)"
elif [ "$fail_count" -gt 0 ]; then
  result="FAIL"
  reason="All tests failed ($fail_count/$total_tests)"
else
  result="SKIP"
  reason="No tests executed or all skipped"
fi

case "$result" in
  PASS)
    log_pass "$TESTNAME $result: $reason"
    echo "PASS" >"$RES_FILE"
    ;;
  FAIL)
    log_fail "$TESTNAME $result: $reason"
    echo "FAIL" >"$RES_FILE"
    ;;
  *)
    log_warn "$TESTNAME $result: $reason"
    echo "SKIP" >"$RES_FILE"
    ;;
esac

exit 0
