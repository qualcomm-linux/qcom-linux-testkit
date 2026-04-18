#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Comprehensive Camera Tests using GStreamer with qtiqmmfsrc
# Test sequence: Fakesink -> Preview -> Encode
# Supports both NV12 (linear) and UBWC (NV12_Q08C compressed) formats
# libcamera supports NV12 only.
# Logs everything to console and also to local log files.
# PASS/FAIL/SKIP is emitted to .res. Always exits 0 (LAVA-friendly).

SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"

TESTNAME="Camera_Tests"
RESULT_TESTNAME="$TESTNAME"
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
[ -f "$TOOLS/lib_display.sh" ] && . "$TOOLS/lib_display.sh"

# shellcheck disable=SC1091
[ -f "$TOOLS/camera/lib_camera.sh" ] && . "$TOOLS/camera/lib_camera.sh"

result="FAIL"
reason="unknown"
pass_count=0
fail_count=0
skip_count=0
total_tests=0

# -------------------- Defaults --------------------
cameraId="${CAMERA_ID:-0}"
cameraPlugin="${CAMERA_PLUGIN:-auto}"
testModeList="${CAMERA_TEST_MODES:-fakesink,preview,encode}"
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
  # Only kill gst-launch-1.0 processes that are children of this shell
  # This prevents killing unrelated GStreamer pipelines running on the system
  pkill -P "$$" -x gst-launch-1.0 >/dev/null 2>&1 || true
}
trap cleanup INT TERM EXIT

# -------------------- Arg parse --------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --camera-id)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --camera-id"
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      [ -n "$2" ] && cameraId="$2"
      shift 2
      ;;
    --plugin)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --plugin"
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      if [ -n "$2" ]; then
        case "$2" in
          qtiqmmfsrc|libcamerasrc|auto)
            cameraPlugin="$2"
            ;;
          *)
            log_warn "Invalid --plugin '$2' (must be: qtiqmmfsrc, libcamerasrc, or auto)"
            echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
            exit 0
            ;;
        esac
      fi
      shift 2
      ;;
    --test-modes)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --test-modes"
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      [ -n "$2" ] && testModeList="$2"
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
    --resolutions)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --resolutions"
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      [ -n "$2" ] && resolutionList="$2"
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
            framerate="$2"
            ;;
        esac
      fi
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
            if [ "$2" -le 0 ] 2>/dev/null; then
              log_warn "Duration must be positive (got '$2')"
              echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
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
        echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      [ -n "$2" ] && gstDebugLevel="$2"
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
Camera Tests - Comprehensive GStreamer Camera Validation

OVERVIEW:
  This test suite validates camera functionality using GStreamer with two camera
  source plugins:
  - qtiqmmfsrc (Qualcomm CAMX downstream) - 10 tests
  - libcamerasrc (upstream) - 7 tests
  
  Tests run in sequence to progressively validate different camera capabilities.

TEST SEQUENCES:

  qtiqmmfsrc (10 Total Tests):
    1. Fakesink  (2 tests)  - Basic camera capture validation (no encoding)
    2. Preview   (2 tests)  - Camera preview on Weston display (4K)
    3. Encode    (6 tests)  - Camera capture with H.264 encoding (720p/1080p/4K)

  libcamerasrc (7 Total Tests):
    1. Fakesink  (2 tests)  - Basic camera capture validation (no encoding, 720p/1080p)
    2. Preview   (2 tests)  - Camera preview on Weston (720p/1080p)
    3. Encode    (3 tests)  - Camera capture with H.264 encoding (720p/1080p/4K)

USAGE:
  $0 [OPTIONS]

OPTIONS:
  --camera-id <id>        Camera device ID (default: 0)
                          Specify which camera to use if multiple cameras available

  --plugin <name>         Camera plugin to use (default: auto)
                          Options: qtiqmmfsrc, libcamerasrc, auto
                          auto - Auto-detect (prioritizes qtiqmmfsrc if both available)
                          qtiqmmfsrc - Use CAMX downstream camera (10 tests)
                          libcamerasrc - Use upstream camera (7 tests)

  --test-modes <list>     Test modes to run (default: fakesink,preview,encode)
                          Options: fakesink, preview, encode
                          Use comma-separated list to run specific modes

  --formats <list>        Formats to test (qtiqmmfsrc only, default: nv12,ubwc)
                          nv12 - Linear NV12 format (standard)
                          ubwc - UBWC compressed format (Qualcomm optimized)
                          Note: libcamerasrc only supports NV12

  --resolutions <list>    Resolutions for tests (default: 720p,1080p,4k)
                          720p    - 1280x720
                          1080p   - 1920x1080
                          4k      - 3840x2160

  --framerate <fps>       Capture framerate in fps (default: 30)
                          Adjust based on camera capabilities

  --duration <seconds>    Test duration in seconds (default: 10)
                          Longer duration for stability testing

  --gst-debug <level>     GStreamer debug level 1-9 (default: 2)
                          Higher levels provide more detailed debug output

  -h, --help              Display this help message

ENVIRONMENT VARIABLES:
  CAMERA_ID               Same as --camera-id (qtiqmmfsrc only)
  CAMERA_PLUGIN           Same as --plugin
  CAMERA_TEST_MODES       Same as --test-modes
  CAMERA_FORMATS          Same as --formats (qtiqmmfsrc only)
  CAMERA_RESOLUTIONS      Same as --resolutions
  CAMERA_FRAMERATE        Same as --framerate
  CAMERA_DURATION         Same as --duration
  CAMERA_GST_DEBUG        Same as --gst-debug

EXAMPLES:
  # Run all tests with auto-detected camera plugin
  $0

  # Explicitly test qtiqmmfsrc (10 tests)
  $0 --plugin qtiqmmfsrc

  # Explicitly test libcamerasrc (7 tests)
  $0 --plugin libcamerasrc

  # Run only fakesink tests with qtiqmmfsrc
  $0 --plugin qtiqmmfsrc --test-modes fakesink

  # Run only fakesink tests with libcamerasrc
  $0 --plugin libcamerasrc --test-modes fakesink

  # Run libcamerasrc preview tests (2 tests)
  $0 --plugin libcamerasrc --test-modes preview

  # Run libcamerasrc encode tests (3 tests)
  $0 --plugin libcamerasrc --test-modes encode

  # qtiqmmfsrc: Run fakesink and encode tests (8 tests)
  $0 --plugin qtiqmmfsrc --test-modes fakesink,encode

  # qtiqmmfsrc: Test only NV12 format (6 tests)
  $0 --plugin qtiqmmfsrc --formats nv12

  # qtiqmmfsrc: Test only UBWC format
  $0 --plugin qtiqmmfsrc --formats ubwc

  # Test specific resolutions for encode tests
  $0 --resolutions 720p,1080p

  # qtiqmmfsrc: Run encode tests with NV12 at 4K for 20 seconds
  $0 --plugin qtiqmmfsrc --test-modes encode --formats nv12 --resolutions 4k --duration 20

  # qtiqmmfsrc: Use camera 1 with custom framerate
  $0 --plugin qtiqmmfsrc --camera-id 1 --framerate 60

  # Using environment variables
  export CAMERA_PLUGIN="qtiqmmfsrc"
  export CAMERA_FORMATS="nv12"
  export CAMERA_RESOLUTIONS="720p"
  $0

TEST DETAILS:

  qtiqmmfsrc Tests (10):
    Fakesink (2):
      - fakesink_nv12  : NV12 format, 720p, no encoding
      - fakesink_ubwc  : UBWC format, 720p, no encoding
    
    Preview (2):
      - preview_nv12_4k : NV12 format, 4K, Weston display
      - preview_ubwc_4k : UBWC format, 4K, Weston display
    
    Encode (6):
      - encode_nv12_720p   : NV12, 1280x720, H.264 encode
      - encode_nv12_1080p  : NV12, 1920x1080, H.264 encode
      - encode_nv12_4k     : NV12, 3840x2160, H.264 encode
      - encode_ubwc_720p   : UBWC, 1280x720, H.264 encode
      - encode_ubwc_1080p  : UBWC, 1920x1080, H.264 encode
      - encode_ubwc_4k     : UBWC, 3840x2160, H.264 encode

  libcamerasrc Tests (7):
    Fakesink (2):
      - libcam_720p_Fakesink    : 720p, no encoding
      - libcam_1080p_Fakesink   : 1080p, no encoding
    
    Preview (2):
      - libcam_720p_Preview    : 720p, Weston display
      - libcam_1080p_Preview   : 1080p, Weston display
    
    Encode (3):
      - libcam_720p_NV12_Encode  : NV12, 1280x720, H.264 encode
      - libcam_1080p_NV12_Encode : NV12, 1920x1080, H.264 encode
      - libcam_4k_NV12_Encode    : NV12, 3840x2160, H.264 encode

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
    - Pipeline: qtiqmmfsrc ! video/x-raw,format=NV12_Q08C ! ...

OUTPUT:
  Result File:  Camera_Tests.res (PASS/FAIL/SKIP)
  Logs:         logs/Camera_Tests/*.log
  Videos:       logs/Camera_Tests/encoded/*.mp4
  GStreamer:    logs/Camera_Tests/gst.log
  Kernel Logs:  logs/Camera_Tests/dmesg/

PREREQUISITES:
  Required Tools:
    - gst-launch-1.0 (GStreamer command-line tool)
    - gst-inspect-1.0 (GStreamer plugin inspector)

  Required Plugins:
    For qtiqmmfsrc (10 tests):
      - qtiqmmfsrc (Qualcomm camera source)
      - v4l2h264enc (V4L2 H.264 encoder, for encode)
      - waylandsink (Wayland display, for preview)
    
    For libcamerasrc (7 tests):
      - libcamerasrc (Upstream camera source)
      - videoconvert (Video format converter, required)
      - v4l2h264enc (V4L2 H.264 encoder, for encode)
      - waylandsink (Wayland display, for preview)

  Hardware:
    - Qualcomm camera hardware
    - Weston display server (for preview tests)
    - Write permissions to output directories

SUCCESS CRITERIA:
  Fakesink:  Pipeline runs without errors, exit code 0
  Preview:   Pipeline runs, video displays on screen, exit code 0
  Encode:    Pipeline runs, MP4 file created (size > 1000 bytes)

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
# shellcheck disable=SC2034
CHECK_DEPS_NO_EXIT=1
if ! check_dependencies "gst-launch-1.0 gst-inspect-1.0"; then
  log_skip "Missing required tools"
  echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi
unset CHECK_DEPS_NO_EXIT

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
if has_element qtiqmmfsrc; then
  qtiqmmfsrc_available=1
  log_info "✓ qtiqmmfsrc detected - CAMX downstream camera available"
else
  log_info "✗ qtiqmmfsrc not detected"
fi

# Check for libcamerasrc (upstream camera)
if has_element libcamerasrc; then
  libcamerasrc_available=1
  log_info "✓ libcamerasrc detected - Upstream camera available"
else
  log_info "✗ libcamerasrc not detected"
fi

# Determine which camera source to use based on --plugin argument or auto-detection
case "$cameraPlugin" in
  qtiqmmfsrc)
    if [ "$qtiqmmfsrc_available" -eq 1 ]; then
      camera_source="qtiqmmfsrc"
      log_info "Using qtiqmmfsrc (CAMX downstream camera) - explicitly requested"
      log_info "Will run 10 qtiqmmfsrc tests: fakesink(2) + preview(2) + encode(6)"
    else
      log_skip "qtiqmmfsrc explicitly requested but not available"
      echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
      exit 0
    fi
    ;;
  libcamerasrc)
    if [ "$libcamerasrc_available" -eq 1 ]; then
      camera_source="libcamerasrc"
      log_info "Using libcamerasrc (upstream camera) - explicitly requested"
      log_info "Will run 7 libcamerasrc tests: fakesink(2) + preview(2) + encode(3)"
    else
      log_skip "libcamerasrc explicitly requested but not available"
      echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
      exit 0
    fi
    ;;
  auto|*)
    # Auto-detection: Priority qtiqmmfsrc > libcamerasrc > skip if neither
    if [ "$qtiqmmfsrc_available" -eq 1 ]; then
      camera_source="qtiqmmfsrc"
      log_info "Using qtiqmmfsrc (CAMX downstream camera) for tests"
      if [ "$libcamerasrc_available" -eq 1 ]; then
        log_info "Note: Both qtiqmmfsrc and libcamerasrc detected, prioritizing qtiqmmfsrc"
        log_info "Use --plugin libcamerasrc to explicitly test libcamerasrc instead"
      fi
      log_info "Will run 10 qtiqmmfsrc tests: fakesink(2) + preview(2) + encode(6)"
    elif [ "$libcamerasrc_available" -eq 1 ]; then
      camera_source="libcamerasrc"
      log_info "Using libcamerasrc (upstream camera) for tests"
      log_info "Will run 7 libcamerasrc tests: fakesink(2) + preview(2) + encode(3)"
    else
      log_skip "No camera source plugin available (neither qtiqmmfsrc nor libcamerasrc detected)"
      echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
      exit 0
    fi
    ;;
esac

log_info "=========================================="

# Function: Essential pre-flight checks
# Only checks that directly affect whether tests can run
camera_preflight_checks() {
  log_info "=========================================="
  log_info "CAMERA PRE-FLIGHT CHECKS"
  log_info "=========================================="
  
  checks_passed=0
  checks_failed=0
  
  # Check 1: GStreamer plugin validation (CRITICAL)
  log_info "[1/2] GStreamer plugin validation..."
  if has_element "$camera_source"; then
    log_pass "  ✓ GStreamer plugin available: $camera_source"
    checks_passed=$((checks_passed + 1))
  else
    log_fail "  ✗ GStreamer plugin missing: $camera_source"
    checks_failed=$((checks_failed + 1))
  fi
  
  # Check 2: Required encoder plugin (only if encode tests are requested)
  if echo "$testModeList" | grep -q "encode"; then
    log_info "[2/2] H.264 encoder plugin check..."
    if has_element v4l2h264enc; then
      log_pass "  ✓ v4l2h264enc available"
      checks_passed=$((checks_passed + 1))
    else
      log_warn "  ⚠ v4l2h264enc not available (encode tests will be skipped)"
    fi
  else
    log_info "[2/2] H.264 encoder plugin check... skipped (encode tests not requested)"
    checks_passed=$((checks_passed + 1))
  fi
  
  log_info "=========================================="
  log_info "Pre-flight summary: $checks_passed passed, $checks_failed failed"
  log_info "=========================================="
  
  if [ "$checks_failed" -gt 0 ]; then
    return 1
  fi
  
  return 0
}

# Function: Enhanced failure diagnostics
diagnose_camera_failure() {
  testname="$1"
  log_file="$2"
  
  log_info "=========================================="
  log_info "FAILURE DIAGNOSTICS: $testname"
  log_info "=========================================="
  
  # Check for common GStreamer errors
  if grep -qi "Could not open camera\|cannot open camera\|failed to open camera" "$log_file"; then
    log_fail "Issue: Camera device not accessible"
    log_info "Possible causes:"
    log_info "  - Camera hardware not connected"
    log_info "  - Insufficient permissions"
    log_info "  - Camera in use by another process"
    log_info ""
    log_info "Diagnostics:"
    log_info "  Video devices:"
    # shellcheck disable=SC2012
    ls -l /dev/video* 2>&1 | head -5 | while IFS= read -r line; do
      log_info "    $line"
    done
  fi
  
  if grep -qi "not-negotiated\|negotiation failed\|could not negotiate" "$log_file"; then
    log_fail "Issue: Format negotiation failed"
    log_info "Possible causes:"
    log_info "  - Requested format/resolution not supported by camera"
    log_info "  - Pipeline element incompatibility"
    log_info "  - Missing caps filter or incorrect format string"
    log_info ""
    
    # Show what was requested
    if grep -q "video/x-raw" "$log_file"; then
      requested=$(grep -o "video/x-raw[^!]*" "$log_file" | head -1)
      log_info "  Requested caps: $requested"
    fi
  fi
  
  if grep -qi "firmware" "$log_file"; then
    log_fail "Issue: Firmware-related error detected"
    
    if command -v camx_find_icp_firmware >/dev/null 2>&1; then
      icp_fw=$(camx_find_icp_firmware 2>/dev/null || echo "")
      if [ -z "$icp_fw" ]; then
        log_fail "  ICP firmware not found"
        log_info "  Expected location: /lib/firmware/qcom/*/CAMERA_ICP*.{mbn,elf}"
      else
        log_info "  ICP firmware present: $icp_fw"
        log_info "  Firmware may be corrupted or incompatible"
      fi
    fi
  fi
  
  if grep -qi "device.*not.*found\|no such device" "$log_file"; then
    log_fail "Issue: Device not found"
    log_info ""
    log_info "Hardware check:"
    
    # Check Device Tree camera nodes
    if command -v camx_fdtdump_has_cam_nodes >/dev/null 2>&1; then
      if camx_fdtdump_has_cam_nodes >/dev/null 2>&1; then
        log_info "  ✓ Camera nodes found in Device Tree"
      else
        log_fail "  ✗ No camera nodes in Device Tree"
        log_info "    Hardware may not be properly configured"
      fi
    fi
    
    # Check video devices
    # shellcheck disable=SC2012
    video_count=$(ls /dev/video* 2>/dev/null | wc -l)
    if [ "$video_count" -eq 0 ]; then
      log_fail "  ✗ No /dev/video* devices found"
      log_info "    Camera driver may not be loaded"
    else
      log_info "  ✓ Video devices present: $video_count"
    fi
  fi
  
  if grep -qi "timeout\|timed out" "$log_file"; then
    log_fail "Issue: Operation timeout"
    log_info "Possible causes:"
    log_info "  - Camera hardware not responding"
    log_info "  - Driver issue or hang"
    log_info "  - Insufficient system resources"
  fi
  
  if grep -qi "permission denied\|access denied" "$log_file"; then
    log_fail "Issue: Permission denied"
    log_info "Solution: Add user to video group:"
    log_info "  sudo usermod -a -G video \$USER"
    log_info "  (logout and login required)"
  fi
  
  # Check for UBWC-specific issues
  if echo "$testname" | grep -q "ubwc" && grep -qi "format.*not.*supported" "$log_file"; then
    log_fail "Issue: UBWC format not supported"
    log_info "Verify pipeline includes: qtiqmmfsrc ! video/x-raw,format=NV12_Q08C"
  fi
  
  # Check kernel logs for related errors
  if [ -d "$DMESG_DIR" ] && [ -f "$DMESG_DIR/dmesg_errors.log" ]; then
    if grep -qi "camera\|video\|v4l2" "$DMESG_DIR/dmesg_errors.log"; then
      log_warn "Kernel errors detected (see dmesg_errors.log):"
      grep -i "camera\|video\|v4l2" "$DMESG_DIR/dmesg_errors.log" | head -3 | while IFS= read -r line; do
        log_info "  $line"
      done
    fi
  fi
  
  log_info "=========================================="
}

# Run essential pre-flight checks
if ! camera_preflight_checks; then
  log_fail "=========================================="
  log_fail "CRITICAL: Pre-flight checks failed"
  log_fail "=========================================="
  log_fail "GStreamer plugin not available - cannot run tests"
  log_fail ""
  log_fail "Recommended actions:"
  log_fail "  1. Check GStreamer plugin installation"
  log_fail "  2. Verify camera hardware is connected"
  log_fail "  3. Check camera driver is loaded"
  log_fail "=========================================="
  
  echo "$RESULT_TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

# -------------------- GStreamer debug capture --------------------
export GST_DEBUG_NO_COLOR=1
export GST_DEBUG="$gstDebugLevel"
export GST_DEBUG_FILE="$GST_LOG"

# -------------------- Test Functions --------------------

# Centralized camera test runner
# Handles common pattern: build pipeline -> log -> run -> validate -> diagnose -> update counters
# Parameters:
#   $1: testname
#   $2: pipeline
#   $3: output_file (optional, for encode tests)
#   $4: restart_cam_server (optional, "yes" to restart cam-server before test - qtiqmmfsrc only)
run_camera_test() {
  testname="$1"
  pipeline="$2"
  output_file="${3:-}"
  restart_cam_server="${4:-no}"
  
  log_info "=========================================="; log_info "Running: $testname"; log_info "=========================================="
  
  # Restart cam-server if requested (temporary workaround for qtiqmmfsrc only)
  # libcamerasrc doesn't use cam-server, so this is skipped for libcamerasrc tests
  if [ "$restart_cam_server" = "yes" ] && [ "$camera_source" = "qtiqmmfsrc" ]; then
    log_info "Restarting cam-server..."
    systemctl restart cam-server >/dev/null 2>&1 || log_warn "Failed to restart cam-server (may not be critical)"
    sleep 1
  fi
  
  test_log="$OUTDIR/${testname}.log"
  : >"$test_log"
  
  if [ -z "$pipeline" ]; then
    log_warn "$testname: Failed to build pipeline"; skip_count=$((skip_count + 1)); return 1
  fi
  
  log_info "Pipeline: gst-launch-1.0 -e $pipeline"
  
  # Run pipeline with timeout
  if gstreamer_run_gstlaunch_timeout "$((duration + 10))" "$pipeline" >>"$test_log" 2>&1; then gstRc=0; else gstRc=$?; fi
  
  # Validate log
  if ! gstreamer_validate_log "$test_log" "$testname"; then
    diagnose_camera_failure "$testname" "$test_log"
    log_fail "$testname: FAIL"; fail_count=$((fail_count + 1)); return 1
  fi
  
  # Check for output file if encode test
  if [ -n "$output_file" ]; then
    if [ -f "$output_file" ] && [ -s "$output_file" ]; then
      file_size=$(gstreamer_file_size_bytes "$output_file")
      # Treat timeout (124) as success if file was created - test is designed to run until timeout
      if [ "$file_size" -gt 1000 ] && { [ "$gstRc" -eq 0 ] || [ "$gstRc" -eq 124 ]; }; then 
        log_info "Output file size: $file_size bytes ($(awk "BEGIN {printf \"%.2f\", $file_size/1024/1024}") MB)"
        log_pass "$testname: PASS"; pass_count=$((pass_count + 1)); return 0
      else 
        diagnose_camera_failure "$testname" "$test_log"
        log_fail "$testname: FAIL (file too small or bad exit code)"; fail_count=$((fail_count + 1)); return 1
      fi
    else 
      diagnose_camera_failure "$testname" "$test_log"
      log_fail "$testname: FAIL (no output)"; fail_count=$((fail_count + 1)); return 1
    fi
  else
    # Non-encode test: treat timeout (124) as success
    if [ "$gstRc" -eq 0 ] || [ "$gstRc" -eq 124 ]; then 
      log_pass "$testname: PASS"; pass_count=$((pass_count + 1)); return 0
    else 
      diagnose_camera_failure "$testname" "$test_log"
      log_fail "$testname: FAIL (rc=$gstRc)"; fail_count=$((fail_count + 1)); return 1
    fi
  fi
}

# qtiqmmfsrc Fakesink test
run_qtiqmmf_fakesink_test() {
  format="$1"
  
  case "$format" in
    nv12) format_name="NV12" ;;
    ubwc) format_name="UBWC" ;;
    *) log_warn "Unknown format: $format"; skip_count=$((skip_count + 1)); return 1 ;;
  esac
  
  testname="fakesink_${format}"
  log_info "Format: $format_name"
  
  pipeline=$(camera_build_qtiqmmfsrc_fakesink_pipeline "$cameraId" "$format" 1280 720 "$framerate")
  run_camera_test "$testname" "$pipeline" "" "yes"
}

# qtiqmmfsrc Preview test
run_qtiqmmf_preview_test() {
  format="$1"
  
  case "$format" in
    nv12) format_name="NV12" ;;
    ubwc) format_name="UBWC" ;;
    *) log_warn "Unknown format: $format"; skip_count=$((skip_count + 1)); return 1 ;;
  esac
  
  if ! has_element waylandsink; then
    log_warn "waylandsink not available, skipping preview test"
    skip_count=$((skip_count + 1)); return 1
  fi
  
  testname="preview_${format}_4k"
  log_info "Format: $format_name"
  
  pipeline=$(camera_build_qtiqmmfsrc_preview_pipeline "$cameraId" "$format" 3840 2160 "$framerate")
  run_camera_test "$testname" "$pipeline" "" "yes"
}

# qtiqmmfsrc Encode test
run_qtiqmmf_encode_test() {
  format="$1"
  resolution="$2"
  width="$3"
  height="$4"
  
  case "$format" in
    nv12) format_name="NV12" ;;
    ubwc) format_name="UBWC" ;;
    *) log_warn "Unknown format: $format"; skip_count=$((skip_count + 1)); return 1 ;;
  esac
  
  if ! has_element v4l2h264enc; then
    log_warn "v4l2h264enc not available, skipping encode test"
    skip_count=$((skip_count + 1)); return 1
  fi
  
  testname="encode_${format}_${resolution}"
  output_file="$ENCODED_DIR/${testname}.mp4"
  
  log_info "Format: $format_name"
  log_info "Resolution: $resolution (${width}x${height})"
  
  pipeline=$(camera_build_qtiqmmfsrc_encode_pipeline "$cameraId" "$format" "$width" "$height" "$framerate" "$output_file")
  run_camera_test "$testname" "$pipeline" "$output_file" "yes"
}

# -------------------- libcamerasrc Test Functions --------------------

# Fakesink test (parameterized)
run_libcam_fakesink_test() {
  width="$1"
  height="$2"
  
  # Determine test name based on resolution
  if [ "$width" -eq 0 ] 2>/dev/null || [ "$height" -eq 0 ] 2>/dev/null; then
    testname="libcam_Default_Fakesink"
    res_name="default"
  else
    testname="libcam_${width}x${height}_Fakesink"
    res_name="${width}x${height}"
  fi
  
  log_info "Resolution: $res_name"
  
  pipeline=$(camera_build_libcamera_fakesink_pipeline "$width" "$height" "$framerate")
  run_camera_test "$testname" "$pipeline"
}

# Preview test (parameterized)
run_libcam_preview_test() {
  width="$1"
  height="$2"
  
  if ! has_element waylandsink; then
    log_warn "waylandsink not available, skipping libcam preview test"
    skip_count=$((skip_count + 1)); return 1
  fi
  
  if ! has_element videoconvert; then
    log_warn "videoconvert not available, skipping libcam preview test"
    skip_count=$((skip_count + 1)); return 1
  fi
  
  # Determine test name based on resolution
  if [ "$width" -eq 0 ] 2>/dev/null || [ "$height" -eq 0 ] 2>/dev/null; then
    testname="libcam_Default_Preview"
    res_name="default"
  elif [ "$width" -eq 1280 ] && [ "$height" -eq 720 ]; then
    testname="libcam_720p_Preview"
    res_name="720p"
  elif [ "$width" -eq 1920 ] && [ "$height" -eq 1080 ]; then
    testname="libcam_1080p_Preview"
    res_name="1080p"
  else
    testname="libcam_${width}x${height}_Preview"
    res_name="${width}x${height}"
  fi
  
  log_info "Resolution: $res_name"
  
  pipeline=$(camera_build_libcamera_preview_pipeline "$width" "$height" "$framerate")
  run_camera_test "$testname" "$pipeline"
}

# Encode test (parameterized)
run_libcam_encode_test() {
  width="$1"
  height="$2"
  resolution_name="$3"
  
  if ! has_element v4l2h264enc; then
    log_warn "v4l2h264enc not available, skipping libcam encode test"
    skip_count=$((skip_count + 1)); return 1
  fi
  
  if ! has_element videoconvert; then
    log_warn "videoconvert not available, skipping libcam encode test"
    skip_count=$((skip_count + 1)); return 1
  fi
  
  testname="libcam_${resolution_name}_NV12_Encode"
  output_file="$ENCODED_DIR/sample_${resolution_name}.mp4"
  
  log_info "Resolution: $resolution_name (${width}x${height})"
  
  pipeline=$(camera_build_libcamera_encode_pipeline "$width" "$height" "$output_file" "$framerate")
  run_camera_test "$testname" "$pipeline" "$output_file"
}

# -------------------- Main test execution --------------------
if [ "$camera_source" = "libcamerasrc" ]; then
  log_info "Starting libcamerasrc tests: fakesink -> preview -> encode"
  
  # Parse test modes and resolutions for libcamerasrc
  test_modes=$(printf '%s' "$testModeList" | tr ',' ' ')
  resolutions=$(printf '%s' "$resolutionList" | tr ',' ' ')
  
  # Wayland/Weston environment setup for libcamerasrc preview tests
  log_info "=========================================="
  log_info "LIBCAMERA - WAYLAND SETUP"
  log_info "=========================================="
  
  wayland_ready=0
  camera_setup_wayland_environment "Libcamera_Tests"
  
  # Run tests based on test modes filter
  for mode in $test_modes; do
    case "$mode" in
      fakesink)
        log_info "=========================================="
        log_info "LIBCAMERA FAKESINK TESTS"
        log_info "=========================================="
        
        # Run fakesink tests based on resolution filter (only 720p and 1080p supported)
        for res in $resolutions; do
          case "$res" in
            720p)
              total_tests=$((total_tests + 1))
              run_libcam_fakesink_test 1280 720 || true  # 720p
              ;;
            1080p)
              total_tests=$((total_tests + 1))
              run_libcam_fakesink_test 1920 1080 || true  # 1080p
              ;;
            default|4k|*)
              # Only 720p and 1080p fakesink supported for libcamerasrc
              total_tests=$((total_tests + 1))
              skip_count=$((skip_count + 1))
              log_warn "libcamerasrc fakesink: Resolution '$res' not supported (only 720p and 1080p are supported)"
              ;;
          esac
        done
        ;;
      
      preview)
        # Preview tests - require Wayland
        if [ "$wayland_ready" -eq 1 ]; then
          log_info "=========================================="
          log_info "LIBCAMERA PREVIEW TESTS"
          log_info "=========================================="
          
          # Run preview tests based on resolution filter (only 720p and 1080p supported)
          for res in $resolutions; do
            case "$res" in
              720p)
                total_tests=$((total_tests + 1))
                run_libcam_preview_test 1280 720 || true  # 720p
                ;;
              1080p)
                total_tests=$((total_tests + 1))
                run_libcam_preview_test 1920 1080 || true  # 1080p
                ;;
              default|4k|*)
                # Only 720p and 1080p preview supported for libcamerasrc
                total_tests=$((total_tests + 1))
                skip_count=$((skip_count + 1))
                log_warn "libcamerasrc preview: Resolution '$res' not supported (only 720p and 1080p are supported)"
                ;;
            esac
          done
        else
          log_warn "Wayland/Weston not available, skipping libcamera preview tests"
          log_warn "To run preview tests, ensure Weston is running or WAYLAND_DISPLAY is set"
          # Count skipped tests based on resolutions (only 720p and 1080p)
          for res in $resolutions; do
            case "$res" in
              720p|1080p)
                total_tests=$((total_tests + 1))
                skip_count=$((skip_count + 1))
                ;;
            esac
          done
        fi
        ;;
      
      encode)
        log_info "=========================================="
        log_info "LIBCAMERA ENCODE TESTS"
        log_info "=========================================="
        
        # Run encode tests based on resolution filter
        for res in $resolutions; do
          case "$res" in
            720p)
              total_tests=$((total_tests + 1))
              run_libcam_encode_test 1280 720 "720p" || true
              ;;
            1080p)
              total_tests=$((total_tests + 1))
              run_libcam_encode_test 1920 1080 "1080p" || true
              ;;
            4k)
              total_tests=$((total_tests + 1))
              run_libcam_encode_test 3840 2160 "4k" || true
              ;;
            *)
              log_warn "Unknown resolution for encode: $res"
              ;;
          esac
        done
        ;;
      
      *)
        log_warn "Unknown test mode for libcamerasrc: $mode"
        ;;
    esac
  done
  
else
  # qtiqmmfsrc tests
  log_info "Starting camera tests in sequence: fakesink -> preview -> encode"
  
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
          run_qtiqmmf_fakesink_test "$format" || true
        done
        ;;
      preview)
        log_info "=========================================="
        log_info "PREVIEW TESTS - WAYLAND SETUP"
        log_info "=========================================="
        
        # Wayland/Weston environment setup for preview tests
        wayland_ready=0
        camera_setup_wayland_environment "Camera_Preview"
        
        # Run preview tests if Wayland is ready
        if [ "$wayland_ready" -eq 1 ]; then
          log_info "=========================================="
          log_info "PREVIEW TESTS"
          log_info "=========================================="
          for format in $formats; do
            total_tests=$((total_tests + 1))
            run_qtiqmmf_preview_test "$format" || true
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
            run_qtiqmmf_encode_test "$format" "$res" "$width" "$height" || true
          done
        done
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
  if [ -s "$DMESG_DIR/dmesg_errors.log" ]; then
    log_warn "dmesg scan found warnings or errors"
  else
    log_info "No relevant errors found in dmesg"
  fi
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
  PASS) log_pass "$TESTNAME $result: $reason"; echo "$RESULT_TESTNAME PASS" >"$RES_FILE" ;;
  FAIL) log_fail "$TESTNAME $result: $reason"; echo "$RESULT_TESTNAME FAIL" >"$RES_FILE" ;;
  *) log_warn "$TESTNAME $result: $reason"; echo "$RESULT_TESTNAME SKIP" >"$RES_FILE" ;;
esac

exit 0
