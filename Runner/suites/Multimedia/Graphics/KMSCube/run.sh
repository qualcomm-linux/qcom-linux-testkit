#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# KMSCube Validator Script (Yocto-Compatible, POSIX sh)

# --- Robustly find and source init_env ---------------------------------------
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

# Only source once (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1090,SC1091
. "$TOOLS/lib_display.sh"

# --- Test metadata -----------------------------------------------------------
TESTNAME="KMSCube"
FRAME_COUNT="${FRAME_COUNT:-999}" # allow override via env
EXPECTED_MIN=$((FRAME_COUNT - 1)) # tolerate off-by-one under-reporting

# Ensure we run from the testcase directory so .res/logs land next to run.sh
test_path="$(find_test_case_by_name "$TESTNAME")"
cd "$test_path" || exit 1

RES_FILE="./$TESTNAME.res"
LOG_FILE="./${TESTNAME}_run.log"
rm -f "$RES_FILE" "$LOG_FILE"

log_info "-------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase -------------------"

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

# --- Basic DRM availability guard -------------------------------------------
set -- /dev/dri/card* 2>/dev/null
if [ ! -e "$1" ]; then
    log_skip "$TESTNAME SKIP: no /dev/dri/card* nodes"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi
# --- Dependencies ------------------------------------------------------------
# With patched check_dependencies(): ask for return code instead of exit
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies kmscube; then
    log_skip "$TESTNAME SKIP: missing dependencies: kmscube"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

KMSCUBE_BIN="$(command -v kmscube 2>/dev/null || true)"
log_info "Using kmscube: ${KMSCUBE_BIN:-<not found>}"

# --- Track whether this test stopped Weston ----------------------------------
weston_stopped_by_test=0
# --- GPU acceleration gating (avoid auto/Wayland for kmscube) ----------------
# KMSCube is a DRM/KMS test. Using "auto" can start/adopt Weston and steal DRM master.
if command -v display_is_cpu_renderer >/dev/null 2>&1; then
    if display_is_cpu_renderer gbm >/dev/null 2>&1; then
        if display_is_cpu_renderer gbm; then
            log_skip "$TESTNAME SKIP: GPU HW acceleration not enabled (CPU/software renderer detected on GBM)"
            echo "$TESTNAME SKIP" >"$RES_FILE"
            exit 0
        fi
    else
        log_warn "display_is_cpu_renderer gbm not supported, falling back to auto (may touch Wayland/Weston)."
        if display_is_cpu_renderer auto; then
            log_skip "$TESTNAME SKIP: GPU HW acceleration not enabled (CPU/software renderer detected)"
            echo "$TESTNAME SKIP" >"$RES_FILE"
            exit 0
        fi
    fi
else
    log_warn "display_is_cpu_renderer helper not found, cannot enforce GPU accel gating (continuing)."
fi

# --- Ensure Weston is NOT running before kmscube (DRM master) -----------------
# Stop weston after gating too, because some helpers may have started it.
if weston_is_running; then
    log_info "Weston is running, stopping it so kmscube can modeset (DRM master)"
    if weston_stop >/dev/null 2>&1; then
        weston_stopped_by_test=1
    else
        log_warn "weston_stop returned non-zero, re-checking Weston state"
        if ! weston_is_running; then
            weston_stopped_by_test=1
        fi
    fi
fi

# Double-check and be strict: kmscube will fail if weston still holds DRM master.
if weston_is_running; then
    log_warn "Weston still running after weston_stop, kmscube may fail to set mode"
fi

# --- Execute kmscube (avoid Wayland env leakage) ------------------------------
unset WAYLAND_DISPLAY
# Keep XDG_RUNTIME_DIR intact for system sanity, but force GBM platform for EGL where honored.
EGL_PLATFORM_SAVED="${EGL_PLATFORM:-}"
export EGL_PLATFORM=gbm

log_info "Running kmscube with --count=${FRAME_COUNT} ..."
if kmscube --count="${FRAME_COUNT}" >"$LOG_FILE" 2>&1; then :; else
    rc=$?
    log_fail "$TESTNAME : Execution failed (rc=$rc) — see $LOG_FILE"
    cat "$LOG_FILE"
    echo "$TESTNAME FAIL" >"$RES_FILE"

    # Restore EGL_PLATFORM
    if [ -n "$EGL_PLATFORM_SAVED" ]; then
        export EGL_PLATFORM="$EGL_PLATFORM_SAVED"
    else
        unset EGL_PLATFORM
    fi

    # Restore Weston if we stopped it
    if [ "$weston_stopped_by_test" -eq 1 ]; then
        log_info "Restoring Weston after failure"
        if ! weston_restore_runtime 15; then
            log_error "Failed to restore Weston runtime after $TESTNAME failure"
        fi
    fi
    exit 1
fi

# Restore EGL_PLATFORM
if [ -n "$EGL_PLATFORM_SAVED" ]; then
    export EGL_PLATFORM="$EGL_PLATFORM_SAVED"
else
    unset EGL_PLATFORM
fi

# --- Parse 'Rendered N frames' (case-insensitive), use the last N ------------
FRAMES_RENDERED="$(
    awk 'BEGIN{IGNORECASE=1}
         /Rendered[[:space:]][0-9]+[[:space:]]+frames/{
             for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) n=$i
             last=n
         }
         END{if (last!="") print last}' "$LOG_FILE"
)"
[ -n "$FRAMES_RENDERED" ] || FRAMES_RENDERED=0
[ "$EXPECTED_MIN" -lt 0 ] && EXPECTED_MIN=0
log_info "kmscube reported: Rendered ${FRAMES_RENDERED} frames (requested ${FRAME_COUNT}, min acceptable ${EXPECTED_MIN})"

# --- Restore Weston if we stopped it -----------------------------------------
restore_failed=0
if [ "$weston_stopped_by_test" -eq 1 ]; then
    log_info "Restoring Weston after $TESTNAME completion"
    if ! weston_restore_runtime 15; then
        restore_failed=1
        log_error "Failed to restore Weston runtime after $TESTNAME"
    fi
fi

# --- Verdict -----------------------------------------------------------------
if [ "$FRAMES_RENDERED" -lt "$EXPECTED_MIN" ]; then
    log_fail "$TESTNAME : FAIL (rendered ${FRAMES_RENDERED} < ${EXPECTED_MIN})"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 1
fi

if [ "$restore_failed" -ne 0 ]; then
    log_fail "$TESTNAME : FAIL (rendered ${FRAMES_RENDERED}, but Weston restore failed)"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 1
fi

log_pass "$TESTNAME : PASS"
echo "$TESTNAME PASS" >"$RES_FILE"

log_info "------------------- Completed $TESTNAME Testcase ------------------"
exit 0
