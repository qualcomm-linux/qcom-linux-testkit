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

TESTNAME="fastCV"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"
summary_file="./$TESTNAME.summary"
rm -f "$res_file" "$summary_file"

log_info "-------------------------------------------------"
log_info "----------- Starting $TESTNAME Test -------------"

# Step 1: Resize rootfs
log_info "Resizing rootfs partition..."
resize2fs /dev/disk/by-partlabel/rootfs

# Step 2: Set permissions
log_info "Setting permissions for OpenCV binaries..."
chmod 777 /usr/bin/FastCV/opencv
chmod 777 /usr/bin/opencv*

# Step 3: Install IPK packages
log_info "Installing IPK packages from /usr/bin/FastCV/opencv..."
cd /usr/bin/FastCV/opencv || exit 1
opkg install *.ipk

# Step 4: Run OpenCV test
log_info "Running OpenCV SFM test suite..."
OPENCV_TEST_DATA_PATH=/usr/bin/FastCV/testdata/ /usr/bin/opencv_test_sfm --perf_min_samples=10 --perf_force_samples=10 > test_output.log 2>&1

# Step 5: Validate output
if grep -q "\[  PASSED  \] 19 tests" test_output.log; then
    log_pass "OpenCV test suite passed successfully."
    echo "$TESTNAME PASS" > "$res_file"
    echo "All 19 tests passed." >> "$summary_file"
    exit 0
else
    log_fail "OpenCV test suite failed or incomplete."
    echo "$TESTNAME FAIL" > "$res_file"
    echo "Test output did not match expected results." >> "$summary_file"
    exit 1
fi

log_info "----------- Completed $TESTNAME Test ------------"