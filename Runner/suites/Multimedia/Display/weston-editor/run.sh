#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause#
# Validate weston-editor runs under a working Wayland session.
# - Uses lib_display.sh to adopt Wayland env (socket + XDG_RUNTIME_DIR)
# - CI-friendly logs and PASS/FAIL/SKIP semantics (LAVA-friendly: exits 0)
# - Optional Wayland protocol validation (WAYLAND_DEBUG based)
# - Optional screenshot delta validation (best-effort, skips if unauthorized)

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
  exit 1
fi

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
  # shellcheck disable=SC1090
  . "$INIT_ENV"
  __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_display.sh"

TESTNAME="weston-editor"
RES_FILE="./${TESTNAME}.res"
RUN_LOG="./${TESTNAME}_run.log"
ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || printf '%s' 0)"
STDOUT_LOG="./${TESTNAME}_stdout_${ts}.log"

: >"$RES_FILE"
: >"$RUN_LOG"
: >"$STDOUT_LOG"

DURATION="${DURATION:-30s}"
STOP_GRACE="${STOP_GRACE:-3s}"
VALIDATE_WAYLAND_PROTO="${VALIDATE_WAYLAND_PROTO:-1}"
VALIDATE_SCREENSHOT="${VALIDATE_SCREENSHOT:-0}"

BUILD_FLAVOUR="base"
if [ -f /usr/share/glvnd/egl_vendor.d/EGL_adreno.json ]; then
  BUILD_FLAVOUR="overlay"
fi

log_info "Weston log directory: $SCRIPT_DIR"
log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting ${TESTNAME} Testcase --------------------------"
log_info "Config: DURATION=${DURATION} VALIDATE_WAYLAND_PROTO=${VALIDATE_WAYLAND_PROTO} VALIDATE_SCREENSHOT=${VALIDATE_SCREENSHOT} BUILD_FLAVOUR=${BUILD_FLAVOUR}"

if command -v detect_platform >/dev/null 2>&1; then
  detect_platform
fi

if command -v display_debug_snapshot >/dev/null 2>&1; then
  display_debug_snapshot "pre-display-check"
fi

if command -v modetest >/dev/null 2>&1; then
  log_info "----- modetest -M msm -ac (capped at 200 lines) -----"
  modetest -M msm -ac 2>&1 | sed -n '1,200p' | while IFS= read -r l; do
    [ -n "$l" ] && log_info "[modetest] $l"
  done
  log_info "----- End modetest -M msm -ac -----"
else
  log_warn "modetest not found in PATH skipping modetest snapshot."
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
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

if command -v wayland_debug_snapshot >/dev/null 2>&1; then
  wayland_debug_snapshot "${TESTNAME}: start"
fi

sock=""
if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
  sock=$(discover_wayland_socket_anywhere | head -n 1 || true)
fi

if [ -n "$sock" ] && command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
  log_info "Found existing Wayland socket: $sock"
  if ! adopt_wayland_env_from_socket "$sock"; then
    log_warn "Failed to adopt env from $sock"
  fi
fi

if [ -z "$sock" ] && command -v overlay_start_weston_drm >/dev/null 2>&1; then
  log_info "No usable Wayland socket trying overlay_start_weston_drm helper..."
  if overlay_start_weston_drm; then
    if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
      sock=$(discover_wayland_socket_anywhere | head -n 1 || true)
    fi
    if [ -n "$sock" ] && command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
      log_info "Overlay Weston created Wayland socket: $sock"
      if ! adopt_wayland_env_from_socket "$sock"; then
        log_warn "Failed to adopt env from $sock"
      fi
    fi
  else
    log_warn "overlay_start_weston_drm returned non-zero private Weston may have failed to start."
  fi
fi

if [ -z "$sock" ]; then
  log_warn "No Wayland socket found after autodetection skipping ${TESTNAME}."
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

if command -v wayland_connection_ok >/dev/null 2>&1; then
  if ! wayland_connection_ok; then
    log_fail "Wayland connection test failed cannot run ${TESTNAME}."
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
  fi
  log_info "Wayland connection test: OK"
fi

if command -v display_is_cpu_renderer >/dev/null 2>&1; then
  if display_is_cpu_renderer auto; then
    log_skip "$TESTNAME SKIP: GPU HW acceleration not enabled (CPU/software renderer detected)"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
  fi
else
  log_warn "display_is_cpu_renderer helper not found continuing without GPU accel gating."
fi

if ! check_dependencies weston-editor; then
  log_fail "Required binary weston-editor not found in PATH."
  echo "$TESTNAME FAIL" >"$RES_FILE"
  exit 0
fi

BIN=$(command -v weston-editor)
log_info "Using weston-editor: $BIN"

# If GLVND overlay exists, prefer it for EGL clients.
if [ "$BUILD_FLAVOUR" = "overlay" ] && [ -f /usr/share/glvnd/egl_vendor.d/EGL_adreno.json ]; then
  __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/EGL_adreno.json
  export __EGL_VENDOR_LIBRARY_FILENAMES
  log_info "EGL vendor override: /usr/share/glvnd/egl_vendor.d/EGL_adreno.json"
fi

shot_begin_rc=2
if [ "$VALIDATE_SCREENSHOT" -ne 0 ]; then
  log_info "Screenshot delta validation enabled."
  if command -v display_screenshot_delta_begin >/dev/null 2>&1; then
    display_screenshot_delta_begin "$TESTNAME" "$SCRIPT_DIR"
    shot_begin_rc=$?
    if [ "$shot_begin_rc" -eq 0 ]; then
      log_info "Screenshot(before) captured."
    else
      if [ "$shot_begin_rc" -eq 2 ]; then
        log_warn "Screenshot tool not available skipping screenshot-delta validation."
      else
        log_warn "Failed to capture screenshot(before) skipping screenshot-delta validation."
      fi
    fi
  else
    log_warn "display_screenshot_delta_begin helper not found skipping screenshot-delta validation."
  fi
fi

log_info "Launching ${TESTNAME} for ${DURATION} ..."

start_ts=$(date +%s)

if [ "$VALIDATE_WAYLAND_PROTO" -ne 0 ]; then
  log_info "Wayland protocol validation enabled (WAYLAND_DEBUG=1)."
  WAYLAND_DEBUG=1
  export WAYLAND_DEBUG
fi

rc=0
if command -v run_with_timeout >/dev/null 2>&1; then
  log_info "Using helper: run_with_timeout"
  if command -v stdbuf >/dev/null 2>&1; then
    run_with_timeout "$DURATION" stdbuf -oL -eL "$BIN" >>"$RUN_LOG" 2>&1
    rc=$?
  else
    run_with_timeout "$DURATION" "$BIN" >>"$RUN_LOG" 2>&1
    rc=$?
  fi
else
  log_warn "run_with_timeout not found using naive sleep+kill fallback."
  "$BIN" >>"$RUN_LOG" 2>&1 &
  cpid=$!
  dur_s=$(printf '%s\n' "$DURATION" | sed -n 's/^\([0-9][0-9]*\)s$/\1/p')
  [ -n "$dur_s" ] || dur_s=30
  sleep "$dur_s"
  kill "$cpid" 2>/dev/null || true
  rc=143
fi

end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))

log_info "Client finished: rc=${rc} elapsed=${elapsed}s"

tail -n 400 "$RUN_LOG" >"$STDOUT_LOG" 2>/dev/null || true

final="PASS"

# For these demo apps, timeout kill is expected (rc=143). Other non-zero is suspicious.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 143 ]; then
  final="FAIL"
fi

if [ "$elapsed" -le 1 ]; then
  log_fail "Client exited too quickly (elapsed=${elapsed}s) expected ~${DURATION} runtime."
  final="FAIL"
fi

if [ "$VALIDATE_WAYLAND_PROTO" -ne 0 ]; then
  if command -v display_wayland_proto_validate >/dev/null 2>&1; then
    if display_wayland_proto_validate "$RUN_LOG"; then
      log_info "Wayland protocol validation passed."
    else
      log_fail "Wayland protocol validation failed (missing surface/commit evidence in WAYLAND_DEBUG)"
      final="FAIL"
    fi
  else
    log_warn "display_wayland_proto_validate helper not found skipping protocol validation."
  fi
fi

if [ "$VALIDATE_SCREENSHOT" -ne 0 ]; then
  if [ "$shot_begin_rc" -eq 0 ]; then
    if command -v display_screenshot_delta_end >/dev/null 2>&1; then
      display_screenshot_delta_end "$TESTNAME"
      shot_end_rc=$?
      if [ "$shot_end_rc" -eq 0 ]; then
        log_info "Screenshot delta validation passed (visible change detected)."
      else
        if [ "$shot_end_rc" -eq 1 ]; then
          log_fail "Screenshot delta validation failed (no visible change detected)."
          final="FAIL"
        else
          log_warn "Screenshot delta validation skipped (tool unavailable or capture failed)."
        fi
      fi
    else
      log_warn "display_screenshot_delta_end helper not found skipping screenshot delta validation."
    fi
  else
    log_warn "Screenshot delta validation skipped (before screenshot was not captured)."
  fi
fi

log_info "Final decision for ${TESTNAME}: ${final}"

echo "$TESTNAME $final" >"$RES_FILE"

if [ "$final" = "PASS" ]; then
  log_pass "${TESTNAME} : PASS"
  exit 0
fi

log_fail "${TESTNAME} : FAIL"
exit 0
