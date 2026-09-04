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

TESTNAME="USBHost"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
RESULT_DIR="$SCRIPT_DIR/results/$TESTNAME"
USB_DMESG_STRICT="${USB_DMESG_STRICT:-0}"

test_result_init "$TESTNAME" "$RES_FILE" || exit 1

if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: cannot create result directory $RESULT_DIR"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME Testcase"

case "$USB_DMESG_STRICT" in
    0|1)
        ;;
    *)
        log_warn "Invalid USB_DMESG_STRICT='$USB_DMESG_STRICT', using 0"
        USB_DMESG_STRICT=0
        ;;
esac

log_info "Configuration: USB_DMESG_STRICT=$USB_DMESG_STRICT"

if ! CHECK_DEPS_RECOVER=0 CHECK_DEPS_NO_EXIT=1 check_dependencies \
    basename \
    cat \
    find \
    grep \
    mkdir \
    readlink \
    rm \
    tr \
    wc; then
    test_result_finish "SKIP" "$TESTNAME SKIP: required base utilities are unavailable"
fi

usb_collect_host_inventory "$RESULT_DIR"
usb_inventory_status=$?

case "$usb_inventory_status" in
    0)
        test_result_record \
            "PASS" \
            "USB host runtime is healthy: root_hubs=$USB_RUNTIME_ROOT_HUB_COUNT devices=$USB_RUNTIME_DEVICE_COUNT interfaces=$USB_RUNTIME_INTERFACE_COUNT"
        ;;
    1)
        test_result_record \
            "FAIL" \
            "USB host runtime validation failed: ${USB_RUNTIME_FAILURE_REASON:-inconsistent host-controller state}"
        ;;
    2)
        test_result_finish "SKIP" "$TESTNAME SKIP: USB host mode is not active on the current connector"
        ;;
    *)
        test_result_finish "FAIL" "$TESTNAME FAIL: USB host runtime inventory could not complete"
        ;;
esac

if [ "$USB_RUNTIME_DEVICE_COUNT" -gt 0 ]; then
    test_result_record "PASS" "USB host has $USB_RUNTIME_DEVICE_COUNT connected non-root device(s)"
    if [ "$USB_RUNTIME_BOUND_INTERFACE_COUNT" -gt 0 ]; then
        test_result_record "PASS" "USB host has $USB_RUNTIME_BOUND_INTERFACE_COUNT bound interface driver(s)"
    else
        test_result_record "SKIP" "Connected USB devices expose no kernel-bound interfaces, userspace-managed functions may still be valid"
    fi
else
    test_result_record "SKIP" "USB host controller is healthy but no external peripheral is connected"
fi

if command -v lsusb >/dev/null 2>&1; then
    log_info "USB userspace validation: collecting bounded lsusb inventory"
    if lsusb >"$RESULT_DIR/lsusb.log" 2>&1; then
        log_file_with_label "LSUSB" "$RESULT_DIR/lsusb.log"
        test_result_record "PASS" "lsusb completed successfully"
    else
        log_file_with_label "LSUSB" "$RESULT_DIR/lsusb.log"
        test_result_record "FAIL" "lsusb is installed but failed to enumerate the USB bus"
    fi
else
    test_result_record "SKIP" "Optional lsusb utility is not provided by the image"
fi

log_info "USB kernel-health validation: capturing DWC3, xHCI, PHY, and UCSI errors"
scan_dmesg_errors \
    "$RESULT_DIR" \
    'dwc3.*|xhci.*|usb.*|ucsi.*|pmic.gl.*' \
    'deferred probe|EPROBE_DEFER|using dummy regulator|supply [^ ]+ not found'
usb_dmesg_status=$?

if [ ! -s "$RESULT_DIR/dmesg_snapshot.log" ]; then
    test_result_record "SKIP" "Kernel log access is unavailable for USB health validation"
elif [ "$usb_dmesg_status" -eq 0 ] && [ "$USB_DMESG_STRICT" -eq 1 ]; then
    test_result_record "FAIL" "USB controller, PHY, or UCSI errors were found in $RESULT_DIR/dmesg_errors.log"
elif [ "$usb_dmesg_status" -eq 0 ]; then
    test_result_record "SKIP" "USB kernel errors were retained as advisory evidence, set USB_DMESG_STRICT=1 to gate them"
else
    test_result_record "PASS" "No non-benign USB controller, PHY, or UCSI errors were found in the captured kernel log"
fi

test_result_finish
