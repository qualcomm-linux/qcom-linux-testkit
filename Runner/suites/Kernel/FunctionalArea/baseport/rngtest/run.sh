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

if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="rngtest"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

log_info "Checking if dependency binary is available"
check_dependencies rngtest dd

TMP_BIN="/tmp/rngtest_input.bin"
TMP_OUT="/tmp/rngtest_output.txt"
ENTROPY_MB=10
RNG_SOURCE="/dev/urandom" # Use /dev/random if you want slow but highest entropy

log_info "Generating ${ENTROPY_MB}MB entropy input from $RNG_SOURCE using dd..."
if ! dd if="$RNG_SOURCE" of="$TMP_BIN" bs=1M count="$ENTROPY_MB" status=none 2>/dev/null; then
    log_fail "$TESTNAME : Failed to read random data from $RNG_SOURCE"
    echo "$TESTNAME FAIL" > "$res_file"
    rm -f "$TMP_BIN"
    exit 1
fi

log_info "Running rngtest -c 1000 < $TMP_BIN"
if ! rngtest -c 1000 < "$TMP_BIN" > "$TMP_OUT" 2>&1; then
    log_fail "$TESTNAME : rngtest execution failed"
    echo "$TESTNAME FAIL" > "$res_file"
    rm -f "$TMP_BIN" "$TMP_OUT"
    exit 1
fi

# Check for entropy errors or source drained
if grep -q "entropy source drained" "$TMP_OUT"; then
    log_fail "rngtest: entropy source drained, input too small"
    echo "$TESTNAME FAIL" > "$res_file"
    rm -f "$TMP_BIN" "$TMP_OUT"
    exit 1
fi

# Parse FIPS 140-2 successes (robust to output variations)
successes=$(awk '/FIPS 140-2 successes:/ {print $NF}' "$TMP_OUT" | head -n1)

if [ -z "$successes" ] || ! echo "$successes" | grep -Eq '^[0-9]+$'; then
    log_fail "rngtest did not return a valid integer for successes; got: '$successes'"
    echo "$TESTNAME FAIL" > "$res_file"
    rm -f "$TMP_BIN" "$TMP_OUT"
    exit 1
fi

log_info "rngtest: FIPS 140-2 successes = $successes"
# You can tune this threshold as needed (10 means <1% fail allowed)
if [ "$successes" -ge 10 ]; then
    log_pass "$TESTNAME : Test Passed ($successes FIPS 140-2 successes)"
    echo "$TESTNAME PASS" > "$res_file"
    rm -f "$TMP_BIN" "$TMP_OUT"
    exit 0
else
    log_fail "$TESTNAME : Test Failed ($successes FIPS 140-2 successes)"
    echo "$TESTNAME FAIL" > "$res_file"
    rm -f "$TMP_BIN" "$TMP_OUT"
    exit 1
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
