#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

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

# --- Dependencies ------------------------------------------------------------
# Note: check_dependencies returns 0 when present, non-zero if missing.
check_dependencies kmscube || {
    log_skip "$TESTNAME SKIP: missing dependencies: kmscube"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
}
KMSCUBE_BIN="$(command -v kmscube 2>/dev/null || true)"
log_info "Using kmscube: ${KMSCUBE_BIN:-<not found>}"

# --- Basic DRM availability guard -------------------------------------------
set -- /dev/dri/card* 2>/dev/null
if [ ! -e "$1" ]; then
    log_skip "$TESTNAME SKIP: no /dev/dri/card* nodes"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

# --- If Weston is running, stop it so KMS has control ------------------------
weston_was_running=0
if weston_is_running; then
    weston_stop
    weston_was_running=1
fi

# --- Execute kmscube ---------------------------------------------------------
log_info "Running kmscube with --count=${FRAME_COUNT} ..."
if kmscube --count="${FRAME_COUNT}" >"$LOG_FILE" 2>&1; then :; else
    rc=$?
    log_fail "$TESTNAME : Execution failed (rc=$rc) — see $LOG_FILE"
    cat "$LOG_FILE"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    if [ "$weston_was_running" -eq 1 ]; then
        log_info "Restarting Weston after failure"
        weston_start
    fi
    exit 1
fi

# --- Parse 'Rendered N frames' (case-insensitive), use the last N -----------
FRAMES_RENDERED="$(
    awk 'BEGIN{IGNORECASE=1}
         /Rendered[[:space:]][0-9]+[[:space:]]+frames/{
             # capture the numeric token on that line; remember the last match
             for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) n=$i
             last=n
         }
         END{if (last!="") print last}' "$LOG_FILE"
)"
[ -n "$FRAMES_RENDERED" ] || FRAMES_RENDERED=0
[ "$EXPECTED_MIN" -lt 0 ] && EXPECTED_MIN=0
log_info "kmscube reported: Rendered ${FRAMES_RENDERED} frames (requested ${FRAME_COUNT}, min acceptable ${EXPECTED_MIN})"

# --- Verdict -----------------------------------------------------------------
if [ "$FRAMES_RENDERED" -ge "$EXPECTED_MIN" ]; then
    log_pass "$TESTNAME : PASS"
    echo "$TESTNAME PASS" >"$RES_FILE"
else
    log_fail "$TESTNAME : FAIL (rendered ${FRAMES_RENDERED} < ${EXPECTED_MIN})"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    if [ "$weston_was_running" -eq 1 ]; then
        log_info "Restarting Weston after failure"
        weston_start
    fi
    exit 1
fi

# --- Restore Weston if we stopped it -----------------------------------------
if [ "$weston_was_running" -eq 1 ]; then
    log_info "Restarting Weston after $TESTNAME completion"
    weston_start
fi

log_info "------------------- Completed $TESTNAME Testcase ------------------"
exit 0
