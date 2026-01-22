#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Validate USB Mass Storage device detection
# Requires at least one USB Mass Storage peripheral (USB flash drive, external HDD/SSD, etc.) connected to a USB Host port.

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

TESTNAME="usb_msd"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

# Check if lsusb is installed
check_dependencies lsusb grep

log_info "=== USB Mass Storage device Detection ==="
# Count interfaces reported as Mass Storage by lsusb -v
msd_iface_count="$(lsusb -v 2>/dev/null | grep -i 'Mass Storage' | wc -l)"

echo "lsusb -v Mass Storage descriptors:"
lsusb -v 2>/dev/null | grep -i 'Mass Storage' || true

echo "Number of Mass Storage interfaces found: $msd_iface_count"

if [ "$msd_iface_count" -gt 0 ]; then
    log_pass "$TESTNAME : Test Passed - USB Mass Storage interface(s) detected"
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
else
    log_fail "$TESTNAME : Test Failed - No 'Mass Storage' interface found"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
