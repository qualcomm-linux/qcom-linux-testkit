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

# Verifying the availability of the dependency binary
check_dependencies rngtest dd

TMP_BIN="/tmp/rngtest_input.bin"
TMP_OUT="/tmp/rngtest_output.txt"
ENTROPY_MB=10
COUNT=1000
PASS_THRESHOLD=997
RNG_SOURCE=""
RNG_TIMEOUT=10

# Preferred order: hwrng -> urandom
if [ -e /dev/hwrng ]; then
    log_info "Attempting to read $ENTROPY_MB MB entropy from /dev/hwrng with timeout $RNG_TIMEOUT sec"
    if timeout "$RNG_TIMEOUT" dd if=/dev/hwrng of="$TMP_BIN" bs=1M count="$ENTROPY_MB" status=none 2>/dev/null; then
        RNG_SOURCE="/dev/hwrng"
        log_info "Successfully read entropy from /dev/hwrng"
    else
        log_warn "/dev/hwrng read failed or timed out, falling back to /dev/urandom"
    fi
fi

if [ -z "$RNG_SOURCE" ]; then
    log_info "Using fallback source: /dev/urandom"
    if ! dd if=/dev/urandom of="$TMP_BIN" bs=1M count="$ENTROPY_MB" status=none 2>/dev/null; then
	RNG_SOURCE="/dev/urandom"
        log_fail "$TESTNAME : Failed to read from /dev/urandom as fallback"
        echo "$TESTNAME FAIL" > "$res_file"
        rm -f "$TMP_BIN"
        exit 1
    fi
fi

log_info "Running rngtest -c $COUNT < $TMP_BIN"
rngtest -c "$COUNT" < "$TMP_BIN" > "$TMP_OUT" 2>&1

successes=$(awk '/FIPS 140-2 successes:/ {print $NF}' "$TMP_OUT" | head -n1)

if [ -z "$successes" ] || ! echo "$successes" | grep -Eq '^[0-9]+$'; then
    log_fail "rngtest: Could not parse valid success count from output"
    echo "$TESTNAME FAIL" > "$res_file"
    cat "$TMP_OUT"
    rm -f "$TMP_BIN" "$TMP_OUT"
    exit 1
fi

log_info "FIPS 140-2 successes: $successes / $COUNT"
percent=$(awk "BEGIN {printf \"%.2f\", ($successes/$COUNT)*100}")
log_info "Success ratio: $percent%"

if [ "$successes" -ge "$PASS_THRESHOLD" ]; then
    log_pass "$TESTNAME : Test Passed ($successes ≥ $PASS_THRESHOLD successes)"
    echo "$TESTNAME PASS" > "$res_file"
    rm -f "$TMP_BIN" "$TMP_OUT"
    exit 0
else
    log_fail "$TESTNAME : Test Failed ($successes < $PASS_THRESHOLD successes)"
    echo "$TESTNAME FAIL" > "$res_file"
    rm -f "$TMP_BIN" "$TMP_OUT"
    exit 1
fi
