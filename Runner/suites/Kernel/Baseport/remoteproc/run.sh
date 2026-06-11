#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
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
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="remoteproc"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

detect_platform

if [ ! -d "/sys/class/remoteproc" ]; then
    log_skip "$TESTNAME : remoteproc sysfs not found (/sys/class/remoteproc missing), skipping test"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

rproc_count=$(find /sys/class/remoteproc -maxdepth 1 -name "remoteproc*" 2>/dev/null | wc -l)
if [ "$rproc_count" -eq 0 ]; then
    log_skip "$TESTNAME : No remoteproc entries found under /sys/class/remoteproc, skipping test"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

all_pass=true

# Iterate over each remoteproc instance
for rproc_dir in /sys/class/remoteproc/remoteproc*; do
    rproc_name=$(basename "$rproc_dir")
    firmware=$(cat "$rproc_dir/firmware" 2>/dev/null)
    state=$(cat "$rproc_dir/state" 2>/dev/null)

    # Skip modem subsystem on Kodiak platform
    if printf '%s' "$firmware" | grep -q "modem" && [ "${PLATFORM_TARGET}" = "Kodiak" ]; then
        log_info "Skipping modem subsystem ($rproc_name) on Kodiak platform"
        continue
    fi

    # soccp is expected to be in 'attached' state, all others in 'running' state
    if printf '%s' "$firmware" | grep -q "soccp"; then
        expected_state="attached"
    else
        expected_state="running"
    fi

    log_info "$rproc_name | firmware: $firmware | state: $state | expected: $expected_state"

    if [ "$state" = "$expected_state" ]; then
        log_info "$rproc_name is in expected state '$expected_state' : PASS"
    else
        log_fail "$rproc_name is in state '$state', expected '$expected_state' : FAIL"
        all_pass=false
    fi
done

# Print overall test result
if [ "$all_pass" = "true" ]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
