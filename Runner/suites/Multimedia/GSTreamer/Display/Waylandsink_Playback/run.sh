#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Waylandsink Playback validation using GStreamer
# Tests video playback using waylandsink with videotestsrc
# Validates Weston/Wayland server and display connectivity
# CI/LAVA-friendly (always exits 0, writes .res file)

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
[ -f "$TOOLS/lib_display.sh" ] && . "$TOOLS/lib_display.sh"

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

result="FAIL"
reason="unknown"

# -------------------- Defaults --------------------
duration="${VIDEO_DURATION:-${RUNTIMESEC:-30}}"
pattern="${VIDEO_PATTERN:-smpte}"
width="${VIDEO_WIDTH:-1920}"
height="${VIDEO_HEIGHT:-1080}"
framerate="${VIDEO_FRAMERATE:-30}"
gstDebugLevel="${VIDEO_GST_DEBUG:-${GST_DEBUG_LEVEL:-2}}"

cleanup() {
  pkill -x gst-launch-1.0 >/dev/null 2>&1 || true
}
trap cleanup INT TERM EXIT

# -------------------- Arg parse --------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --duration)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --duration"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      duration="$2"
      shift 2
      ;;

    --pattern)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --pattern"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      pattern="$2"
      shift 2
      ;;

    --width)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --width"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      width="$2"
      shift 2
      ;;

    --height)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
        log_warn "Missing/invalid value for --height"
        echo "SKIP" >"$RES_FILE"
        exit 0
      fi
      height="$2"
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
  --duration <seconds>
      Playback duration in seconds
      Default: ${duration}

  --pattern <smpte|snow|ball|etc>
      videotestsrc pattern
      Default: ${pattern}

  --width <pixels>
      Video width
      Default: ${width}

  --height <pixels>
      Video height
      Default: ${height}

  --framerate <fps>
      Video framerate
      Default: ${framerate}

  --gst-debug <level>
      Sets GST_DEBUG=<level> (1-9)
      Default: ${gstDebugLevel}

Examples:
  # Run default test (1920x1080 SMPTE pattern for 10s)
  ./run.sh

  # Run with custom duration
  ./run.sh --duration 20

  # Run with different pattern
  ./run.sh --pattern ball

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

# -------------------- Pre-checks --------------------
check_dependencies "gst-launch-1.0" "gst-inspect-1.0" >/dev/null 2>&1 || {
  log_warn "Missing gstreamer runtime (gst-launch-1.0/gst-inspect-1.0)"
  echo "SKIP" >"$RES_FILE"
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

if [ "$have_connector" -eq 0 ]; then
  log_warn "No connected DRM display found, skipping ${TESTNAME}."
  echo "SKIP" >"$RES_FILE"
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
if [ -z "$sock" ] && command -v overlay_start_weston_drm >/dev/null 2>&1; then
  log_info "No usable Wayland socket; trying to start Weston..."
  if overlay_start_weston_drm; then
    if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
      sock=$(discover_wayland_socket_anywhere | head -n 1 || true)
    fi
    if [ -n "$sock" ] && command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
      log_info "Weston created Wayland socket: $sock"
      if ! adopt_wayland_env_from_socket "$sock"; then
        log_warn "Failed to adopt env from $sock"
      fi
    fi
  fi
fi

# Final check
if [ -z "$sock" ]; then
  log_warn "No Wayland socket found; skipping ${TESTNAME}."
  echo "SKIP" >"$RES_FILE"
  exit 0
fi

# Verify Wayland connection
if command -v wayland_connection_ok >/dev/null 2>&1; then
  if ! wayland_connection_ok; then
    log_fail "Wayland connection test failed; cannot run ${TESTNAME}."
    echo "SKIP" >"$RES_FILE"
    exit 0
  fi
  log_info "Wayland connection test: OK"
fi

# -------------------- Check waylandsink element --------------------
if ! has_element waylandsink; then
  log_warn "waylandsink element not available"
  echo "SKIP" >"$RES_FILE"
  exit 0
fi

log_info "waylandsink element: available"

# -------------------- GStreamer debug capture --------------------
export GST_DEBUG_NO_COLOR=1
export GST_DEBUG="$gstDebugLevel"
export GST_DEBUG_FILE="$GST_LOG"

# -------------------- Build and run pipeline --------------------
num_buffers=$((duration * framerate))

pipeline="videotestsrc num-buffers=${num_buffers} pattern=${pattern} ! video/x-raw,width=${width},height=${height},framerate=${framerate}/1 ! videoconvert ! waylandsink"

log_info "Pipeline: $pipeline"

# Run with timeout
start_ts=$(date +%s)

if gstreamer_run_gstlaunch_timeout "$((duration + 10))" "$pipeline" >>"$RUN_LOG" 2>&1; then
  gstRc=0
else
  gstRc=$?
fi

end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))

log_info "Playback finished: rc=${gstRc} elapsed=${elapsed}s"

# -------------------- Validation --------------------
# Check for GStreamer errors in log
if ! gstreamer_validate_log "$RUN_LOG" "$TESTNAME"; then
  result="FAIL"
  reason="GStreamer errors detected in log"
else
  # Accept 0 (normal) and 143 (timeout/SIGTERM) as success
  if [ "$gstRc" -eq 0 ] || [ "$gstRc" -eq 143 ]; then
    if [ "$elapsed" -ge "$((duration - 2))" ]; then
      result="PASS"
      reason="Playback completed successfully (rc=$gstRc, elapsed=${elapsed}s)"
    else
      result="FAIL"
      reason="Playback exited too quickly (elapsed=${elapsed}s, expected ~${duration}s)"
    fi
  else
    result="FAIL"
    reason="Playback failed (rc=$gstRc)"
  fi
fi

# -------------------- Emit result --------------------
case "$result" in
  PASS)
    log_pass "$TESTNAME $result: $reason"
    echo "PASS" >"$RES_FILE"
    ;;
  *)
    log_fail "$TESTNAME $result: $reason"
    echo "FAIL" >"$RES_FILE"
    ;;
esac

exit 0
