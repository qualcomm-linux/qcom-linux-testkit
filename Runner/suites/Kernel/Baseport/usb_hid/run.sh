#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Validate USB HID device detection
# Requires at least one USB HID peripheral (keyboard/mouse, etc.) connected to a USB Host port.

# Robustly find and source init_env
SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"
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
	__INIT_ENV_LOADED=1
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="usb_hid"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

# Check if grep is installed, else skip test
deps_list="grep"
check_dependencies "$deps_list"

# Count uniques devices with bInterfaceClass = 03 (HID) under /sys/bus/usb/devices
hid_device_count=0
log_info "=== USB HID device Detection ==="
hid_device_count=$(
  for f in /sys/bus/usb/devices/*/bInterfaceClass; do
    [ -r "$f" ] || continue
    if grep -qx '03' "$f"; then
      d=${f%/bInterfaceClass}     
      echo "${d##*/}"            
    fi
  done | sed 's/:.*$//' | sort -u | wc -l)

echo "$hid_device_count"

log_info "Number of HID devices found: $hid_device_count"

if [ "$hid_device_count" -gt 0 ]; then
    log_pass "$TESTNAME : Test Passed - USB HID device(s) detected"
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
else
    log_fail "$TESTNAME : Test Failed - No USB 'Human Interface Device' found"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
