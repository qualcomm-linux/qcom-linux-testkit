#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
#
# Validate weston-simple-egl runs under a working Wayland session.
# - Wayland env resolution (adopts socket & fixes XDG_RUNTIME_DIR perms)
# - CI-friendly logs and PASS/FAIL/SKIP semantics (0/1/2)
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

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="weston-simple-egl"

# ---------- Tunables (env override) ----------
DURATION="${DURATION:-30s}" # how long to run the client
STOP_GRACE="${STOP_GRACE:-3s}" # grace period on stop (reserved for future)
EXPECT_FPS="${EXPECT_FPS:-60}" # nominal refresh (used for logs)
FPS_TOL_PCT="${FPS_TOL_PCT:-10}" # +/- tolerance %
REQUIRE_FPS="${REQUIRE_FPS:-0}" # 1=require FPS lines & threshold; 0=best effort

# ---------- Paths / logs ----------
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || echo "$SCRIPT_DIR")"
if ! cd "$test_path"; then
  log_error "cd failed: $test_path"
  exit 1
fi

RES_FILE="./$TESTNAME.res"
LOG_FILE="./${TESTNAME}_run.log"
rm -f "$RES_FILE" "$LOG_FILE"

log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase --------------------------"

# --- Platform details (robust logging; prefer helpers) ---
if command -v detect_platform >/dev/null 2>&1; then
  detect_platform >/dev/null 2>&1 || true
  log_info "Platform Details: machine='${PLATFORM_MACHINE:-unknown}' target='${PLATFORM_TARGET:-unknown}' kernel='${PLATFORM_KERNEL:-}' arch='${PLATFORM_ARCH:-}'"
else
  log_info "Platform Details: unknown"
fi

log_info "Config: DURATION=$DURATION STOP_GRACE=$STOP_GRACE EXPECT_FPS=${EXPECT_FPS}+/-${FPS_TOL_PCT}% REQUIRE_FPS=$REQUIRE_FPS"

# ---------- Dependencies ----------
if ! check_dependencies weston-simple-egl; then
  log_skip "$TESTNAME : SKIP (weston-simple-egl not found in PATH)"
  echo "$TESTNAME SKIP" > "$RES_FILE"
  exit 2
fi

BIN="$(command -v weston-simple-egl 2>/dev/null || true)"
log_info "Using weston-simple-egl: ${BIN:-<none>}"

# ----- Display presence check (DP/HDMI/etc.) -----
# Quick snapshot for debugging (lists DRM nodes, sysfs connectors, weston outputs)
display_debug_snapshot "pre-display-check"

have_connector=0

# sysfs-based summary (existing helper)
sysfs_summary="$(display_connected_summary 2>/dev/null || printf '%s' '')"
if [ -n "$sysfs_summary" ] && [ "$sysfs_summary" != "none" ]; then
  have_connector=1
  log_info "Connected display (sysfs): $sysfs_summary"
fi

if [ "$have_connector" -eq 0 ]; then
  log_skip "$TESTNAME : SKIP (no connected display detected)"
  echo "$TESTNAME SKIP" > "$RES_FILE"
  exit 2
fi

wayland_debug_snapshot "weston-simple-egl: start"

# ---------- Choose/adopt Wayland socket (using helper) ----------
# Capture only the actual socket path from helper output (filter out logs)
sock="$(
  wayland_choose_or_start 2>/dev/null \
    | grep -E '/(run/user/[0-9]+|tmp|dev/socket/weston)/wayland-[0-9]+$' \
    | tail -n 1
)"
if [ -n "$sock" ]; then
  log_info "Found Wayland socket: $sock"
else
  log_fail "$TESTNAME : FAIL (no Wayland socket found after attempting to start Weston)"
  echo "$TESTNAME FAIL" > "$RES_FILE"
  wayland_debug_snapshot "weston-simple-egl: no-socket"
  exit 1
fi

adopt_wayland_env_from_socket "$sock" || log_warn "adopt_wayland_env_from_socket: invalid: $sock"
log_info "Final Wayland env: XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}<sep>WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"
# Replace <sep> to avoid confusion in CI logs:
# shellcheck disable=SC2016
printf '%s\n' "" | sed 's/.*/[DBG] (env adopted)/' >/dev/null 2>&1 || true

# ---------- Sanity check Wayland connectivity ----------
if wayland_connection_ok; then
  log_info "Wayland connection test: OK"
else
  log_fail "$TESTNAME : FAIL (Wayland connection test failed)"
  print_path_meta "$XDG_RUNTIME_DIR" | sed 's/^/[DBG] /'
  stat "$XDG_RUNTIME_DIR" 2>/dev/null | sed 's/^/[DBG] /' || true
  echo "$TESTNAME FAIL" > "$RES_FILE"
  exit 1
fi

# Try to enable FPS prints if supported by the client (best effort).
export SIMPLE_EGL_FPS=1
export WESTON_SIMPLE_EGL_FPS=1

# ---------- Run the client ----------
log_info "Launching weston-simple-egl for $DURATION …"
start_ts="$(date +%s 2>/dev/null || echo 0)"

if command -v run_with_timeout >/dev/null 2>&1; then
  log_info "Using helper: run_with_timeout"
  run_with_timeout "$DURATION" weston-simple-egl >"$LOG_FILE" 2>&1
  rc=$?
else
  if command -v timeout >/dev/null 2>&1; then
    log_info "Using coreutils timeout"
    timeout "$DURATION" weston-simple-egl >"$LOG_FILE" 2>&1
    rc=$?
  else
    log_info "No timeout helpers; running in background with manual sleep-stop"
    sh -c 'weston-simple-egl' >"$LOG_FILE" 2>&1 &
    pid=$!
    # DURATION like "30s" → "30"
    dur_s="$(printf '%s' "$DURATION" | sed -n 's/^\([0-9][0-9]*\)s$/\1/p')"
    [ -z "$dur_s" ] && dur_s="$DURATION"
    sleep "$dur_s"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rc=143
  fi
fi

end_ts="$(date +%s 2>/dev/null || echo 0)"
elapsed=$(( end_ts - start_ts ))
[ "$elapsed" -lt 0 ] && elapsed=0
log_info "Client finished: rc=$rc elapsed=${elapsed}s"

# ---------- FPS parsing (best effort) ----------
fps="-"
fps_line="$(grep -E '([Ff][Pp][Ss]|frames per second|^fps:)' "$LOG_FILE" 2>/dev/null | tail -n 1)"
if [ -n "$fps_line" ]; then
  fps="$(printf '%s\n' "$fps_line" | awk '{ for (i=NF;i>=1;i--) if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {print $i; exit} }')"
  [ -z "$fps" ] && fps="-"
fi

log_info "Result summary: rc=$rc elapsed=${elapsed}s fps=${fps} (expected ~${EXPECT_FPS}+/-${FPS_TOL_PCT}%)"

# ---------- Gating ----------
dur_s="$(printf '%s' "$DURATION" | sed -n 's/^\([0-9][0-9]*\)s$/\1/p')"
[ -z "$dur_s" ] && dur_s="$DURATION"
min_ok=$(( dur_s - 1 ))
[ "$min_ok" -lt 0 ] && min_ok=0

final="PASS"

# Must have run ~DURATION seconds
if [ "$elapsed" -lt "$min_ok" ]; then
  final="FAIL"
  log_fail "$TESTNAME : FAIL (exited after ${elapsed}s; expected ~${dur_s}s) — rc=$rc"
fi

# Optional FPS gate
if [ "$final" = "PASS" ] && [ "$REQUIRE_FPS" -eq 1 ]; then
  if [ "$fps" = "-" ]; then
    final="FAIL"
    log_fail "$TESTNAME : FAIL (no FPS lines found but REQUIRE_FPS=1)"
  else
    lo=$(( (EXPECT_FPS * (100 - FPS_TOL_PCT)) / 100 ))
    hi=$(( (EXPECT_FPS * (100 + FPS_TOL_PCT)) / 100 ))
    fps_int="$(printf '%s' "$fps" | cut -d. -f1)"
    if [ "$fps_int" -lt "$lo" ] || [ "$fps_int" -gt "$hi" ]; then
      final="FAIL"
      log_fail "$TESTNAME : FAIL (fps=$fps outside ${lo}-${hi})"
    fi
  fi
fi

# ---------- Epilogue / exit codes ----------
case "$final" in
  PASS)
    log_pass "$TESTNAME : PASS"
    echo "$TESTNAME PASS" > "$RES_FILE"
    exit 0
    ;;
  SKIP)
    # (Not used here, but keeping consistent mapping)
    log_skip "$TESTNAME : SKIP"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 2
    ;;
  *)
    log_fail "$TESTNAME : FAIL"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
    ;;
esac
