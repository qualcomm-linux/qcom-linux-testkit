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

TESTNAME="qcom_hwrng"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

log_info "Checking if dependency binary is available"
check_dependencies rngtest dd

# Set the hardware RNG source to Qualcomm's RNG
RNG_PATH="/sys/class/misc/hw_random/rng_current"
if [ -e "$RNG_PATH" ]; then
    echo qcom_hwrng > "$RNG_PATH"
else
    log_fail "$TESTNAME : RNG path $RNG_PATH does not exist"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

# Verify that qcom_hwrng was successfully set
current_rng=$(cat "$RNG_PATH")
if [ "$current_rng" != "qcom_hwrng" ]; then
    log_fail "$TESTNAME : Failed to set qcom_hwrng as the current RNG source"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
else
    log_info "qcom_hwrng successfully set as the current RNG source."
fi

TMP_OUT="./qcom_hwrng_output.txt"
ENTROPY_B=20000032
RNG_SOURCE="/dev/random"

log_info "Running rngtest with $ENTROPY_B bytes of entropy from $RNG_SOURCE..."

# Generate entropy and run rngtest
if ! dd if="$RNG_SOURCE" bs=1 count="$ENTROPY_B" status=none 2>/dev/null | rngtest -c 1000 2>&1 | tee "$TMP_OUT"; then
    log_fail "$TESTNAME : rngtest pipeline execution failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

# Parse FIPS 140-2 failures
failures=$(awk '/FIPS 140-2 failures:/ {print $NF}' "$TMP_OUT" | head -n1)

if [ -z "$failures" ] || ! echo "$failures" | grep -Eq '^[0-9]+$'; then
    log_fail "rngtest did not return a valid integer for failures; got: '$failures'"
    echo "$TESTNAME FAIL" > "$res_file"
    rm -f "$TMP_OUT"
    exit 1
fi

log_info "rngtest: FIPS 140-2 failures = $failures"
# You can tune this threshold as needed (10 means <1% fail allowed)
if [ "$failures" -lt 10 ]; then
    log_pass "$TESTNAME : Test Passed ($failures failures)"
    echo "$TESTNAME PASS" > "$res_file"
    rm -f "$TMP_OUT"
    exit 0
else
    log_fail "$TESTNAME : Test Failed ($failures failures)"
    echo "$TESTNAME FAIL" > "$res_file"
    rm -f "$TMP_OUT"
    exit 1
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
