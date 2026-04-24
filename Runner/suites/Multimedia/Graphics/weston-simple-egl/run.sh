#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause#
# Validate weston-simple-egl runs under a working Wayland session.
# - Wayland env resolution (adopts socket & fixes XDG_RUNTIME_DIR perms)
# - CI-friendly logs and PASS/FAIL/SKIP semantics
# - Optional FPS parsing (best-effort)

# ---------- Source init_env and functestlib ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

TESTNAME="weston-simple-egl"

# Ensure we run from the testcase directory so .res/logs land next to run.sh
test_path="$(find_test_case_by_name "$TESTNAME")"
cd "$test_path" || exit 1

RES_FILE="./${TESTNAME}.res"
RUN_LOG="./${TESTNAME}_run.log"

: >"$RES_FILE"
: >"$RUN_LOG"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
DURATION="${DURATION:-30s}"
STOP_GRACE="${STOP_GRACE:-3s}"
FPS_EXPECT_MODE="${FPS_EXPECT_MODE:-auto}"
EXPECT_FPS="${EXPECT_FPS:-}"
EXPECT_FPS_DEFAULT="${EXPECT_FPS_DEFAULT:-60}"
FPS_TOL_PCT="${FPS_TOL_PCT:-10}"
MIN_FPS_PCT="${MIN_FPS_PCT:-85}"
REQUIRE_FPS="${REQUIRE_FPS:-1}"

# Detect overlay by presence of Adreno GLVND vendor JSON
BUILD_FLAVOUR="base"
EGL_VENDOR_JSON=""

# Check common vendor JSON locations and filename patterns
for d in /usr/share/glvnd/egl_vendor.d /etc/glvnd/egl_vendor.d; do
  [ -d "$d" ] || continue

  # Try both naming styles: 10_adreno.json and 10_EGL_adreno.json
  for f in "$d"/*adreno*.json "$d"/*EGL_adreno*.json; do
    [ -e "$f" ] || continue
    if [ -f "$f" ]; then
      EGL_VENDOR_JSON="$f"
      BUILD_FLAVOUR="overlay"
      break 2
    fi
  done
done

log_info "Weston log directory: $SCRIPT_DIR"
log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting ${TESTNAME} Testcase --------------------------"

# Optional platform details (helper from functestlib)
if command -v detect_platform >/dev/null 2>&1; then
  detect_platform
fi

if [ "$BUILD_FLAVOUR" = "overlay" ]; then
  log_info "Build flavor: overlay (EGL vendor JSON present: ${EGL_VENDOR_JSON})"
else
  log_info "Build flavor: base (no Adreno EGL vendor JSON found)"
fi

log_info "Input config: DURATION=${DURATION} STOP_GRACE=${STOP_GRACE} FPS_EXPECT_MODE=${FPS_EXPECT_MODE} EXPECT_FPS=${EXPECT_FPS:-<unset>} EXPECT_FPS_DEFAULT=${EXPECT_FPS_DEFAULT} (fallback) FPS_TOL_PCT=${FPS_TOL_PCT}% MIN_FPS_PCT=${MIN_FPS_PCT}% REQUIRE_FPS=${REQUIRE_FPS} BUILD_FLAVOUR=${BUILD_FLAVOUR}"
# ---------------------------------------------------------------------------
# Display snapshot
# ---------------------------------------------------------------------------
if command -v display_debug_snapshot >/dev/null 2>&1; then
  display_debug_snapshot "pre-display-check"
fi

# Always print modetest as part of the snapshot (best-effort).
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
  echo "${TESTNAME} SKIP" >"$RES_FILE"
  exit 0
fi

# ---------------------------------------------------------------------------
# Dependencies (patched check_dependencies: use return instead of exit)
# Avoid SC2034 by using inline env assignment (no standalone var).
# ---------------------------------------------------------------------------
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies weston-simple-egl; then
  log_skip "${TESTNAME} SKIP: missing dependency: weston-simple-egl"
  echo "${TESTNAME} SKIP" >"$RES_FILE"
  exit 0
fi

# ---------------------------------------------------------------------------
# Wayland / Weston environment (runtime detection; do NOT stop/restart Weston)
# - On base: we should not start/kill Weston; we only adopt existing socket.
# - On overlay: if no socket, we may start private Weston via overlay_start_weston_drm.
# ---------------------------------------------------------------------------
if command -v wayland_debug_snapshot >/dev/null 2>&1; then
  wayland_debug_snapshot "${TESTNAME}: start"
fi

sock=""

# Try to find any existing Wayland socket (base or overlay)
if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
  sock=$(discover_wayland_socket_anywhere | head -n 1 || true)
fi

# If we found a socket, adopt its environment
if [ -n "$sock" ] && command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
  log_info "Found existing Wayland socket: $sock"
  if ! adopt_wayland_env_from_socket "$sock"; then
    log_warn "Failed to adopt env from $sock"
  fi
fi

# On base, do not start Weston here, but allow a short wait for an already
# expected Weston runtime to come back after a previous DRM-exclusive test.
if [ -z "$sock" ] && [ "$BUILD_FLAVOUR" = "base" ]; then
  if command -v weston_wait_ready >/dev/null 2>&1; then
    log_info "No usable Wayland socket yet on base build; waiting briefly for Weston runtime..."
    if weston_wait_ready 10; then
      if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
        sock=$(discover_wayland_socket_anywhere | head -n 1 || true)
      fi
      if [ -n "$sock" ] && command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
        log_info "Base Weston runtime became ready: $sock"
        if ! adopt_wayland_env_from_socket "$sock"; then
          log_warn "Failed to adopt env from $sock after wait"
        fi
      fi
    fi
  fi
fi

# If no usable socket yet:
# - base: SKIP (do not try to start/stop Weston)
# - overlay: try starting private Weston (helper) then re-discover/adopt
if [ -z "$sock" ]; then
  if [ "$BUILD_FLAVOUR" = "overlay" ] && command -v overlay_start_weston_drm >/dev/null 2>&1; then
    log_info "No usable Wayland socket; trying overlay_start_weston_drm helper (overlay build)..."
    if command -v weston_force_primary_1080p60_if_not_60 >/dev/null 2>&1; then
      log_info "Pre-configuring primary output to ~60Hz before starting Weston (best-effort) ..."
      weston_force_primary_1080p60_if_not_60 || true
    fi

    if overlay_start_weston_drm; then
      if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
        sock=$(discover_wayland_socket_anywhere | head -n 1 || true)
      fi
      if [ -n "$sock" ] && command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
        log_info "Overlay Weston created Wayland socket: $sock"
        if ! adopt_wayland_env_from_socket "$sock"; then
          log_warn "Failed to adopt env from $sock"
        fi
      else
        log_warn "overlay_start_weston_drm reported success but no Wayland socket was found."
      fi
    else
      log_warn "overlay_start_weston_drm returned non-zero; private Weston may have failed to start."
    fi
  else
    log_fail "No Wayland socket found and not starting Weston on base build, failing ${TESTNAME}."
    echo "${TESTNAME} FAIL" >"$RES_FILE"
    exit 0
  fi
fi

# Re-evaluate socket after adoption/start (env may have changed)
if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
  new_sock=$(discover_wayland_socket_anywhere | head -n 1 || true)
  [ -n "$new_sock" ] && sock="$new_sock"
fi

# Final decision: run or FAIL
if [ -z "$sock" ]; then
  log_fail "No Wayland socket found after autodetection, failing ${TESTNAME}."
  echo "${TESTNAME} FAIL" >"$RES_FILE"
  exit 0
fi

# Best-effort: ensure WAYLAND_DISPLAY matches the socket basename
sock_base=$(basename "$sock" 2>/dev/null || true)
if [ -n "$sock_base" ]; then
  case "$sock_base" in
    wayland-*) export WAYLAND_DISPLAY="$sock_base" ;;
  esac
fi

if command -v wayland_connection_ok >/dev/null 2>&1; then
  if ! wayland_connection_ok; then
    if [ "$BUILD_FLAVOUR" = "base" ] && command -v weston_wait_ready >/dev/null 2>&1; then
      log_warn "Initial Wayland connection test failed, waiting briefly and retrying..."
      if weston_wait_ready 5; then
        if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
          sock=$(discover_wayland_socket_anywhere | head -n 1 || true)
        fi
        if [ -n "$sock" ] && command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
          adopt_wayland_env_from_socket "$sock" || true
        fi
      fi
    fi

    if ! wayland_connection_ok; then
      log_fail "Wayland connection test failed, cannot run ${TESTNAME}."
      echo "${TESTNAME} FAIL" >"$RES_FILE"
      exit 0
    fi
  fi
  log_info "Wayland connection test: OK"
else
  log_warn "wayland_connection_ok helper not found continuing without explicit Wayland probe."
fi

if ! display_resolve_fps_policy; then
  log_fail "Failed to resolve FPS policy"
  echo "${TESTNAME} FAIL" >"$RES_FILE"
  exit 0
fi

if [ "${DISPLAY_FPS_MODE:-}" = "detected" ]; then
  log_info "Resolved FPS policy: mode=${DISPLAY_FPS_MODE} refresh=${DISPLAY_FPS_DETECTED_HZ}Hz expected=${DISPLAY_FPS_EXPECTED} min_ok=${DISPLAY_FPS_MIN_OK}"
else
  log_info "Resolved FPS policy: mode=${DISPLAY_FPS_MODE} expected=${DISPLAY_FPS_EXPECTED} range=[${DISPLAY_FPS_MIN_OK}, ${DISPLAY_FPS_MAX_OK}]"
fi
# ---------------------------------------------------------------------------
# Apply refresh policy resolved in lib_display.sh
# ---------------------------------------------------------------------------
if command -v display_debug_snapshot >/dev/null 2>&1; then
  display_debug_snapshot "${TESTNAME}: before-refresh-policy"
fi
if command -v wayland_debug_snapshot >/dev/null 2>&1; then
  wayland_debug_snapshot "${TESTNAME}: before-refresh-policy"
fi

display_apply_fps_refresh_policy || true

if command -v display_debug_snapshot >/dev/null 2>&1; then
  display_debug_snapshot "${TESTNAME}: after-refresh-policy"
fi

# --- Skip if only CPU/software renderer is active (GPU HW accel not enabled) ---
# Prefer Wayland path; fall back to auto only if helper doesn't support "wayland".
if command -v display_is_cpu_renderer >/dev/null 2>&1; then
  if display_is_cpu_renderer wayland >/dev/null 2>&1; then
    if display_is_cpu_renderer wayland; then
      log_skip "$TESTNAME SKIP: GPU HW acceleration not enabled (CPU/software renderer on Wayland)"
      echo "${TESTNAME} SKIP" >"$RES_FILE"
      exit 0
    fi
  else
    log_warn "display_is_cpu_renderer wayland not supported; falling back to auto."
    if display_is_cpu_renderer auto; then
      log_skip "$TESTNAME SKIP: GPU HW acceleration not enabled (CPU/software renderer detected)"
      echo "${TESTNAME} SKIP" >"$RES_FILE"
      exit 0
    fi
  fi
else
  log_warn "display_is_cpu_renderer helper not found and cannot enforce GPU accel gating (continuing)."
fi

# ---------------------------------------------------------------------------
# Binary & EGL vendor override
# ---------------------------------------------------------------------------
BIN=$(command -v weston-simple-egl 2>/dev/null || true)
if [ -z "$BIN" ]; then
  log_fail "Required binary weston-simple-egl not found in PATH."
  echo "${TESTNAME} FAIL" >"$RES_FILE"
  exit 0
fi

log_info "Using weston-simple-egl: $BIN"

# On overlay, force GLVND to use Adreno vendor JSON if available
if [ "$BUILD_FLAVOUR" = "overlay" ] && [ -n "$EGL_VENDOR_JSON" ]; then
  export __EGL_VENDOR_LIBRARY_FILENAMES="$EGL_VENDOR_JSON"
  log_info "EGL vendor override: ${EGL_VENDOR_JSON}"
fi

# Enable FPS prints in the client
export SIMPLE_EGL_FPS=1
export WESTON_SIMPLE_EGL_FPS=1

# ---------------------------------------------------------------------------
# Run client with timeout
# ---------------------------------------------------------------------------
log_info "Launching ${TESTNAME} for ${DURATION} ..."

start_ts=$(date +%s)

if command -v run_with_timeout >/dev/null 2>&1; then
  log_info "Using helper: run_with_timeout"
  if command -v stdbuf >/dev/null 2>&1; then
    run_with_timeout "$DURATION" stdbuf -oL -eL "$BIN" >>"$RUN_LOG" 2>&1
  else
    log_warn "stdbuf not found running $BIN without output re-buffering."
    run_with_timeout "$DURATION" "$BIN" >>"$RUN_LOG" 2>&1
  fi
  rc=$?
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

# ---------------------------------------------------------------------------
# FPS parsing: average / min / max from all intervals
# - Discard FIRST sample as warm-up if we have 2+ samples.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# FPS parsing
# ---------------------------------------------------------------------------
fps_count=0
fps_avg="-"
fps_min="-"
fps_max="-"

if display_parse_fps_log "$RUN_LOG"; then
  fps_count="$DISPLAY_FPS_COUNT"
  fps_avg="$DISPLAY_FPS_AVG"
  fps_min="$DISPLAY_FPS_MIN"
  fps_max="$DISPLAY_FPS_MAX"
  log_info "FPS stats from ${RUN_LOG}: samples=${fps_count} avg=${fps_avg} min=${fps_min} max=${fps_max}"
else
  log_warn "No FPS lines detected in ${RUN_LOG} weston-simple-egl may not have emitted FPS stats (or output was truncated)."
fi

fps_for_summary="$fps_avg"
if [ "$fps_count" -eq 0 ]; then
  fps_for_summary="-"
fi

if [ "${DISPLAY_FPS_MODE:-}" = "detected" ]; then
  log_info "Result summary: rc=${rc} elapsed=${elapsed}s fps=${fps_for_summary} mode=${DISPLAY_FPS_MODE} refresh=${DISPLAY_FPS_DETECTED_HZ}Hz expected=${DISPLAY_FPS_EXPECTED} min_ok=${DISPLAY_FPS_MIN_OK}"
else
  log_info "Result summary: rc=${rc} elapsed=${elapsed}s fps=${fps_for_summary} mode=${DISPLAY_FPS_MODE} expected=${DISPLAY_FPS_EXPECTED} range=[${DISPLAY_FPS_MIN_OK}, ${DISPLAY_FPS_MAX_OK}]"
fi

# ---------------------------------------------------------------------------
# PASS / FAIL decision
# ---------------------------------------------------------------------------
final="PASS"

# Exit code: accept 0 (normal) and 143 (timeout) as non-fatal here
if [ "$rc" -ne 0 ] && [ "$rc" -ne 143 ]; then
  final="FAIL"
fi

# Duration sanity: reject if it bails out immediately
if [ "$elapsed" -le 1 ]; then
  log_fail "Client exited too quickly (elapsed=${elapsed}s) expected ~${DURATION} runtime."
  final="FAIL"
fi

if ! display_fps_gate_avg "$fps_avg" "$fps_count"; then
  final="FAIL"
fi

log_info "Final decision for ${TESTNAME}: ${final}"

# ---------------------------------------------------------------------------
# Emit result & exit
# ---------------------------------------------------------------------------
echo "${TESTNAME} ${final}" >"$RES_FILE"

if [ "$final" = "PASS" ]; then
  log_pass "${TESTNAME} : PASS"
  exit 0
fi

log_fail "${TESTNAME} : FAIL"
exit 0
