#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Comprehensive Camera Tests using GStreamer with qtiqmmfsrc
# Test sequence: Fakesink -> Preview -> Encode -> Encode+Snapshot
# Supports both NV12 (linear) and UBWC (NV12_Q08C compressed) formats
# Logs everything to console and also to local log files.
# PASS/FAIL/SKIP is emitted to .res. Always exits 0 (LAVA-friendly).

SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"

TESTNAME="Camera_Tests"
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
[ -f "$TOOLS/lib_display.sh" ] && . "$TOOLS/lib_display.sh"

result="FAIL"
reason="unknown"
pass_count=0
fail_count=0
skip_count=0
total_tests=0

# -------------------- Defaults --------------------
cameraId="${CAMERA_ID:-0}"
testModeList="${CAMERA_TEST_MODES:-fakesink,preview,encode,snapshot}"
formatList="${CAMERA_FORMATS:-nv12,ubwc}"
resolutionList="${CAMERA_RESOLUTIONS:-720p,1080p,4k}"
framerate="${CAMERA_FRAMERATE:-30}"
duration="${CAMERA_DURATION:-10}"
gstDebugLevel="${CAMERA_GST_DEBUG:-${GST_DEBUG_LEVEL:-2}}"

# Validate environment variables if set (POSIX-safe; no indirect expansion)
for param in CAMERA_DURATION CAMERA_FRAMERATE CAMERA_GST_DEBUG GST_DEBUG_LEVEL; do
  val=""
  case "$param" in
    CAMERA_DURATION) val="${CAMERA_DURATION-}" ;;
    CAMERA_FRAMERATE) val="${CAMERA_FRAMERATE-}" ;;
    CAMERA_GST_DEBUG) val="${CAMERA_GST_DEBUG-}" ;;
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
  if ! pkill -P "$$" -x gst-launch-1.0 >/dev/null 2>&1; then
    pkill -x gst-launch-1.0 >/dev/null 2>&1 || true
  fi
  if ! pkill -P "$$" -x gst-pipeline-app >/dev/null 2>&1; then
    pkill -x gst-pipeline-app >/dev/null 2>&1 || true
  fi
}
trap cleanup INT TERM EXIT

# -------------------- Arg parse --------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --camera-id)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --camera-id"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      [ -n "$2" ] && cameraId="$2"
      shift 2
      ;;
    --test-modes)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --test-modes"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      [ -n "$2" ] && testModeList="$2"
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
    --resolutions)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --resolutions"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      [ -n "$2" ] && resolutionList="$2"
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
            framerate="$2"
            ;;
        esac
      fi
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
            if [ "$2" -le 0 ] 2>/dev/null; then
              log_warn "Duration must be positive (got '$2')"
              echo "$TESTNAME SKIP" >"$RES_FILE"
              exit 0
            fi
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
    -h|--help)
      cat <<EOF
Camera Tests - Comprehensive GStreamer Camera Validation

OVERVIEW:
  This test suite validates camera functionality using GStreamer with Qualcomm's
  qtiqmmfsrc plugin. Tests run in sequence to progressively validate different
  camera capabilities.

TEST SEQUENCE (11 Total Tests):
  1. Fakesink  (2 tests)  - Basic camera capture validation (no encoding)
  2. Preview   (2 tests)  - Camera preview on Weston display (4K)
  3. Encode    (6 tests)  - Camera capture with H.264 encoding (720p/1080p/4K)
  4. Snapshot  (1 test)   - Video encoding + JPEG snapshot capture (720p)

USAGE:
  $0 [OPTIONS]

OPTIONS:
  --camera-id <id>        Camera device ID (default: 0)
                          Specify which camera to use if multiple cameras available

  --test-modes <list>     Test modes to run (default: fakesink,preview,encode,snapshot)
                          Options: fakesink, preview, encode, snapshot
                          Use comma-separated list to run specific modes

  --formats <list>        Formats to test (default: nv12,ubwc)
                          nv12 - Linear NV12 format (standard)
                          ubwc - UBWC compressed format (Qualcomm optimized)

  --resolutions <list>    Resolutions for encode tests (default: 720p,1080p,4k)
                          720p  - 1280x720
                          1080p - 1920x1080
                          4k    - 3840x2160

  --framerate <fps>       Capture framerate in fps (default: 30)
                          Adjust based on camera capabilities

  --duration <seconds>    Test duration in seconds (default: 10)
                          Longer duration for stability testing

  --gst-debug <level>     GStreamer debug level 1-9 (default: 2)
                          Higher levels provide more detailed debug output

  -h, --help              Display this help message

ENVIRONMENT VARIABLES:
  CAMERA_ID               Same as --camera-id
  CAMERA_TEST_MODES       Same as --test-modes
  CAMERA_FORMATS          Same as --formats
  CAMERA_RESOLUTIONS      Same as --resolutions
  CAMERA_FRAMERATE        Same as --framerate
  CAMERA_DURATION         Same as --duration
  CAMERA_GST_DEBUG        Same as --gst-debug

EXAMPLES:
  # Run all 11 tests with default settings
  $0

  # Run only fakesink tests (2 tests)
  $0 --test-modes fakesink

  # Run fakesink and encode tests (8 tests)
  $0 --test-modes fakesink,encode

  # Test only NV12 format (6 tests)
  $0 --formats nv12

  # Test only UBWC format (5 tests, no snapshot)
  $0 --formats ubwc

  # Test specific resolutions for encode tests
  $0 --resolutions 720p,1080p

  # Run encode tests with NV12 at 4K for 20 seconds
  $0 --test-modes encode --formats nv12 --resolutions 4k --duration 20

  # Use camera 1 with custom framerate
  $0 --camera-id 1 --framerate 60

  # Using environment variables
  export CAMERA_FORMATS="nv12"
  export CAMERA_RESOLUTIONS="720p"
  $0

TEST DETAILS:

  Fakesink Tests (2):
    - fakesink_nv12  : NV12 format, 720p, no encoding
    - fakesink_ubwc  : UBWC format, 720p, no encoding

  Preview Tests (2):
    - preview_nv12_4k : NV12 format, 4K, Weston display
    - preview_ubwc_4k : UBWC format, 4K, Weston display

  Encode Tests (6):
    - encode_nv12_720p   : NV12, 1280x720, H.264 encode
    - encode_nv12_1080p  : NV12, 1920x1080, H.264 encode
    - encode_nv12_4k     : NV12, 3840x2160, H.264 encode
    - encode_ubwc_720p   : UBWC, 1280x720, H.264 encode
    - encode_ubwc_1080p  : UBWC, 1920x1080, H.264 encode
    - encode_ubwc_4k     : UBWC, 3840x2160, H.264 encode

  Snapshot Test (1):
    - snapshot_nv12_720p : NV12, 720p, video + JPEG snapshots

FORMAT DETAILS:
  NV12 (Linear):
    - Standard uncompressed YUV 4:2:0 format
    - Higher memory bandwidth usage
    - Universal hardware support
    - Pipeline: qtiqmmfsrc ! video/x-raw,format=NV12 ! ...

  UBWC (Compressed):
    - Qualcomm's Universal Bandwidth Compression
    - Reduced memory bandwidth (optimized)
    - Qualcomm-specific hardware support
    - Pipeline: qtiqmmfsrc video_0::type=preview ! video/x-raw,format=NV12_Q08C ! ...
    - Note: Requires 'video_0::type=preview' in qtiqmmfsrc

OUTPUT:
  Result File:  Camera_Tests.res (PASS/FAIL/SKIP)
  Logs:         logs/Camera_Tests/*.log
  Videos:       logs/Camera_Tests/encoded/*.mp4
  Snapshots:    logs/Camera_Tests/encoded/frame*.jpg
  GStreamer:    logs/Camera_Tests/gst.log
  Kernel Logs:  logs/Camera_Tests/dmesg/

PREREQUISITES:
  Required Tools:
    - gst-launch-1.0 (GStreamer command-line tool)
    - gst-inspect-1.0 (GStreamer plugin inspector)
    - gst-pipeline-app (for snapshot test, optional)

  Required Plugins:
    - qtiqmmfsrc (Qualcomm camera source)
    - v4l2h264enc (V4L2 H.264 encoder, for encode/snapshot)
    - waylandsink (Wayland display, for preview)

  Hardware:
    - Qualcomm camera hardware
    - Weston display server (for preview tests)
    - Write permissions to output directories

SUCCESS CRITERIA:
  Fakesink:  Pipeline runs without errors, exit code 0
  Preview:   Pipeline runs, video displays on screen, exit code 0
  Encode:    Pipeline runs, MP4 file created (size > 1000 bytes)
  Snapshot:  Pipeline runs, MP4 + JPEG files created

TROUBLESHOOTING:
  Test Skipped:
    - Check if required plugins are installed (gst-inspect-1.0 <plugin>)
    - Verify camera hardware is connected
    - Ensure Weston is running for preview tests

  Test Failed:
    - Check logs in logs/Camera_Tests/ directory
    - Review gst.log for GStreamer errors
    - Check dmesg/ for kernel errors
    - Verify camera permissions (ls -l /dev/video*)

For detailed documentation, see README.md in this directory.

EOF
      exit 0
      ;;
    *) shift ;;
  esac
done

# -------------------- Pre-checks --------------------
check_dependencies "gst-launch-1.0 gst-inspect-1.0" >/dev/null 2>&1 || {
  log_skip "Missing required tools"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
}

log_info "Test: $TESTNAME"
log_info "Camera ID: $cameraId"
log_info "Test Modes: $testModeList"
log_info "Formats: $formatList"
log_info "Resolutions: $resolutionList"
log_info "Framerate: ${framerate}fps"
log_info "Duration: ${duration}s"

# -------------------- Camera source detection --------------------
log_info "=========================================="
log_info "CAMERA SOURCE DETECTION"
log_info "=========================================="

qtiqmmfsrc_available=0
libcamerasrc_available=0

# Check for qtiqmmfsrc (Qualcomm CAMX downstream camera)
if gst-inspect-1.0 qtiqmmfsrc >/dev/null 2>&1; then
  qtiqmmfsrc_available=1
  log_info "✓ qtiqmmfsrc detected - CAMX downstream camera available"
else
  log_info "✗ qtiqmmfsrc not detected"
fi

# Check for libcamerasrc (upstream camera)
if gst-inspect-1.0 libcamerasrc >/dev/null 2>&1; then
  libcamerasrc_available=1
  log_info "✓ libcamerasrc detected - Upstream camera available"
else
  log_info "✗ libcamerasrc not detected"
fi

# Determine which camera source to use
# Priority: qtiqmmfsrc > libcamerasrc > skip if neither
if [ "$qtiqmmfsrc_available" -eq 1 ]; then
  log_info "Using qtiqmmfsrc (CAMX downstream camera) for tests"
  if [ "$libcamerasrc_available" -eq 1 ]; then
    log_info "Note: Both qtiqmmfsrc and libcamerasrc detected, prioritizing qtiqmmfsrc"
  fi
  log_info "Will run 11 qtiqmmfsrc tests: fakesink(2) + preview(2) + encode(6) + snapshot(1)"
  camera_source="qtiqmmfsrc"
elif [ "$libcamerasrc_available" -eq 1 ]; then
  log_info "Using libcamerasrc (upstream camera) for tests"
  log_info "Will run 2 libcamerasrc tests: preview(1) + encode(1)"
  camera_source="libcamerasrc"
else
  log_skip "No camera source plugin available (neither qtiqmmfsrc nor libcamerasrc detected)"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

log_info "=========================================="

# -------------------- GStreamer debug capture --------------------
export GST_DEBUG_NO_COLOR=1
export GST_DEBUG="$gstDebugLevel"
export GST_DEBUG_FILE="$GST_LOG"

# -------------------- Test Functions --------------------

# Fakesink test
run_fakesink_test() {
  format="$1"
  
  case "$format" in
    nv12) format_name="NV12" ;;
    ubwc) format_name="UBWC" ;;
    *) log_warn "Unknown format: $format"; skip_count=$((skip_count + 1)); return 1 ;;
  esac
  
  testname="fakesink_${format}"
  log_info "=========================================="; log_info "Running: $testname"; log_info "=========================================="
  
  test_log="$OUTDIR/${testname}.log"
  : >"$test_log"
  
  # Use modular pipeline builder with duration for num-buffers calculation
  pipeline=$(camera_build_qtiqmmfsrc_fakesink_pipeline "$cameraId" "$format" 1280 720 "$framerate" "$duration")
  if [ -z "$pipeline" ]; then
    log_warn "$testname: Failed to build pipeline"; skip_count=$((skip_count + 1)); return 1
  fi
  
  log_info "Format: $format_name"; log_info "Pipeline: gst-launch-1.0 -e $pipeline"
  
  if gstreamer_run_gstlaunch_timeout "$((duration + 10))" "$pipeline" >>"$test_log" 2>&1; then gstRc=0; else gstRc=$?; fi
  
  if ! gstreamer_validate_log "$test_log" "$testname"; then
    log_fail "$testname: FAIL"; fail_count=$((fail_count + 1)); return 1
  fi
  
  if [ "$gstRc" -eq 0 ]; then log_pass "$testname: PASS"; pass_count=$((pass_count + 1)); return 0
  else log_fail "$testname: FAIL (rc=$gstRc)"; fail_count=$((fail_count + 1)); return 1; fi
}

# Preview test
run_preview_test() {
  format="$1"
  
  case "$format" in
    nv12) format_name="NV12" ;;
    ubwc) format_name="UBWC" ;;
    *) log_warn "Unknown format: $format"; skip_count=$((skip_count + 1)); return 1 ;;
  esac
  
  if ! gst-inspect-1.0 waylandsink >/dev/null 2>&1; then
    log_warn "waylandsink not available, skipping preview test"
    skip_count=$((skip_count + 1)); return 1
  fi
  
  testname="preview_${format}_4k"
  log_info "=========================================="; log_info "Running: $testname"; log_info "=========================================="
  
  test_log="$OUTDIR/${testname}.log"
  : >"$test_log"
  
  # Use modular pipeline builder
  pipeline=$(camera_build_qtiqmmfsrc_preview_pipeline "$cameraId" "$format" 3840 2160 "$framerate")
  if [ -z "$pipeline" ]; then
    log_warn "$testname: Failed to build pipeline"; skip_count=$((skip_count + 1)); return 1
  fi
  
  log_info "Format: $format_name"; log_info "Pipeline: gst-launch-1.0 -e $pipeline"
  
  if gstreamer_run_gstlaunch_timeout "$((duration + 10))" "$pipeline" >>"$test_log" 2>&1; then gstRc=0; else gstRc=$?; fi
  
  if ! gstreamer_validate_log "$test_log" "$testname"; then
    log_fail "$testname: FAIL"; fail_count=$((fail_count + 1)); return 1
  fi
  
  if [ "$gstRc" -eq 0 ]; then log_pass "$testname: PASS"; pass_count=$((pass_count + 1)); return 0
  else log_fail "$testname: FAIL (rc=$gstRc)"; fail_count=$((fail_count + 1)); return 1; fi
}

# Encode test
run_encode_test() {
  format="$1"
  resolution="$2"
  width="$3"
  height="$4"
  
  case "$format" in
    nv12) format_name="NV12" ;;
    ubwc) format_name="UBWC" ;;
    *) log_warn "Unknown format: $format"; skip_count=$((skip_count + 1)); return 1 ;;
  esac
  
  if ! gst-inspect-1.0 v4l2h264enc >/dev/null 2>&1; then
    log_warn "v4l2h264enc not available, skipping encode test"
    skip_count=$((skip_count + 1)); return 1
  fi
  
  testname="encode_${format}_${resolution}"
  log_info "=========================================="; log_info "Running: $testname"; log_info "=========================================="
  
  output_file="$ENCODED_DIR/${testname}.mp4"
  test_log="$OUTDIR/${testname}.log"
  : >"$test_log"
  
  # Use modular pipeline builder
  pipeline=$(camera_build_qtiqmmfsrc_encode_pipeline "$cameraId" "$format" "$width" "$height" "$framerate" "$output_file")
  if [ -z "$pipeline" ]; then
    log_warn "$testname: Failed to build pipeline"; skip_count=$((skip_count + 1)); return 1
  fi
  
  log_info "Format: $format_name"; log_info "Resolution: $resolution (${width}x${height})"; log_info "Pipeline: gst-launch-1.0 -e $pipeline"
  
  if gstreamer_run_gstlaunch_timeout "$((duration + 10))" "$pipeline" >>"$test_log" 2>&1; then gstRc=0; else gstRc=$?; fi
  
  if ! gstreamer_validate_log "$test_log" "$testname"; then
    log_fail "$testname: FAIL"; fail_count=$((fail_count + 1)); return 1
  fi
  
  if [ -f "$output_file" ] && [ -s "$output_file" ]; then
    file_size=$(gstreamer_file_size_bytes "$output_file")
    if [ "$file_size" -gt 1000 ]; then log_pass "$testname: PASS"; pass_count=$((pass_count + 1)); return 0
    else log_fail "$testname: FAIL (file too small)"; fail_count=$((fail_count + 1)); return 1; fi
  else log_fail "$testname: FAIL (no output)"; fail_count=$((fail_count + 1)); return 1; fi
}

# Snapshot test
run_snapshot_test() {
  if ! command -v gst-pipeline-app >/dev/null 2>&1; then
    log_warn "gst-pipeline-app not available, skipping snapshot test"
    skip_count=$((skip_count + 1)); return 1
  fi
  
  if ! gst-inspect-1.0 v4l2h264enc >/dev/null 2>&1; then
    log_warn "v4l2h264enc not available, skipping snapshot test"
    skip_count=$((skip_count + 1)); return 1
  fi
  
  testname="snapshot_nv12_720p"
  log_info "=========================================="; log_info "Running: $testname"; log_info "=========================================="
  
  videoOutput="$ENCODED_DIR/mux_avc.mp4"
  snapshotPath="$ENCODED_DIR/frame%d.jpg"
  test_log="$OUTDIR/${testname}.log"
  : >"$test_log"
  
  # Use modular pipeline builder
  pipeline=$(camera_build_qtiqmmfsrc_snapshot_pipeline "$cameraId" 1280 720 "$framerate" "$videoOutput" "$snapshotPath")
  if [ -z "$pipeline" ]; then
    log_warn "$testname: Failed to build pipeline"; skip_count=$((skip_count + 1)); return 1
  fi
  
  log_info "Pipeline: gst-pipeline-app -e $pipeline"
  
  if gstreamer_run_gstlaunch_timeout "$((duration + 10))" "$pipeline" >>"$test_log" 2>&1; then gstRc=0; else gstRc=$?; fi
  
  if ! gstreamer_validate_log "$test_log" "$testname"; then
    log_fail "$testname: FAIL"; fail_count=$((fail_count + 1)); return 1
  fi
  
  video_ok=0; snapshot_ok=0
  if [ -f "$videoOutput" ] && [ -s "$videoOutput" ]; then
    file_size=$(gstreamer_file_size_bytes "$videoOutput")
    [ "$file_size" -gt 1000 ] && video_ok=1
  fi
  
  snapshot_count=$(find "$ENCODED_DIR" -name "frame*.jpg" -type f 2>/dev/null | wc -l)
  [ "$snapshot_count" -gt 0 ] && snapshot_ok=1
  
  if [ "$video_ok" -eq 1 ] && [ "$snapshot_ok" -eq 1 ]; then
    log_pass "$testname: PASS"; pass_count=$((pass_count + 1)); return 0
  else log_fail "$testname: FAIL"; fail_count=$((fail_count + 1)); return 1; fi
}

# -------------------- libcamerasrc Test Functions --------------------

# libcamerasrc Preview test
run_libcamera_preview_test() {
  if ! gst-inspect-1.0 waylandsink >/dev/null 2>&1; then
    log_warn "waylandsink not available, skipping libcamera preview test"
    skip_count=$((skip_count + 1)); return 1
  fi
  
  if ! gst-inspect-1.0 videoconvert >/dev/null 2>&1; then
    log_warn "videoconvert not available, skipping libcamera preview test"
    skip_count=$((skip_count + 1)); return 1
  fi
  
  testname="libcamera_preview"
  log_info "=========================================="; log_info "Running: $testname"; log_info "=========================================="
  
  test_log="$OUTDIR/${testname}.log"
  : >"$test_log"
  
  # Use modular pipeline builder with duration and framerate for num-buffers
  pipeline=$(camera_build_libcamera_preview_pipeline "$duration" "$framerate")
  if [ -z "$pipeline" ]; then
    log_warn "$testname: Failed to build pipeline"; skip_count=$((skip_count + 1)); return 1
  fi
  
  log_info "Pipeline: gst-launch-1.0 -e $pipeline"
  
  if gstreamer_run_gstlaunch_timeout "$((duration + 10))" "$pipeline" >>"$test_log" 2>&1; then gstRc=0; else gstRc=$?; fi
  
  if ! gstreamer_validate_log "$test_log" "$testname"; then
    log_fail "$testname: FAIL"; fail_count=$((fail_count + 1)); return 1
  fi
  
  if [ "$gstRc" -eq 0 ]; then log_pass "$testname: PASS"; pass_count=$((pass_count + 1)); return 0
  else log_fail "$testname: FAIL (rc=$gstRc)"; fail_count=$((fail_count + 1)); return 1; fi
}

# libcamerasrc Encode test
run_libcamera_encode_test() {
  if ! gst-inspect-1.0 v4l2h264enc >/dev/null 2>&1; then
    log_warn "v4l2h264enc not available, skipping libcamera encode test"
    skip_count=$((skip_count + 1)); return 1
  fi
  
  if ! gst-inspect-1.0 videoconvert >/dev/null 2>&1; then
    log_warn "videoconvert not available, skipping libcamera encode test"
    skip_count=$((skip_count + 1)); return 1
  fi
  
  testname="libcamera_encode"
  log_info "=========================================="; log_info "Running: $testname"; log_info "=========================================="
  
  output_file="$ENCODED_DIR/sample_mipi.mp4"
  test_log="$OUTDIR/${testname}.log"
  : >"$test_log"
  
  # Use modular pipeline builder with duration and framerate for num-buffers
  pipeline=$(camera_build_libcamera_encode_pipeline "$output_file" "$duration" "$framerate")
  if [ -z "$pipeline" ]; then
    log_warn "$testname: Failed to build pipeline"; skip_count=$((skip_count + 1)); return 1
  fi
  
  log_info "Pipeline: gst-launch-1.0 -e $pipeline"
  
  if gstreamer_run_gstlaunch_timeout "$((duration + 10))" "$pipeline" >>"$test_log" 2>&1; then gstRc=0; else gstRc=$?; fi
  
  if ! gstreamer_validate_log "$test_log" "$testname"; then
    log_fail "$testname: FAIL"; fail_count=$((fail_count + 1)); return 1
  fi
  
  if [ -f "$output_file" ] && [ -s "$output_file" ]; then
    file_size=$(gstreamer_file_size_bytes "$output_file")
    if [ "$file_size" -gt 1000 ]; then log_pass "$testname: PASS"; pass_count=$((pass_count + 1)); return 0
    else log_fail "$testname: FAIL (file too small)"; fail_count=$((fail_count + 1)); return 1; fi
  else log_fail "$testname: FAIL (no output)"; fail_count=$((fail_count + 1)); return 1; fi
}

# -------------------- Main test execution --------------------
if [ "$camera_source" = "libcamerasrc" ]; then
  log_info "Starting libcamerasrc tests: preview -> encode"
  
  # Wayland/Weston environment setup for libcamerasrc preview test
  log_info "=========================================="
  log_info "LIBCAMERA PREVIEW - WAYLAND SETUP"
  log_info "=========================================="
  
  wayland_ready=0
  sock=""
  
  # Try to find existing Wayland socket
  if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
    sock=$(discover_wayland_socket_anywhere | head -n 1 || true)
    if [ -n "$sock" ]; then
      log_info "Found existing Wayland socket: $sock"
      if command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
        if adopt_wayland_env_from_socket "$sock"; then
          wayland_ready=1
          log_info "Adopted Wayland environment from socket"
        fi
      fi
    fi
  fi
  
  # Try starting Weston if no socket found
  if [ "$wayland_ready" -eq 0 ] && [ -z "$sock" ]; then
    if command -v weston_pick_env_or_start >/dev/null 2>&1; then
      log_info "No Wayland socket found, attempting to start Weston..."
      if weston_pick_env_or_start "Libcamera_Preview"; then
        # Re-discover socket after Weston start
        if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
          sock=$(discover_wayland_socket_anywhere | head -n 1 || true)
          if [ -n "$sock" ]; then
            log_info "Weston started successfully with socket: $sock"
            if command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
              if adopt_wayland_env_from_socket "$sock"; then
                wayland_ready=1
              fi
            fi
          fi
        fi
      fi
    fi
  fi
  
  # Verify Wayland connection
  if [ "$wayland_ready" -eq 1 ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    if command -v wayland_connection_ok >/dev/null 2>&1; then
      if wayland_connection_ok; then
        wayland_ready=1
        log_info "Wayland connection verified: OK"
      else
        wayland_ready=0
        log_warn "Wayland connection test failed"
      fi
    else
      # Assume ready if WAYLAND_DISPLAY is set and no verification available
      wayland_ready=1
      log_info "Wayland environment set (WAYLAND_DISPLAY=${WAYLAND_DISPLAY})"
    fi
  fi
  
  # Run libcamerasrc preview test if Wayland is ready
  if [ "$wayland_ready" -eq 1 ]; then
    log_info "=========================================="
    log_info "LIBCAMERA PREVIEW TEST"
    log_info "=========================================="
    total_tests=$((total_tests + 1))
    run_libcamera_preview_test || true
  else
    log_warn "Wayland/Weston not available, skipping libcamera preview test"
    log_warn "To run preview test, ensure Weston is running or WAYLAND_DISPLAY is set"
    total_tests=$((total_tests + 1))
    skip_count=$((skip_count + 1))
  fi
  
  # Run libcamerasrc encode test (doesn't need Wayland)
  log_info "=========================================="
  log_info "LIBCAMERA ENCODE TEST"
  log_info "=========================================="
  total_tests=$((total_tests + 1))
  run_libcamera_encode_test || true
  
else
  # qtiqmmfsrc tests
  log_info "Starting camera tests in sequence: fakesink -> preview -> encode -> snapshot"
  
  test_modes=$(printf '%s' "$testModeList" | tr ',' ' ')
  formats=$(printf '%s' "$formatList" | tr ',' ' ')
  resolutions=$(printf '%s' "$resolutionList" | tr ',' ' ')
  
  for mode in $test_modes; do
    case "$mode" in
      fakesink)
        log_info "=========================================="
        log_info "FAKESINK TESTS"
        log_info "=========================================="
        for format in $formats; do
          total_tests=$((total_tests + 1))
          run_fakesink_test "$format" || true
        done
        ;;
      preview)
        log_info "=========================================="
        log_info "PREVIEW TESTS - WAYLAND SETUP"
        log_info "=========================================="
        
        # Wayland/Weston environment setup for preview tests
        wayland_ready=0
        sock=""
        
        # Try to find existing Wayland socket
        if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
          sock=$(discover_wayland_socket_anywhere | head -n 1 || true)
          if [ -n "$sock" ]; then
            log_info "Found existing Wayland socket: $sock"
            if command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
              if adopt_wayland_env_from_socket "$sock"; then
                wayland_ready=1
                log_info "Adopted Wayland environment from socket"
              fi
            fi
          fi
        fi
        
        # Try starting Weston if no socket found
        if [ "$wayland_ready" -eq 0 ] && [ -z "$sock" ]; then
          if command -v weston_pick_env_or_start >/dev/null 2>&1; then
            log_info "No Wayland socket found, attempting to start Weston..."
            if weston_pick_env_or_start "Camera_Preview"; then
              # Re-discover socket after Weston start
              if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
                sock=$(discover_wayland_socket_anywhere | head -n 1 || true)
                if [ -n "$sock" ]; then
                  log_info "Weston started successfully with socket: $sock"
                  if command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
                    if adopt_wayland_env_from_socket "$sock"; then
                      wayland_ready=1
                    fi
                  fi
                fi
              fi
            fi
          fi
        fi
        
        # Verify Wayland connection
        if [ "$wayland_ready" -eq 1 ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
          if command -v wayland_connection_ok >/dev/null 2>&1; then
            if wayland_connection_ok; then
              wayland_ready=1
              log_info "Wayland connection verified: OK"
            else
              wayland_ready=0
              log_warn "Wayland connection test failed"
            fi
          else
            # Assume ready if WAYLAND_DISPLAY is set and no verification available
            wayland_ready=1
            log_info "Wayland environment set (WAYLAND_DISPLAY=${WAYLAND_DISPLAY})"
          fi
        fi
        
        # Run preview tests if Wayland is ready
        if [ "$wayland_ready" -eq 1 ]; then
          log_info "=========================================="
          log_info "PREVIEW TESTS"
          log_info "=========================================="
          for format in $formats; do
            total_tests=$((total_tests + 1))
            run_preview_test "$format" || true
          done
        else
          log_warn "Wayland/Weston not available, skipping preview tests"
          log_warn "To run preview tests, ensure Weston is running or WAYLAND_DISPLAY is set"
          # Count skipped tests
          for format in $formats; do
            total_tests=$((total_tests + 1))
            skip_count=$((skip_count + 1))
          done
        fi
        ;;
      encode)
        log_info "=========================================="
        log_info "ENCODE TESTS"
        log_info "=========================================="
        for format in $formats; do
          for res in $resolutions; do
            case "$res" in
              720p) width=1280; height=720 ;;
              1080p) width=1920; height=1080 ;;
              4k) width=3840; height=2160 ;;
              *) log_warn "Unknown resolution: $res"; skip_count=$((skip_count + 1)); continue ;;
            esac
            total_tests=$((total_tests + 1))
            run_encode_test "$format" "$res" "$width" "$height" || true
          done
        done
        ;;
      snapshot)
        log_info "=========================================="
        log_info "SNAPSHOT TEST"
        log_info "=========================================="
        total_tests=$((total_tests + 1))
        run_snapshot_test || true
        ;;
      *)
        log_warn "Unknown test mode: $mode"
        ;;
    esac
  done
fi

# -------------------- Dmesg error scan --------------------
log_info "=========================================="
log_info "DMESG ERROR SCAN"
log_info "=========================================="

module_regex="camera|qmmf|venus|vcodec|v4l2|video|gstreamer|wayland"
exclude_regex="dummy regulator|supply [^ ]+ not found|using dummy regulator"

if command -v scan_dmesg_errors >/dev/null 2>&1; then
  scan_dmesg_errors "$DMESG_DIR" "$module_regex" "$exclude_regex" || true
  [ -s "$DMESG_DIR/dmesg_errors.log" ] && log_warn "dmesg scan found warnings or errors" || log_info "No relevant errors found in dmesg"
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
  reason="All tests passed ($pass_count/$total_tests)"
elif [ "$fail_count" -gt 0 ]; then
  result="FAIL"
  reason="Some tests failed (passed: $pass_count, failed: $fail_count, skipped: $skip_count)"
else
  result="SKIP"
  reason="No tests passed (skipped: $skip_count)"
fi

case "$result" in
  PASS) log_pass "$TESTNAME $result: $reason"; echo "$TESTNAME PASS" >"$RES_FILE" ;;
  FAIL) log_fail "$TESTNAME $result: $reason"; echo "$TESTNAME FAIL" >"$RES_FILE" ;;
  *) log_warn "$TESTNAME $result: $reason"; echo "$TESTNAME SKIP" >"$RES_FILE" ;;
esac

exit 0
