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

TESTNAME="usb_msd"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
RESULT_DIR="$SCRIPT_DIR/results/$TESTNAME"

USB_MSD_READ_VERIFY="${USB_MSD_READ_VERIFY:-1}"
USB_MSD_WAIT_SECONDS="${USB_MSD_WAIT_SECONDS:-10}"

usage() {
    cat <<'EOF'
Usage: ./run.sh [options]

Options:
  --read-verify 0|1      Read the first 512 bytes from each block device, default: 1.
  --wait-seconds N       Wait for USB storage block-device creation, default: 10.
  -h, --help             Show this help.

Environment:
  USB_MSD_READ_VERIFY=0|1
  USB_MSD_WAIT_SECONDS=N
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --read-verify)
                [ "$#" -ge 2 ] || return 1
                USB_MSD_READ_VERIFY="$2"
                shift 2
                ;;
            --wait-seconds)
                [ "$#" -ge 2 ] || return 1
                USB_MSD_WAIT_SECONDS="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                return 1
                ;;
        esac
    done
}

parse_args "$@" || {
    usage >&2
    exit 2
}

case "$USB_MSD_READ_VERIFY" in
    0|1)
        ;;
    *)
        log_warn "Invalid USB_MSD_READ_VERIFY='$USB_MSD_READ_VERIFY', using 1"
        USB_MSD_READ_VERIFY=1
        ;;
esac

case "$USB_MSD_WAIT_SECONDS" in
    ''|*[!0-9]*)
        log_warn "Invalid USB_MSD_WAIT_SECONDS='$USB_MSD_WAIT_SECONDS', using 10"
        USB_MSD_WAIT_SECONDS=10
        ;;
esac

test_result_init "$TESTNAME" "$RES_FILE" || exit 1

if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: cannot create result directory $RESULT_DIR"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME Testcase"
log_info "Configuration: read_verify=$USB_MSD_READ_VERIFY wait_seconds=$USB_MSD_WAIT_SECONDS"

if ! CHECK_DEPS_RECOVER=0 CHECK_DEPS_NO_EXIT=1 check_dependencies \
    basename \
    cat \
    dirname \
    grep \
    mkdir \
    readlink \
    sleep \
    tr; then
    test_result_finish "SKIP" "$TESTNAME SKIP: required base utilities are unavailable"
fi

USB_MSD_EFFECTIVE_READ_VERIFY="$USB_MSD_READ_VERIFY"
usb_msd_read_tool_missing=0
if [ "$USB_MSD_READ_VERIFY" -eq 1 ] && ! command -v dd >/dev/null 2>&1; then
    USB_MSD_EFFECTIVE_READ_VERIFY=0
    usb_msd_read_tool_missing=1
fi

usb_validate_mass_storage_runtime \
    "$RESULT_DIR" \
    "$USB_MSD_EFFECTIVE_READ_VERIFY" \
    "$USB_MSD_WAIT_SECONDS"
usb_msd_status=$?

case "$usb_msd_status" in
    0)
        test_result_record \
            "PASS" \
            "All $USB_MSD_DEVICE_COUNT USB mass-storage device(s) passed driver and block-device validation"
        ;;
    1)
        test_result_record \
            "FAIL" \
            "$USB_MSD_FAILURE_COUNT validation failure(s) were found across $USB_MSD_DEVICE_COUNT USB mass-storage device(s)"
        ;;
    2)
        test_result_finish "SKIP" "$TESTNAME SKIP: no USB mass-storage peripheral is connected"
        ;;
    *)
        test_result_finish "FAIL" "$TESTNAME FAIL: USB mass-storage runtime validation could not complete"
        ;;
esac

if [ "$usb_msd_read_tool_missing" -eq 1 ]; then
    test_result_record "SKIP" "USB mass-storage read verification was requested but dd is unavailable"
elif [ "$USB_MSD_READ_VERIFY" -eq 0 ]; then
    test_result_record "SKIP" "USB mass-storage read verification is disabled"
elif [ "$usb_msd_status" -eq 0 ]; then
    test_result_record "PASS" "USB mass-storage read verification completed for every discovered block device"
fi

test_result_finish
