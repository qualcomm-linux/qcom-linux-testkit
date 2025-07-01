#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Description: Script to test the 'weston-simple-egl' Wayland client for 30 seconds and log the result.

# Robustly find and source init_env
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

# Only source if not already loaded (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="weston-simple-egl"

test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
RES_FILE="./$TESTNAME.res"
LOG_FILE="./${TESTNAME}_run.log"
rm -f "$RES_FILE" "$LOG_FILE"

log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase --------------------------"

# Only start if not already running
if ! weston_is_running; then
    log_info "Weston not running. Attempting to start..."
    weston_start
fi

if check_dependencies weston-simple-egl; then
    log_fail "$TESTNAME : weston-simple-egl binary not found"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 1
fi

XDG_RUNTIME_DIR="/dev/socket/weston"
WAYLAND_DISPLAY="wayland-1"
export XDG_RUNTIME_DIR WAYLAND_DISPLAY

mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"
log_info "Running weston-simple-egl for 30 seconds..."
script -q -c "weston-simple-egl" "$LOG_FILE" 2>/dev/null &
EGL_PID=$!
sleep 30
kill "$EGL_PID" 2>/dev/null
wait "$EGL_PID" 2>/dev/null

count=$(grep -i -o "5 seconds" "$LOG_FILE" | wc -l)
if [ "$count" -ge 5 ]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$RES_FILE"
    exit 0
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi

log_info "------------------- Completed $TESTNAME Testcase ------------------------"
exit 0
