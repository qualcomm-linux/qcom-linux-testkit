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

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

# Set the hardware RNG source to Qualcomm's RNG
if [ -e /sys/class/misc/hw_random/rng_current ]; then
    echo qcom_hwrng > /sys/class/misc/hw_random/rng_current
else
    echo "Path /sys/class/misc/hw_random/rng_current does not exist."
    log_fail "$TESTNAME : Test Failed"
    exit 1
fi

# Verify that qcom_hwrng was successfully set
current_rng=$(cat /sys/class/misc/hw_random/rng_current)
if [ "$current_rng" != "qcom_hwrng" ]; then
    log_info "Error: Failed to set qcom_hwrng as the current RNG source."
    log_fail "$TESTNAME : Test Failed"
    exit 1
else
    log_info "qcom_hwrng successfully set as the current RNG source."
fi

log_info "Checking if dependency binary is available"
check_dependencies rngtest

dd if=/dev/random bs=1 count=1000 | rngtest -c 1000 > ./qcom_hwrng_output.txt 2>&1

grep 'FIPS 140-2 failures' ./qcom_hwrng_output.txt | awk '{print $NF}' > ./rngtest_failures.txt

value=$(cat ./rngtest_failures.txt)

if [ "$value" -lt 10 ]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > $test_path/$TESTNAME.res
    exit 0
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
    exit 1
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"