#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

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

TESTNAME="wpss_remoteproc"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

log_info "=== Detecting and validating WPSS remoteproc instance ==="
 
log_info "Looking for remoteproc device exposing WPSS..."
wpss_path=""
for node in /sys/class/remoteproc/remoteproc*; do
    [ -f "$node/name" ] || continue
    name=$(cat "$node/name" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if echo "$name" | grep -qi "wpss"; then
        wpss_path="$node"
        break
    fi
done
 
if [ -z "$wpss_path" ]; then
    log_skip "WPSS remoteproc node not found"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi
 
log_info "Found WPSS remoteproc node at: $wpss_path"
firmware=$(cat "$wpss_path/firmware" 2>/dev/null)
log_info "WPSS firmware: $firmware"
 
# Capture state before any change
orig_state=$(cat "$wpss_path/state" 2>/dev/null)
log_info "Original state: $orig_state"
 
log_info "Attempting to stop WPSS..."
if echo stop > "$wpss_path/state" 2>/dev/null; then
    sleep 1
    new_state=$(cat "$wpss_path/state" 2>/dev/null)
    if [ "$new_state" != "offline" ]; then
        log_warn "Expected offline state after stop, got: $new_state"
    fi
else
    log_warn "Could not stop WPSS; may already be offline"
fi
 
log_info "Attempting to start WPSS..."
if echo start > "$wpss_path/state" 2>/dev/null; then
    sleep 1
    final_state=$(cat "$wpss_path/state" 2>/dev/null)
    if [ "$final_state" = "running" ]; then
        log_pass "WPSS remoteproc started successfully"
        echo "$TESTNAME PASS" > "$res_file"
        exit 0
    else
        log_fail "WPSS remoteproc failed to start, state: $final_state"
        echo "$TESTNAME FAIL" > "$res_file"
        exit 1
    fi
else
    log_fail "Failed to write 'start' to $wpss_path/state"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
