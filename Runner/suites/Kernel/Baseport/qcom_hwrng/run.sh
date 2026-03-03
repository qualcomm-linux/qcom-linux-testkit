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
res_file="./qcom_hwrng.res"

if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    echo "qcom_hwrng SKIP" > "$res_file"
    exit 0
fi
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="qcom_hwrng"

if [ "$(id -u)" -ne 0 ]; then
    log_info "$TESTNAME : Root privileges required"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

test_path=$(find_test_case_by_name "$TESTNAME")
if [ -z "$test_path" ] || ! cd "$test_path"; then
    log_info "$TESTNAME : Test path not found or cd failed"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

log_info "Checking if dependency binary is available"
if ! check_dependencies rngtest dd; then
    log_info "$TESTNAME : Required dependencies not met"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

# Set the hardware RNG source to Qualcomm's RNG
RNG_PATH="/sys/class/misc/hw_random/rng_current"
if [ ! -e "$RNG_PATH" ]; then
    log_fail "$TESTNAME : RNG path $RNG_PATH does not exist"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

PREV_RNG=$(cat "$RNG_PATH")
echo qcom_hwrng > "$RNG_PATH"
current_rng=$(cat "$RNG_PATH")
if [ "$current_rng" != "qcom_hwrng" ]; then
    log_fail "$TESTNAME : Failed to set qcom_hwrng as the current RNG source"
    echo "$TESTNAME FAIL" > "$res_file"
    echo "$PREV_RNG" > "$RNG_PATH"
    exit 1
else
    log_info "qcom_hwrng successfully set as the current RNG source."
fi
RNG_SOURCE="/dev/hwrng"
if [ ! -e "$RNG_SOURCE" ]; then
    log_info "$TESTNAME : $RNG_SOURCE not available"
    echo "$TESTNAME SKIP" > "$res_file"
    echo "$PREV_RNG" > "$RNG_PATH"
    exit 0
fi

TMP_OUT="./qcom_hwrng_output.txt"
ENTROPY_B=20000032
FAILURE_THRESHOLD=10

log_info "Using FIPS 140-2 failure threshold: $FAILURE_THRESHOLD"
log_info "Running rngtest with $ENTROPY_B bytes of entropy from $RNG_SOURCE..."

dd if="$RNG_SOURCE" bs=1 count="$ENTROPY_B" status=none 2>/dev/null > temp_entropy.bin
rngtest -c 1000 < temp_entropy.bin > "$TMP_OUT" 2>&1
rm -f temp_entropy.bin

failures=$(awk '/^rngtest: FIPS 140-2 failures:/ {print $NF}' "$TMP_OUT" | head -n1)
rm -f "$TMP_OUT"

if [ -z "$failures" ] || ! echo "$failures" | grep -Eq '^[0-9]+$'; then
    log_fail "rngtest did not return a valid integer for failures; got: '$failures'"
    echo "$TESTNAME FAIL" > "$res_file"
    echo "$PREV_RNG" > "$RNG_PATH"
    exit 1
fi
log_info "rngtest: FIPS 140-2 failures = $failures"
if [ "$failures" -lt "$FAILURE_THRESHOLD" ]; then
    log_pass "$TESTNAME : Test Passed ($failures failures)"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "$TESTNAME : Test Failed ($failures failures)"
    echo "$TESTNAME FAIL" > "$res_file"
fi

echo "$PREV_RNG" > "$RNG_PATH"
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
exit 0