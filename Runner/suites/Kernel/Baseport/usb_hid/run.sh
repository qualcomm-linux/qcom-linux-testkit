#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Validate USB HID device detection
# Requires at least one USB HID peripheral (keyboard/mouse, etc.) connected to a USB Host port.

TESTNAME="usb_hid"

# Robustly find and source init_env
SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"

# Default result file (works even before functestlib is available)
# shellcheck disable=SC2034
RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"

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
	echo "$TESTNAME SKIP" >"$RES_FILE" 2>/dev/null || true
    exit 0
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

# Resolve test path and cd (single SKIP/exit path)
SKIP_REASON=""
test_path=$(find_test_case_by_name "$TESTNAME")
if [ -z "$test_path" ] || [ ! -d "$test_path" ]; then
  SKIP_REASON="$TESTNAME SKIP - test path not found"
elif ! cd "$test_path"; then
  SKIP_REASON="$TESTNAME SKIP - cannot cd into $test_path"
else
  RES_FILE="$test_path/${TESTNAME}.res"
fi

if [ -n "$SKIP_REASON" ]; then
  log_skip "$SKIP_REASON"
  echo "$TESTNAME SKIP" >"$RES_FILE" 2>/dev/null || true
  exit 0
fi

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

# Check if grep is installed, else skip test
deps_list="grep sed sort wc"
if ! check_dependencies "$deps_list"; then
  log_skip "$TESTNAME SKIP - missing dependencies: $deps_list"
  echo "$TESTNAME SKIP" >"$RES_FILE"
  exit 0
fi

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
  done 2>/dev/null | sed 's/:.*$//' | sort -u | wc -l | tr -d '[:space:]'
  )

log_info "Number of HID devices found: $hid_device_count"

if [ "$hid_device_count" -gt 0 ]; then
    log_pass "$TESTNAME : Test Passed - USB HID device(s) detected"
    echo "$TESTNAME PASS" > "$RES_FILE"
    exit 0
else
    log_fail "$TESTNAME : Test Failed - No USB 'Human Interface Device' found"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi
