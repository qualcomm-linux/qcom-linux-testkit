#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# ---------- Repo env + helpers ----------
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

# Only source once (idempotent)
# NOTE: We intentionally **do not export** any new vars. They stay local to this shell.
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="usb_hid"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
RESULT_DIR="$SCRIPT_DIR/results/$TESTNAME"

test_result_init "$TESTNAME" "$RES_FILE" || exit 1

if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: cannot create result directory $RESULT_DIR"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME Testcase"

if ! CHECK_DEPS_RECOVER=0 CHECK_DEPS_NO_EXIT=1 check_dependencies \
    basename cat dirname mkdir readlink tr; then
    test_result_finish "SKIP" "$TESTNAME SKIP: required base utilities are unavailable"
fi

usb_validate_hid_runtime "$RESULT_DIR"
usb_hid_status=$?

case "$usb_hid_status" in
    0)
        test_result_record "PASS" "All $USB_HID_INTERFACE_COUNT USB HID interface(s) are driver-bound"
        ;;
    1)
        test_result_record "FAIL" "$USB_HID_UNBOUND_COUNT of $USB_HID_INTERFACE_COUNT USB HID interface(s) have no bound kernel driver"
        ;;
    2)
        test_result_finish "SKIP" "$TESTNAME SKIP: no USB HID peripheral is connected"
        ;;
    *)
        test_result_finish "FAIL" "$TESTNAME FAIL: USB HID runtime validation could not complete"
        ;;
esac

test_result_finish
