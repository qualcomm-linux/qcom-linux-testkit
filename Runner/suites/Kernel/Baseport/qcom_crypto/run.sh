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
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="qcom_crypto"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

log_info "Checking if dependency binary is available"
check_dependencies kcapi

# Initialize test status
TEST_PASSED=true

# Encryption Test
log_info "Running encryption test"
ENCRYPT_OUTPUT=$(kcapi -x 1 -e -c "cbc(aes)" \
  -k 8d7dd9b0170ce0b5f2f8e1aa768e01e91da8bfc67fd486d081b28254c99eb423 \
  -i 7fbc02ebf5b93322329df9bfccb635af \
  -p 48981da18e4bb9ef7e2e3162d16b1910 2>&1)

EXPECTED_ENCRYPT="8b19050f66582cb7f7e4b6c873819b71"

if [ "$ENCRYPT_OUTPUT" != "$EXPECTED_ENCRYPT" ]; then
    log_fail "$TESTNAME : Encryption test failed"
    log_info "Expected: $EXPECTED_ENCRYPT"
    log_info "Got     : $ENCRYPT_OUTPUT"
    TEST_PASSED=false
else
    log_pass "Encryption test passed"
fi

# Decryption Test
log_info "Running decryption test"
DECRYPT_OUTPUT=$(kcapi -x 1 -c "cbc(aes)" \
  -k 3023b2418ea59a841757dcf07881b3a8def1c97b659a4dad \
  -i 95aa5b68130be6fcf5cabe7d9f898a41 \
  -q c313c6b50145b69a77b33404cb422598 2>&1)

EXPECTED_DECRYPT="836de0065f9d6f6a3dd2c53cd17e33a5"

if [ "$DECRYPT_OUTPUT" != "$EXPECTED_DECRYPT" ]; then
    log_fail "$TESTNAME : Decryption test failed"
    log_info "Expected: $EXPECTED_DECRYPT"
    log_info "Got     : $DECRYPT_OUTPUT"
    TEST_PASSED=false
else
    log_pass "Decryption test passed"
fi

# HMAC-SHA256 Test
log_info "Running HMAC-SHA256 test"
HMAC_OUTPUT=$(kcapi -x 12 -c "hmac(sha256)" \
  -k 0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b \
  -i 000102030405060708090a0b0c \
  -p f0f1f2f3f4f5f6f7f8f9 \
  -b 42 2>&1)

EXPECTED_HMAC="3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"

if [ "$HMAC_OUTPUT" != "$EXPECTED_HMAC" ]; then
    log_fail "$TESTNAME : HMAC-SHA256 test failed"
    log_info "Expected: $EXPECTED_HMAC"
    log_info "Got     : $HMAC_OUTPUT"
    TEST_PASSED=false
else
    log_pass "HMAC-SHA256 test passed"
fi

# Final Result
if [ "$TEST_PASSED" = true ]; then
    log_pass "$TESTNAME : All tests passed"
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
else
    log_fail "$TESTNAME : One or more tests failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"



