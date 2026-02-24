#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Waylandsink Playback validation using GStreamer
# Tests video playback using waylandsink with videotestsrc
# Validates Weston/Wayland server and display connectivity
# CI/LAVA-friendly (always exits 0, writes .res file)

SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"

TESTNAME="Waylandsink_Playback"
RES_FILE="${SCRIPT_DIR}/${TESTNAME}.res"
LOG_DIR="${SCRIPT_DIR}/logs"
OUTDIR="$LOG_DIR/$TESTNAME"
GST_LOG="$OUTDIR/gst.log"
RUN_LOG="$OUTDIR/run.log"

mkdir -p "$OUTDIR" >/dev/null 2>&1 || true
: >"$RES_FILE"
: >"$GST_LOG"
: >"$RUN_LOG"

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
[ -f "$TOOLS/lib_display.sh" ] && . "$TOOLS/lib_display.sh"

result="FAIL"
reason="unknown"

# -------------------- Defaults --------------------
# Validate environment variables if set
if [ -n "${VIDEO_DURATION:-}" ] && ! echo "$VIDEO_DURATION" | grep -q "^[0-9]\+$"; then
  log_warn "VIDEO_DURATION must be numeric (got '$VIDEO_DURATION')"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi
if [ -n "${RUNTIMESEC:-}" ] && ! echo "$RUNTIMESEC" | grep -q "^[0-9]\+$"; then
  log_warn "RUNTIMESEC must be numeric (got '$RUNTIMESEC')"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi
if [ -n "${VIDEO_FRAMERATE:-}" ] && ! echo "$VIDEO_FRAMERATE" | grep -q "^[0-9]\+$"; then
  log_warn "VIDEO_FRAMERATE must be numeric (got '$VIDEO_FRAMERATE')"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi
if [ -n "${VIDEO_GST_DEBUG:-${GST_DEBUG_LEVEL:-}}" ] && ! echo "${VIDEO_GST_DEBUG:-${GST_DEBUG_LEVEL:-}}" | grep -q "^[0-9]\+$"; then
  log_warn "GST debug level must be numeric (got '${VIDEO_GST_DEBUG:-${GST_DEBUG_LEVEL:-}}')"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

duration="${VIDEO_DURATION:-${RUNTIMESEC:-30}}"
pattern="${VIDEO_PATTERN:-smpte}"
width="${VIDEO_WIDTH:-1920}"
height="${VIDEO_HEIGHT:-1080}"
framerate="${VIDEO_FRAMERATE:-30}"
gstDebugLevel="${VIDEO_GST_DEBUG:-${GST_DEBUG_LEVEL:-2}}"

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
    --resolution)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --resolution"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      # Parse and validate WIDTHxHEIGHT format (e.g., 1920x1080)
      if [ -n "$2" ]; then
        # Validate format contains 'x'
        if ! echo "$2" | grep -q "x"; then
          log_warn "Invalid resolution format '$2' - must be WIDTHxHEIGHT"
          echo "$TESTNAME SKIP" >"$RES_FILE"
          exit 0
        fi
        
        width="${2%%x*}"
        height="${2#*x}"
        
        # Validate both width and height are numeric
        if ! echo "$width" | grep -q "^[0-9]\+$" || ! echo "$height" | grep -q "^[0-9]\+$"; then
          log_warn "Width and height must be numeric values (got width='$width', height='$height')"
          echo "$TESTNAME SKIP" >"$RES_FILE"
          exit 0
        fi
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
        if ! echo "$2" | grep -q "^[0-9]\+$"; then
          log_warn "Duration must be a numeric value (got '$2')"
          echo "$TESTNAME SKIP" >"$RES_FILE"
          exit 0
        fi
        duration="$2"
      fi
      shift 2
      ;;

    --pattern)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --pattern"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      # If $2 is empty, keep default and shift 2
      [ -n "$2" ] && pattern="$2"
      shift 2
      ;;

    --width)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --width"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      # Validate width is numeric
      if [ -n "$2" ]; then
        if ! echo "$2" | grep -q "^[0-9]\+$"; then
          log_warn "Width must be a numeric value (got '$2')"
          echo "$TESTNAME SKIP" >"$RES_FILE"
          exit 0
        fi
        width="$2"
      fi
      shift 2
      ;;

    --height)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --height"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      # Validate height is numeric
      if [ -n "$2" ]; then
        if ! echo "$2" | grep -q "^[0-9]\+$"; then
          log_warn "Height must be a numeric value (got '$2')"
          echo "$TESTNAME SKIP" >"$RES_FILE"
          exit 0
        fi
        height="$2"
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
        if ! echo "$2" | grep -q "^[0-9]\+$"; then
          log_warn "Framerate must be a numeric value (got '$2')"
          echo "$TESTNAME SKIP" >"$RES_FILE"
          exit 0
        fi
        framerate="$2"
      fi
      shift 2
      ;;

    --gst-debug)
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --gst-debug"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
      fi
      if ! echo "$2" | grep -q "^[0-9]\+$"; then
        log_warn "GST debug level must be numeric (got '$2')"
        echo "$TESTNAME SKIP" >"$RES_FILE"
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
  --resolution <WIDTHxHEIGHT>
      Video resolution (e.g., 1920x1080, 3840x2160)
      Default: ${width}x${height}

  --duration <seconds>
      Playback duration in seconds
      Default: ${duration}

  --pattern <smpte|snow|ball|etc>
      videotestsrc pattern
      Default: ${pattern}

  --width <pixels>
      Video width (alternative to --resolution)
      Default: ${width}

  --height <pixels>
      Video height (alternative to --resolution)
      Default: ${height}

  --framerate <fps>
      Video framerate
      Default: ${framerate}

  --gst-debug <level>
      Sets GST_DEBUG=<level> (1-9)
      Default: ${gstDebugLevel}

Examples:
  # Run default test (1920x1080 SMPTE pattern for 30s)
  ./run.sh

  # Run with custom resolution and duration
  ./run.sh --resolution 3840x2160 --duration 20

  # Run with different pattern
  ./run.sh --pattern ball

  # Run with separate width/height
  ./run.sh --width 1280 --height 720

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

# Basic sanity
if [ "$duration" -le 0 ] || [ "$width" -le 0 ] || [ "$height" -le 0 ] || [ "$framerate" -le 0 ]; then
  log_warn "Invalid parameters: duration=$duration width=$width height=$height framerate=$framerate"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

# -------------------- Pre-checks --------------------
check_dependencies "gst-launch-1.0 gst-inspect-1.0 grep head sed tail date mktemp" >/dev/null 2>&1 || {
  log_skip "Missing required tools (gst-launch-1.0, gst-inspect-1.0, grep, head, sed, tail, date, mktemp)"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
}

log_info "Test: $TESTNAME"
log_info "Duration: ${duration}s, Resolution: ${width}x${height}, Framerate: ${framerate}fps"
log_info "Pattern: $pattern"
log_info "GST debug: GST_DEBUG=$gstDebugLevel"
log_info "Logs: $OUTDIR"

# -------------------- Display connectivity check --------------------
if command -v display_debug_snapshot >/dev/null 2>&1; then
  display_debug_snapshot "pre-test"
fi

have_connector=0
if command -v display_connected_summary >/dev/null 2>&1; then
  sysfs_summary=$(display_connected_summary)
  if [ -n "$sysfs_summary" ] && [ "$sysfs_summary" != "none" ]; then
    have_connector=1
    log_info "Connected display (sysfs): $sysfs_summary"
  fi
fi

# Fallback: check /sys/class/drm/*/status
if [ "$have_connector" -eq 0 ]; then
  drm_connected=""
  for st in /sys/class/drm/card*-*/status; do
    [ -f "$st" ] || continue
    if grep -qi "connected" "$st"; then
      conn=$(basename "$(dirname "$st")")
      drm_connected="${drm_connected}${drm_connected:+,}${conn}"
    fi
  done
  if [ -n "$drm_connected" ]; then
    have_connector=1
    log_info "Connected display (drm sysfs): $drm_connected"
  fi
fi

if [ "$have_connector" -eq 0 ]; then
  log_warn "No connected DRM display found, skipping ${TESTNAME}."
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

# -------------------- Wayland/Weston environment check --------------------
if command -v wayland_debug_snapshot >/dev/null 2>&1; then
  wayland_debug_snapshot "${TESTNAME}: start"
fi

sock=""

# Try to find existing Wayland socket
if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
  sock=$(discover_wayland_socket_anywhere | head -n 1 || true)
fi

# Adopt socket environment if found
if [ -n "$sock" ] && command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
  log_info "Found existing Wayland socket: $sock"
  if ! adopt_wayland_env_from_socket "$sock"; then
    log_warn "Failed to adopt env from $sock"
  fi
fi

# Try starting Weston if no socket found
if [ -z "$sock" ]; then
  if command -v weston_pick_env_or_start >/dev/null 2>&1; then
    log_info "No usable Wayland socket; trying weston_pick_env_or_start..."
    if weston_pick_env_or_start "${TESTNAME}"; then
      # Re-discover socket after Weston start
      if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
        sock=$(discover_wayland_socket_anywhere | head -n 1 || true)
      fi
      if [ -n "$sock" ]; then
        log_info "Weston started successfully with socket: $sock"
        if command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
          adopt_wayland_env_from_socket "$sock" >/dev/null 2>&1 || true
        fi
      fi
    else
      log_warn "weston_pick_env_or_start failed"
    fi
  elif command -v overlay_start_weston_drm >/dev/null 2>&1; then
    log_info "No usable Wayland socket; trying overlay_start_weston_drm (fallback)..."
    if overlay_start_weston_drm; then
      if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
        sock=$(discover_wayland_socket_anywhere | head -n 1 || true)
      fi
      if [ -n "$sock" ]; then
        log_info "Weston created Wayland socket: $sock"
        if command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
          adopt_wayland_env_from_socket "$sock" >/dev/null 2>&1 || true
        fi
      fi
    fi
  else
    log_warn "No Weston startup helper available (weston_pick_env_or_start or overlay_start_weston_drm)"
  fi
fi

# Final check
if [ -z "$sock" ]; then
  log_warn "No Wayland socket found; skipping ${TESTNAME}."
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

# Verify Wayland connection
if command -v wayland_connection_ok >/dev/null 2>&1; then
  if ! wayland_connection_ok; then
    log_warn "Wayland connection test failed; skipping ${TESTNAME}."
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
  fi
  log_info "Wayland connection test: OK"
fi

# -------------------- Check waylandsink element --------------------
if ! has_element waylandsink; then
  log_warn "waylandsink element not available"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

log_info "waylandsink element: available"

# -------------------- GStreamer debug capture --------------------
export GST_DEBUG_NO_COLOR=1
export GST_DEBUG="$gstDebugLevel"
export GST_DEBUG_FILE="$GST_LOG"

# -------------------- Build and run pipeline --------------------
# Make source real-time to match duration validation.
num_buffers=$((duration * framerate))

pipeline="videotestsrc is-live=true num-buffers=${num_buffers} pattern=${pattern} ! video/x-raw,width=${width},height=${height},framerate=${framerate}/1 ! videoconvert ! waylandsink"

log_info "Pipeline: $pipeline"

# Run with timeout
start_ts=$(date +%s)

# Give some slack, but timeout should still be treated as a real failure for this test
timeout_sec=$((duration + 15))

if gstreamer_run_gstlaunch_timeout "$timeout_sec" "$pipeline" >>"$RUN_LOG" 2>&1; then
  gstRc=0
else
  gstRc=$?
fi

end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))

log_info "Playback finished: rc=${gstRc} elapsed=${elapsed}s"

# -------------------- Validation --------------------
if [ "$duration" -gt 2 ]; then
  min_duration=$((duration - 2))
else
  min_duration=0
fi

# Check for GStreamer errors in both run log and GST debug log
run_log_ok=1
gst_log_ok=1

# Validate run log
if ! gstreamer_validate_log "$RUN_LOG" "$TESTNAME"; then
  run_log_ok=0
fi

# Validate last 1000 lines of GST debug log if it exists and has content
if [ -s "$GST_LOG" ]; then
  tmp_tail=$(mktemp "${OUTDIR}/gst.tail.XXXXXX" 2>/dev/null || mktemp) || tmp_tail=""
  if [ -n "$tmp_tail" ]; then
    tail -n 1000 "$GST_LOG" >"$tmp_tail" 2>/dev/null || true
    if ! gstreamer_validate_log "$tmp_tail" "$TESTNAME"; then
      gst_log_ok=0
    fi
    rm -f "$tmp_tail" >/dev/null 2>&1 || true
  else
    # If mktemp failed, fall back to validating the full GST log
    if ! gstreamer_validate_log "$GST_LOG" "$TESTNAME"; then
      gst_log_ok=0
    fi
  fi
  rm -f "${GST_LOG}.tail"
fi

if [ "$run_log_ok" -eq 0 ] || [ "$gst_log_ok" -eq 0 ]; then
  result="FAIL"
  if [ "$run_log_ok" -eq 0 ] && [ "$gst_log_ok" -eq 0 ]; then
    reason="GStreamer errors detected in both run log and GST debug log"
  elif [ "$run_log_ok" -eq 0 ]; then
    reason="GStreamer errors detected in run log"
  else
    reason="GStreamer errors detected in GST debug log"
  fi
else
  # First check if it ran long enough
  if [ "$elapsed" -ge "$min_duration" ]; then
    # If it ran long enough, check exit code
    case "$gstRc" in
      0)  # Normal exit
        result="PASS"
        reason="Playback completed successfully (elapsed=${elapsed}/${duration}s)"
        ;;
      124)
        result="FAIL"
        reason="Playback timed out (timeout=${timeout_sec}s, elapsed=${elapsed}s) - pipeline did not exit cleanly"
        ;;
      137|143)
        result="FAIL"
        reason="Playback killed by signal (rc=$gstRc, elapsed=${elapsed}s) - unexpected termination"
        ;;
      *)  # Unexpected return code
        result="FAIL"
        reason="Playback failed with unexpected exit code (rc=$gstRc, elapsed=${elapsed}/${duration}s)"
        ;;
    esac
  else
    # Didn't run long enough - always fail regardless of return code
    result="FAIL"
    reason="Playback exited too quickly (elapsed=${elapsed}s, minimum required=${min_duration}s)"
  fi
fi

# Helpful tails on failure (stdout visibility in CI)
if [ "$result" != "PASS" ]; then
  log_info "---- gst-launch output (tail) ----"
  tail -n 120 "$RUN_LOG" 2>/dev/null || true
  if [ -s "$GST_LOG" ]; then
    log_info "---- GST debug log (tail) ----"
    tail -n 120 "$GST_LOG" 2>/dev/null || true
  fi
fi

# -------------------- Emit result --------------------
case "$result" in
  PASS)
    log_pass "$TESTNAME $result: $reason"
    echo "$TESTNAME PASS" >"$RES_FILE"
    ;;
  *)
    log_fail "$TESTNAME $result: $reason"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    ;;
esac

exit 0
